require "./spec_helper"
require "file_utils"

private def w237p_minmax_type(function : String, argument : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(function, argument)
end

private def w237p_values(
  type : CrystalClick::BinaryDataType,
  states : Array(Bytes),
) : Array(CrystalClick::BinaryValue)
  states.map { |state| CrystalClick::BinaryValue.aggregate_function_state(type, state) }
end

private def w237p_expect_values!(
  actual : Array(CrystalClick::BinaryValue),
  expected : Array(CrystalClick::BinaryValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    value.type.should eq(expected[index].type)
    value.aggregate_function_state_bytes.should eq(expected[index].aggregate_function_state_bytes) if value.type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
    CrystalClick::BinaryValueCodec.encode(value).should eq(CrystalClick::BinaryValueCodec.encode(expected[index]))
  end
end

private def w237p_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  values : Array(CrystalClick::BinaryValue),
) : String
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
    "v",
    type,
    [values[0, 2], values[2, 2], values[4, 1]],
    rows_per_mark: 2,
    frame_bytes: 64,
  )
end

private def w237p_with_parent(&)
  parent = File.tempname("crystal-click-w237-minmax-part-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w237p_assert_physical_part!(
  type : CrystalClick::BinaryDataType,
  expected : Array(CrystalClick::BinaryValue),
) : Nil
  w237p_with_parent do |parent|
    part = File.join(parent, "all_1_1_0")
    w237p_write_part(part, type, expected).should eq(part)

    reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
    reader.schema_declaration.should eq(type.name)
    reader.source_declaration.should eq(type.name)
    reader.row_count.should eq(5_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    reader.physical_stream_names.sort.should eq(
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "v").stream_names.values.sort
    )
    w237p_expect_values!(reader.read_marks(0, 3).flatten, expected)
    w237p_expect_values!(reader.read_marks(0, 1).first, expected[0, 2])
    w237p_expect_values!(reader.read_marks(1, 1).first, expected[2, 2])
    w237p_expect_values!(reader.read_marks(2, 1).first, expected[4, 1])
    reader.read_marks(3, 0).should be_empty

    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
    table.column_types.should eq([{"pk", "UInt64"}, {"v", type.name}])
    observed = [] of CrystalClick::BinaryValue
    keys = [] of UInt64
    table.scan_typed(batch_rows: 2) do |batch|
      keys.concat(batch.values_for("pk").to_a)
      observed.concat(batch.binary_bulk_values_for("v").to_a)
    end
    keys.should eq([11_u64, 22_u64, 33_u64, 44_u64, 55_u64])
    w237p_expect_values!(observed, expected)

    selected = [] of CrystalClick::BinaryValue
    table.scan_typed_window(2_u64, max_rows: 2) do |batch|
      selected.concat(batch.binary_bulk_values_for("v").to_a)
    end
    w237p_expect_values!(selected, expected[2, 2])
    final = [] of CrystalClick::BinaryValue
    table.scan_typed_window(4_u64, max_rows: 1) do |batch|
      final.concat(batch.binary_bulk_values_for("v").to_a)
    end
    w237p_expect_values!(final, expected[4, 1])
    eof = [] of CrystalClick::BinaryValue
    table.scan_typed_window(5_u64, max_rows: 1) do |batch|
      eof.concat(batch.binary_bulk_values_for("v").to_a)
    end
    eof.should be_empty
  end
  nil
end

describe "W237 AggregateFunction(min/max) variable-state physical parts" do
  it "keeps numeric presence and original-width values distinct for both nominal functions" do
    argument = CrystalClick::BinaryDataType.primitive("UInt8")
    states = [
      Bytes[0x00_u8],
      Bytes[0x01_u8, 0x00_u8],
      Bytes[0x01_u8, 0x01_u8],
      Bytes[0x01_u8, 0xff_u8],
      Bytes[0x01_u8, 0x2a_u8],
    ] of Bytes

    ["min", "max"].each do |function|
      type = w237p_minmax_type(function, argument)
      type.name.should eq("AggregateFunction(#{function}, UInt8)")
      values = w237p_values(type, states)
      values.map(&.aggregate_function_state_bytes).should eq(states)

      streams = CrystalClick::BinaryBulkCodec.encode(type, [values[0, 2], values[2, 2], values[4, 1]])
      streams.roles.should eq(["root.data"])
      streams.stream("root.data").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0xff_u8, 0x01_u8, 0x2a_u8])
      streams.stream("root.data").offsets.should eq([0_u64, 3_u64, 7_u64, 9_u64])
      decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64, 2_u64, 1_u64])
      w237p_expect_values!(decoded.flatten, values)
      w237p_assert_physical_part!(type, values)
    end
  end

  it "preserves String absent, present-empty, and embedded-NUL states across marks" do
    type = w237p_minmax_type("max", CrystalClick::BinaryDataType.primitive("String"))
    type.name.should eq("AggregateFunction(max, String)")
    states = [
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x61_u8, 0x00_u8, 0x62_u8, 0x00_u8],
      Bytes[0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x7a_u8, 0x00_u8],
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
    ] of Bytes
    values = w237p_values(type, states)
    values.map(&.aggregate_function_state_bytes).should eq(states)

    streams = CrystalClick::BinaryBulkCodec.encode(type, [values[0, 2], values[2, 2], values[4, 1]])
    streams.roles.should eq(["root.data"])
    streams.stream("root.data").bytes.should eq(
      Bytes[
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x61_u8, 0x00_u8, 0x62_u8, 0x00_u8,
        0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x7a_u8, 0x00_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      ]
    )
    streams.stream("root.data").offsets.should eq([0_u64, 9_u64, 23_u64, 27_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64, 2_u64, 1_u64])
    w237p_expect_values!(decoded.flatten, values)
    w237p_assert_physical_part!(type, values)
  end

  it "delegates generic Array(Tuple(UInt8,String)) bodies while retaining only opaque state bytes" do
    argument = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.tuple([
        CrystalClick::BinaryDataType.primitive("UInt8"),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType)
    )
    type = w237p_minmax_type("min", argument)
    type.name.should eq("AggregateFunction(min, Array(Tuple(UInt8, String)))")
    states = [
      Bytes[0x00_u8],
      Bytes[0x01_u8, 0x00_u8],
      Bytes[0x01_u8, 0x01_u8, 0x01_u8, 0x00_u8],
      Bytes[0x01_u8, 0x02_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0x02_u8, 0x01_u8, 0x62_u8],
      Bytes[0x01_u8, 0x01_u8, 0xff_u8, 0x01_u8, 0x7a_u8],
    ] of Bytes
    values = w237p_values(type, states)
    values.map(&.aggregate_function_state_bytes).should eq(states)

    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
    plan.stream_names.keys.should eq(["root.data"])
    streams = CrystalClick::BinaryBulkCodec.encode(type, [values[0, 2], values[2, 2], values[4, 1]])
    streams.roles.should eq(["root.data"])
    streams.stream("root.data").bytes.to_a.should eq(states.flat_map { |state| state.to_a })
    streams.stream("root.data").offsets.should eq([0_u64, 3_u64, 15_u64, 20_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64, 2_u64, 1_u64])
    w237p_expect_values!(decoded.flatten, values)
    w237p_assert_physical_part!(type, values)
  end

  it "keeps Nullable outer null-presence distinct from MinMax's inner value presence" do
    argument = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = w237p_minmax_type("max", argument)
    type.name.should eq("AggregateFunction(max, Nullable(UInt8))")
    states = [
      Bytes[0x00_u8],
      Bytes[0x01_u8, 0x01_u8, 0x00_u8],
      Bytes[0x01_u8, 0x01_u8, 0x01_u8],
      Bytes[0x01_u8, 0x01_u8, 0xff_u8],
      Bytes[0x01_u8, 0x01_u8, 0x2a_u8],
    ] of Bytes
    values = w237p_values(type, states)
    values.map(&.aggregate_function_state_bytes).should eq(states)

    streams = CrystalClick::BinaryBulkCodec.encode(type, [values[0, 2], values[2, 2], values[4, 1]])
    streams.roles.should eq(["root.data"])
    streams.stream("root.data").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0x01_u8, 0xff_u8, 0x01_u8, 0x01_u8, 0x2a_u8])
    streams.stream("root.data").offsets.should eq([0_u64, 4_u64, 10_u64, 13_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64, 2_u64, 1_u64])
    w237p_expect_values!(decoded.flatten, values)
    w237p_assert_physical_part!(type, values)
  end

  it "keeps multiple outer Array schedules separate from AggregateFunction argument metadata" do
    min = w237p_minmax_type("min", CrystalClick::BinaryDataType.primitive("UInt8"))
    inner_type = CrystalClick::BinaryDataType.array(min)
    outer_type = CrystalClick::BinaryDataType.array(inner_type)
    state_bytes = [
      Bytes[0x00_u8],
      Bytes[0x01_u8, 0x10_u8],
      Bytes[0x01_u8, 0x20_u8],
      Bytes[0x01_u8, 0x30_u8],
      Bytes[0x01_u8, 0x40_u8],
    ] of Bytes
    states = w237p_values(min, state_bytes)
    inner = ->(children : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(inner_type, children)
    }
    outer = ->(children : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(outer_type, children)
    }
    values = [
      outer.call([
        inner.call([states[0], states[1]] of CrystalClick::BinaryValue),
        inner.call([] of CrystalClick::BinaryValue),
        inner.call([states[2]] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
      outer.call([] of CrystalClick::BinaryValue),
      outer.call([
        inner.call([] of CrystalClick::BinaryValue),
        inner.call([states[3]] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
      outer.call([
        inner.call([states[4], states[0], states[1]] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
      outer.call([
        inner.call([] of CrystalClick::BinaryValue),
        inner.call([] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue

    streams = CrystalClick::BinaryBulkCodec.encode(outer_type, [values[0, 2], values[2, 2], values[4, 1]])
    streams.roles.sort.should eq(["root.elements.elements.data", "root.elements.sizes", "root.sizes"])
    streams.stream("root.elements.elements.data").bytes.should eq(
      Bytes[0x00_u8, 0x01_u8, 0x10_u8, 0x01_u8, 0x20_u8, 0x01_u8, 0x30_u8, 0x01_u8, 0x40_u8, 0x00_u8, 0x01_u8, 0x10_u8]
    )
    streams.stream("root.elements.elements.data").offsets.should eq([0_u64, 5_u64, 12_u64, 12_u64])
    decoded = CrystalClick::BinaryBulkCodec.decode(outer_type, streams, [2_u64, 2_u64, 1_u64])
    decoded.flatten.map { |value| CrystalClick::BinaryValueCodec.encode(value) }.should eq(
      values.map { |value| CrystalClick::BinaryValueCodec.encode(value) }
    )

    w237p_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w237p_write_part(part, outer_type, values).should eq(part)
      reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", outer_type)
      reader.schema_declaration.should eq(outer_type.name)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.physical_stream_names.sort.should eq(
        CrystalClick::BinaryBulkPhysicalPlan.new(outer_type, "v").stream_names.values.sort
      )
      observed = reader.read_marks(0, 3).flatten
      observed.map { |value| CrystalClick::BinaryValueCodec.encode(value) }.should eq(
        values.map { |value| CrystalClick::BinaryValueCodec.encode(value) }
      )
      reader.read_marks(1, 1).flatten.map { |value| CrystalClick::BinaryValueCodec.encode(value) }.should eq(
        values[2, 2].map { |value| CrystalClick::BinaryValueCodec.encode(value) }
      )
      reader.read_marks(3, 0).should be_empty
    end
  end

  it "copies Min/Max state bytes into the owning BinaryValue" do
    type = w237p_minmax_type("min", CrystalClick::BinaryDataType.primitive("UInt16"))
    source = Bytes[0x01_u8, 0x34_u8, 0x12_u8]
    expected = source.dup
    value = CrystalClick::BinaryValue.aggregate_function_state(type, source)
    source.fill(0_u8)
    value.aggregate_function_state_bytes.should eq(expected)
    returned = value.aggregate_function_state_bytes
    returned.fill(0_u8)
    value.aggregate_function_state_bytes.should eq(expected)
  end
end
