require "./spec_helper"
require "file_utils"

private def w250_codec_limits(
  max_depth : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
  max_nodes : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
  max_elements : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
  max_bytes : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w250_plan_streams(
  type : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  limits : CrystalClick::BinaryCodecLimits,
) : CrystalClick::BinaryDynamicStructureStreams
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(type, structures, budget)
  plan.encode_structure_streams(budget)
end

describe "W250 persisted Dynamic structure versions" do
  it "decodes complete V1 metadata and preserves its independent legacy maximum" do
    # UInt64LE(1), legacy maximum 9, one StringBinary("UInt8") type, then
    # mandatory unflagged counts [SharedVariant=7, UInt8=2] and empty map.
    # The legacy maximum deliberately differs from the one-entry roster.
    wire = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x09_u8, 0x01_u8,
      0x05_u8, 0x55_u8, 0x49_u8, 0x6e_u8, 0x74_u8, 0x38_u8,
      0x07_u8, 0x02_u8, 0x00_u8,
    ]

    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.types.should eq([
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    decoded.canonical_variant_names.should eq(["SharedVariant", "UInt8"] of String)
    decoded.statistics.not_nil!.counts.should eq([7_u64, 2_u64])
    decoded.statistics.not_nil!.shared.should be_empty
    decoded.version.should eq(1_u64)
    decoded.legacy_max_dynamic_types.should eq(9_u64)
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)

    rebuilt = CrystalClick::DynamicStructure.new(
      decoded.types,
      decoded.statistics,
      version: decoded.version,
      legacy_max_dynamic_types: decoded.legacy_max_dynamic_types,
    )
    rebuilt.should eq(decoded)
    CrystalClick::DynamicStructureCodec.encode(rebuilt).should eq(wire)
  end

  it "decodes V2 StringBinary SQL names and canonical statistics for an unsorted roster" do
    # The descriptor roster is UInt8, String, Array(Nullable(Enum8(...)));
    # statistics instead follow sorted canonical names: Array(...),
    # SharedVariant, String, UInt8. V1/V2 have no statistics-present flag.
    wire = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x03_u8,
      0x05_u8, 0x55_u8, 0x49_u8, 0x6e_u8, 0x74_u8, 0x38_u8,
      0x06_u8, 0x53_u8, 0x74_u8, 0x72_u8, 0x69_u8, 0x6e_u8, 0x67_u8,
      0x20_u8,
      0x41_u8, 0x72_u8, 0x72_u8, 0x61_u8, 0x79_u8, 0x28_u8,
      0x4e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8, 0x61_u8, 0x62_u8, 0x6c_u8, 0x65_u8, 0x28_u8,
      0x45_u8, 0x6e_u8, 0x75_u8, 0x6d_u8, 0x38_u8, 0x28_u8,
      0x27_u8, 0x61_u8, 0x27_u8, 0x20_u8, 0x3d_u8, 0x20_u8, 0x2d_u8, 0x31_u8,
      0x29_u8, 0x29_u8, 0x29_u8,
      0x2b_u8, 0x1f_u8, 0x17_u8, 0x0d_u8, 0x00_u8,
    ]

    enum_type = CrystalClick::BinaryDataType.enum8([
      {"a", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    array_type = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(enum_type)
    )
    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.types.should eq([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("String"),
      array_type,
    ] of CrystalClick::BinaryDataType)
    decoded.canonical_variant_names.should eq([
      "Array(Nullable(Enum8('a' = -1)))", "SharedVariant", "String", "UInt8",
    ] of String)
    decoded.statistics.not_nil!.counts.should eq([43_u64, 31_u64, 23_u64, 13_u64])
    decoded.statistics.not_nil!.shared.should be_empty
    decoded.version.should eq(2_u64)
    decoded.legacy_max_dynamic_types.should be_nil
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)
  end

  it "retains constructor defaults, version identity, and the opaque V1 legacy maximum" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    counts = [0_u64, 1_u64]
    shared = [] of CrystalClick::StructureStatistic
    statistics = CrystalClick::StructureStatistics.new(counts, shared)

    default_v3 = CrystalClick::DynamicStructure.new([uint8], statistics)
    default_v3.version.should eq(4_u64)
    default_v3.legacy_max_dynamic_types.should be_nil

    v1_default = CrystalClick::DynamicStructure.new([uint8], statistics, version: 1_u64)
    v1_default.legacy_max_dynamic_types.should eq(1_u64)
    v1_explicit_default = CrystalClick::DynamicStructure.new(
      [uint8], statistics, version: 1_u64, legacy_max_dynamic_types: 1_u64
    )
    v1_default.should eq(v1_explicit_default)
    v1_default.hash.should eq(v1_explicit_default.hash)

    v1_opaque = CrystalClick::DynamicStructure.new(
      [uint8], statistics, version: 1_u64, legacy_max_dynamic_types: UInt64::MAX
    )
    v1_opaque.legacy_max_dynamic_types.should eq(UInt64::MAX)
    v1_opaque.should_not eq(v1_default)
    versions = Hash(CrystalClick::DynamicStructure, String).new
    versions[v1_default] = "default"
    versions[v1_explicit_default] = "same value"
    versions[v1_opaque] = "opaque maximum"
    versions.size.should eq(2)
    versions[v1_default].should eq("same value")
    versions[v1_opaque].should eq("opaque maximum")

    v1_wire = CrystalClick::DynamicStructureCodec.encode(v1_opaque)
    decoded_v1 = CrystalClick::DynamicStructureCodec.decode(v1_wire)
    decoded_v1.version.should eq(1_u64)
    decoded_v1.legacy_max_dynamic_types.should eq(UInt64::MAX)
    CrystalClick::DynamicStructureCodec.encode(decoded_v1).should eq(v1_wire)

    v2 = CrystalClick::DynamicStructure.new([uint8], statistics, version: 2_u64)
    v2.legacy_max_dynamic_types.should be_nil
    v2.should_not eq(default_v3)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([uint8], statistics, version: 2_u64, legacy_max_dynamic_types: 1_u64)
    end
    {0_u64, 3_u64, UInt64::MAX}.each do |unsupported_version|
      expect_raises(ArgumentError) do
        CrystalClick::DynamicStructure.new([uint8], statistics, version: unsupported_version)
      end
    end

    # Inputs and returned statistics stay detached across the versioned owner.
    counts[0] = 99_u64
    shared << CrystalClick::StructureStatistic.new("external", 7_u64)
    v1_default.statistics.not_nil!.counts.should eq([0_u64, 1_u64])
    detached_counts = v1_default.statistics.not_nil!.counts
    detached_counts[0] = 88_u64
    v1_default.statistics.not_nil!.counts.should eq([0_u64, 1_u64])
  end

  it "keeps V1/V2 complete statistics mandatory while leaving their prefixes writable" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    {1_u64, 2_u64}.each do |version|
      structure = CrystalClick::DynamicStructure.new([uint8], version: version)
      prefix = CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(structure)
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix).version.should eq(version)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.encode(structure)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, nil, true)
        CrystalClick::DynamicStructureCodec.write_with_statistics_offset(structure, context)
      end
    end
  end

  it "rejects malformed V2 names and same-name descriptors with incompatible storage widths" do
    header = Bytes[0x02_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    invalid_utf8 = Bytes.new(header.size + 3) do |index|
      case index
      when 0...header.size then header[index]
      when header.size     then 0x01_u8 # one declared type
      when header.size + 1 then 0x01_u8 # StringBinary length
      else                      0xff_u8
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(invalid_utf8)
    end

    unsupported_name = "NotAClickHouseType"
    name_bytes = unsupported_name.to_slice
    unsupported = Bytes.new(header.size + 2 + name_bytes.size) do |index|
      if index < header.size
        header[index]
      elsif index == header.size
        0x01_u8
      elsif index == header.size + 1
        name_bytes.size.to_u8
      else
        name_bytes[index - header.size - 2]
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(unsupported)
    end

    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    decimal64 = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    decimal32.name.should eq(decimal64.name)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new(
        [decimal32, decimal64] of CrystalClick::BinaryDataType,
        version: 2_u64,
      )
    end
  end

  it "charges multiple textual names and Dynamic sites to one codec budget" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_string = CrystalClick::BinaryDataType.array(string)
    one_type = CrystalClick::DynamicStructure.new(
      [uint8] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: 2_u64,
    )
    two_types = CrystalClick::DynamicStructure.new(
      [uint8, string] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: 2_u64,
    )

    measured_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    measured_context = CrystalClick::BinaryCodecContext.new(
      CrystalClick::BinaryCodecLimits.default, nil, true, measured_budget
    )
    CrystalClick::DynamicStructureCodec.write_to(two_types, measured_context)
    two_type_wire = measured_context.finish_bytes
    exact_limits = w250_codec_limits(
      max_nodes: measured_budget.node_count.to_i,
      max_elements: measured_budget.element_count.to_i,
      max_bytes: measured_budget.wire_byte_count.to_i,
    )
    CrystalClick::DynamicStructureCodec.encode(two_types, exact_limits).should eq(two_type_wire)

    below_nodes = w250_codec_limits(
      max_nodes: measured_budget.node_count.to_i - 1,
      max_elements: measured_budget.element_count.to_i,
      max_bytes: measured_budget.wire_byte_count.to_i,
    )
    CrystalClick::DynamicStructureCodec.encode(one_type, below_nodes).should_not be_empty
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(two_types, below_nodes)
    end

    below_elements = w250_codec_limits(
      max_nodes: measured_budget.node_count.to_i,
      max_elements: measured_budget.element_count.to_i - 1,
      max_bytes: measured_budget.wire_byte_count.to_i,
    )
    CrystalClick::DynamicStructureCodec.encode(one_type, below_elements).should_not be_empty
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(two_types, below_elements)
    end

    below_bytes = w250_codec_limits(
      max_nodes: measured_budget.node_count.to_i,
      max_elements: measured_budget.element_count.to_i,
      max_bytes: measured_budget.wire_byte_count.to_i - 1,
    )
    CrystalClick::DynamicStructureCodec.encode(one_type, below_bytes).should_not be_empty
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(two_types, below_bytes)
    end

    nested_name = CrystalClick::DynamicStructure.new(
      [array_string] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 0_u64], [] of CrystalClick::StructureStatistic),
      version: 2_u64,
    )
    CrystalClick::DynamicStructureCodec.encode(nested_name, w250_codec_limits(max_depth: 2)).should_not be_empty
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.encode(nested_name, w250_codec_limits(max_depth: 1))
    end

    depth_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    shallow_type = CrystalClick::BinaryDataType.tuple([depth_dynamic] of CrystalClick::BinaryDataType)
    deeper_type = CrystalClick::BinaryDataType.tuple([
      depth_dynamic,
      CrystalClick::BinaryDataType.array(depth_dynamic),
    ] of CrystalClick::BinaryDataType)
    shallow_path = "root.field.0"
    deeper_path = "root.field.1.elements"
    shallow_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      shallow_type,
      {shallow_path => nested_name} of String => CrystalClick::DynamicStructure,
    )
    deeper_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      deeper_type,
      {
        "root.field.0" => nested_name,
        deeper_path    => nested_name,
      } of String => CrystalClick::DynamicStructure,
    )
    shallow_depth = shallow_plan.depth_for_site(shallow_path)
    deeper_plan.depth_for_site(deeper_path).should eq(shallow_depth + 1)
    inherited_depth_cap = shallow_depth.to_i + 2 # Array(String)'s final child depth.
    w250_plan_streams(
      shallow_type,
      {shallow_path => nested_name} of String => CrystalClick::DynamicStructure,
      w250_codec_limits(max_depth: inherited_depth_cap),
    ).site_count.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w250_plan_streams(
        deeper_type,
        {
          "root.field.0" => nested_name,
          deeper_path    => nested_name,
        } of String => CrystalClick::DynamicStructure,
        w250_codec_limits(max_depth: inherited_depth_cap),
      )
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple = CrystalClick::BinaryDataType.tuple([dynamic, dynamic] of CrystalClick::BinaryDataType)
    v1 = CrystalClick::DynamicStructure.new(
      [uint8] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: 1_u64,
      legacy_max_dynamic_types: 9_u64,
    )
    v2 = CrystalClick::DynamicStructure.new(
      [string] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: 2_u64,
    )
    site_structures = {
      "root.field.0" => v1,
      "root.field.1" => v2,
    }
    measured_plan_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    measured_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(tuple, site_structures, measured_plan_budget)
    measured_streams = measured_plan.encode_structure_streams(measured_plan_budget)
    measured_streams.site_paths.should eq(["root.field.0", "root.field.1"] of String)
    site_limits = w250_codec_limits(
      max_nodes: measured_plan_budget.node_count.to_i,
      max_elements: measured_plan_budget.element_count.to_i,
      max_bytes: measured_plan_budget.wire_byte_count.to_i,
    )
    w250_plan_streams(tuple, site_structures, site_limits).site_count.should eq(2)

    shared_budget_limits = [
      w250_codec_limits(
        max_nodes: measured_plan_budget.node_count.to_i - 1,
        max_elements: measured_plan_budget.element_count.to_i,
        max_bytes: measured_plan_budget.wire_byte_count.to_i,
      ),
      w250_codec_limits(
        max_nodes: measured_plan_budget.node_count.to_i,
        max_elements: measured_plan_budget.element_count.to_i - 1,
        max_bytes: measured_plan_budget.wire_byte_count.to_i,
      ),
      w250_codec_limits(
        max_nodes: measured_plan_budget.node_count.to_i,
        max_elements: measured_plan_budget.element_count.to_i,
        max_bytes: measured_plan_budget.wire_byte_count.to_i - 1,
      ),
    ] of CrystalClick::BinaryCodecLimits
    shared_budget_limits.each do |limits|
      single_site_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
      single_site = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        dynamic, {"root" => v1}, single_site_budget
      )
      single_site.encode_structure_streams(single_site_budget).site_count.should eq(1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w250_plan_streams(tuple, site_structures, limits)
      end
    end
  end

  it "preserves V1/V2 versions in mixed no-statistics Dynamic structure streams under borrowed budgets" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    tuple = CrystalClick::BinaryDataType.tuple([dynamic, dynamic] of CrystalClick::BinaryDataType)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    v1 = CrystalClick::DynamicStructure.new(
      [uint8] of CrystalClick::BinaryDataType,
      version: 1_u64,
      legacy_max_dynamic_types: 9_u64,
    )
    v2 = CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType, version: 2_u64)
    structures = {
      "root.field.0" => v1,
      "root.field.1" => v2,
    } of String => CrystalClick::DynamicStructure

    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_prefix_without_statistics(
      tuple, structures, write_budget
    )
    streams = plan.encode_structure_prefix_streams_without_statistics(write_budget)
    write_budget.wire_byte_count.should be > 0_u64

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_prefix_streams_without_statistics(
      tuple, streams, read_budget
    )
    read_budget.wire_byte_count.should be > 0_u64
    decoded.structure_for("root.field.0").version.should eq(1_u64)
    decoded.structure_for("root.field.0").legacy_max_dynamic_types.should eq(9_u64)
    decoded.structure_for("root.field.0").statistics.should be_nil
    decoded.structure_for("root.field.1").version.should eq(2_u64)
    decoded.structure_for("root.field.1").legacy_max_dynamic_types.should be_nil
    decoded.structure_for("root.field.1").statistics.should be_nil
  end

  it "preserves mixed V1/V2 nested prefixes through Object shared-path tapes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    actual_tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType
    )
    outer = CrystalClick::DynamicStructure.new([actual_tuple] of CrystalClick::BinaryDataType)
    arm = outer.canonical_index_for(actual_tuple)
    first_path = "root.arm.#{arm}.field.0"
    second_path = "root.arm.#{arm}.field.1"
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    structures = {
      "root"     => outer,
      first_path => CrystalClick::DynamicStructure.new(
        [uint8] of CrystalClick::BinaryDataType,
        version: 1_u64,
        legacy_max_dynamic_types: 9_u64,
      ),
      second_path => CrystalClick::DynamicStructure.new(
        [string] of CrystalClick::BinaryDataType,
        version: 2_u64,
      ),
    } of String => CrystalClick::DynamicStructure
    rows = [
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.tuple(actual_tuple, [
          CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])),
          CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("v2-child")),
        ] of CrystalClick::BinaryValue),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic),
    ] of CrystalClick::BinaryValue

    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_budget(
      dynamic, structures, rows, write_budget, profile
    )
    write_budget.wire_byte_count.should be > 0_u64

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_structures_with_budget(
      encoded.data, encoded.events, rows.size, dynamic, read_budget, profile
    )
    read_budget.wire_byte_count.should be > 0_u64
    decoded.rows.map { |row| CrystalClick::BinaryValueCodec.encode(row) }.should eq(
      rows.map { |row| CrystalClick::BinaryValueCodec.encode(row) }
    )
    decoded.structures[first_path].version.should eq(1_u64)
    decoded.structures[first_path].legacy_max_dynamic_types.should eq(9_u64)
    decoded.structures[first_path].statistics.should be_nil
    decoded.structures[second_path].version.should eq(2_u64)
    decoded.structures[second_path].legacy_max_dynamic_types.should be_nil
    decoded.structures[second_path].statistics.should be_nil
  end

  it "writes and reads one public part with V1, V2, and V3 Dynamic sites" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    triple = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic, dynamic] of CrystalClick::BinaryDataType
    )
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    one_value_stats = CrystalClick::StructureStatistics.new(
      [0_u64, 1_u64], [] of CrystalClick::StructureStatistic
    )
    structures = {
      "root.field.0" => CrystalClick::DynamicStructure.new(
        [uint8] of CrystalClick::BinaryDataType,
        one_value_stats,
        version: 1_u64,
        legacy_max_dynamic_types: 9_u64,
      ),
      "root.field.1" => CrystalClick::DynamicStructure.new(
        [string] of CrystalClick::BinaryDataType,
        one_value_stats,
        version: 2_u64,
      ),
      "root.field.2" => CrystalClick::DynamicStructure.new(
        [int64] of CrystalClick::BinaryDataType,
        one_value_stats,
        version: 4_u64,
      ),
    } of String => CrystalClick::DynamicStructure
    row = CrystalClick::BinaryValue.tuple(triple, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("v2-value")),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.int64(-3_i64)),
    ] of CrystalClick::BinaryValue)

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      parent = File.tempname("crystal-click-w250-dynamic-versions-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "part")
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          Slice[41_u64],
          "payload",
          triple,
          structures,
          [[row] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
          rows_per_mark: 1,
          profile: profile,
          frame_bytes: 32,
        ).should eq(part)

        reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", triple)
        reader.row_count.should eq(1_u64)
        reader.mark_count.should eq(1)
        reader.ordinary_profile.should eq(profile)
        values = reader.read_marks(0, 1)[0][0]
        values.child_at(0).child_at(0).type.should eq(uint8)
        values.child_at(0).child_at(0).bytes.should eq(Bytes[0x07_u8])
        values.child_at(1).child_at(0).type.should eq(string)
        values.child_at(1).child_at(0).as_string.should eq("v2-value")
        values.child_at(2).child_at(0).type.should eq(int64)
        values.child_at(2).child_at(0).as_int64.should eq(-3_i64)
        reader.read_marks(1, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects invalid UTF-8 SQL-name transport while keeping V3 opaque Enum labels binary" do
    invalid_label = String.new(Bytes[0xff_u8])
    enum_type = CrystalClick::BinaryDataType.enum8(
      [{invalid_label, -1_i16}] of CrystalClick::BinaryEnumDefinition::Entry
    )
    enum_type.enum_definition.not_nil!.label_byte_at(0, 0).should eq(0xff_u8)
    enum_statistics = CrystalClick::StructureStatistics.new(
      [0_u64, 1_u64], [] of CrystalClick::StructureStatistic
    )

    {1_u64, 2_u64}.each do |version|
      legacy = CrystalClick::DynamicStructure.new(
        [enum_type] of CrystalClick::BinaryDataType,
        enum_statistics,
        version: version,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(legacy)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.encode(legacy)
      end
    end

    v3 = CrystalClick::DynamicStructure.new([enum_type] of CrystalClick::BinaryDataType)
    wire = CrystalClick::DynamicStructureCodec.encode(v3)
    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.version.should eq(4_u64)
    decoded.type_at(0).enum_definition.not_nil!.label_byte_at(0, 0).should eq(0xff_u8)
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)
  end

  it "requires complete unflagged statistics even for an empty old-version roster" do
    # V1 empty roster: version, ignored legacy maximum, type count, the one
    # implicit SharedVariant count, and the mandatory shared-map count.
    v1_empty = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x07_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    decoded_v1 = CrystalClick::DynamicStructureCodec.decode(v1_empty)
    decoded_v1.types.should be_empty
    decoded_v1.statistics.not_nil!.counts.should eq([0_u64])
    decoded_v1.statistics.not_nil!.shared.should be_empty
    CrystalClick::DynamicStructureCodec.encode(decoded_v1).should eq(v1_empty)

    # V2 empty roster has the same mandatory statistics suffix but no V1 field.
    v2_empty = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8,
    ]
    decoded_v2 = CrystalClick::DynamicStructureCodec.decode(v2_empty)
    decoded_v2.types.should be_empty
    decoded_v2.statistics.not_nil!.counts.should eq([0_u64])
    decoded_v2.statistics.not_nil!.shared.should be_empty
    CrystalClick::DynamicStructureCodec.encode(decoded_v2).should eq(v2_empty)

    # Descriptor-only V1/V2 prefixes omit the mandatory complete-metadata
    # statistics suffix. Preserve their version and V1 legacy field exactly.
    v1_prefix = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x09_u8, 0x01_u8,
      0x05_u8, 0x55_u8, 0x49_u8, 0x6e_u8, 0x74_u8, 0x38_u8,
    ]
    prefix_v1 = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(v1_prefix)
    prefix_v1.types.should eq([
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    prefix_v1.statistics.should be_nil
    CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(prefix_v1).should eq(v1_prefix)

    v2_prefix = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8,
    ]
    prefix_v2 = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(v2_prefix)
    prefix_v2.types.should be_empty
    prefix_v2.statistics.should be_nil
    CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(prefix_v2).should eq(v2_prefix)
  end

  it "rejects every truncated prefix, trailing bytes, and a roster count above the limit" do
    complete_v1 = Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x09_u8, 0x01_u8,
      0x05_u8, 0x55_u8, 0x49_u8, 0x6e_u8, 0x74_u8, 0x38_u8,
      0x07_u8, 0x02_u8, 0x00_u8,
    ]
    (0...complete_v1.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicStructureCodec.decode(complete_v1[0, length])
      end
    end

    trailing_v1 = Bytes.new(complete_v1.size + 1) do |index|
      index == complete_v1.size ? 0_u8 : complete_v1[index]
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(trailing_v1)
    end

    # UInt64LE(2), declared roster count 255 (VarUInt FF 01), no descriptors.
    # The count must fail its domain guard before any descriptor traversal.
    over_count = Bytes[
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0xff_u8, 0x01_u8,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(over_count)
    end
  end

  it "keeps V3's optional flag and wrong-channel version guards distinct" do
    # V3 (part version 4) carries a statistics flag; zero means absent.
    v3_without_statistics = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8,
    ]
    CrystalClick::DynamicStructureCodec.decode(v3_without_statistics).statistics.should be_nil
    CrystalClick::DynamicStructureCodec.encode(
      CrystalClick::DynamicStructureCodec.decode(v3_without_statistics)
    ).should eq(v3_without_statistics)
    CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(
      v3_without_statistics[0, v3_without_statistics.size - 1]
    ).types.should be_empty

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(v3_without_statistics[0, v3_without_statistics.size - 1])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(Bytes[
        0x03_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      ])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode(Bytes[
        0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x02_u8,
      ])
    end
  end

  it "recomputes empty Object statistics without changing V1/V2 Dynamic identity" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    old_v1_stats = CrystalClick::StructureStatistics.new([41_u64, 42_u64], [] of CrystalClick::StructureStatistic)
    old_v2_stats = CrystalClick::StructureStatistics.new([51_u64, 52_u64], [] of CrystalClick::StructureStatistic)
    old_object_stats = CrystalClick::StructureStatistics.new([61_u64, 62_u64], [] of CrystalClick::StructureStatistic)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["dynamic.v1", "dynamic.v2"], statistics: old_object_stats),
      {
        "dynamic.v1" => CrystalClick::DynamicStructure.new(
          [string] of CrystalClick::BinaryDataType,
          old_v1_stats,
          version: 1_u64,
          legacy_max_dynamic_types: 9_u64,
        ),
        "dynamic.v2" => CrystalClick::DynamicStructure.new(
          [uint8] of CrystalClick::BinaryDataType,
          old_v2_stats,
          version: 2_u64,
        ),
      } of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {} of String => CrystalClick::BinaryDataType,
    )

    fresh = CrystalClick::ObjectDocumentStatistics.recompute(
      plan,
      [] of Array(CrystalClick::ObjectDocument),
    )
    fresh.structures.object.statistics.not_nil!.counts.should eq([0_u64, 0_u64])

    v1 = fresh.structures.dynamic_for("dynamic.v1")
    v1.version.should eq(1_u64)
    v1.legacy_max_dynamic_types.should eq(9_u64)
    v1.statistics.not_nil!.counts.should eq([0_u64, 0_u64])
    v1.statistics.not_nil!.shared.should be_empty
    v1_wire = CrystalClick::DynamicStructureCodec.encode(v1)
    v1_decoded = CrystalClick::DynamicStructureCodec.decode(v1_wire)
    v1_decoded.version.should eq(1_u64)
    v1_decoded.legacy_max_dynamic_types.should eq(9_u64)
    v1_decoded.statistics.not_nil!.counts.should eq([0_u64, 0_u64])
    CrystalClick::DynamicStructureCodec.encode(v1_decoded).should eq(v1_wire)

    v2 = fresh.structures.dynamic_for("dynamic.v2")
    v2.version.should eq(2_u64)
    v2.legacy_max_dynamic_types.should be_nil
    v2.statistics.not_nil!.counts.should eq([0_u64, 0_u64])
    v2.statistics.not_nil!.shared.should be_empty
    v2_wire = CrystalClick::DynamicStructureCodec.encode(v2)
    v2_decoded = CrystalClick::DynamicStructureCodec.decode(v2_wire)
    v2_decoded.version.should eq(2_u64)
    v2_decoded.legacy_max_dynamic_types.should be_nil
    v2_decoded.statistics.not_nil!.counts.should eq([0_u64, 0_u64])
    CrystalClick::DynamicStructureCodec.encode(v2_decoded).should eq(v2_wire)

    plan.structures.object.statistics.not_nil!.counts.should eq([61_u64, 62_u64])
    plan.structures.dynamic_for("dynamic.v1").statistics.not_nil!.counts.should eq([41_u64, 42_u64])
    plan.structures.dynamic_for("dynamic.v1").legacy_max_dynamic_types.should eq(9_u64)
    plan.structures.dynamic_for("dynamic.v2").statistics.not_nil!.counts.should eq([51_u64, 52_u64])
    plan.structures.dynamic_for("dynamic.v1").version.should eq(1_u64)
    plan.structures.dynamic_for("dynamic.v2").version.should eq(2_u64)
  end

  it "rejects a unique V1/V2 Decimal64 alias while admitting the matching Decimal32 name" do
    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    decimal64 = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    decimal32.name.should eq(decimal64.name)

    {1_u64, 2_u64}.each do |version|
      statistics = CrystalClick::StructureStatistics.new(
        [0_u64, 0_u64],
        [] of CrystalClick::StructureStatistic,
      )
      matching = CrystalClick::DynamicStructure.new(
        [decimal32] of CrystalClick::BinaryDataType,
        statistics,
        version: version,
      )
      matching_wire = CrystalClick::DynamicStructureCodec.encode(matching)
      matching_decoded = CrystalClick::DynamicStructureCodec.decode(matching_wire)
      matching_decoded.version.should eq(version)
      matching_decoded.types.should eq([decimal32] of CrystalClick::BinaryDataType)

      mismatched = CrystalClick::DynamicStructure.new(
        [decimal64] of CrystalClick::BinaryDataType,
        statistics,
        version: version,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.encode(mismatched)
      end
    end
  end
end
