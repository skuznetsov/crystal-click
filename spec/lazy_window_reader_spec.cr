require "./spec_helper"

LAZY_WINDOW_NUMERIC_FIXTURE         = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
LAZY_WINDOW_STRING_FIXTURE          = File.expand_path("../test/fixtures/public/wide_string_nullable/part", __DIR__)
LAZY_WINDOW_NULLABLE_STRING_FIXTURE = File.expand_path("../test/fixtures/public/wide_nullable_string/part", __DIR__)
LAZY_WINDOW_NUMERIC_ROWS            = 17_001

class LazyWindowSpecStop < Exception
end

def with_lazy_window_root(&)
  root = File.tempname("crystal-click-lazy-window-spec")
  FileUtils.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def copy_lazy_window_part(root : String, fixture : String, name : String) : String
  path = File.join(root, name)
  FileUtils.cp_r(fixture, path)
  path
end

def lazy_window_stream_path(part_path : String, column : String, extension : String = "bin") : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(column)}.#{extension}")
end

def corrupt_lazy_window_first_frame(part_path : String, column : String) : Nil
  File.open(lazy_window_stream_path(part_path, column), "r+b") do |io|
    io.seek(16)
    io.write_byte(0_u8)
  end
end

describe CrystalClick::WidePartTable do
  it "crops an intra-mark window and a window crossing marks with exact provenance" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "p-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["left", "right"])
      batches = [] of {Int32, UInt64, UInt64, UInt64, Array(UInt64), Array(UInt64)}

      table.scan_typed_window(8_190_u64, 5) do |batch|
        left = batch.values_for("left", UInt64)
        right = batch.values_for("right", UInt64)
        batches << {
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          left.to_a,
          right.to_a,
        }
      end

      batches.should eq([
        {0_i32, 8_190_u64, 8_190_u64, 8_190_u64, [8_190_u64, 8_191_u64], [24_577_u64, 24_580_u64]},
        {1_i32, 0_u64, 8_192_u64, 8_192_u64, [8_192_u64, 8_193_u64, 8_194_u64], [24_583_u64, 24_586_u64, 24_589_u64]},
      ])
    end
  end

  it "crosses caller-ordered parts without duplicating rows and reports source offsets" do
    with_lazy_window_root do |root|
      later = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "z-2_0_0_0")
      earlier = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "a-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected_typed([later, earlier], ["left"])
      observed = [] of {Int32, String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}

      table.scan_typed_window((LAZY_WINDOW_NUMERIC_ROWS - 2).to_u64, 4) do |batch|
        observed << {
          batch.part_index,
          batch.part_name,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("left", UInt64).to_a,
        }
      end

      observed.should eq([
        {0_i32, "z-2_0_0_0", 2_i32, 615_u64, 16_999_u64, 16_999_u64, [16_999_u64, 17_000_u64]},
        {1_i32, "a-1_0_0_0", 0_i32, 0_u64, 0_u64, 17_001_u64, [0_u64, 1_u64]},
      ])
    end
  end

  it "matches String and Nullable values, including embedded NUL, for a cropped window" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_STRING_FIXTURE, "all_1_1_0")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["label", "maybe_u64"])
      observed = [] of {Int32, UInt64, UInt64, String, UInt64?}

      table.scan_typed_window(1_u64, 3) do |batch|
        batch.strings_for("label").each_with_index do |label, index|
          observed << {
            batch.mark_index,
            batch.mark_row_offset + index.to_u64,
            batch.part_row_offset + index.to_u64,
            label.dup,
            batch.nullable_values_for("maybe_u64", UInt64)[index],
          }
        end
      end

      observed.should eq([
        {0_i32, 1_u64, 1_u64, "alpha", nil},
        {1_i32, 0_u64, 2_u64, "a\0b", UInt64::MAX},
        {1_i32, 1_u64, 3_u64, "tail", 7_u64},
      ])
    end
  end

  it "crops Nullable(String) across marks without losing NULL or embedded NUL" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_NULLABLE_STRING_FIXTURE, "all_1_1_0")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["seq", "payload"])
      observed = [] of {UInt64, String?}

      table.scan_typed_window(4_u64, 4) do |batch|
        seq = batch.values_for("seq", UInt64)
        payload = batch.nullable_strings_for("payload")
        seq.each_with_index { |value, index| observed << {value, payload[index]} }
      end

      observed.should eq([
        {5_u64, "a\0b"},
        {6_u64, "z"},
        {7_u64, nil},
        {8_u64, "Q\0R"},
      ])
    end
  end

  it "returns the last row, emits nothing at EOF, and rejects invalid windows before callbacks" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "p-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["left"])
      last_row = [] of UInt64
      table.scan_typed_window(table.total_row_count - 1_u64, 10) do |batch|
        last_row.concat(batch.values_for("left", UInt64).to_a)
      end
      last_row.should eq([17_000_u64])

      callbacks = 0
      table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
      callbacks.should eq(0)

      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(table.total_row_count + 1_u64, 1) { |_batch| callbacks += 1 }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(UInt64::MAX, CrystalClick::WidePartTable::MAX_BATCH_ROWS) { |_batch| callbacks += 1 }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(0_u64, 0) { |_batch| callbacks += 1 }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(0_u64, -1) { |_batch| callbacks += 1 }
      end
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(0_u64, CrystalClick::WidePartTable::MAX_BATCH_ROWS + 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "lets the original callback exception escape unchanged" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "p-1_0_0_0")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["left"])
      error = expect_raises(LazyWindowSpecStop) do
        table.scan_typed_window(1_u64, 2) { |_batch| raise LazyWindowSpecStop.new("stop at caller") }
      end
      error.message.should eq("stop at caller")
    end
  end

  it "skips corrupt payload in a disjoint mark and rejects it when selected" do
    with_lazy_window_root do |root|
      part_path = copy_lazy_window_part(root, LAZY_WINDOW_NUMERIC_FIXTURE, "p-1_0_0_0")
      corrupt_lazy_window_first_frame(part_path, "left")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["left"])

      later_values = [] of UInt64
      table.scan_typed_window(8_192_u64, 1) do |batch|
        later_values.concat(batch.values_for("left", UInt64).to_a)
      end
      later_values.should eq([8_192_u64])

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed_window(0_u64, 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end
end
