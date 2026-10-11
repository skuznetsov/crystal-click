require "./spec_helper"
require "json"
require "../scripts/support/compact_dynamic_w262_fixture"

describe "W262 Compact Dynamic roster adversaries" do
  it "rejects changed wire version, V1 legacy cap, ordinary order, and site set" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    baseline = CompactDynamicW262Fixture.structure(
      [uint8, string] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V1,
      legacy_max_dynamic_types: 2_u64,
    )
    context = CompactDynamicW262Fixture.prepared_context({"root" => baseline})

    changed_version = CompactDynamicW262Fixture.structure(
      [uint8, string] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V2,
    )
    changed_legacy = CompactDynamicW262Fixture.structure(
      [uint8, string] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V1,
      legacy_max_dynamic_types: 3_u64,
    )
    changed_order = CompactDynamicW262Fixture.structure(
      [string, uint8] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V1,
      legacy_max_dynamic_types: 2_u64,
    )

    {changed_version, changed_legacy, changed_order}.each do |changed|
      expect_raises(CrystalClick::CorruptPartError) do
        context.validate_granule_roster!({"root" => changed})
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      context.validate_granule_roster!({"not_root" => baseline})
    end
    expect_raises(CrystalClick::CorruptPartError) do
      context.validate_granule_roster!({"root" => baseline, "extra" => baseline})
    end
  end

  it "rejects incomplete/over-budget borrowed-input accounting without partial charge" do
    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, 5_i64, Bytes[1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      [] of String,
    )
    too_small = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(64, 4_096, 1_000_000, 4),
    )
    expect_raises(CrystalClick::CorruptPartError) { cursor.charge_complete_wire_input!(too_small) }
    too_small.wire_byte_count.should eq(0_i64)
    expect_raises(ArgumentError) { cursor.advance_borrowed_prefix(0) }

    writer_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    expect_raises(ArgumentError) { cursor.charge_complete_wire_input!(writer_budget) }
    writer_budget.wire_byte_count.should eq(0_i64)
  end

  it "binds the full mrk4 discovery roster and rejects an unconsumed trailing callback" do
    first = CrystalClick::CompactPartPhysicalShard.new(0, "first", 0_i64, 1_i64, Bytes[0x11_u8])
    second = CrystalClick::CompactPartPhysicalShard.new(1, "second", 0_i64, 1_i64, Bytes[0x22_u8])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactBinaryBulkGranuleCursor.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        [first, second],
        ["first", "first"],
      )
    end

    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      [first, second],
      nil,
    )
    cursor.validate_expected_events!(["first", "second"])
    expect_raises(CrystalClick::CorruptPartError) do
      cursor.validate_expected_events!(["second", "first"])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      cursor.validate_expected_events!(["first"])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      cursor.validate_expected_events!(["first", "second", "third"])
    end

    cursor.begin_next_discovery_event.should eq("first")
    cursor.read_exact(1).should eq(Bytes[0x11_u8])
    cursor.finish_event
    expect_raises(CrystalClick::CorruptPartError) { cursor.finish_granule }
  end

  it "records the mrk3 two-site interleaving grammar that discovery must preserve" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    declared_tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
    )
    declared_tuple.child_count.should eq(2)
    declared_tuple.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
    declared_tuple.child_at(1).tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)

    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
    structure = CrystalClick::DynamicStructure.new(
      [low_cardinality] of CrystalClick::BinaryDataType,
    )
    structure_prefix = CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(structure)
    variant_basic = CompactDynamicW262Fixture.u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE)
    variant_compact = CompactDynamicW262Fixture.u64_bytes(CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_MODE)
    arm_prefix = CompactDynamicW262Fixture.u64_bytes(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)

    tape_writer = IO::Memory.new
    tape_writer.write(structure_prefix) # Dynamic site 0 structure
    tape_writer.write(variant_basic)    # Dynamic site 0 implicit Variant prefix
    tape_writer.write(arm_prefix)       # Dynamic site 0 LowCardinality arm prefix
    tape_writer.write(structure_prefix) # Dynamic site 1 structure
    tape_writer.write(variant_compact)  # Dynamic site 1 implicit Variant prefix
    tape_writer.write(arm_prefix)       # Dynamic site 1 LowCardinality arm prefix
    tape = tape_writer.to_slice.dup
    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, tape.size.to_i64, tape)

    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      [] of String,
    )
    first_structure = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(
      cursor.read_exact(structure_prefix.size.to_i32),
    )
    first_structure.types.map(&.name).should eq(["LowCardinality(String)"])
    cursor.read_u64.should eq(CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE)
    cursor.read_u64.should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
    second_structure = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(
      cursor.read_exact(structure_prefix.size.to_i32),
    )
    second_structure.types.map(&.name).should eq(["LowCardinality(String)"])
    cursor.read_u64.should eq(CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_MODE)
    cursor.read_u64.should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
    cursor.finish_granule

    # This is a tape grammar control, not an invocation of production Dynamic
    # discovery. A structures-only pass would misread site 0's Variant mode
    # as the start of site 1's structure rather than skipping site 0's prefixes.
    structures_only = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      [] of String,
    )
    structures_only.read_exact(structure_prefix.size.to_i32)
    wrong_second_structure = structures_only.read_exact(structure_prefix.size.to_i32)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(wrong_second_structure)
    end
  end

  it "rejects reader budgets whose direction or declared limits disagree before opening storage" do
    dynamic = CompactDynamicW262Fixture.dynamic_type
    limits = CrystalClick::BinaryCodecLimits.default
    mismatch = CrystalClick::BinaryCodecLimits.new(
      limits.max_depth,
      limits.max_nodes,
      limits.max_elements,
      limits.max_bytes - 1,
    )

    expect_raises(ArgumentError) do
      CrystalClick::CompactDynamicBulkColumnReader.open(
        "/no/such/w262/part",
        "root",
        dynamic,
        codec_budget: CrystalClick::BinaryCodecBudget.new(mismatch),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactDynamicBulkColumnReader.open(
        "/no/such/w262/part",
        "root",
        dynamic,
        codec_budget: CrystalClick::BinaryCodecBudget.new(limits, true),
      )
    end
  end

  # This native-backed falsifier is opt-in so the portable suite does not
  # imply that an external ClickHouse capture is part of its default fixtures.
  if native_manifest_path = ENV["CRYSTAL_CLICK_W262_NATIVE_MANIFEST"]?
    it "accounts the live reader base during native Dynamic normalization" do
      manifest_bytes = File.read(native_manifest_path)
      manifest = JSON.parse(manifest_bytes).as_h
      native_parts = manifest["parts"].as_a
      native_record = native_parts.find do |entry|
        entry.as_h["label"].as_s == "mrk3_s0_vbasic"
      end || raise "native W262 manifest lacks mrk3_s0_vbasic"
      part_path = native_record.as_h["path"].as_s

      type = CompactDynamicW262Fixture.root_type
      column_name = "root"
      limits = CrystalClick::BinaryCodecLimits.default
      reader = CrystalClick::CompactDynamicBulkColumnReader.open(
        part_path,
        column_name,
        type,
        limits,
      )
      retained_base = reader.retained_workspace_bytes

      # Independently run the exact same normalizer over a second read-only
      # physical window. This gives a W+T reference without substituting a
      # synthetic writer or treating the test's scratch owners as reader B.
      scratch_context = CrystalClick::CompactPartPhysicalContext.open(part_path)
      scratch_window = scratch_context.read_window(column_name, 0, reader.mark_count)
      reader_observations = [] of UInt64
      reader_observer = ->(bytes : UInt64) {
        reader_observations << bytes
        nil
      }
      reader.read_marks(0, 0, reader_observer)

      reader_observations.size.should be > 3
      reader_observations[0].should eq(retained_base + reader.logical_read_bytes)
      reader_observations[1].should be >= retained_base
      physical_workspace = reader_observations[1] - retained_base

      normalizer = CrystalClick::CompactBinaryBulkNormalizer.new(
        type,
        column_name,
        reader.ordinary_profile,
        limits,
      )
      normalizer_observations = [] of UInt64
      normalizer_observer = ->(bytes : UInt64) {
        normalizer_observations << bytes
        nil
      }
      normalizer.normalize_dynamic(
        scratch_window,
        CrystalClick::BinaryCodecBudget.new(limits),
        normalizer_observer,
        physical_workspace,
      )

      normalizer_observations.should_not be_empty
      # The first two callbacks are reader preflight (B+logical and B+P); the
      # final callback is the post-prepare decode census. Only the middle
      # callbacks correspond to normalizer W+T and are relevant here.
      normalization_count = reader_observations.size - 3
      reader_normalization_peak = reader_observations[2, normalization_count].max
      normalizer_peak = normalizer_observations.max
      reader_normalization_peak.should be >= retained_base
      (reader_normalization_peak - retained_base).should be >= normalizer_peak
    end
  end
end
