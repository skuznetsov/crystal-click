require "./spec_helper"

describe "W299 Wide aggregate compressed-mark writer rollback" do
  it "writes authenticated compressed marks for the precomputed count constructor" do
    parent_stage = File.tempname("crystal-click-w299-writer-count-")
    begin
      Dir.mkdir(parent_stage)
      context = CrystalClick::WidePartWriter::WidePartOperationContext.new(
        2,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::ObjectDocumentCodec::DEFAULT_MODE,
        4096,
        0_i64,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        CrystalClick::CompressedStreamLimits.new,
      )
      projection = CrystalClick::WidePartProjection.precomputed_count(
        "by_count",
        "k",
        Slice[1_u64, 2_u64, 3_u64],
        Slice[2_u64, 1_u64, 2_u64],
        rows_per_mark: 2,
        compress_marks: true,
      )
      prepared = CrystalClick::WidePartWriter::WidePartPreparedProjection.prepare(
        File.join(parent_stage, "unused_parent"),
        projection,
        context,
        parent_row_count: 5_u64,
      )
      prepared.encode!
      prepared.publish(parent_stage)

      child = File.join(parent_stage, "by_count.proj")
      checksums = CrystalClick::PartChecksums.open(child)
      mark_entries = checksums.entries.select { |name, _entry| name.ends_with?(".cmrk2") }
      mark_entries.size.should eq(2)
      mark_entries.each_value do |entry|
        entry.compressed.should be_true
        entry.uncompressed_size.should eq(72_u64)
        entry.uncompressed_hash.should_not be_nil
      end
      checksums.entries.keys.none?(&.ends_with?(".mrk2")).should be_true
    ensure
      FileUtils.rm_rf(parent_stage) if Dir.exists?(parent_stage)
    end
  end

  it "cleans its child stage when authenticated mark readback exhausts the shared budget" do
    parent_stage = File.tempname("crystal-click-w299-writer-parent-")
    begin
      Dir.mkdir(parent_stage)
      read_limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 24)
      context = CrystalClick::WidePartWriter::WidePartOperationContext.new(
        2,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::ObjectDocumentCodec::DEFAULT_MODE,
        4096,
        0_i64,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
        CrystalClick::CompressedStreamLimits.new,
        read_transport_limits: read_limits,
      )
      projection = CrystalClick::WidePartProjection.precomputed_aggregate(
        "by_sum",
        "k",
        Slice[1_u64, 2_u64, 3_u64],
        [CrystalClick::WidePartProjectionAggregate.sum_uint64("value", Slice[11_u64, 22_u64, 33_u64])],
        rows_per_mark: 2,
        compress_marks: true,
      )
      prepared = CrystalClick::WidePartWriter::WidePartPreparedProjection.prepare(
        File.join(parent_stage, "unused_parent"),
        projection,
        context,
        parent_row_count: 4_u64,
      )
      prepared.encode!

      expect_raises(CrystalClick::CorruptPartError, /decoded-byte limit exceeded/) do
        prepared.publish(parent_stage)
      end

      # The second frame-header charge is the root key `.cmrk2` readback,
      # which runs only after the child stage has been created and populated.
      context.read_transport_budget.record_count.should eq(2_i64)
      context.read_transport_budget.decoded_byte_count.should eq(24_i64)
      Dir.children(parent_stage).should be_empty
      File.exists?(File.join(parent_stage, "by_sum.proj")).should be_false
    ensure
      FileUtils.rm_rf(parent_stage) if Dir.exists?(parent_stage)
    end
  end
end
