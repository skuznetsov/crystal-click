require "./spec_helper"
require "file_utils"

private def w224p_type(source : String) : CrystalClick::BinaryDataType
  parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
  parsed.should_not be_nil
  parsed || CrystalClick::BinaryDataType.primitive("UInt8")
end

private def w224p_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w224p_varuint_bytes(value : UInt64) : Bytes
  buffer = Bytes.new(10, 0_u8)
  remaining = value
  count = 0
  loop do
    byte = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    byte |= 0x80_u8 unless remaining == 0_u64
    buffer[count] = byte
    count += 1
    break if remaining == 0_u64
  end
  Bytes.new(count) { |index| buffer[index] }
end

private def w224p_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.size.times { |index| result[offset + index] = part[index] }
    offset += part.size
  end
  result
end

private def w224p_state(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  if type.aggregate_count_type
    CrystalClick::BinaryValue.aggregate_count_state(type, value)
  else
    CrystalClick::BinaryValue.aggregate_function_state(type, w224p_u64_bytes(value))
  end
end

private def w224p_tuple(
  type : CrystalClick::BinaryDataType,
  count : UInt64,
  sum : UInt64,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    type,
    [w224p_state(type.child_at(0), count), w224p_state(type.child_at(1), sum)]
  )
end

private def w224p_rows(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
  case type.name
  when "AggregateFunction(sum, UInt8)"
    [1_u64, 7_u64, 255_u64, 256_u64, 17_u64].map { |value| w224p_state(type, value) }
  when "Array(AggregateFunction(sum, UInt8))"
    element_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.array(type, [w224p_state(element_type, 1_u64), w224p_state(element_type, 7_u64)]),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [w224p_state(element_type, 255_u64)]),
      CrystalClick::BinaryValue.array(type, [
        w224p_state(element_type, 0_u64),
        w224p_state(element_type, 256_u64),
        w224p_state(element_type, 17_u64),
      ]),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  when "Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))"
    [
      w224p_tuple(type, 0_u64, 1_u64),
      w224p_tuple(type, 127_u64, 7_u64),
      w224p_tuple(type, 128_u64, 9_u64),
      w224p_tuple(type, 16_384_u64, 11_u64),
      w224p_tuple(type, UInt64::MAX, 13_u64),
    ] of CrystalClick::BinaryValue
  when "Map(UInt8, AggregateFunction(count))"
    key_type = type.child_at(0)
    count_type = type.child_at(1)
    [
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[3_u8]),
        w224p_state(count_type, 0_u64),
      ]),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[4_u8]),
        w224p_state(count_type, 128_u64),
        CrystalClick::BinaryValue.fixed(key_type, Bytes[5_u8]),
        w224p_state(count_type, 16_384_u64),
      ]),
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[9_u8]),
        w224p_state(count_type, UInt64::MAX),
      ]),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  when "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))"
    tuple_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, w224p_tuple(tuple_type, 7_u64, 9_u64)),
      CrystalClick::BinaryValue.nullable(type, w224p_tuple(tuple_type, 128_u64, 11_u64)),
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, w224p_tuple(tuple_type, 16_384_u64, 13_u64)),
    ] of CrystalClick::BinaryValue
  when "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))"
    tuple_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.nested(type, [
        w224p_tuple(tuple_type, 0_u64, 1_u64),
        w224p_tuple(tuple_type, 127_u64, 7_u64),
      ]),
      CrystalClick::BinaryValue.nested(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.nested(type, [w224p_tuple(tuple_type, 128_u64, 255_u64)]),
      CrystalClick::BinaryValue.nested(type, [
        w224p_tuple(tuple_type, 16_384_u64, 0_u64),
        w224p_tuple(tuple_type, UInt64::MAX, 256_u64),
        w224p_tuple(tuple_type, 2_u64, 17_u64),
      ]),
      CrystalClick::BinaryValue.nested(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  else
    raise ArgumentError.new("unexpected W224 fixture type: #{type.name}")
  end
end

private def w224p_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  marks = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  [2, 2, 1].each do |mark_rows|
    mark = Array(CrystalClick::BinaryValue).new(mark_rows)
    mark_rows.times { |index| mark << rows[offset + index] }
    marks << mark
    offset += mark_rows
  end
  marks
end

private def w224p_signature(value : CrystalClick::BinaryValue) : String
  type = value.type
  return "#{type.name}=NULL" if value.is_null?

  if type.aggregate_count_type
    return "#{type.name}:count=#{value.count_state}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
    return "#{type.name}:#{value.aggregate_function_state_bytes.to_a.join(",")}"
  end

  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_NESTED,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NULLABLE
    "#{type.name}[#{value.elements.map { |child| w224p_signature(child) }.join(";")}]"
  else
    "#{type.name}:#{value.bytes.to_a.join(",")}"
  end
end

private def w224p_expected_lanes(type : CrystalClick::BinaryDataType) : Hash(String, Bytes)
  lanes = Hash(String, Bytes).new
  case type.name
  when "AggregateFunction(sum, UInt8)"
    lanes["root.data"] = w224p_concat([1_u64, 7_u64, 255_u64, 256_u64, 17_u64].map { |value| w224p_u64_bytes(value) })
  when "Array(AggregateFunction(sum, UInt8))"
    lanes["root.elements.data"] = w224p_concat([1_u64, 7_u64, 255_u64, 0_u64, 256_u64, 17_u64].map { |value| w224p_u64_bytes(value) })
    lanes["root.sizes"] = w224p_concat([2_u64, 0_u64, 1_u64, 3_u64, 0_u64].map { |value| w224p_u64_bytes(value) })
  when "Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))"
    lanes["root.field.0.data"] = w224p_concat([0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX].map { |value| w224p_varuint_bytes(value) })
    lanes["root.field.1.data"] = w224p_concat([1_u64, 7_u64, 9_u64, 11_u64, 13_u64].map { |value| w224p_u64_bytes(value) })
  when "Map(UInt8, AggregateFunction(count))"
    lanes["root.elements.field.0.data"] = Bytes[3_u8, 4_u8, 5_u8, 9_u8]
    lanes["root.elements.field.1.data"] = w224p_concat([0_u64, 128_u64, 16_384_u64, UInt64::MAX].map { |value| w224p_varuint_bytes(value) })
    lanes["root.sizes"] = w224p_concat([1_u64, 0_u64, 2_u64, 1_u64, 0_u64].map { |value| w224p_u64_bytes(value) })
  when "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))"
    lanes["root.nested.field.0.data"] = w224p_concat([0_u64, 7_u64, 128_u64, 0_u64, 16_384_u64].map { |value| w224p_varuint_bytes(value) })
    lanes["root.nested.field.1.data"] = w224p_concat([0_u64, 9_u64, 11_u64, 0_u64, 13_u64].map { |value| w224p_u64_bytes(value) })
    lanes["root.nulls"] = Bytes[1_u8, 0_u8, 0_u8, 1_u8, 0_u8]
  when "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))"
    lanes["root.elements.field.0.data"] = w224p_concat([0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX, 2_u64].map { |value| w224p_varuint_bytes(value) })
    lanes["root.elements.field.1.data"] = w224p_concat([1_u64, 7_u64, 255_u64, 0_u64, 256_u64, 17_u64].map { |value| w224p_u64_bytes(value) })
    lanes["root.sizes"] = w224p_concat([2_u64, 0_u64, 1_u64, 3_u64, 0_u64].map { |value| w224p_u64_bytes(value) })
  else
    raise ArgumentError.new("unexpected W224 lane oracle type: #{type.name}")
  end
  lanes
end

private def w224p_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  granules : Array(Array(CrystalClick::BinaryValue)),
) : String
  keys = Slice[7_u64, 18_u64, 29_u64, 40_u64, 51_u64]
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    keys,
    "v",
    type,
    granules,
    rows_per_mark: 2
  )
