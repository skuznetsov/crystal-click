require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_dynamic_w262_fixture"

describe "W262 Compact Dynamic prepared context" do
  it "accepts statistics drift while freezing the part-wide actual roster" do
    source_types = CompactDynamicW262Fixture.ordinary_types
    original = CompactDynamicW262Fixture.structure(
      source_types,
      statistics: CompactDynamicW262Fixture.statistics([1_u64, 2_u64, 3_u64]),
    )
    observed = CompactDynamicW262Fixture.structure(
      statistics: CompactDynamicW262Fixture.statistics([9_u64, 8_u64, 7_u64]),
    )
    source = {"root" => original}
    context = CompactDynamicW262Fixture.prepared_context(source)

    # The prepared plan owns its source structure and type list. Mutating
    # caller containers cannot rewrite the frozen plan or physical roster.
    source_types.clear
    source.clear
    context.validate_granule_roster!({"root" => observed})
    context.plan.structure_for("root").types.map(&.name).should eq(["UInt8", "String"])
    context.plan.structure_for("root").statistics.not_nil!.counts.should eq([1_u64, 2_u64, 3_u64])
    detached_names = context.physical.stream_names
    detached_names.clear
    context.physical.stream_names.keys.should_not be_empty
  end

  it "keeps an empty actual roster valid as the implicit SharedVariant-only plan" do
    empty = CompactDynamicW262Fixture.structure([] of CrystalClick::BinaryDataType)
    context = CompactDynamicW262Fixture.prepared_context({"root" => empty})

    context.plan.arm_count("root").should eq(1)
    context.plan.arm_type("root", context.plan.shared_index("root")).name.should eq("String")
    context.validate_granule_roster!({"root" => CompactDynamicW262Fixture.structure([] of CrystalClick::BinaryDataType)})
  end

  it "accounts for larger retained shared-statistics graphs with the same actual roster" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CompactDynamicW262Fixture.dynamic_type(2)
    small_statistics = CompactDynamicW262Fixture.statistics(
      [0_u64, 1_u64],
    )
    large_shared = Array(CrystalClick::StructureStatistic).new(12) do |index|
      name = String.build do |io|
        io << "shared_" << index
        48.times { io << 'x' }
      end
      CrystalClick::StructureStatistic.new(name, index.to_u64)
    end
    large_statistics = CrystalClick::StructureStatistics.new([0_u64, 1_u64], large_shared)
    small_structure = CompactDynamicW262Fixture.structure(
      [uint8] of CrystalClick::BinaryDataType,
      statistics: small_statistics,
    )
    large_structure = CompactDynamicW262Fixture.structure(
      [uint8] of CrystalClick::BinaryDataType,
      statistics: large_statistics,
    )
    small_context = CrystalClick::CompactDynamicBulkPreparedContext.new(
      dynamic,
      "payload",
      CrystalClick::BinaryBulkProfile.single_stream,
      {"root" => small_structure},
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    large_context = CrystalClick::CompactDynamicBulkPreparedContext.new(
      dynamic,
      "payload",
      CrystalClick::BinaryBulkProfile.single_stream,
      {"root" => large_structure},
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    normalizer = CrystalClick::CompactBinaryBulkNormalizer.new(
      dynamic,
      "payload",
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryCodecLimits.default,
    )

    small_structure.types.map(&.name).should eq(large_structure.types.map(&.name))
    small_context.plan.structure_for("root").canonical_variant_names.should eq(
      large_context.plan.structure_for("root").canonical_variant_names,
    )
    large_context.plan.structure_for("root").statistics.not_nil!.shared_count.should eq(12)
    normalizer.dynamic_prepared_context_workspace_bytes(large_context).should be >
                                                                              normalizer.dynamic_prepared_context_workspace_bytes(small_context)
  end
end

describe CrystalClick::CompactSerializationProfile do
  it "derives Dynamic String framing from propagation and rejects unknown raw versions" do
    dynamic_v1_root = File.tempname("crystal-click-w262-dynamic-string-v1-")
    dynamic_unpropagated_root = File.tempname("crystal-click-w262-dynamic-string-unpropagated-")
    unknown_version_root = File.tempname("crystal-click-w262-dynamic-string-unknown-")
    nested_static_root = File.tempname("crystal-click-w262-static-nested-string-")
    begin
      dynamic_v1 = CompactDynamicW262Fixture.open_profile(
        dynamic_v1_root,
        "root",
        "Dynamic(max_types=1)",
        "{\"string\":1}",
        true,
      )
      dynamic_v1.ordinary_profile.with_size_stream?.should be_true
      dynamic_v1.propagated_nested_versions.should be_true

      dynamic_unpropagated = CompactDynamicW262Fixture.open_profile(
        dynamic_unpropagated_root,
        "root",
        "Dynamic(max_types=1)",
        "{\"string\":1}",
        false,
      )
      dynamic_unpropagated.ordinary_profile.single_stream?.should be_true
      dynamic_unpropagated.propagated_nested_versions.should be_false

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CompactDynamicW262Fixture.open_profile(
          unknown_version_root,
          "root",
          "Dynamic(max_types=1)",
          "{\"string\":2}",
          true,
          true,
        )
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CompactDynamicW262Fixture.open_profile(
          nested_static_root,
          "root",
          "Array(String)",
          "{\"string\":1}",
          false,
        )
      end
    ensure
      FileUtils.rm_rf(dynamic_v1_root)
      FileUtils.rm_rf(dynamic_unpropagated_root)
      FileUtils.rm_rf(unknown_version_root)
      FileUtils.rm_rf(nested_static_root)
    end
  end

  it "keeps the exact serialization envelope and requires the propagation flag" do
    root = File.tempname("crystal-click-w262-profile-envelope-")
    begin
      type = CompactDynamicW262Fixture.dynamic_type(1)
      columns = [{"root", type.name}] of Tuple(String, String)
      serialization = %({"version":1,"columns":[{"kind":"Default","name":"root","num_defaults":0,"num_rows":2}],"types_serialization_versions":{"string":1}})
      CompactTypedW260Fixture.write_profile_metadata(root, serialization)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactSerializationProfile.open(
          root,
          columns,
          "root",
          type,
          2_u64,
          CrystalClick::CompressedStreamBudget.read_default,
        )
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "refuses unknown raw Map versions and admits known versions with a Dynamic nominal type" do
    unknown_root = File.tempname("crystal-click-w262-dynamic-map-v2-")
    known_propagated_root = File.tempname("crystal-click-w262-dynamic-map-v1-propagated-")
    known_unpropagated_root = File.tempname("crystal-click-w262-dynamic-map-v1-unpropagated-")
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CompactDynamicW262Fixture.open_profile(
          unknown_root,
          "root",
          "Dynamic(max_types=1)",
          "{\"map\":2}",
          true,
        )
      end

      propagated = CompactDynamicW262Fixture.open_profile(
        known_propagated_root,
        "root",
        "Dynamic(max_types=1)",
        "{\"map\":1}",
        true,
      )
      propagated.map_basic.should be_false
      propagated.propagated_nested_versions.should be_true

      unpropagated = CompactDynamicW262Fixture.open_profile(
        known_unpropagated_root,
        "root",
        "Dynamic(max_types=1)",
        "{\"map\":1}",
        false,
      )
      unpropagated.map_basic.should be_false
      unpropagated.propagated_nested_versions.should be_false
    ensure
      FileUtils.rm_rf(unknown_root)
      FileUtils.rm_rf(known_propagated_root)
      FileUtils.rm_rf(known_unpropagated_root)
    end
  end
end

describe "W262 Compact Dynamic canonical prefix arms" do
  it "places implicit SharedVariant at its canonical index and charges its depth" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    float64 = CrystalClick::BinaryDataType.primitive("Float64")
    structure = CompactDynamicW262Fixture.structure(
      [uint8, float64] of CrystalClick::BinaryDataType,
    )
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)

    arms = CrystalClick::BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(
      structure,
      budget,
      2,
    )

    structure.canonical_variant_names.should eq(["Float64", "SharedVariant", "UInt8"])
    structure.shared_index.should eq(1)
    arms.map(&.name).should eq(["Float64", "String", "UInt8"])
    arms[structure.shared_index].name.should eq("String")
    # The implicit Shared String is visited under the same borrowed operation
    # budget at descriptor depth two; the empty-roster depth control below
    # isolates that implicit descriptor from actual alternatives.
  end

  it "rejects writer-direction, inherited-depth, and exhausted borrowed budgets" do
    empty = CompactDynamicW262Fixture.structure([] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError, /read-direction/) do
      CrystalClick::BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(
        empty,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        2,
      )
    end

    depth_limits = CrystalClick::BinaryCodecLimits.new(1, 16, 16, 4096)
    depth_budget = CrystalClick::BinaryCodecBudget.new(depth_limits)
    depth_budget.charge_node
    expect_raises(CrystalClick::CorruptPartError, /depth/) do
      CrystalClick::BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(
        empty,
        depth_budget,
        2,
      )
    end
    depth_budget.node_count.should eq(1_i64)

    node_limits = CrystalClick::BinaryCodecLimits.new(8, 1, 16, 4096)
    node_budget = CrystalClick::BinaryCodecBudget.new(node_limits)
    node_budget.charge_node
    expect_raises(CrystalClick::CorruptPartError, /node/) do
      CrystalClick::BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(
        empty,
        node_budget,
        1,
      )
    end
    node_budget.node_count.should eq(1_i64)
  end
end

describe "W262 Compact granule input ownership" do
  it "charges the complete mrk4 input once, then advances borrowed prefixes within callback bounds" do
    source_a = Bytes[1_u8, 2_u8]
    shard_a = CrystalClick::CompactPartPhysicalShard.new(0, "first", 0_i64, 2_i64, source_a)
    shard_b = CrystalClick::CompactPartPhysicalShard.new(1, "second", 0_i64, 3_i64, Bytes[3_u8, 4_u8, 5_u8])
    source_a[0] = 99_u8
    detached = shard_a.bytes
    detached[1] = 88_u8

    limits = CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 5)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      [shard_a, shard_b],
      ["first", "second"],
    )

    cursor.begin_event("first")
    expect_raises(ArgumentError) { cursor.remaining_slice }
    expect_raises(ArgumentError) { cursor.advance_borrowed_prefix(1) }
    cursor.charge_complete_wire_input!(budget)
    budget.wire_byte_count.should eq(5_i64)
    cursor.remaining_slice.should eq(Bytes[1_u8, 2_u8])
    expect_raises(CrystalClick::CorruptPartError) { cursor.advance_borrowed_prefix(-1) }
    expect_raises(CrystalClick::CorruptPartError) { cursor.advance_borrowed_prefix(3) }
    cursor.remaining_slice.should eq(Bytes[1_u8, 2_u8])
    cursor.advance_borrowed_prefix(1)
    cursor.remaining_slice.should eq(Bytes[2_u8])
    cursor.read_exact(1).should eq(Bytes[2_u8])
    cursor.finish_event

    cursor.begin_event("second")
    cursor.advance_borrowed_prefix(3)
    cursor.finish_event
    cursor.finish_granule
    budget.wire_byte_count.should eq(5_i64)
    expect_raises(ArgumentError) { cursor.charge_complete_wire_input!(budget) }
    budget.wire_byte_count.should eq(5_i64)
  end
