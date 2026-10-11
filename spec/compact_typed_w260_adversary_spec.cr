require "./spec_helper"
require "../scripts/support/compact_typed_w260_fixture"

private def w260_adversary_profile(
  part_path : String,
  type_name : String,
  record : String,
  versions : String = "{}",
  propagate : Bool = true,
) : CrystalClick::CompactSerializationProfile
  json = CompactTypedW260Fixture.profile_envelope([record], versions, propagate)
  CompactTypedW260Fixture.write_profile_metadata(part_path, json)
  CompactTypedW260Fixture.open_profile(part_path, "payload", type_name, 2_u64)
end

describe CrystalClick::CompactSerializationProfile do
  it "checks later nested Tuple common counts before returning an earlier unsupported shape" do
    root = File.tempname("crystal-click-w260-tuple-common-count-")
    begin
      earlier_unsupported = "{\"kind\":\"Custom\",\"num_defaults\":0,\"num_rows\":2}"
      later_malformed = "{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":3}"
      tuple_record = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2," \
                     "\"subcolumns\":[#{earlier_unsupported},#{later_malformed}]}"

      expect_raises(CrystalClick::CorruptPartError) do
        w260_adversary_profile(root, "Tuple(a UInt64, b String)", tuple_record)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "refuses non-BASIC Map, unpropagated nested String v1, and unknown String versions" do
    map_root = File.tempname("crystal-click-w260-map-profile-")
    nested_root = File.tempname("crystal-click-w260-nested-string-profile-")
    version_root = File.tempname("crystal-click-w260-string-version-profile-")
    begin
      map_record = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2}"
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w260_adversary_profile(map_root, "Map(String, UInt64)", map_record, "{\"map\":1}")
      end

      array_string_record = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2}"
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w260_adversary_profile(nested_root, "Array(String)", array_string_record, "{\"string\":1}", false)
      end

      string_record = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2}"
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w260_adversary_profile(version_root, "String", string_record, "{\"string\":2}", false)
      end
    ensure
      FileUtils.rm_rf(map_root)
      FileUtils.rm_rf(nested_root)
      FileUtils.rm_rf(version_root)
    end
  end

  it "does not relax Tuple subcolumn arity when optional exact flags are absent" do
    root = File.tempname("crystal-click-w260-tuple-arity-")
    begin
      one_child = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2," \
                  "\"subcolumns\":[{\"kind\":\"Default\",\"num_defaults\":0,\"num_rows\":2}]}"
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w260_adversary_profile(root, "Tuple(a UInt64, b String)", one_child)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a present top-level Tuple Default record without subcolumns" do
    root = File.tempname("crystal-click-w260-tuple-missing-subcolumns-")
    begin
      tuple_record = "{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":0,\"num_rows\":2}"
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w260_adversary_profile(root, "Tuple(a UInt64, b String)", tuple_record)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

describe CrystalClick::TypedBinaryBulkColumnReader do
  it "rejects borrowed budget mismatches before reading part metadata" do
    type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("UInt64").not_nil!
    missing_part = File.tempname("crystal-click-w260-budget-dispatch-")
    default_codec_limits = CrystalClick::BinaryCodecLimits.default
    default_transport_limits = CrystalClick::CompressedStreamLimits.new

    mismatched_codec_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: default_codec_limits.max_depth,
      max_nodes: default_codec_limits.max_nodes,
      max_elements: default_codec_limits.max_elements,
      max_bytes: default_codec_limits.max_bytes - 1,
    )
    codec_budget = CrystalClick::BinaryCodecBudget.new(mismatched_codec_limits)
    expect_raises(ArgumentError) do
      CrystalClick::TypedBinaryBulkColumnReader.open(
        missing_part,
        "payload",
        type,
        codec_budget: codec_budget,
      )
    end
    codec_budget.node_count.should eq(0_i64)
    codec_budget.element_count.should eq(0_i64)
    codec_budget.wire_byte_count.should eq(0_i64)

    mismatched_transport_limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: default_transport_limits.max_file_bytes - 1,
      max_mark_bytes: default_transport_limits.max_mark_bytes,
      max_frame_compressed_bytes: default_transport_limits.max_frame_compressed_bytes,
      max_frame_decompressed_bytes: default_transport_limits.max_frame_decompressed_bytes,
      max_records: default_transport_limits.max_records,
      max_decoded_bytes: default_transport_limits.max_decoded_bytes,
      max_result_bytes: default_transport_limits.max_result_bytes,
    )
    transport_budget = CrystalClick::CompressedStreamBudget.new(mismatched_transport_limits)
    expect_raises(ArgumentError) do
      CrystalClick::TypedBinaryBulkColumnReader.open(
        missing_part,
        "payload",
        type,
        transport_budget: transport_budget,
      )
    end
    transport_budget.file_byte_count.should eq(0_i64)
    transport_budget.record_count.should eq(0_i64)
    transport_budget.decoded_byte_count.should eq(0_i64)
    transport_budget.result_byte_count.should eq(0_i64)

    write_budget = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(ArgumentError) do
      CrystalClick::TypedBinaryBulkColumnReader.open(
        missing_part,
        "payload",
        type,
        transport_budget: write_budget,
      )
    end
    write_budget.file_byte_count.should eq(0_i64)
    write_budget.record_count.should eq(0_i64)
    write_budget.decoded_byte_count.should eq(0_i64)
    write_budget.result_byte_count.should eq(0_i64)
  end
end

describe CrystalClick::WidePart do
  it "keeps root Nothing in the codec grammar but excludes it from generic selected-column admission" do
    nothing = CrystalClick::StaticBinaryBulkColumnDeclaration.parse("Nothing").not_nil!
    nothing.tag.should eq(CrystalClick::BinaryDataType::TAG_NOTHING)
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?("Nothing").should be_false
    CrystalClick::WidePart.supports_static_binary_bulk_type?("Nothing").should be_false

    # Preserve recursive Nothing forms in the codec-driven generic route; this
    # local guard scope is not a qualification of native storable profiles.
    ["Array(Nothing)", "Nullable(Nothing)"].each do |declaration|
      CrystalClick::StaticBinaryBulkColumnDeclaration.parse(declaration).should_not be_nil
      CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(declaration).should be_true
    end

    # The established Dynamic owner remains separate from generic static
    # admission, so the root-Nothing guard cannot widen or disable that route.
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic").should be_nil
    CrystalClick::WidePart.supports_typed_type?("Dynamic").should be_true
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?("Dynamic").should be_false
  end
end
