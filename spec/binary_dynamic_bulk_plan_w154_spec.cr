require "./spec_helper"

private def w154_plan_u64_structure : Bytes
  # V3, one ordinary UInt64 arm, no statistics.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x04_u8, 0_u8]
end

private def w154_plan_string_structure : Bytes
  # V3, one ordinary String arm, no statistics.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x15_u8, 0_u8]
end

private def w154_plan_empty_structure : Bytes
  # V3, no ordinary arms, no statistics (SharedVariant remains implicit).
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
end

private def w154_plan_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W154 Dynamic actual-roster bulk metadata plan" do
  it "plans declared Tuple and Array Dynamic sites by occurrence, independent of each cap" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    dynamic_one = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    declared = CrystalClick::BinaryDataType.tuple([
      CrystalClick::BinaryDataType.array(dynamic_zero),
      dynamic_one,
    ] of CrystalClick::BinaryDataType)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structures = {
      "root.field.0.elements" => CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType),
      "root.field.1"          => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    }

    plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, structures)
    expected_sites = ["root.field.0.elements", "root.field.1"] of String
    plan.site_paths.should eq(expected_sites)
    plan.type_for_site(expected_sites[0]).should eq(dynamic_zero)
    plan.type_for_site(expected_sites[1]).should eq(dynamic_one)
    plan.structure_for(expected_sites[0]).types.should eq([string_type] of CrystalClick::BinaryDataType)
    plan.structure_for(expected_sites[1]).types.should eq([uint64] of CrystalClick::BinaryDataType)

    # Site metadata is separate from the logical-value roles. Each occurrence
    # has its own structure lane and discriminator, and each SharedVariant
    # receives its canonical arm ID rather than aliasing an ordinary String.
    plan.structure_roles.should eq([
      "root.field.0.elements.dynamic_structure",
      "root.field.1.dynamic_structure",
    ] of String)
    plan.data_roles.should eq([
      "root.field.0.elements.arm.0.data",
      "root.field.0.elements.arm.1.data",
      "root.field.0.elements.discriminators",
      "root.field.0.sizes",
      "root.field.1.arm.0.data",
      "root.field.1.arm.1.data",
      "root.field.1.discriminators",
    ] of String)

    # Literal structure bytes are the independent expected outputs. The
    # max_types=0 occurrence still carries a real String roster; max_types=1
    # does not change how its actual UInt64 roster is decoded.
    expected_streams = CrystalClick::BinaryDynamicStructureStreams.new({
      "root.field.0.elements" => w154_plan_string_structure,
      "root.field.1"          => w154_plan_u64_structure,
    })
    write_budget = CrystalClick::BinaryCodecBudget.new(w154_plan_limits, true)
    encoded = plan.encode_structure_streams(write_budget)
    encoded.site_paths.should eq(expected_sites)
    encoded.site_count.should eq(2)
    encoded.has_site?(expected_sites[0]).should be_true
    encoded.has_site?(expected_sites[1]).should be_true
    encoded.structure_bytes_for(expected_sites[0]).should eq(w154_plan_string_structure)
    encoded.structure_bytes_for(expected_sites[1]).should eq(w154_plan_u64_structure)
    encoded.total_input_byte_size.should eq(22_u64)

    read_budget = CrystalClick::BinaryCodecBudget.new(w154_plan_limits)
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      declared,
      expected_streams,
      read_budget,
    )
    decoded.site_paths.should eq(expected_sites)
    decoded.structure_roles.should eq(plan.structure_roles)
    decoded.data_roles.should eq(plan.data_roles)
    decoded.structure_for(expected_sites[0]).types.should eq([string_type] of CrystalClick::BinaryDataType)
    decoded.structure_for(expected_sites[1]).types.should eq([uint64] of CrystalClick::BinaryDataType)
  end

  it "retains a nested actual Array(Dynamic) site even when its roster is empty" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic_zero)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    outer = CrystalClick::DynamicStructure.new([
      array_dynamic,
      string_type,
    ] of CrystalClick::BinaryDataType)
    nested_empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    nested_path = "root.arm.0.elements"

    # No DynamicValue rows are supplied to a structure plan. The path exists
    # because the declared actual arm contains Dynamic, not because an Array
    # happened to contain an element in one batch.
    empty_nested_plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root"      => outer,
      nested_path => nested_empty,
    })
    empty_nested_plan.site_paths.should eq(["root", nested_path] of String)
    empty_nested_plan.type_for_site(nested_path).should eq(dynamic_zero)
    empty_nested_plan.structure_for("root").types.should eq([array_dynamic, string_type] of CrystalClick::BinaryDataType)
    empty_nested_plan.structure_for(nested_path).types.should be_empty
    empty_nested_plan.structure_roles.should eq([
      "root.arm.0.elements.dynamic_structure",
      "root.dynamic_structure",
    ] of String)
    empty_nested_plan.data_roles.should eq([
      "root.arm.0.elements.arm.0.data",
      "root.arm.0.elements.discriminators",
      "root.arm.0.sizes",
      "root.arm.1.data",
      "root.arm.2.data",
      "root.discriminators",
    ] of String)

    # The same outer descriptor and cap can pair with a distinct non-empty
    # nested roster. Occurrence identity, not descriptor equality or cap,
    # chooses the structure stream.
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nested_with_arm = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
    populated_nested_plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root"      => outer,
      nested_path => nested_with_arm,
    })
    populated_nested_plan.site_paths.should eq(["root", nested_path] of String)
    populated_nested_plan.structure_for(nested_path).types.should eq([uint64] of CrystalClick::BinaryDataType)
    populated_nested_plan.data_roles.should contain("root.arm.0.elements.arm.1.data")
  end

  it "discovers sites through static Variant, Nullable-Tuple, and Map declaration edges" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    static_variant = CrystalClick::BinaryDataType.variant([
      string_type,
      array_dynamic,
    ] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType)
    )
    map = CrystalClick::BinaryDataType.map(string_type, dynamic)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)

    plan = CrystalClick::BinaryDynamicBulkPlan.new(
      CrystalClick::BinaryDataType.tuple([
        static_variant,
        map,
        nullable_tuple,
      ] of CrystalClick::BinaryDataType),
      {
        "root.field.0.arm.0.elements"   => empty,
        "root.field.1.elements.field.1" => empty,
        "root.field.2.nested.field.0"   => empty,
      }
    )

    # The full declaration starts at root.field.i; each expected suffix below
    # is occurrence-specific and follows the same recursive edge grammar.
    plan.site_paths.should eq([
      "root.field.0.arm.0.elements",
      "root.field.1.elements.field.1",
      "root.field.2.nested.field.0",
    ] of String)
    plan.site_paths.each do |path|
      plan.type_for_site(path).should eq(dynamic)
      plan.structure_for(path).should eq(empty)
    end
  end

  it "keeps two equal nominal Dynamic descriptors paired with separate site rosters" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.tuple([
      dynamic_zero,
      CrystalClick::BinaryDataType.dynamic(max_types: 0),
    ] of CrystalClick::BinaryDataType)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    left = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
    right = CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType)
    plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root.field.0" => left,
      "root.field.1" => right,
    })

    plan.type_for_site("root.field.0").should eq(plan.type_for_site("root.field.1"))
    plan.structure_for("root.field.0").should eq(left)
    plan.structure_for("root.field.1").should eq(right)
    plan.structure_for("root.field.0").should_not eq(plan.structure_for("root.field.1"))
    encoded = plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154_plan_limits, true))
    encoded.structure_bytes_for("root.field.0").should eq(w154_plan_u64_structure)
    encoded.structure_bytes_for("root.field.1").should eq(w154_plan_string_structure)
  end

  it "retains an empty declared site and treats SharedVariant and ordinary String as distinct arms" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    declared_array = CrystalClick::BinaryDataType.array(dynamic_zero)
    empty_site = CrystalClick::BinaryDynamicBulkPlan.new(declared_array, {
      "root.elements" => empty,
    })
    empty_site.site_paths.should eq(["root.elements"] of String)
    empty_site.structure_for("root.elements").types.should be_empty
    empty_encoded = empty_site.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154_plan_limits, true))
    empty_encoded.structure_bytes_for("root.elements").should eq(w154_plan_empty_structure)

    string_type = CrystalClick::BinaryDataType.primitive("String")
    statistics = CrystalClick::StructureStatistics.new(
      [3_u64, 7_u64],
      [
        CrystalClick::StructureStatistic.new("z", 3_u64),
        CrystalClick::StructureStatistic.new("a", 5_u64),
      ] of CrystalClick::StructureStatistic,
    )
    with_string = CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType, statistics)
    string_plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic_zero, {"root" => with_string})
    string_plan.structure_roles.should eq(["root.dynamic_structure"] of String)
    string_plan.data_roles.should eq([
      "root.arm.0.data", # synthetic SharedVariant String lane
      "root.arm.1.data", # ordinary String alternative, distinct canonical ID
      "root.discriminators",
    ] of String)
    string_plan.structure_for("root").canonical_variant_names.should eq(["SharedVariant", "String"] of String)
    string_plan.structure_for("root").shared_index.should eq(0)

    literal_with_statistics = Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0x15_u8, 0x01_u8,
      0x03_u8, 0x07_u8, 0x02_u8,
      0x01_u8, 0x61_u8, 0x05_u8,
      0x01_u8, 0x7a_u8, 0x03_u8,
    ]
    string_streams = string_plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154_plan_limits, true))
    string_streams.structure_bytes_for("root").should eq(literal_with_statistics)
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      dynamic_zero,
      CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal_with_statistics}),
      CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
    )
    decoded.structure_for("root").should eq(with_string)
    decoded.structure_for("root").statistics.should eq(statistics)

    # WithSize changes each String lane's role roster, not Dynamic's paired
    # structure bytes or the canonical arm IDs.
    with_size = CrystalClick::BinaryBulkProfile.with_size_stream
    sized_plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic_zero, {"root" => with_string}, with_size)
    sized_plan.structure_roles.should eq(["root.dynamic_structure"] of String)
    sized_plan.data_roles.should eq([
      "root.arm.0.data",
      "root.arm.0.string_sizes",
      "root.arm.1.data",
      "root.arm.1.string_sizes",
      "root.discriminators",
    ] of String)
    sized_streams = sized_plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154_plan_limits, true))
    sized_streams.structure_bytes_for("root").should eq(literal_with_statistics)
    sized_decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      dynamic_zero,
      CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal_with_statistics}),
      CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      with_size,
    )
    sized_decoded.structure_for("root").should eq(with_string)
    sized_decoded.structure_roles.should eq(sized_plan.structure_roles)
    sized_decoded.data_roles.should eq(sized_plan.data_roles)
  end

  it "detaches caller keys and bytes, returned snapshots, and plan role arrays" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
    expected = w154_plan_u64_structure
    path = String.new("root".to_slice)
    source = Bytes.new(expected.size) { |index| expected[index] }
    supplied = Hash(String, Bytes).new
    supplied[path] = source

    streams = CrystalClick::BinaryDynamicStructureStreams.new(supplied)
    path.to_unsafe[0] = 'X'.ord.to_u8
    source[0] = 0x7f_u8
    streams.site_paths.should eq(["root"] of String)
    streams.structure_bytes_for("root").should eq(expected)
    streams.total_input_byte_size.should eq(expected.size.to_u64)

    returned_paths = streams.site_paths
    returned_paths[0].to_unsafe[0] = 'Y'.ord.to_u8
    returned_bytes = streams.structure_bytes_for("root")
    returned_bytes[0] = 0x7e_u8
    streams.site_paths.should eq(["root"] of String)
    streams.structure_bytes_for("root").should eq(expected)

    plan_path = String.new("root".to_slice)
    plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic_zero, {plan_path => structure})
    plan_path.to_unsafe[0] = 'Z'.ord.to_u8
    plan.site_paths.should eq(["root"] of String)
    site_snapshot = plan.site_paths
    site_snapshot[0].to_unsafe[0] = 'Q'.ord.to_u8
    role_snapshot = plan.structure_roles
    role_snapshot.clear
    data_snapshot = plan.data_roles
    data_snapshot.clear
    plan.site_paths.should eq(["root"] of String)
    plan.structure_roles.should eq(["root.dynamic_structure"] of String)
    plan.data_roles.should eq([
      "root.arm.0.data",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
  end

  it "requires exact site-key sets and rejects malformed or direct-invalid structure bytes" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.tuple([
      CrystalClick::BinaryDataType.array(dynamic_zero),
      dynamic_zero,
    ] of CrystalClick::BinaryDataType)
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new(declared, {"root.field.1" => structure})
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new(declared, {
        "root.field.0.elements" => structure,
        "root.field.1"          => structure,
        "root.field.9"          => structure,
      })
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new(declared, {
        "root.field.0" => structure,
        "root.field.1" => structure,
      })
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared,
        CrystalClick::BinaryDynamicStructureStreams.new({"root.field.1" => w154_plan_empty_structure}),
        CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared,
        CrystalClick::BinaryDynamicStructureStreams.new({
          "root.field.0.elements" => w154_plan_empty_structure,
          "root.field.1"          => w154_plan_empty_structure,
          "root.field.9"          => w154_plan_empty_structure,
        }),
        CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared,
        CrystalClick::BinaryDynamicStructureStreams.new({
          "root.field.0" => w154_plan_empty_structure,
          "root.field.1" => w154_plan_empty_structure,
        }),
        CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      )
    end

    direct_variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("Nothing")] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64")),
      ] of CrystalClick::BinaryDataType)
    end
    low_cardinality_nullable = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64"))
    )
    low_cardinality_refusal = expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([low_cardinality_nullable] of CrystalClick::BinaryDataType)
    end
    low_cardinality_refusal.message.should eq("LowCardinality(Nullable) alternatives are not admitted in Dynamic V3")
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([direct_variant] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([dynamic_zero] of CrystalClick::BinaryDataType)
    end

    invalid_direct_dynamic = Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0x2b_u8, 0x00_u8, 0x00_u8,
    ]
    invalid_direct_variant = Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x00_u8,
    ]
    invalid_low_cardinality_nullable = Bytes[
      0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
      0x01_u8, 0x26_u8, 0x23_u8, 0x04_u8, 0x00_u8,
    ]
    {invalid_direct_dynamic, invalid_direct_variant}.each do |literal|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
          CrystalClick::BinaryDataType.dynamic,
          CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal}),
          CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
        )
      end
    end
    low_cardinality_wire_refusal = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        CrystalClick::BinaryDataType.dynamic,
        CrystalClick::BinaryDynamicStructureStreams.new({"root" => invalid_low_cardinality_nullable}),
        CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      )
    end
    low_cardinality_wire_refusal.message.should eq("LowCardinality(Nullable) alternatives are not admitted in Dynamic V3")

    valid = CrystalClick::BinaryDynamicStructureStreams.new({"root" => w154_plan_empty_structure})
    declared_dynamic = CrystalClick::BinaryDataType.dynamic
    (0...w154_plan_empty_structure.size).each do |length|
      truncated = Bytes.new(length) { |index| w154_plan_empty_structure[index] }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
          declared_dynamic,
          CrystalClick::BinaryDynamicStructureStreams.new({"root" => truncated}),
          CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
        )
      end
    end
    trailing = Bytes.new(w154_plan_empty_structure.size + 1) do |index|
      index == w154_plan_empty_structure.size ? 0_u8 : w154_plan_empty_structure[index]
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared_dynamic,
        CrystalClick::BinaryDynamicStructureStreams.new({"root" => trailing}),
        CrystalClick::BinaryCodecBudget.new(w154_plan_limits),
      )
    end
    valid.site_paths.should eq(["root"] of String)
  end
end
