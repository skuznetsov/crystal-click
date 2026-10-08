require "./spec_helper"
require "file_utils"

private def w227c_avg_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "avg",
    CrystalClick::BinaryDataType.primitive("UInt8")
  )
end

private def w227c_states(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
  [
    CrystalClick::BinaryValue.aggregate_function_state(
      type,
      Bytes[0x80_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x01_u8]
    ),
    CrystalClick::BinaryValue.aggregate_function_state(
      type,
      Bytes[0x80_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x01_u8]
    ),
    CrystalClick::BinaryValue.aggregate_function_state(
      type,
      Bytes[0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x7f_u8]
    ),
    CrystalClick::BinaryValue.aggregate_function_state(
      type,
      Bytes[0x80_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0x01_u8]
    ),
    CrystalClick::BinaryValue.aggregate_function_state(
      type,
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    ),
  ] of CrystalClick::BinaryValue
end

private def w227c_state_bytes(values : Array(CrystalClick::BinaryValue)) : Array(Bytes)
  values.map(&.aggregate_function_state_bytes)
end

private def w227c_expect_values!(
  actual : Array(CrystalClick::BinaryValue),
  expected : Array(CrystalClick::BinaryValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    value.type.should eq(expected[index].type)
    value.aggregate_function_state_bytes.should eq(expected[index].aggregate_function_state_bytes)
  end
end

private def w227c_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  values : Array(CrystalClick::BinaryValue),
) : String
  marks = [values[0, 2], values[2, 2], values[4, 1]]
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
    "v",
    type,
    marks,
    rows_per_mark: 2,
    frame_bytes: 64,
  )
end

private def w227c_offline_table(
  type_name : String,
  part : String,
) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
  CrystalClick::OfflineTable.new(
    "w227_avg_events",
    "w227-avg-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", type_name),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate,
  )
end

private def w227c_with_parent(&)
  parent = File.tempname("crystal-click-w227-avg-consumer-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w227c_expect_bulk_roundtrip!(
  type : CrystalClick::BinaryDataType,
  rows : Array(CrystalClick::BinaryValue),
) : Nil
  rows_by_mark = [rows]
  streams = CrystalClick::BinaryBulkCodec.encode(type, rows_by_mark)
  restored = CrystalClick::BinaryBulkCodec.decode(type, streams, [rows.size.to_u64])
  restored.size.should eq(1)
  restored.first.size.should eq(rows.size)
  restored.first.each_with_index do |value, index|
    value.type.should eq(type)
    CrystalClick::BinaryValueCodec.encode(value).should eq(
      CrystalClick::BinaryValueCodec.encode(rows[index])
    )
  end
end

