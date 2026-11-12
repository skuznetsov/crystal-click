require "./spec_helper"
require "./support/projection_checksum_fixture"
require "file_utils"

private def w224c_type(source : String) : CrystalClick::BinaryDataType
  parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
  parsed.should_not be_nil
  parsed || CrystalClick::BinaryDataType.primitive("UInt8")
end

private def w224c_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w224c_state(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  if type.aggregate_count_type
    CrystalClick::BinaryValue.aggregate_count_state(type, value)
  else
    CrystalClick::BinaryValue.aggregate_function_state(type, w224c_u64_bytes(value))
  end
end

private def w224c_tuple(
  type : CrystalClick::BinaryDataType,
  count : UInt64,
  sum : UInt64,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    type,
    [w224c_state(type.child_at(0), count), w224c_state(type.child_at(1), sum)]
  )
end

private def w224c_rows(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
  case type.name
  when "AggregateFunction(sum, UInt8)"
    [1_u64, 7_u64, 255_u64, 256_u64, 17_u64].map { |value| w224c_state(type, value) }
  when "Array(AggregateFunction(sum, UInt8))"
    element_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.array(type, [w224c_state(element_type, 1_u64), w224c_state(element_type, 7_u64)]),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [w224c_state(element_type, 255_u64)]),
      CrystalClick::BinaryValue.array(type, [
        w224c_state(element_type, 0_u64),
        w224c_state(element_type, 256_u64),
        w224c_state(element_type, 17_u64),
      ]),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  when "Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))"
    [
      w224c_tuple(type, 0_u64, 1_u64),
      w224c_tuple(type, 127_u64, 7_u64),
      w224c_tuple(type, 128_u64, 9_u64),
      w224c_tuple(type, 16_384_u64, 11_u64),
      w224c_tuple(type, UInt64::MAX, 13_u64),
    ] of CrystalClick::BinaryValue
  when "Map(UInt8, AggregateFunction(count))"
    key_type = type.child_at(0)
    count_type = type.child_at(1)
    [
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[3_u8]),
        w224c_state(count_type, 0_u64),
      ]),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[4_u8]),
        w224c_state(count_type, 128_u64),
        CrystalClick::BinaryValue.fixed(key_type, Bytes[5_u8]),
        w224c_state(count_type, 16_384_u64),
      ]),
      CrystalClick::BinaryValue.map(type, [
        CrystalClick::BinaryValue.fixed(key_type, Bytes[9_u8]),
        w224c_state(count_type, UInt64::MAX),
      ]),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  when "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))"
    tuple_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, w224c_tuple(tuple_type, 7_u64, 9_u64)),
      CrystalClick::BinaryValue.nullable(type, w224c_tuple(tuple_type, 128_u64, 11_u64)),
      CrystalClick::BinaryValue.nullable(type),
      CrystalClick::BinaryValue.nullable(type, w224c_tuple(tuple_type, 16_384_u64, 13_u64)),
    ] of CrystalClick::BinaryValue
  when "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))"
    tuple_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.nested(type, [
        w224c_tuple(tuple_type, 0_u64, 1_u64),
        w224c_tuple(tuple_type, 127_u64, 7_u64),
      ]),
      CrystalClick::BinaryValue.nested(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.nested(type, [w224c_tuple(tuple_type, 128_u64, 255_u64)]),
      CrystalClick::BinaryValue.nested(type, [
        w224c_tuple(tuple_type, 16_384_u64, 0_u64),
        w224c_tuple(tuple_type, UInt64::MAX, 256_u64),
        w224c_tuple(tuple_type, 2_u64, 17_u64),
      ]),
      CrystalClick::BinaryValue.nested(type, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  else
    raise ArgumentError.new("unexpected W224 consumer fixture type: #{type.name}")
  end
end

private def w224c_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
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

private def w224c_signature(value : CrystalClick::BinaryValue) : String
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
    "#{type.name}[#{value.elements.map { |child| w224c_signature(child) }.join(";")}]"
  else
    "#{type.name}:#{value.bytes.to_a.join(",")}"
  end
end

private def w224c_find_count(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  return type if type.aggregate_count_type
  type.child_count.times do |index|
    if found = w224c_find_count(type.child_at(index))
      return found
    end
  end
  nil
end

private def w224c_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  rows : Array(CrystalClick::BinaryValue),
) : String
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    Slice[7_u64, 18_u64, 29_u64, 40_u64, 51_u64],
    "v",
    type,
    w224c_marks(rows),
    rows_per_mark: 2
  )
end

private def w224c_offline_table(
  source : String,
  part : String,
) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
  CrystalClick::OfflineTable.new(
    "w224_events",
    "w224-consumer-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", source),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate
  )
