require "./spec_helper"
require "file_utils"

private def w107r_write_part(
  parent : String,
  label : String,
  type_name : String,
  row_sizes : Array(UInt64),
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32 = 1,
) : String
  container = File.join(parent, label)
  Dir.mkdir(container)
  destination = File.join(container, "all_1_1_0")
  keys = Array(UInt64).new(row_sizes.size) { |index| (index + 10).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size),
    columns,
    rows_per_mark
  )
end

private def w107r_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w107r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w107r_shift_later_string_boundary(part : String, type_name : String, leaf_name : String, mark_index : Int32) : Nil
  plan = CrystalClick::WideArrayTupleTypePlan.for_type(type_name) || raise "invalid W107 Array(Tuple) type"
  field = plan.tuple_plan.fields.find { |candidate| candidate.name == leaf_name } || raise "missing W107 leaf"
  stream = plan.leaf_stream_name("payload", field)
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index.to_i * CrystalClick::WidePart::MARK_SIZE + 8
  w107r_write_u64(marks, offset, w107r_u64(marks, offset) + 1_u64)
  File.write(mark_path, marks)
end

describe CrystalClick::WidePart do
  it "retains ragged outer rows, nested Nullable values, and detached schedule exports" do
    parent = File.tempname("crystal-click-array-tuple-w107-reader-ragged")
    Dir.mkdir(parent)
    type_name = "Array(Tuple(id UInt64, details Tuple(note Nullable(String), score UInt64)))"
    null_map = CrystalClick::ScalarNullMap.new(Bytes[0_u8, 1_u8, 0_u8], 3_u64)
    columns = [
      CrystalClick::WideTupleLeafColumn.new("id", [101_u64, 102_u64, 103_u64] of UInt64),
      CrystalClick::WideTupleLeafColumn.new(
        "details.note",
        CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!,
        ["alpha", "hidden", "omega"] of String,
        null_map
      ),
      CrystalClick::WideTupleLeafColumn.new("details.score", [7_u64, 8_u64, 9_u64] of UInt64),
    ] of CrystalClick::WideTupleLeafColumn
    sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]

    begin
      part_path = w107r_write_part(parent, "ragged", type_name, sizes, columns, 2)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      data = reader.read_array_tuple_mark_range("payload", 0, reader.mark_count)

      data.type_name.should eq(type_name)
      data.row_count.should eq(5)
      data.element_count.should eq(3)
      data.row_sizes.should eq(sizes)
      data.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])
      data.row(0).size.should eq(0)
      data.row(1).size.should eq(2)
      data.row(2).size.should eq(0)
      data.row(3).size.should eq(1)
      data.row(4).size.should eq(0)

      first_element = data.row(1)[0]
      first_element["id"].should eq(101_u64)
      first_element.tuple("details")["note"].should eq("alpha")
      first_element.tuple("details").value_as("score", UInt64).should eq(7_u64)
      hidden_element = data.row(1)[1]
      hidden_element["id"].should eq(102_u64)
      hidden_element.tuple("details")["note"].should be_nil
      hidden_element["details.note"].should be_nil
      data.tuple_data["details.note"].physical_values.as(Array(String)).should eq(["alpha", "hidden", "omega"])
      data.tuple_data["details.note"].null_map.not_nil!.bytes.should eq([0_u8, 1_u8, 0_u8])
      data.row(3)[0].tuple("details")["note"].should eq("omega")

      detached_sizes = data.row_sizes
      detached_sizes[1] = 99_u64
      data.row_sizes.should eq(sizes)
      detached_offsets = data.offsets
      detached_offsets[1] = 99_u64
      data.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])

      selected = reader.read_array_tuple_mark_range("payload", 1, 1)
      selected.row_sizes.should eq([0_u64, 1_u64])
      selected.row(1)[0]["id"].should eq(103_u64)
      mark_indexes = [] of Int32
      mark_rows = [] of Int32
      reader.each_array_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
        mark_indexes << mark_index
        mark_rows << mark_data.row_count
        nil
      end
      mark_indexes.should eq([0_i32, 1_i32, 2_i32])
      mark_rows.should eq([2_i32, 2_i32, 1_i32])

      expect_raises(CrystalClick::BoundsError) { data.row(-1) }
      expect_raises(CrystalClick::BoundsError) { data.row(data.row_count) }
      expect_raises(CrystalClick::BoundsError) { data.row(0)[-1] }
      expect_raises(CrystalClick::BoundsError) { data.row(0)[0] }
      expect_raises(CrystalClick::BoundsError) { reader.read_array_tuple_mark_range("payload", Int64::MAX, 1) }
      expect_raises(CrystalClick::BoundsError) { reader.read_array_tuple_mark_range("payload", 0, Int64::MAX) }
      expect_raises(CrystalClick::BoundsError) { reader.read_array_tuple_mark_range("payload", Int128::MAX, 1) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts all-empty rows without inventing flattened elements" do
    parent = File.tempname("crystal-click-array-tuple-w107-reader-empty")
    Dir.mkdir(parent)
    type_name = "Array(Tuple(v UInt64))"
    columns = [CrystalClick::WideTupleLeafColumn.new("v", [] of UInt64)] of CrystalClick::WideTupleLeafColumn
    begin
      part_path = w107r_write_part(parent, "empty", type_name, [0_u64, 0_u64, 0_u64], columns, 1)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      data = reader.read_array_tuple_mark_range("payload", 0, reader.mark_count)
      data.row_count.should eq(3)
      data.element_count.should eq(0)
      data.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])
      data.row_sizes.should eq([0_u64, 0_u64, 0_u64])
      data.row(0).each { |_row| fail "empty Array(Tuple) row yielded an element" }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "validates a shifted later String boundary before the first callback" do
    parent = File.tempname("crystal-click-array-tuple-w107-reader-boundary")
    Dir.mkdir(parent)
    type_name = "Array(Tuple(note String))"
    columns = [CrystalClick::WideTupleLeafColumn.new("note", ["a", "bc", "d"] of String)] of CrystalClick::WideTupleLeafColumn
    begin
      part_path = w107r_write_part(parent, "boundary", type_name, [1_u64, 1_u64, 1_u64], columns, 1)
      w107r_shift_later_string_boundary(part_path, type_name, "note", 2)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader.each_array_tuple_mark_range("payload", 0, 3) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges lazy streaming as schedule plus one mark while full-range materialization remains cumulative" do
    parent = File.tempname("crystal-click-array-tuple-w107-reader-lazy-budget")
    Dir.mkdir(parent)
    type_name = "Array(Tuple(note String))"
    large = "x" * 2048
    columns = [CrystalClick::WideTupleLeafColumn.new("note", [large, large, large, large] of String)] of CrystalClick::WideTupleLeafColumn
    begin
      part_path = w107r_write_part(parent, "lazy", type_name, [1_u64, 1_u64, 1_u64, 1_u64], columns, 1)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      limit = 4096_u64
      seen = [] of Int32
      reader.each_array_tuple_mark_range("payload", 0, 4, limit) do |mark_data, mark_index|
        mark_data.row_count.should eq(1)
        mark_data.element_count.should eq(1)
        seen << mark_index
        nil
      end
      seen.should eq([0_i32, 1_i32, 2_i32, 3_i32])
      expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
        reader.read_array_tuple_mark_range("payload", 0, 4, limit)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