end

private def w224p_parent(&)
  parent = File.tempname("crystal-click-w224-aggregate-part-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W224 recursive AggregateFunction paired physical parts" do
  [
    "AggregateFunction(sum, UInt8)",
    "Array(AggregateFunction(sum, UInt8))",
    "Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))",
    "Map(UInt8, AggregateFunction(count))",
    "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))",
    "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))",
  ].each do |source|
    it "writes exact Count/Sum leaf bytes through the shared paired writer for #{source}" do
      type = w224p_type(source)
      rows = w224p_rows(type)
      granules = w224p_marks(rows)
      expected_rows = rows.map { |value| w224p_signature(value) }
      expected_lanes = w224p_expected_lanes(type)

      w224p_parent do |parent|
        part = File.join(parent, "all_1_1_0")
        w224p_write_part(part, type, granules).should eq(part)

        reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
        reader.schema_declaration.should eq(source)
        reader.source_declaration.should eq(source)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        reader.physical_stream_names.sort.should eq(
          CrystalClick::BinaryBulkPhysicalPlan.new(type, "v").stream_names.values.sort
        )

        observed = reader.read_marks(0, reader.mark_count).flatten
        observed.map { |value| w224p_signature(value) }.should eq(expected_rows)
        reader.read_marks(1, 1).flatten.map { |value| w224p_signature(value) }.should eq(expected_rows[2, 2])
        reader.read_marks(reader.mark_count, 0).should be_empty

        plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
        plan.stream_names.keys.sort.should eq(expected_lanes.keys.sort)
        expected_lanes.each do |role, bytes|
          filename = plan.data_file_for(role, true)
          decoded_lane = CrystalClick::CompressedBlock.decode_all(
            File.read(File.join(part, filename)).to_slice
          )
          decoded_lane.to_a.should eq(bytes.to_a)
        end
      end
    end
  end

  it "preserves the root-Sum state plan API and excludes root Count from the generic declaration" do
    root_sum = w224p_type("AggregateFunction(sum, UInt8)")
    root_declaration = CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.new(root_sum)
    root_declaration.state_plan.type.should eq(root_sum)
    root_declaration.state_plan.state_width.should eq(8)

    recursive_type = w224p_type("Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))")
    recursive_declaration = CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.new(recursive_type)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      recursive_declaration.state_plan
    end

    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse("AggregateFunction(count)").should be_nil
  end
end