end

describe "W262 Compact Dynamic online prefix discovery" do
  it "normalizes a two-site mrk3 tape with interleaved statistics-bearing prefixes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
    )
    first_structure = CompactDynamicW262Fixture.structure(
      [uint8] of CrystalClick::BinaryDataType,
      statistics: CompactDynamicW262Fixture.statistics([0_u64, 1_u64]),
    )
    second_structure = CompactDynamicW262Fixture.structure(
      [] of CrystalClick::BinaryDataType,
      statistics: CompactDynamicW262Fixture.statistics([0_u64]),
    )
    structures = {
      "root.field.0" => first_structure,
      "root.field.1" => second_structure,
    }
    row = CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
      ),
      CrystalClick::BinaryValue.dynamic(dynamic),
    ] of CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
      tuple,
      structures,
      [[row] of CrystalClick::BinaryValue],
    )

    # Each encoded structure is complete V3 metadata with a present statistics
    # suffix. The physical mrk3 tape interleaves structure/mode callbacks per
    # Dynamic site before the recursive tuple body callbacks.
    decoded_first_structure = CrystalClick::DynamicStructureCodec.decode(
      encoded.structures.structure_bytes_for("root.field.0"),
    )
    decoded_second_structure = CrystalClick::DynamicStructureCodec.decode(
      encoded.structures.structure_bytes_for("root.field.1"),
    )
    decoded_first_structure.statistics.not_nil!.counts.should eq([0_u64, 1_u64])
    decoded_second_structure.statistics.not_nil!.counts.should eq([0_u64])
    encoded.data.stream("root.field.0.discriminators").bytes.should eq(Bytes[1_u8])
    encoded.data.stream("root.field.0.arm.0.data").bytes.should be_empty
    encoded.data.stream("root.field.0.arm.1.data").bytes.should eq(Bytes[0x2a_u8])
    encoded.data.stream("root.field.1.discriminators").bytes.should eq(Bytes[0xff_u8])
    encoded.data.stream("root.field.1.arm.0.data").bytes.should be_empty

    tape_writer = IO::Memory.new
    tape_writer.write(encoded.structures.structure_bytes_for("root.field.0"))
    tape_writer.write(CompactDynamicW262Fixture.u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE))
    tape_writer.write(encoded.structures.structure_bytes_for("root.field.1"))
    tape_writer.write(CompactDynamicW262Fixture.u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE))
    tape_writer.write(encoded.data.stream("root.field.0.discriminators").bytes)
    tape_writer.write(encoded.data.stream("root.field.0.arm.0.data").bytes)
    tape_writer.write(encoded.data.stream("root.field.0.arm.1.data").bytes)
    tape_writer.write(encoded.data.stream("root.field.1.discriminators").bytes)
    tape_writer.write(encoded.data.stream("root.field.1.arm.0.data").bytes)
    tape = tape_writer.to_slice.dup

    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, tape.size.to_i64, tape)
    granule = CrystalClick::CompactPartPhysicalGranule.new(0, 0_u64, 1_u64, [shard])
    window = CrystalClick::CompactPartPhysicalWindow.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      "payload",
      0,
      0_u64,
      [granule],
    )
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryCodecLimits.default
    normalizer = CrystalClick::CompactBinaryBulkNormalizer.new(tuple, "payload", profile, limits)
    workspace_observations = [] of UInt64
    workspace_observer = ->(bytes : UInt64) { workspace_observations << bytes; nil }
    physical_workspace_bytes = 1_000_000_u64
    normalized, rows, prepared = normalizer.normalize_dynamic(
      window,
      CrystalClick::BinaryCodecBudget.new(limits),
      workspace_observer,
      physical_workspace_bytes,
    )

    workspace_observations.should_not be_empty
    workspace_observations.each { |bytes| bytes.should be >= physical_workspace_bytes }
    workspace_observations.max.should be > physical_workspace_bytes
    workspace_observations.max.should be > workspace_observations.first

    rows.should eq([1_u64])
    prepared.plan.site_count.should eq(2)
    prepared.plan.structure_for("root.field.0").types.map(&.name).should eq(["UInt8"])
    prepared.plan.structure_for("root.field.1").types.should be_empty
    prepared.plan.arm_type("root.field.0", prepared.plan.shared_index("root.field.0")).name.should eq("String")
    prepared.plan.arm_type("root.field.1", prepared.plan.shared_index("root.field.1")).name.should eq("String")

    paired = CrystalClick::BinaryDynamicBulkStreams.new(encoded.structures, normalized)
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(tuple, paired, rows, profile: profile)
    decoded.size.should eq(1)
    decoded[0].size.should eq(1)
    decoded_value = decoded[0][0]
    decoded_value.child_at(0).child_at(0).bytes.should eq(Bytes[0x2a_u8])
    decoded_value.child_at(1).is_null?.should be_true

    first_discriminators = encoded.data.stream("root.field.0.discriminators").bytes
    first_discriminators.should eq(Bytes[1_u8])
    first_body_offset = encoded.structures.structure_bytes_for("root.field.0").size +
                        sizeof(UInt64) +
                        encoded.structures.structure_bytes_for("root.field.1").size +
                        sizeof(UInt64)
    corrupt_tape = tape.dup
    corrupt_tape[first_body_offset] = 2_u8
    corrupt_shard = CrystalClick::CompactPartPhysicalShard.new(
      0,
      nil,
      0_i64,
      corrupt_tape.size.to_i64,
      corrupt_tape,
    )
    corrupt_window = CrystalClick::CompactPartPhysicalWindow.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      "payload",
      0,
      0_u64,
      [CrystalClick::CompactPartPhysicalGranule.new(0, 0_u64, 1_u64, [corrupt_shard])],
    )
    prepared_observations = [] of CrystalClick::CompactDynamicBulkPreparedContext
    prepared_observer = ->(context : CrystalClick::CompactDynamicBulkPreparedContext) {
      prepared_observations << context
      nil
    }
    expect_raises(CrystalClick::CorruptPartError) do
      normalizer.normalize_dynamic(
        corrupt_window,
        CrystalClick::BinaryCodecBudget.new(limits),
        workspace_observer,
        physical_workspace_bytes,
        nil,
        prepared_observer,
      )
    end
    prepared_observations.size.should eq(1)
    prepared_observations.first.plan.site_count.should eq(2)
  end

  it "rejects a prepared context for a different type, profile, or column" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryCodecLimits.default
    structures = {"root" => CompactDynamicW262Fixture.structure([uint8] of CrystalClick::BinaryDataType)}
    selected_context = CrystalClick::CompactDynamicBulkPreparedContext.new(
      dynamic,
      "payload",
      profile,
      structures,
      CrystalClick::BinaryCodecBudget.new(limits),
    )
    wrong_column_context = CrystalClick::CompactDynamicBulkPreparedContext.new(
      dynamic,
      "other",
      profile,
      structures,
      CrystalClick::BinaryCodecBudget.new(limits),
    )
    empty_window = CrystalClick::CompactPartPhysicalWindow.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      "payload",
      0,
      0_u64,
      [] of CrystalClick::CompactPartPhysicalGranule,
    )
    wrong_type = CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType)
    no_workspace_observer = ->(_bytes : UInt64) { nil }

    {
      {wrong_type, profile, selected_context},
      {dynamic, CrystalClick::BinaryBulkProfile.with_size_stream, selected_context},
      {dynamic, profile, wrong_column_context},
    }.each do |(type, observed_profile, context)|
      normalizer = CrystalClick::CompactBinaryBulkNormalizer.new(
        type,
        "payload",
        observed_profile,
        limits,
      )
      expect_raises(ArgumentError, /does not match the selected column, descriptor, and profile/) do
        normalizer.normalize_dynamic(
          empty_window,
          CrystalClick::BinaryCodecBudget.new(limits),
          no_workspace_observer,
          0_u64,
          context,
        )
      end
    end
  end
