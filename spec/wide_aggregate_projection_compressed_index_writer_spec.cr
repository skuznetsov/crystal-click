require "./spec_helper"

describe "W300 Wide aggregate compressed primary-index writer" do
  it "preserves the compressed-key option through binding and encodes multiple frames plus the final key" do
    parent_stage = File.tempname("crystal-click-w300-primary-index-")
    begin
      Dir.mkdir(parent_stage)
      context = CrystalClick::WidePartWriter::WidePartOperationContext.new(
        2,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::ObjectDocumentCodec::DEFAULT_MODE,
        9,
        0_i64,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        CrystalClick::CompressedStreamLimits.new,
      )
      projection = CrystalClick::WidePartProjection.precomputed_count(
        "by_count",
        "k",
        Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64],
        Slice[1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64],
        rows_per_mark: 2,
        compress_primary_key: true,
      )
      binding = CrystalClick::PartSchemaBinding.new(
        "k",
        [
          {"k", "UInt64"},
          {"count()", CrystalClick::WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME},
        ] of Tuple(String, String),
        "projection",
      )
      bound_projection = projection.with_schema_binding(binding)
      bound_projection.compress_primary_key.should be_true
      prepared = CrystalClick::WidePartWriter::WidePartPreparedProjection.prepare(
        File.join(parent_stage, "unused_parent"),
        bound_projection,
        context,
        parent_row_count: 6_u64,
      )
      prepared.encode!
      prepared.publish(parent_stage)

      child = File.join(parent_stage, "by_count.proj")
      File.exists?(File.join(child, "primary.cidx")).should be_true
      File.exists?(File.join(child, "primary.idx")).should be_false
      checksums = CrystalClick::PartChecksums.open(child)
      entry = checksums.entry("primary.cidx").not_nil!
      entry.compressed.should be_true
      entry.uncompressed_size.should eq(32_u64)
      raw_index = Bytes.new(32)
      [10_u64, 30_u64, 50_u64, 60_u64].each_with_index do |value, index|
        IO::ByteFormat::LittleEndian.encode(value, raw_index[index * 8, 8])
      end
      entry.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(raw_index))
      physical_index = File.read(File.join(child, "primary.cidx")).to_slice
      frame_index = CrystalClick::CompressedFrameIndex.new(
        physical_index,
        CrystalClick::CompressedStreamLimits.new,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      frame_index.frames.size.should be > 1
      opened = CrystalClick::PrimaryKeyIndex.open(child, 3, checksums, verify_recorded_hash: true)
      opened.keys.should eq([10_u64, 30_u64, 50_u64, 60_u64])
      checksums.entries.keys.none?(&.ends_with?(".cmrk2")).should be_true
      checksums.entries.keys.any?(&.ends_with?(".mrk2")).should be_true
    ensure
      FileUtils.rm_rf(parent_stage) if Dir.exists?(parent_stage)
    end
  end

  it "rolls back a Compact parent when a later cidx exceeds the read budget shared with a value lane" do
    control_parent = File.tempname("crystal-click-w300-index-budget-control-")
    failed_root = File.tempname("crystal-click-w300-index-budget-failure-")
    begin
      Dir.mkdir(control_parent)
      Dir.mkdir(failed_root)
      read_limits = CrystalClick::CompressedStreamLimits.new
      context = CrystalClick::WidePartWriter::WidePartOperationContext.new(
        2,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::ObjectDocumentCodec::DEFAULT_MODE,
        9,
        0_i64,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        CrystalClick::CompressedStreamLimits.new,
        read_transport_limits: read_limits,
      )
      first = CrystalClick::WidePartProjection.precomputed_count(
        "by_marks",
        "k",
        Slice[10_u64, 30_u64, 50_u64],
        Slice[2_u64, 2_u64, 2_u64],
        rows_per_mark: 2,
        compress_marks: true,
      )
      second = CrystalClick::WidePartProjection.precomputed_count(
        "by_index",
        "k",
        Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64],
        Slice[1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 1_u64],
        rows_per_mark: 2,
        compress_primary_key: true,
      )
      first_prepared = CrystalClick::WidePartWriter::WidePartPreparedProjection.prepare(
        File.join(control_parent, "unused_parent"), first, context, parent_row_count: 6_u64
      )
      first_prepared.encode!
      first_prepared.publish(control_parent)
      value_lane_decoded_bytes = context.read_transport_budget.decoded_byte_count
      value_lane_decoded_bytes.should be > 0_i64
      Dir.exists?(File.join(control_parent, "by_marks.proj")).should be_true

      parent_path = File.join(failed_root, "all_1_1_0")
      parent_keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
      parent_values = CrystalClick::CompactPartColumn.binary_bulk(
        "value",
        CrystalClick::BinaryDataType.primitive("UInt64"),
        [
          [CrystalClick::BinaryValue.uint64(101_u64), CrystalClick::BinaryValue.uint64(102_u64)],
          [CrystalClick::BinaryValue.uint64(103_u64), CrystalClick::BinaryValue.uint64(104_u64)],
          [CrystalClick::BinaryValue.uint64(105_u64), CrystalClick::BinaryValue.uint64(106_u64)],
        ] of Array(CrystalClick::BinaryValue),
      )
      limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: value_lane_decoded_bytes)
      expect_raises(CrystalClick::CorruptPartError, /decoded-byte limit exceeded/) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          parent_path,
          "id",
          parent_keys,
          [parent_values] of CrystalClick::CompactPartColumn,
          rows_per_mark: 2,
          frame_bytes: 9,
          reader_limits: limits,
          projections: [first, second],
        )
      end

      File.exists?(parent_path).should be_false
      Dir.children(failed_root).should be_empty
    ensure
      FileUtils.rm_rf(control_parent) if Dir.exists?(control_parent)
      FileUtils.rm_rf(failed_root) if Dir.exists?(failed_root)
    end
  end
end
