require "./spec_helper"

private def w193_path_source_data : Bytes
  # Independently inspected first Compact Data slice for the retained root
  # ADVANCED v2 path "alpha": a no-statistics Dynamic V3 prefix, compact
  # discriminator prefix/body, UInt64 String size, then the typed String body.
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x02_u8, 0x00_u8, 0x00_u8, 0xff_u8,
    0x0b_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x15_u8, 0x09_u8, 0x72_u8, 0x2d_u8, 0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8, 0x2d_u8, 0x31_u8,
  ]
end

private def w193_path_source_events : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 0_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr_prefix", 9_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr", 17_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant.size", 21_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant", 29_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
end

private def w193_path_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 100_000,
  max_bytes : Int = 1_048_576,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

describe "W193 paired Object shared per-path Compact payload codec" do
  it "has a named no-statistics Dynamic structure prefix without changing complete-blob framing" do
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    prefix = CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(empty)
    prefix.should eq(Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])
    CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix).types.should be_empty
    CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix).statistics.should be_nil

    complete = CrystalClick::DynamicStructureCodec.encode(empty)
    complete.should eq(Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {"root" => empty}
    complete_plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, structures)
    complete_plan.statistics_offset_for("root").should eq(9)

    prefix_budget = CrystalClick::BinaryCodecBudget.new(w193_path_limits, true)
    prefix_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_prefix_without_statistics(
      dynamic,
      structures,
      prefix_budget,
    )
    expect_raises(ArgumentError) { prefix_plan.statistics_offset_for("root") }

    prefix_streams = CrystalClick::BinaryDynamicStructureStreams.new({"root" => prefix})
    prefix_read_budget = CrystalClick::BinaryCodecBudget.new(w193_path_limits)
    prefix_read_plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_prefix_streams_without_statistics(
      dynamic,
      prefix_streams,
      prefix_read_budget,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    expect_raises(ArgumentError) { prefix_read_plan.statistics_offset_for("root") }
  end

  it "matches the retained path slice and exact getter order, then decodes an independently authored slice" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    string = CrystalClick::BinaryDataType.primitive("String")
    rows = [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("r-alpha-1")),
      CrystalClick::BinaryValue.dynamic(dynamic),
    ] of CrystalClick::BinaryValue
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }

    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    encoded.data.should eq(w193_path_source_data)
    encoded.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64},
      {".SharedVariant.size", 21_u64},
      {".SharedVariant", 29_u64},
    ] of Tuple(String, UInt64))

    # Getter values are owned: mutating a returned lane cannot alter the
    # stream object or a subsequent read.
    returned_data = encoded.data
    returned_data[0] = 0xff_u8
    encoded.data.should eq(w193_path_source_data)
    encoded.events.size.should eq(5)

    decoded = CrystalClick::ObjectSharedPathCodec.decode(
      w193_path_source_data,
      w193_path_source_events,
      2,
      dynamic,
    )
    decoded.size.should eq(2)
    decoded[0].child_at(0).type.should eq(string)
    decoded[0].child_at(0).as_string.should eq("r-alpha-1")
    decoded[1].is_null?.should be_true
    decoded[1].type.should eq(dynamic)
  end

  it "reuses recursive actual-type value serde and accepts explicit nested Dynamic rosters" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    nullable_int64 = CrystalClick::BinaryDataType.nullable(int64)
    array_type = CrystalClick::BinaryDataType.array(nullable_int64)
    nested_array = CrystalClick::BinaryDataType.array(nested_dynamic)

    values = [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.nullable(nullable_int64, CrystalClick::BinaryValue.int64(7_i64)),
        CrystalClick::BinaryValue.nullable(nullable_int64),
      ] of CrystalClick::BinaryValue)),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)),
    ] of CrystalClick::BinaryValue
    structures = {
      "root" => CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType),
    }
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, values)
    decoded = CrystalClick::ObjectSharedPathCodec.decode(encoded.data, encoded.events, values.size, dynamic)
    decoded[0].child_at(0).elements[0].elements[0].as_int64.should eq(7_i64)
    decoded[0].child_at(0).elements[1].is_null?.should be_true
    decoded[1].child_at(0).elements.should be_empty

    nested_values = [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(nested_array, [
        CrystalClick::BinaryValue.dynamic(nested_dynamic, CrystalClick::BinaryValue.int64(11_i64)),
      ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::BinaryValue
    nested_structures = {
      "root"                => CrystalClick::DynamicStructure.new([nested_array] of CrystalClick::BinaryDataType),
      "root.arm.0.elements" => CrystalClick::DynamicStructure.new([int64] of CrystalClick::BinaryDataType),
    }
    nested = CrystalClick::ObjectSharedPathCodec.encode(dynamic, nested_structures, nested_values)
    nested_decoded = CrystalClick::ObjectSharedPathCodec.decode(nested.data, nested.events, 1, dynamic)
    nested_decoded[0].child_at(0).elements[0].child_at(0).as_int64.should eq(11_i64)
  end

  it "preflights cumulative nested-site depth before parsing a child structure prefix" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    nested_array = CrystalClick::BinaryDataType.array(nested_dynamic)
    row = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(nested_array, [
      CrystalClick::BinaryValue.dynamic(nested_dynamic, CrystalClick::BinaryValue.int64(11_i64)),
    ] of CrystalClick::BinaryValue))
    structures = {
      "root"                => CrystalClick::DynamicStructure.new([nested_array] of CrystalClick::BinaryDataType),
      "root.arm.0.elements" => CrystalClick::DynamicStructure.new([int64] of CrystalClick::BinaryDataType),
    }
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, [row])
    child_structure = encoded.events.find do |event|
      event.name.ends_with?(".dynamic_structure") && event.relative_offset > 0_u64
    end || raise "nested Dynamic structure event is missing"
    malformed = encoded.data
    malformed[child_structure.relative_offset.to_i] = 0xff_u8

    limits = w193_path_limits(max_depth: 3)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError, "binary codec depth limit exceeded") do
      CrystalClick::ObjectSharedPathCodec.decode_with_budget(
        malformed,
        encoded.events,
        1,
        dynamic,
        budget,
      )
    end
  end

  it "keeps read/write budgets caller-owned and rejects a malformed getter coordinate" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    rows = [CrystalClick::BinaryValue.dynamic(dynamic)] of CrystalClick::BinaryValue
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)

    write_budget = CrystalClick::BinaryCodecBudget.new(w193_path_limits, true)
    CrystalClick::ObjectSharedPathCodec.encode_with_budget(dynamic, structures, rows, write_budget)
    write_budget.wire_byte_count.should be > 0
    read_budget = CrystalClick::BinaryCodecBudget.new(w193_path_limits)
    CrystalClick::ObjectSharedPathCodec.decode_with_budget(
      encoded.data,
      encoded.events,
      rows.size,
      dynamic,
      read_budget,
    ).size.should eq(1)
    read_budget.wire_byte_count.should be > 0

    malformed_events = w193_path_source_events
    malformed_events[0] = CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 1_u64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(
        w193_path_source_data,
        malformed_events,
        2,
        dynamic,
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPathCodec.encode_with_budget(dynamic, structures, rows, read_budget)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedPathCodec.decode_with_budget(
        encoded.data,
        encoded.events,
        1,
        dynamic,
        write_budget,
      )
    end
  end
end
