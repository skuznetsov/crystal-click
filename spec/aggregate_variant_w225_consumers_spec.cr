require "./spec_helper"
require "file_utils"

private def w225c_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w225c_state(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  if type.aggregate_count_type
    CrystalClick::BinaryValue.aggregate_count_state(type, value)
  else
    CrystalClick::BinaryValue.aggregate_function_state(type, w225c_u64_bytes(value))
  end
end

private def w225c_types : Hash(String, CrystalClick::BinaryDataType)
  count = CrystalClick::BinaryDataType.aggregate_count
  sum = CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt8")
  )
  string = CrystalClick::BinaryDataType.primitive("String")
  root = CrystalClick::BinaryDataType.variant([count, sum, string] of CrystalClick::BinaryDataType)
  array_variant = CrystalClick::BinaryDataType.array(root)
  array_sum = CrystalClick::BinaryDataType.array(sum)
  tuple = CrystalClick::BinaryDataType.tuple([count, sum] of CrystalClick::BinaryDataType)

  {
    "root_variant_single"             => root,
    "root_variant_with_size"          => root,
    "root_variant_null_unused_string" => root,
    "root_variant_null_unused_sum"    => root,
    "array_variant"                   => array_variant,
    "variant_array_sum"               => CrystalClick::BinaryDataType.variant([array_sum, string] of CrystalClick::BinaryDataType),
    "variant_tuple"                   => CrystalClick::BinaryDataType.variant([tuple, string] of CrystalClick::BinaryDataType),
  }
end

private def w225c_variant_index(
  type : CrystalClick::BinaryDataType,
  alternative : CrystalClick::BinaryDataType,
) : UInt8
  index = type.children.index { |child| child.name == alternative.name } ||
          raise ArgumentError.new("W225 alternative is missing from canonical Variant")
  index.to_u8
end

private def w225c_variant(
  type : CrystalClick::BinaryDataType,
  alternative : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.variant(type, w225c_variant_index(type, alternative), value)
end

private def w225c_rows(
  id : String,
  type : CrystalClick::BinaryDataType,
) : Array(CrystalClick::BinaryValue)
  count = CrystalClick::BinaryDataType.aggregate_count
  sum = CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt8")
  )
  string = CrystalClick::BinaryDataType.primitive("String")
  null_variant = ->(variant_type : CrystalClick::BinaryDataType) {
    CrystalClick::BinaryValue.variant_null(variant_type)
  }

  case id
  when "root_variant_single", "root_variant_with_size"
    [
      w225c_variant(type, count, w225c_state(count, 128_u64)),
      w225c_variant(type, sum, w225c_state(sum, 256_u64)),
      null_variant.call(type),
      null_variant.call(type),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("tail")),
    ] of CrystalClick::BinaryValue
  when "root_variant_null_unused_string"
    [
      w225c_variant(type, count, w225c_state(count, 0_u64)),
      w225c_variant(type, sum, w225c_state(sum, 255_u64)),
      null_variant.call(type),
      null_variant.call(type),
      w225c_variant(type, count, w225c_state(count, UInt64::MAX)),
    ] of CrystalClick::BinaryValue
  when "root_variant_null_unused_sum"
    [
      w225c_variant(type, count, w225c_state(count, 1_u64)),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("left")),
      null_variant.call(type),
      null_variant.call(type),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("right")),
    ] of CrystalClick::BinaryValue
  when "array_variant"
    element_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.array(type, [
        w225c_variant(element_type, count, w225c_state(count, 127_u64)),
        w225c_variant(element_type, sum, w225c_state(sum, 256_u64)),
      ]),
      CrystalClick::BinaryValue.array(type, [
        w225c_variant(element_type, sum, w225c_state(sum, 7_u64)),
      ]),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [null_variant.call(element_type)]),
    ] of CrystalClick::BinaryValue
  when "variant_array_sum"
    array_type = CrystalClick::BinaryDataType.array(sum)
    [
      w225c_variant(type, array_type, CrystalClick::BinaryValue.array(array_type, [
        w225c_state(sum, 1_u64), w225c_state(sum, 7_u64),
      ])),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("xy")),
      w225c_variant(type, array_type, CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)),
      null_variant.call(type),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("z")),
    ] of CrystalClick::BinaryValue
  when "variant_tuple"
    tuple_type = CrystalClick::BinaryDataType.tuple([count, sum] of CrystalClick::BinaryDataType)
    tuple_value = ->(count_value : UInt64, sum_value : UInt64) {
      CrystalClick::BinaryValue.tuple(tuple_type, [
        w225c_state(count, count_value), w225c_state(sum, sum_value),
      ])
    }
    [
      w225c_variant(type, tuple_type, tuple_value.call(128_u64, 7_u64)),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("mid")),
      w225c_variant(type, tuple_type, tuple_value.call(UInt64::MAX, 256_u64)),
      null_variant.call(type),
      w225c_variant(type, string, CrystalClick::BinaryValue.string("end")),
    ] of CrystalClick::BinaryValue
  else
    raise ArgumentError.new("unexpected W225 consumer profile: #{id}")
  end
