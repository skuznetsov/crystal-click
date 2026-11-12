require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w278_fixture"

private def w278_assert_refusal_has_no_side_effect(parent : String, target : String) : Nil
  File.exists?(target).should be_false
  Dir.children(parent).sort.should eq(["keep.txt"])
  File.read(File.join(parent, "keep.txt")).should eq("unrelated")
  nil
end

private def w278_expect_resource_refusal(
  part_path : String,
  transport_limits : CrystalClick::CompressedStreamLimits,
) : Nil
  fixture = CompactPartWriterW278Fixture
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW278Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns(2_u64),
      rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
      frame_bytes: 64,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      transport_limits: transport_limits,
    )
  end
  nil
end

private def w278_relocation_plan_at_mark_zero : Tuple(
  Array(CrystalClick::CompactPartEncodedColumn),
  UInt64,
  Int32,
)
  fixture = CompactPartWriterW278Fixture
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  input = fixture.column(CompactPartWriterW278Fixture::ARRAY_COLUMN, 2_u64).json_input
  callback_plan = CrystalClick::CompactJsonCallbackPlan.new(input, limits, codec_budget)
  encoded_column = CrystalClick::CompactJsonEncodedColumn.encode(callback_plan, codec_budget)
  encoded_columns = [] of CrystalClick::CompactPartEncodedColumn
  encoded_columns << encoded_column

  raw_size = 0_u64
  encoded_column.each_callback_event do |callback|
    raw_size += encoded_column.callback_bytes(callback, 0).size.to_u64
  end
  {encoded_columns, raw_size, encoded_column.callback_relocation_count_at(0)}
end

describe "W278 advanced JSON writer adversaries" do
  it "rejects advanced shared versions with invalid bucket grids at the shape boundary" do
    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new(
        [CompactPartWriterW278Fixture::PAYLOAD_PATH] of String,
        version: 4_u64,
        shared_data_version: 2_u64,
        bucket_count: 0_u64,
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectStructure.new(
        [CompactPartWriterW278Fixture::PAYLOAD_PATH] of String,
        version: 4_u64,
        shared_data_version: 4_u64,
        bucket_count: 2_u64,
      )
    end
  end

  it "preserves an unrelated sentinel and publishes no part on bounded transport refusal" do
    parent = File.tempname("crystal-click-w278-transport-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      File.write(File.join(parent, "keep.txt"), "unrelated")
      w278_expect_resource_refusal(
        part_path,
        CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1),
      )
      w278_assert_refusal_has_no_side_effect(parent, part_path)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not replace or mutate an existing destination" do
    parent = File.tempname("crystal-click-w278-existing-destination-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      Dir.mkdir(part_path)
      sentinel = File.join(part_path, "sentinel")
      File.write(sentinel, "existing")
      fixture = CompactPartWriterW278Fixture
      expect_raises(ArgumentError) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW278Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns(2_u64),
          rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
          frame_bytes: 64,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        )
      end
      Dir.children(part_path).should eq(["sentinel"])
      File.read(sentinel).should eq("existing")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "leaves the raw granule unchanged when the last relocation escapes local EOF" do
    encoded_columns, raw_size, relocation_count = w278_relocation_plan_at_mark_zero
    relocation_count.should be >= 2
    first_aux_query_index = 2
    plan = CrystalClick::CompactGranuleRelocationPlan.new(
      encoded_columns,
      0,
      first_aux_query_index,
      raw_size,
      [0_u64] of UInt64,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
    )
    plan.target_query_count.should eq(relocation_count)

    queries = [{0_u64, 0_u64}, {5_u64, 0_u64}] of Tuple(UInt64, UInt64)
    malformed_target_index = first_aux_query_index + relocation_count - 1
    relocation_count.times do |index|
      # Earlier target coordinates are inside the local segment. The final
      # one is beyond this mark's EOF but still inside the whole data file.
      queries << if index == relocation_count - 1
        {6_u64, 0_u64}
      else
        {2_u64, 0_u64}
      end
    end
    malformed_target_index.should eq(queries.size - 1)

    raw_segment = Bytes.new(raw_size.to_i) { |index| (index % 251).to_u8 }
    original = Bytes.new(raw_segment.size) { |index| raw_segment[index] }
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.patch!(raw_segment, queries, 10_u64, 100_u64, 64)
    end
    raw_segment.should eq(original)
  end

  it "leaves the raw granule unchanged when a target frame offset is out of bounds" do
    encoded_columns, raw_size, relocation_count = w278_relocation_plan_at_mark_zero
    relocation_count.should be >= 2
    first_aux_query_index = 2
    plan = CrystalClick::CompactGranuleRelocationPlan.new(
      encoded_columns,
      0,
      first_aux_query_index,
      raw_size,
      [0_u64] of UInt64,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
    )

    queries = [{0_u64, 0_u64}, {5_u64, 0_u64}] of Tuple(UInt64, UInt64)
    relocation_count.times do |index|
      # Keep the first target valid; the final target has a valid earlier
      # frame number but an impossible within-frame offset.
      queries << if index == relocation_count - 1
        {2_u64, UInt64::MAX}
      else
        {2_u64, 0_u64}
      end
    end

    raw_segment = Bytes.new(raw_size.to_i) { |index| (index % 251).to_u8 }
    original = Bytes.new(raw_segment.size) { |index| raw_segment[index] }
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.patch!(raw_segment, queries, 10_u64, 100_u64, 64)
    end
    raw_segment.should eq(original)
  end

  it "rejects stale column and query grids without mutating caller state" do
    encoded_columns, raw_size, relocation_count = w278_relocation_plan_at_mark_zero
    relocation_count.should be > 0
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    expect_raises(ArgumentError) do
      CrystalClick::CompactGranuleRelocationPlan.new(
        encoded_columns, 0, 2, raw_size, [] of UInt64,
        CrystalClick::BinaryCodecBudget.new(limits, true),
      )
    end

    plan = CrystalClick::CompactGranuleRelocationPlan.new(
      encoded_columns, 0, 2, raw_size, [0_u64] of UInt64,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    stale_queries = [0_u64] of UInt64
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.append_target_queries!(stale_queries)
    end
    stale_queries.should eq([0_u64])

    raw_segment = Bytes.new(raw_size.to_i, 0xa5_u8)
    original = raw_segment.dup
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.patch!(raw_segment, [{0_u64, 0_u64}, {5_u64, 0_u64}], 10_u64, 100_u64, 64)
    end
    raw_segment.should eq(original)
  end
end
