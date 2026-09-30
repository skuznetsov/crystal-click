require "./spec_helper"

private def w95_table_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w95_table_write_part(
  parent : String,
  label : String,
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32 = 2,
  part_name : String = "all_1_1_0",
) : String
  row_count = columns.first?.try(&.size) || 0
  keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
  container = File.join(parent, label)
  Dir.mkdir(container)
  destination = File.join(container, part_name)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w95_table_tuple_type(columns),
    columns,
    rows_per_mark: rows_per_mark
  )
  destination
end

private def w95_table_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w95_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w95_table_shift_later_child_schedule(part : String, stream : String) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  # Preserve key and reference-child schedules. The selected non-reference
  # child still has the same total rows, but marks 1 and 2 disagree (1 + 3).
  w95_table_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
  w95_table_write_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
  File.write(path, marks)
end

private def w95_table_corrupt_mark_frame_header(part : String, stream : String, mark_index : Int) : Nil
  marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w95_table_read_u64(marks, mark_offset).to_i
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  data = File.read(data_path).to_slice.dup
  header_offset = compressed_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5
  raise "W95 frame-header corruption target is out of bounds" if compressed_offset < 0 || header_offset > data.size - 4
  4.times { |index| data[header_offset + index] = 0_u8 }
  File.write(data_path, data)
end

class CrystalClick::WidePartTable
  # Spec-only access to the adapter's checked arithmetic; this avoids a huge
  # near-limit fixture while exercising both the aggregate cap and overflow.
  def self.w95_test_tuple_table_charge(column_charge : UInt64, rows : UInt64, max_bytes : UInt64) : UInt64
    TupleColumnAdapter.checked_total_charge(column_charge, rows, max_bytes)
  end
end

