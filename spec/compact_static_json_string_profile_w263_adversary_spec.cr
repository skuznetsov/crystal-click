require "./spec_helper"
require "json"
require "file_utils"
require "../scripts/support/compact_json_w263_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_static_json_w263_adversary_fixture"
require "./support/compact_static_json_mrk4_chunked_w263_fixture"

private def w263_string_profile_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_string_profile_logical_tape(part_path : String) : Bytes
  data_path = File.join(part_path, "data.bin")
  CrystalClick::CompressedMarkReader.read_all(data_path, File.size(data_path).to_i64)
end

private def w263_string_profile_shard(
  physical : CrystalClick::CompactPartPhysicalContext,
  mark_index : Int32,
  stream_name : String,
) : CrystalClick::CompactPartPhysicalShard
  mark = physical.read_window("root", mark_index, 1).granules.first? ||
         raise CrystalClick::CorruptPartError.new("W263 adversary mark is absent")
  mark.shards.find { |shard| shard.stream_name == stream_name } ||
    raise CrystalClick::CorruptPartError.new("W263 adversary callback is absent: #{stream_name}")
end

private def w263_string_profile_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w263_string_profile_read_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w263_string_profile_native_source(label : String) : String
  evidence_root = CompactStaticJsonW263AdversaryFixture.evidence_root
  CompactStaticJsonW263AdversaryFixture.source_part(evidence_root, label)[:path]
end

