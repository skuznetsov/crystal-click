require "./spec_helper"

TABLE_READER_FIXTURE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
TABLE_READER_ROWS    = 17001

class TableReaderSpecStop < Exception
end

def with_table_reader_root(&)
  root = File.tempname("crystal-click-table-reader-spec")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def copy_table_reader_part(root : String, name : String) : String
  path = File.join(root, name)
  FileUtils.cp_r(TABLE_READER_FIXTURE, path)
  path
end

def table_reader_write_u64(file : String, offset : Int, value : UInt64)
  bytes = Bytes.new(8)
  8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  File.open(file, "r+b") do |io|
    io.seek(offset)
    io.write(bytes)
  end
end

describe CrystalClick::WidePartTable do
  it "scans aligned columns in caller order and supports an ordinary Crystal filter" do
    with_table_reader_root do |root|
      part_path = copy_table_reader_part(root, "p-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"])
      table.columns.should eq(["left", "right"])
      table.part_count.should eq(1)
      table.total_row_count.should eq(TABLE_READER_ROWS.to_u64)
      table.checksum_verification.should eq(CrystalClick::ChecksumVerification::SizeChecked)
      CrystalClick::WidePart.open(part_path, "left").mark_row_counts.should eq([8192_u64, 8192_u64, 617_u64])

      selected = Array({UInt64, UInt64}).new
      observed_rows = 0_u64
      mark_rows = 0_u64
      active_mark = -1_i32
      table.scan(batch_rows: 127) do |batch|
        batch.part_index.should eq(0_i32)
        batch.part_name.should eq("p-1_0_0_0")
        batch.part_path.should eq(part_path)
        batch.source_row_offset.should eq(observed_rows)
        batch.part_row_offset.should eq(observed_rows)
        batch.values_for("left").size.should eq(batch.values_for("right").size)
        batch.values_for("left").size.should be <= 127
        if batch.mark_index != active_mark
          batch.mark_index.should eq(active_mark + 1)
          batch.mark_row_offset.should eq(0_u64)
          active_mark = batch.mark_index
          mark_rows = 0_u64
        else
          batch.mark_row_offset.should eq(mark_rows)
        end

        left = batch.values_for("left")
        right = batch.values_for("right")
        left.each_with_index do |value, index|
          expected = observed_rows + index.to_u64
          value.should eq(expected)
          right[index].should eq(expected * 3_u64 + 7_u64)
          selected << {value, right[index]} if value % 2_u64 == 0
        end
        mark_rows += left.size.to_u64
        observed_rows += left.size.to_u64
      end

      observed_rows.should eq(TABLE_READER_ROWS.to_u64)
      active_mark.should eq(2_i32)
      mark_rows.should eq(617_u64)
      selected.should eq((0_u64...TABLE_READER_ROWS.to_u64).select(&.even?).map { |value| {value, value * 3_u64 + 7_u64} })
    end
  end

  it "preserves explicit part order and reports part, mark, and source offsets" do
    with_table_reader_root do |root|
      later_name = copy_table_reader_part(root, "z-2_0_0_0")
      earlier_name = copy_table_reader_part(root, "a-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected([later_name, earlier_name], ["left", "right"])
      seen = 0_u64
      observed = [] of {Int32, String, Int32, UInt64, UInt64, UInt64, Int32}

      table.scan(batch_rows: 300) do |batch|
        batch.source_row_offset.should eq(seen)
        batch.part_row_offset.should eq(seen % TABLE_READER_ROWS.to_u64)
        observed << {
          batch.part_index,
          batch.part_name,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("left").size.to_i32,
        }
        seen += batch.values_for("left").size.to_u64
      end

      seen.should eq((TABLE_READER_ROWS * 2).to_u64)
      observed.first[0].should eq(0_i32)
      observed.first[1].should eq("z-2_0_0_0")
      observed.last[0].should eq(1_i32)
      observed.last[1].should eq("a-1_0_0_0")
      observed.last[5].should eq(TABLE_READER_ROWS.to_u64 + observed.last[4])
      observed.each_cons(2) do |pair|
        left = pair[0]
        right = pair[1]
        right[5].should eq(left[5] + left[6].to_u64)
      end
    end
  end

  it "rejects equal-total but differently segmented selected columns before callbacks" do
    with_table_reader_root do |root|
      part_path = copy_table_reader_part(root, "p-1_0_0_0")
      right = CrystalClick::WidePart.open(part_path, "right")
      table_reader_write_u64(right.mark_path, 16, 8193_u64)
      table_reader_write_u64(right.mark_path, 40, 8191_u64)
      CrystalClick::WidePart.open(part_path, "right").mark_row_counts.should eq([8193_u64, 8191_u64, 617_u64])

      callback_count = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"]).scan do |_batch|
          callback_count += 1
        end
      end
      error.message.not_nil!.should contain("mark row counts")
      callback_count.should eq(0)
    end
  end

  it "preflights every part before any callback and lets callback failures escape unchanged" do
    with_table_reader_root do |root|
      valid = copy_table_reader_part(root, "p-1_0_0_0")
      invalid = copy_table_reader_part(root, "p-2_1_1_0")
      File.write(File.join(invalid, "count.txt"), "invalid\n")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected([valid, invalid], ["left", "right"]).scan do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    with_table_reader_root do |root|
      part_path = copy_table_reader_part(root, "p-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"])
      error = expect_raises(TableReaderSpecStop) do
        table.scan { |_batch| raise TableReaderSpecStop.new("stop at caller") }
      end
      error.message.should eq("stop at caller")
    end
  end

  it "rejects duplicate, empty, malformed, symlinked, and over-bound inputs" do
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WidePartTable.open_selected([] of String, ["left"]) }
    expect_raises(CrystalClick::BoundsError) { CrystalClick::WidePartTable.open_selected(["p-1_0_0_0"], [] of String) }
    expect_raises(CrystalClick::BoundsError) do
      CrystalClick::WidePartTable.open_selected(["p-1_0_0_0"], ["left", "left"])
    end

    with_table_reader_root do |root|
      part_path = copy_table_reader_part(root, "p-1_0_0_0")
      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::WidePartTable.open_selected([part_path, File.join(root, ".", "p-1_0_0_0")], ["left", "right"])
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected([part_path], ["not-present"])
      end
      expect_raises(CrystalClick::BoundsError) { CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"]).scan(batch_rows: 0) { |_| } }
      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::WidePartTable.open_selected([part_path], ["left", "right"]).scan(
          batch_rows: CrystalClick::WidePartTable::MAX_BATCH_ROWS + 1
        ) { |_| }
      end

      link = File.join(root, "p-2_1_1_0")
      File.symlink(part_path, link)
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected([link], ["left", "right"])
      end
    end

    with_table_reader_root do |root|
      lower = copy_table_reader_part(root, "p-1_0_1_0")
      upper = copy_table_reader_part(root, "p-1_1_2_0")
      error = expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::WidePartTable.open_selected([upper, lower], ["left", "right"])
      end
      error.message.not_nil!.should contain("overlap")
    end
  end
end