describe "W95 compositional Tuple table rows" do
  it "scans mixed leaf arities in declared order and preserves owned copied rows" do
    profiles = [] of Tuple(String, Array(CrystalClick::WideTupleLeafColumn))
    profiles << {"one", [
      CrystalClick::WideTupleLeafColumn.new("only", [1_u64, 3_u64, UInt64::MAX, 7_u64, 9_u64]),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"two", [
      CrystalClick::WideTupleLeafColumn.new("text", ["", "é", String.new(Bytes[0xff_u8, 0_u8]), "", "last"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [8_u64, 9_u64, 10_u64, 11_u64, 12_u64]),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"three", [
      CrystalClick::WideTupleLeafColumn.new("first", ["", "", "", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("middle", ["a", "", "b\0c", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("last", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"nine", [
      CrystalClick::WideTupleLeafColumn.new("a", [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]),
      CrystalClick::WideTupleLeafColumn.new("b", ["", "b", "", "d", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("c", ["c", "", "", "", "e"] of String),
      CrystalClick::WideTupleLeafColumn.new("d", [5_u64, 6_u64, 7_u64, 8_u64, 9_u64]),
      CrystalClick::WideTupleLeafColumn.new("e", ["", "", "i", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("f", [10_u64, 11_u64, 12_u64, 13_u64, 14_u64]),
      CrystalClick::WideTupleLeafColumn.new("g", ["g", "", "", "h", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("h", [15_u64, 16_u64, 17_u64, 18_u64, 19_u64]),
      CrystalClick::WideTupleLeafColumn.new("i", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}

    parent = File.tempname("crystal-click-w95-table-profiles")
    Dir.mkdir(parent)
    begin
      profiles.each do |label, columns|
        part = w95_table_write_part(parent, label, columns)
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        observed = 0
        retained = [] of CrystalClick::WideTupleRow
        table.scan_typed(batch_rows: 1) do |batch|
          rows = batch.tuple_rows_for("payload")
          rows.size.should eq(1)
          row = rows[0]
          row.type_name.should eq(w95_table_tuple_type(columns))
          row.field_count.should eq(columns.size)
          row.fields.map { |field| {field.name, field.type_name} }.should eq(
            columns.map { |column| {column.name, column.type_name} }
          )
          row_index = batch.source_row_offset.to_i
          columns.each do |column|
            if column.type_name == "UInt64"
              row[column.name].should eq(column.uint64_values[row_index])
            else
              row[column.name].should eq(column.string_values[row_index])
            end
          end
          retained << row if observed == 0
          observed += rows.size
          nil
        end
        observed.should eq(5)
        retained.size.should eq(1)
        if columns.any? { |column| column.type_name == "String" }
          string_field = columns.find { |column| column.type_name == "String" }.not_nil!
          retained[0][string_field.name].should eq(string_field.string_values[0])
        else
          retained[0][columns.first.name].should eq(columns.first.uint64_values[0])
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_typed do |batch|
            batch.tuples_for("payload")
            nil
          end
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves the legacy exact-pair accessor and rejects row API mixing" do
    values = [
      CrystalClick::WideTupleLeafColumn.new("a", [1_u64, 2_u64, 3_u64]),
      CrystalClick::WideTupleLeafColumn.new("b", ["x", "", "z"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w95-table-exact-pair")
    Dir.mkdir(parent)
    begin
      part = w95_table_write_part(parent, "exact-pair", values, 2)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed = [] of Tuple(UInt64, String)
      table.scan_typed do |batch|
        observed.concat(batch.tuples_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.tuple_rows_for("payload") }
        nil
      end
      observed.should eq([{1_u64, "x"}, {2_u64, ""}, {3_u64, "z"}] of Tuple(UInt64, String))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "supports full, window, and sparse candidate selection" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("text", ["r0", "r1", "r2", "r3", "r4"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]),
      CrystalClick::WideTupleLeafColumn.new("tail", ["", "t1", "t2", "", "t4"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w95-table-selection")
    Dir.mkdir(parent)
    begin
      part = w95_table_write_part(parent, "selection", columns)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

      window_rows = [] of Tuple(UInt64, String)
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.tuple_rows_for("payload").each do |row|
          window_rows << {row["number"].as(UInt64), row["text"].as(String)}
        end
        nil
      end
      window_rows.should eq([{1_u64, "r1"}, {2_u64, "r2"}, {3_u64, "r3"}])

      candidate_rows = [] of UInt64
      table.scan_typed_candidate_marks([[0_i32, 2_i32]]) do |batch|
        batch.tuple_rows_for("payload").each do |row|
          candidate_rows << row["number"].as(UInt64)
        end
        nil
      end
      candidate_rows.should eq([0_u64, 1_u64, 4_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a malformed child schedule while opening the selected table" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("reference", ["a", "b", "c", "d", "e", "f"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64]),
      CrystalClick::WideTupleLeafColumn.new("tail", ["u", "v", "w", "x", "y", "z"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w95-table-schedule")
    Dir.mkdir(parent)
    begin
      valid_part = w95_table_write_part(parent, "valid", columns)
      malformed_container = File.join(parent, "malformed")
      Dir.mkdir(malformed_container)
      malformed_part = File.join(malformed_container, "all_2_2_0")
      FileUtils.cp_r(valid_part, malformed_part)
      w95_table_shift_later_child_schedule(malformed_part, "payload%2Etail.size")

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "selected substreams have different mark row counts") do
        table = CrystalClick::WidePartTable.open_selected_typed([malformed_part], ["pk", "payload"])
        table.scan_typed do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps later payload decoding lazy and stops after a callback exception" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("text", ["first", "second", "third"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [0_u64, 1_u64, 2_u64]),
      CrystalClick::WideTupleLeafColumn.new("tail", ["a", "b", "c"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w95-table-lazy")
    Dir.mkdir(parent)
    begin
      part = w95_table_write_part(parent, "lazy", columns, 1)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      w95_table_corrupt_mark_frame_header(part, "payload%2Etext", 1)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed do |batch|
          batch.tuple_rows_for("payload")[0]["number"].should eq(0_u64)
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(1)

      valid_part = w95_table_write_part(parent, "valid-callback", columns, 1)
      valid_table = CrystalClick::WidePartTable.open_selected_typed([valid_part], ["pk", "payload"])
      callbacks = 0
      expect_raises(Exception, "stop after first callback") do
        valid_table.scan_typed_candidate_marks([[0_i32, 1_i32]]) do |_batch|
          callbacks += 1
          raise "stop after first callback"
        end
      end
      callbacks.should eq(1)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects incompatible later Tuple schemas before callbacks" do
    first_columns = [
      CrystalClick::WideTupleLeafColumn.new("a", [1_u64, 2_u64]),
      CrystalClick::WideTupleLeafColumn.new("b", ["x", "y"] of String),
      CrystalClick::WideTupleLeafColumn.new("c", ["z", "w"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    second_columns = [
      CrystalClick::WideTupleLeafColumn.new("a", [1_u64, 2_u64]),
      CrystalClick::WideTupleLeafColumn.new("c", ["z", "w"] of String),
      CrystalClick::WideTupleLeafColumn.new("b", ["x", "y"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w95-table-schema")
    Dir.mkdir(parent)
    begin
      first = w95_table_write_part(parent, "first", first_columns)
      second = w95_table_write_part(parent, "second", second_columns, part_name: "all_2_2_0")
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "selected columns have different types across parts") do
        table = CrystalClick::WidePartTable.open_selected_typed([first, second], ["pk", "payload"])
        table.scan_typed do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "uses checked combined-charge arithmetic including row-array overhead" do
    row_bytes = sizeof(CrystalClick::WideTupleRow).to_u64
    column_charge = 100_u64
    rows = 3_u64
    total = column_charge + 64_u64 + rows * row_bytes
    CrystalClick::WidePartTable.w95_test_tuple_table_charge(column_charge, rows, total).should eq(total)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePartTable.w95_test_tuple_table_charge(column_charge, rows, total - 1_u64)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePartTable.w95_test_tuple_table_charge(UInt64::MAX, 1_u64, UInt64::MAX)
    end
    expect_raises(CrystalClick::CorruptPartError, "Tuple table materialization charge overflows") do
      CrystalClick::WidePartTable.w95_test_tuple_table_charge(0_u64, UInt64::MAX, UInt64::MAX)
    end
  end
end