end

private def w225c_signature(value : CrystalClick::BinaryValue) : String
  type = value.type
  return "#{type.name}=NULL" if value.is_null?

  if type.aggregate_count_type
    return "#{type.name}:count=#{value.count_state}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
    return "#{type.name}:#{value.aggregate_function_state_bytes.to_a.join(",")}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    index = value.variant_index? || raise ArgumentError.new("non-null Variant has no selected alternative")
    child = value.variant_child? || raise ArgumentError.new("non-null Variant has no child")
    return "#{type.name}<#{type.child_at(index).name}=#{w225c_signature(child)}>"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_STRING
    return "#{type.name}:#{value.as_string}"
  end

  "#{type.name}[#{value.elements.map { |child| w225c_signature(child) }.join(";")}]"
end

private def w225c_marks(
  rows : Array(CrystalClick::BinaryValue),
) : Array(Array(CrystalClick::BinaryValue))
  marks = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  [2, 2, 1].each do |size|
    mark = Array(CrystalClick::BinaryValue).new(size)
    size.times { |index| mark << rows[offset + index] }
    marks << mark
    offset += size
  end
  marks
end

private def w225c_profile(id : String) : CrystalClick::BinaryBulkProfile
  id == "root_variant_with_size" ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream
end

private def w225c_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  rows : Array(CrystalClick::BinaryValue),
  profile : CrystalClick::BinaryBulkProfile,
) : String
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
    "v",
    type,
    w225c_marks(rows),
    rows_per_mark: 2,
    profile: profile
  )
end

private def w225c_offline_table(
  source : String,
  part : String,
) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
  CrystalClick::OfflineTable.new(
    "w225_events",
    "w225-variant-consumer-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", source),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate
  )
end