end

private def w224c_parent(&)
  parent = File.tempname("crystal-click-w224-aggregate-consumer-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W224 recursive AggregateFunction public consumers" do
  [
    "AggregateFunction(sum, UInt8)",
    "Array(AggregateFunction(sum, UInt8))",
    "Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8))",
    "Map(UInt8, AggregateFunction(count))",
    "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))",
    "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))",
  ].each do |source|
    it "keeps exact BinaryValues through selected batches and owned values for #{source}" do
      type = w224c_type(source)
      rows = w224c_rows(type)
      expected = rows.map { |value| w224c_signature(value) }

      w224c_parent do |parent|
        part = File.join(parent, "all_1_1_0")
        w224c_write_part(part, type, rows).should eq(part)

        selected = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
        selected.column_types.should eq([{"pk", "UInt64"}, {"v", source}])
        batch_values = [] of CrystalClick::BinaryValue
        selected.scan_typed(batch_rows: 2) do |batch|
          values = batch.binary_bulk_values_for("v")
          values.size.should eq(batch.values_for("pk").size)
          batch_values.concat(values.to_a)
        end
        batch_values.map { |value| w224c_signature(value) }.should eq(expected)

        offline = w224c_offline_table(source, part)
        offline_values = [] of CrystalClick::BinaryValue
        offline.scan_typed(["v"], batch_rows: 2) do |batch|
          offline_values.concat(batch.binary_bulk_values_for("v").to_a)
        end
        offline_values.map { |value| w224c_signature(value) }.should eq(expected)

        owned = offline["v"].values(max_rows: 5_u64).map do |value|
          value.as(CrystalClick::BinaryValue)
        end
        owned.map { |value| w224c_signature(value) }.should eq(expected)

        if count_type = w224c_find_count(type)
          expect_raises(CrystalClick::UnsupportedFormatError) do
            selected.scan_typed(batch_rows: 2) do |batch|
              batch.aggregate_count_states_for("v", count_type)
            end
          end
        end

        if source == "AggregateFunction(sum, UInt8)" || source == "Array(AggregateFunction(sum, UInt8))"
          window = [] of CrystalClick::BinaryValue
          offline.scan_typed_window(["v"], 1_u64, 2) do |batch|
            window.concat(batch.binary_bulk_values_for("v").to_a)
          end
          window.map { |value| w224c_signature(value) }.should eq(expected[1, 2])
        end
      end
    end
  end

  it "routes a recursive state column from its selected projection child" do
    base_type = w224c_type("AggregateFunction(sum, UInt8)")
    projection_type = w224c_type("Array(AggregateFunction(sum, UInt8))")
    base_rows = [91_u64, 92_u64, 93_u64, 94_u64, 95_u64].map { |value| w224c_state(base_type, value) }
    projection_rows = w224c_rows(projection_type)

    w224c_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w224c_write_part(part, base_type, base_rows)
      child = File.join(part, "selected.proj")
      w224c_write_part(child, projection_type, projection_rows)
      ProjectionChecksumFixture.rebind!(part, "selected")

      selected = CrystalClick::WidePartTable.open_selected_projection_typed(
        [part], "selected", ["v"]
      )
      selected.total_row_count.should eq(5_u64)
      observed = [] of CrystalClick::BinaryValue
      selected.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.binary_bulk_values_for("v").to_a)
      end
      observed.map { |value| w224c_signature(value) }.should eq(
        projection_rows.map { |value| w224c_signature(value) }
      )
      observed.map { |value| w224c_signature(value) }.should_not eq(
        base_rows.map { |value| w224c_signature(value) }
      )
    end
  end
end