end

describe "W262 Compact Dynamic batch carrier guards" do
  it "installs and reads exact Dynamic values while preserving row, type, and static refusal guards" do
    dynamic = CrystalClick::BinaryDataType.dynamic
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    )
    values = [value] of CrystalClick::BinaryValue
    values_slice = Slice.new(values.to_unsafe, values.size)
    batch = CrystalClick::WidePartTableBatch.new(
      0_i32,
      "all_1_1_0",
      "",
      0_i32,
      0_u64,
      0_u64,
      0_u64,
      ["payload"],
      ["Dynamic"],
      [] of CrystalClick::WidePartNumericSlice,
      row_count: 1_u64,
    )
    batch.install_dynamic_bulk_values("payload", values_slice, 1)
    batch.column_type_for("payload").should eq("Dynamic")
    observed = batch.dynamic_bulk_values_for("payload")
    observed.size.should eq(1)
    observed[0].type.should eq(dynamic)
    observed[0].child_at(0).byte_at(0).should eq(0x2a_u8)

    wrong_rows = CrystalClick::WidePartTableBatch.new(
      0_i32, "all_1_1_0", "", 0_i32, 0_u64, 0_u64, 0_u64,
      ["payload"], ["Dynamic"], [] of CrystalClick::WidePartNumericSlice,
      row_count: 1_u64,
    )
    expect_raises(CrystalClick::CorruptPartError, /row count mismatch/) do
      wrong_rows.install_dynamic_bulk_values("payload", values_slice, 2)
    end

    wrong_type = CrystalClick::WidePartTableBatch.new(
      0_i32, "all_1_1_0", "", 0_i32, 0_u64, 0_u64, 0_u64,
      ["payload"], ["Dynamic"], [] of CrystalClick::WidePartNumericSlice,
      row_count: 1_u64,
    )
    wrong_type_values = [CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8])] of CrystalClick::BinaryValue
    wrong_type_slice = Slice.new(wrong_type_values.to_unsafe, wrong_type_values.size)
    expect_raises(CrystalClick::CorruptPartError, /value type differs/) do
      wrong_type.install_dynamic_bulk_values("payload", wrong_type_slice, 1)
    end

    static = CrystalClick::WidePartTableBatch.new(
      0_i32, "all_1_1_0", "", 0_i32, 0_u64, 0_u64, 0_u64,
      ["payload"], ["UInt64"], [] of CrystalClick::WidePartNumericSlice,
      row_count: 1_u64,
    )
    expect_raises(CrystalClick::CorruptPartError, /non-admitted declaration/) do
      static.install_dynamic_bulk_values("payload", values_slice, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic-bearing declaration/) do
      static.dynamic_bulk_values_for("payload")
    end
  end
end