private def w263_string_profile_assert_size_mutation_rejected(
  source_path : String,
  mark_index : Int32,
  size_stream : String,
  data_stream : String,
  expected_sizes : Array(UInt64),
  mutated_sizes : Array(UInt64),
) : Nil
  expected_sizes.size.should eq(mutated_sizes.size)
  parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_path)
  begin
    physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
    physical.mode.mrk4?.should be_true
    physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
    raw = w263_string_profile_logical_tape(copied_part)
    original_size = w263_string_profile_shard(physical, mark_index, size_stream)
    original_data = w263_string_profile_shard(physical, mark_index, data_stream)
    original_size.logical_end.should be > original_size.logical_start
    original_data.logical_end.should be > original_data.logical_start
    (original_size.logical_end - original_size.logical_start).should eq((expected_sizes.size * 8).to_i64)

    expected_sizes.each_with_index do |length, index|
      w263_string_profile_read_u64(original_size.bytes, index * 8).should eq(length)
    end
    expected_payload_bytes = 0_u64
    expected_sizes.each do |length|
      if length > UInt64::MAX - expected_payload_bytes
        raise CrystalClick::CorruptPartError.new("W263 expected String sizes overflow their aggregate")
      end
      expected_payload_bytes += length
    end
    original_data.bytes.size.to_u64.should eq(expected_payload_bytes)
    original_data_bytes = Bytes.new(original_data.bytes.size) { |index| original_data.bytes[index] }

    expected_sizes.each_with_index do |_length, index|
      w263_string_profile_write_u64(raw, original_size.logical_start.to_i32 + index * 8, mutated_sizes[index])
    end
    CompactStaticJsonMrk4ChunkedW263Fixture.rewrite_mrk4_tape!(copied_part, physical, raw)

    reopened = CrystalClick::CompactPartPhysicalContext.open(copied_part)
    mutated_size = w263_string_profile_shard(reopened, mark_index, size_stream)
    mutated_data = w263_string_profile_shard(reopened, mark_index, data_stream)
    mutated_size.logical_start.should eq(original_size.logical_start)
    mutated_size.logical_end.should eq(original_size.logical_end)
    mutated_data.logical_start.should eq(original_data.logical_start)
    mutated_data.logical_end.should eq(original_data.logical_end)
    mutated_sizes.each_with_index do |length, index|
      w263_string_profile_read_u64(mutated_size.bytes, index * 8).should eq(length)
    end
    mutated_data.bytes.should eq(original_data_bytes)

    reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      copied_part,
      "root",
      CompactJsonW263Fixture.json_type,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      reader.read_marks(reader.mark_count, 0)
    end
    expect_raises(ArgumentError) { reader.prepared_context }
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w263_string_profile_observed_nonempty_sizes(
  source_path : String,
  mark_index : Int32,
  size_stream : String,
  data_stream : String,
) : Array(UInt64)
  physical = CrystalClick::CompactPartPhysicalContext.open(source_path)
  size_shard = w263_string_profile_shard(physical, mark_index, size_stream)
  data_shard = w263_string_profile_shard(physical, mark_index, data_stream)
  size_shard.bytes.size.should be > 0
  (size_shard.bytes.size % 8).should eq(0)
  data_shard.bytes.size.should be > 0

  values = [] of UInt64
  total = 0_u64
  (size_shard.bytes.size // 8).times do |index|
    length = w263_string_profile_read_u64(size_shard.bytes, index * 8)
    if length > UInt64::MAX - total
      raise CrystalClick::CorruptPartError.new("W263 source String sizes overflow their aggregate")
    end
    total += length
    values << length
  end
  values.any? { |length| length > 0_u64 }.should be_true
  total.should eq(data_shard.bytes.size.to_u64)
  values
end

describe "Compact static JSON String profile adversaries (W263)" do
  it "rejects a late same-length S1 label-size corruption before publishing EOF preparation" do
    label = "obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_basic"
    source_path = w263_string_profile_native_source(label)

    pristine = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      source_path,
      "root",
      CompactJsonW263Fixture.json_type,
    )
    pristine.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.with_size_stream)
    pristine.read_marks(pristine.mark_count, 0).should be_empty

    parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_path)
    begin
      physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
      physical.mode.mrk4?.should be_true
      physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
      raw = w263_string_profile_logical_tape(copied_part)
      shard = w263_string_profile_shard(physical, 3, "root.label.size")
      (shard.logical_end - shard.logical_start).should eq(16_i64)
      offset = shard.logical_start.to_i32
      w263_string_profile_read_u64(raw, offset).should eq(6_u64)
      w263_string_profile_read_u64(raw, offset + 8).should eq(6_u64)

      # Replace one UInt64 length with an impossible value without changing
      # the callback extent or shifting any following whole-file coordinates.
      w263_string_profile_write_u64(raw, offset, UInt64::MAX)
      CompactStaticJsonMrk4ChunkedW263Fixture.rewrite_mrk4_tape!(copied_part, physical, raw)

      reopened = CrystalClick::CompactPartPhysicalContext.open(copied_part)
      poisoned_shard = w263_string_profile_shard(reopened, 3, "root.label.size")
      poisoned_shard.logical_start.should eq(shard.logical_start)
      poisoned_shard.logical_end.should eq(shard.logical_end)
      w263_string_profile_read_u64(poisoned_shard.bytes, 0).should eq(UInt64::MAX)

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        copied_part,
        "root",
        CompactJsonW263Fixture.json_type,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_marks(reader.mark_count, 0)
      end
      expect_raises(ArgumentError) { reader.prepared_context }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a later label-size overrun before publishing EOF preparation" do
    source_path = w263_string_profile_native_source("obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_basic")

    w263_string_profile_assert_size_mutation_rejected(
      source_path,
      3,
      "root.label.size",
      "root.label",
      [6_u64, 6_u64],
      [7_u64, 6_u64],
    )
  end

  it "rejects later label-size underconsumption before publishing EOF preparation" do
    source_path = w263_string_profile_native_source("obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_basic")

    w263_string_profile_assert_size_mutation_rejected(
      source_path,
      3,
      "root.label.size",
      "root.label",
      [6_u64, 6_u64],
      [5_u64, 6_u64],
    )
  end

  it "validates a later nonempty Dynamic SharedVariant String-size lane at EOF" do
    source_path = w263_string_profile_native_source("obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_basic")

    # Read the captured callback bytes rather than inferring a dense occurrence
    # count from the mark's row count. The source vector and payload must form
    # an exact nonempty extent before the same-width poison is introduced.
    observed_sizes = w263_string_profile_observed_nonempty_sizes(
      source_path,
      3,
      "root.sample.SharedVariant.size",
      "root.sample.SharedVariant",
    )
    poisoned_sizes = observed_sizes.dup
    poison_index = poisoned_sizes.index { |length| length > 0_u64 } ||
                   raise CrystalClick::CorruptPartError.new("W263 SharedVariant size lane has no nonempty value")
    poisoned_sizes[poison_index] = UInt64::MAX

    w263_string_profile_assert_size_mutation_rejected(
      source_path,
      3,
      "root.sample.SharedVariant.size",
      "root.sample.SharedVariant",
      observed_sizes,
      poisoned_sizes,
    )
  end

  it "defers a well-framed inner SharedVariant tag error until that mark is selected" do
    label = "obj_v3_dyn_v3_advanced_chunked_mrk4_s1_variant_basic"
    source_path = w263_string_profile_native_source(label)
    parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_path)
    begin
      physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
      raw = w263_string_profile_logical_tape(copied_part)
      shard = w263_string_profile_shard(physical, 0, "root.sample.SharedVariant")
      (shard.logical_end - shard.logical_start).should eq(9_i64)
      offset = shard.logical_start.to_i32
      raw[offset].should_not eq(0xff_u8)

      # The String-v1 payload contains a BinaryValue. Changing only its type
      # tag leaves the separate size lane and all callback boundaries intact.
      raw[offset] = 0xff_u8
      CompactStaticJsonMrk4ChunkedW263Fixture.rewrite_mrk4_tape!(copied_part, physical, raw)

      reopened = CrystalClick::CompactPartPhysicalContext.open(copied_part)
      poisoned_shard = w263_string_profile_shard(reopened, 0, "root.sample.SharedVariant")
      (poisoned_shard.logical_end - poisoned_shard.logical_start).should eq(9_i64)
      poisoned_shard.byte_at(0).should eq(0xff_u8)

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        copied_part,
        "root",
        CompactJsonW263Fixture.json_type,
      )
      reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.with_size_stream)
      # Empty selection at EOF performs whole-part framing/prefix preparation
      # without decoding the poisoned value envelope.
      reader.read_marks(reader.mark_count, 0).should be_empty

      # The last mark remains independently readable while the malformed
      # first-mark value is still unselected.
      later = reader.read_marks(3, 1)
      later.size.should eq(1)
      later[0].map { |document| w263_string_profile_document_signature(document) }
        .should eq(CompactJsonW263Fixture.root_values[6, 2].map { |value| CompactJsonW263Fixture.value_signature(value) })

      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_marks(0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "uses effective nested String v0 for a metadata-only S0 MAP propagation-false control" do
    label = "obj_v2_dyn_v2_map_mrk4_s0_variant_basic"
    source_path = w263_string_profile_native_source(label)
    original_metadata = JSON.parse(File.read(File.join(source_path, "serialization.json")))
    original_versions = original_metadata["types_serialization_versions"].as_h
    original_versions["string"].as_i.should eq(0)
    original_metadata["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true

    parent, copied_part = CompactStaticJsonW263AdversaryFixture.copy_part(source_path)
    begin
      metadata_path = File.join(copied_part, "serialization.json")
      metadata = JSON.parse(File.read(metadata_path)).as_h
      versions = metadata["types_serialization_versions"].as_h
      versions["string"] = JSON::Any.new(1_i64)
      # Keep the MAP setting absent/default or explicitly BASIC. This control
      # changes only the synthetic global String declaration and propagation.
      (versions["map"]?.try(&.as_i) || 0).should eq(0)
      metadata["propagate_types_serialization_versions_to_nested_types"] = JSON::Any.new(false)
      File.write(metadata_path, JSON::Any.new(metadata).to_json)
      CompactPhysicalContextW259Fixture.refresh_checksums(copied_part)

      mutated_metadata = JSON.parse(File.read(metadata_path))
      mutated_metadata["types_serialization_versions"]["string"].as_i.should eq(1)
      mutated_metadata["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_false
      (mutated_metadata["types_serialization_versions"]["map"]?.try(&.as_i) || 0).should eq(0)

      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        copied_part,
        "root",
        CompactJsonW263Fixture.json_type,
      )
      reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.single_stream)
      reader.read_marks(reader.mark_count, 0).should be_empty
      actual = reader.read_marks(0, reader.mark_count).flat_map do |mark|
        mark.map { |document| w263_string_profile_document_signature(document) }
      end
      expected = CompactJsonW263Fixture.root_values.map do |value|
        CompactJsonW263Fixture.value_signature(value)
      end
      actual.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