private def w225c_parent(&)
  parent = File.tempname("crystal-click-w225-variant-consumer-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W225 generic AggregateFunction Variant public consumers" do
  {
    "root_variant_single",
    "root_variant_with_size",
    "array_variant",
    "variant_array_sum",
    "variant_tuple",
    "root_variant_null_unused_string",
    "root_variant_null_unused_sum",
  }.each do |id|
    it "publishes, selects, scans, windows, and owns exact BinaryValues for #{id}" do
      type = w225c_types[id]
      rows = w225c_rows(id, type)
      expected = rows.map { |value| w225c_signature(value) }
      profile = w225c_profile(id)

      w225c_parent do |parent|
        part = File.join(parent, "all_1_1_0")
        w225c_write_part(part, type, rows, profile).should eq(part)

        physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v", profile)
        reader = CrystalClick::BinaryBulkColumnReader.open(part, "v", type)
        reader.schema_declaration.should eq(type.name)
        reader.source_declaration.should eq(type.name)
        reader.ordinary_profile.should eq(profile)
        reader.row_count.should eq(5_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        reader.physical_stream_names.sort.should eq(physical.stream_names.values.sort)
        observed = reader.read_marks(0, reader.mark_count).flatten
        observed.map { |value| w225c_signature(value) }.should eq(expected)
        reader.read_marks(reader.mark_count, 0).should be_empty

        selected = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
        selected.column_types.should eq([{"pk", "UInt64"}, {"v", type.name}])
        selected_rows = [] of CrystalClick::BinaryValue
        selected_schedule = [] of Tuple(Int32, Int64, Int32)
        selected.scan_typed(batch_rows: 2) do |batch|
          values = batch.binary_bulk_values_for("v")
          values.size.should eq(batch.values_for("pk").size)
          selected_rows.concat(values.to_a)
          selected_schedule << {batch.mark_index, batch.part_row_offset.to_i64, values.size}
          expect_raises(CrystalClick::UnsupportedFormatError) do
            batch.variant_string_uint64_for("v")
          end
        end
        selected_rows.map { |value| w225c_signature(value) }.should eq(expected)
        selected_schedule.should eq([{0, 0_i64, 2}, {1, 2_i64, 2}, {2, 4_i64, 1}])

        selected_window = [] of CrystalClick::BinaryValue
        selected.scan_typed_window(1_u64, 3) do |batch|
          selected_window.concat(batch.binary_bulk_values_for("v").to_a)
        end
        selected_window.map { |value| w225c_signature(value) }.should eq(expected[1, 3])

        offline = w225c_offline_table(type.name, part)
        offline_rows = [] of CrystalClick::BinaryValue
        offline.scan_typed(["pk", "v"], batch_rows: 2) do |batch|
          offline_rows.concat(batch.binary_bulk_values_for("v").to_a)
        end
        offline_rows.map { |value| w225c_signature(value) }.should eq(expected)

        offline_window = [] of CrystalClick::BinaryValue
        offline.scan_typed_window(["pk", "v"], 1_u64, 3) do |batch|
          offline_window.concat(batch.binary_bulk_values_for("v").to_a)
        end
        offline_window.map { |value| w225c_signature(value) }.should eq(expected[1, 3])

        owned = offline["v"].values(max_rows: 5_u64).map do |value|
          value.as(CrystalClick::BinaryValue)
        end
        owned.map { |value| w225c_signature(value) }.should eq(expected)
        if id == "root_variant_null_unused_sum"
          offline["v"].values(max_rows: 5_u64, max_string_bytes: 9_u64).size.should eq(5)
        end
      end
    end
  end

  it "applies exact and one-short owned String budgets to selected Variant arms" do
    type = w225c_types["root_variant_single"]
    rows = w225c_rows("root_variant_single", type)

    w225c_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w225c_write_part(part, type, rows, CrystalClick::BinaryBulkProfile.single_stream)
      offline = w225c_offline_table(type.name, part)

      exact = offline["v"].values(max_rows: 5_u64, max_string_bytes: 4_u64)
      exact.map { |value| w225c_signature(value.as(CrystalClick::BinaryValue)) }.should eq(
        rows.map { |value| w225c_signature(value) }
      )
      expect_raises(CrystalClick::BoundsError) do
        offline["v"].values(max_rows: 5_u64, max_string_bytes: 3_u64)
      end
    end
  end

  it "routes a synthetic selected projection child through generic BinaryBulk values" do
    types = w225c_types
    base_type = types["root_variant_single"]
    child_type = types["array_variant"]
    base_rows = w225c_rows("root_variant_null_unused_string", base_type)
    child_rows = w225c_rows("array_variant", child_type)

    w225c_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w225c_write_part(part, base_type, base_rows, CrystalClick::BinaryBulkProfile.single_stream)
      child = File.join(part, "selected.proj")
      w225c_write_part(child, child_type, child_rows, CrystalClick::BinaryBulkProfile.single_stream)

      info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
      candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
      selected = CrystalClick::OfflineTable.new(
        "w225_events",
        "w225-variant-projection-fixture",
        "MergeTree",
        [
          CrystalClick::OfflineColumn.new("pk", "UInt64"),
          CrystalClick::OfflineColumn.new("v", base_type.name),
        ] of CrystalClick::OfflineColumn,
        [candidate] of CrystalClick::OfflinePartCandidate,
        projections: [CrystalClick::OfflineProjection.new("selected", "SELECT v")]
      )
      observed = [] of CrystalClick::BinaryValue
      selected.scan_projection_typed("selected", ["v"], batch_rows: 2) do |batch|
        batch.column_type_for("v").should eq(child_type.name)
        observed.concat(batch.binary_bulk_values_for("v").to_a)
      end
      observed.map { |value| w225c_signature(value) }.should eq(
        child_rows.map { |value| w225c_signature(value) }
      )
      observed.map { |value| w225c_signature(value) }.should_not eq(
        base_rows.map { |value| w225c_signature(value) }
      )
    end
  end
end