describe "W227 AggregateFunction(avg) public consumers" do
  it "keeps opaque raw Avg states exact through paired part reads, typed batches, and owned values" do
    type = w227c_avg_type
    type.name.should eq("AggregateFunction(avg, UInt8)")
    expected = w227c_states(type)
    expected_bytes = w227c_state_bytes(expected)
    expected_bytes.map(&.size).should eq([10, 10, 9, 10, 9])

    w227c_with_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w227c_write_part(part, type, expected).should eq(part)

      reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
      reader.schema_declaration.should eq(type.name)
      reader.row_count.should eq(5_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      w227c_expect_values!(reader.read_marks(0, 3).flatten, expected)
      w227c_expect_values!(reader.read_marks(0, 1).first, expected[0, 2])
      w227c_expect_values!(reader.read_marks(1, 1).first, expected[2, 2])
      w227c_expect_values!(reader.read_marks(2, 1).first, expected[4, 1])
      reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      table.column_types.should eq([{"pk", "UInt64"}, {"v", type.name}])
      observed = [] of CrystalClick::BinaryValue
      observed_keys = [] of UInt64
      table.scan_typed(batch_rows: 2) do |batch|
        values = batch.binary_bulk_values_for("v")
        values.size.should eq(batch.values_for("pk").size)
        values.each do |value|
          value.type.should eq(type)
          observed << value
        end
        observed_keys.concat(batch.values_for("pk").to_a)
      end
      w227c_expect_values!(observed, expected)
      observed_keys.should eq([11_u64, 22_u64, 33_u64, 44_u64, 55_u64])

      # Rows 0-1 carry two-byte denominators; row 2's one-byte denominator
      # must still be selected at its correct row boundary.
      selected = [] of CrystalClick::BinaryValue
      table.scan_typed_window(2_u64, max_rows: 1) do |batch|
        selected.concat(batch.binary_bulk_values_for("v").to_a)
      end
      w227c_expect_values!(selected, expected[2, 1])

      offline = w227c_offline_table(type.name, part)
      owned = offline["v"].values(max_rows: 5_u64).map do |value|
        value.as(CrystalClick::BinaryValue)
      end
      w227c_expect_values!(owned, expected)
      copy = owned[0].aggregate_function_state_bytes
      copy.fill(0_u8)
      owned[0].aggregate_function_state_bytes.should eq(expected_bytes[0])
    end
  end

  it "uses the same Avg leaf in Array, Tuple, Map, Variant, and generic Dynamic bulk paths" do
    avg = w227c_avg_type
    states = w227c_states(avg)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")

    array_type = CrystalClick::BinaryDataType.array(avg)
    w227c_expect_bulk_roundtrip!(array_type, [
      CrystalClick::BinaryValue.array(array_type, [states[0], states[1]] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [states[2]] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)

    tuple_type = CrystalClick::BinaryDataType.tuple([avg, uint8] of CrystalClick::BinaryDataType)
    tuple_rows = [
      CrystalClick::BinaryValue.tuple(tuple_type, [states[0], CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])]),
      CrystalClick::BinaryValue.tuple(tuple_type, [states[2], CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8])]),
    ] of CrystalClick::BinaryValue
    w227c_expect_bulk_roundtrip!(tuple_type, tuple_rows)

    map_type = CrystalClick::BinaryDataType.map(uint8, avg)
    map_rows = [
      CrystalClick::BinaryValue.map(map_type, [
        CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8]), states[0],
        CrystalClick::BinaryValue.fixed(uint8, Bytes[2_u8]), states[1],
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(map_type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    w227c_expect_bulk_roundtrip!(map_type, map_rows)

    variant_type = CrystalClick::BinaryDataType.variant([string, avg] of CrystalClick::BinaryDataType)
    avg_arm = variant_type.children.index { |child| child == avg }.not_nil!.to_u8
    variant_rows = [
      CrystalClick::BinaryValue.variant(variant_type, avg_arm, states[0]),
      CrystalClick::BinaryValue.variant_null(variant_type),
      CrystalClick::BinaryValue.variant(variant_type, avg_arm, states[2]),
    ] of CrystalClick::BinaryValue
    w227c_expect_bulk_roundtrip!(variant_type, variant_rows)

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    dynamic_rows = states.map do |state|
      CrystalClick::BinaryValue.dynamic(dynamic, state)
    end
    structures = {"root" => CrystalClick::DynamicStructure.new([avg] of CrystalClick::BinaryDataType)}
    dynamic_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      structures,
      [dynamic_rows] of Array(CrystalClick::BinaryValue),
    )
    dynamic_restored = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic,
      dynamic_streams,
      [dynamic_rows.size.to_u64],
    )
    dynamic_restored.first.each_with_index do |value, index|
      value.type.should eq(dynamic)
      value.child_at(0).type.should eq(avg)
      value.child_at(0).aggregate_function_state_bytes.should eq(states[index].aggregate_function_state_bytes)
    end

    shared_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    shared_rows = states.map do |state|
      CrystalClick::BinaryValue.dynamic(shared_dynamic, state)
    end
    shared_structures = {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    shared_streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      shared_dynamic,
      shared_structures,
      [shared_rows] of Array(CrystalClick::BinaryValue),
    )
    shared_restored = CrystalClick::BinaryDynamicBulkCodec.decode(
      shared_dynamic,
      shared_streams,
      [shared_rows.size.to_u64],
    )
    shared_restored.first.each_with_index do |value, index|
      value.type.should eq(shared_dynamic)
      value.child_at(0).type.should eq(avg)
      value.child_at(0).aggregate_function_state_bytes.should eq(states[index].aggregate_function_state_bytes)
    end

    nullable_avg = CrystalClick::BinaryDataType.aggregate_function(
      "avg",
      CrystalClick::BinaryDataType.nullable(uint8),
    )
    tuple_with_nullable_avg = CrystalClick::BinaryDataType.tuple(
      [nullable_avg] of CrystalClick::BinaryDataType,
    )
    tuple_default = CrystalClick::BinaryBulkDefaultValue.build(tuple_with_nullable_avg)
    tuple_default.child_at(0).aggregate_function_state_bytes.should eq(Bytes[0_u8])
    w227c_expect_bulk_roundtrip!(
      tuple_with_nullable_avg,
      [tuple_default] of CrystalClick::BinaryValue,
    )
  end

  it "keeps JSON typed paths and the unbound shared Dynamic helper closed over Avg" do
    avg = w227c_avg_type
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"state" => avg})
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    value = CrystalClick::BinaryValue.dynamic(dynamic, w227c_states(avg).first)
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(value, budget, 1)
    end
  end
end
