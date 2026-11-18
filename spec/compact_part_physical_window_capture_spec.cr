require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_part_writer_w278_fixture"

private def compact_window_capture_write(part_path : String) : Nil
  fixture = CompactPartWriterW278Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW278Fixture::KEY_NAME,
    fixture.keys,
    [fixture.column(CompactPartWriterW278Fixture::ROOT_COLUMN, 2_u64)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW278Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
  ).should eq(part_path)
  nil
end

private def compact_window_capture_write_part(part_path : String, first_key : UInt64 = 1_u64) : Nil
  fixture = CompactPartWriterW278Fixture
  keys = Slice(UInt64).new(CompactPartWriterW278Fixture::ROW_COUNT) do |index|
    first_key + index.to_u64
  end
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW278Fixture::KEY_NAME,
    keys,
    [fixture.column(CompactPartWriterW278Fixture::ROOT_COLUMN, 2_u64)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
    frame_bytes: 64,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
  ).should eq(part_path)
  nil
end

private def compact_window_capture_touched_frames(
  physical : CrystalClick::CompactPartPhysicalContext,
  mark_index : Int32,
) : Set(Int32)
  granule = physical.read_window(
    CompactPartWriterW278Fixture::ROOT_COLUMN,
    mark_index,
    1,
  ).granules.first
  touched = Set(Int32).new
  granule.shards.each do |shard|
    first, limit = physical.frame_index.touched_frame_bounds(shard.logical_start, shard.logical_end)
    (first...limit).each { |index| touched.add(index) }
  end
  touched
end

private def compact_window_capture_transport_state(
  budget : CrystalClick::CompressedStreamBudget,
) : Tuple(Int64, Int64, Int64, Int64)
  {
    budget.file_byte_count,
    budget.record_count,
    budget.decoded_byte_count,
    budget.result_byte_count,
  }
end

private def compact_window_capture_coordinate_records(
  capture : CrystalClick::CompactPartPhysicalWindowCapture,
) : Int64
  capture.granules.sum { |granule| 2_i64 * granule.shards.size.to_i64 }
end

private def compact_window_capture_framer(
  physical : CrystalClick::CompactPartPhysicalContext,
  capture : CrystalClick::CompactPartPhysicalWindowCapture,
  mark_index : Int32,
  shards : Array(CrystalClick::CompactPartPhysicalShard),
  budget : CrystalClick::BinaryCodecBudget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
) : CrystalClick::CompactJsonObjectSiteFramer
  CrystalClick::CompactJsonObjectSiteFramer.new(
    physical.mode,
    shards,
    budget,
    physical,
    "root_json:mark=#{mark_index}",
    capture,
    mark_index,
  )
end

describe "Compact physical window source capture" do
  it "reuses only a full authenticated snapshot and keeps public shard checks fresh" do
    parent = File.tempname("crystal-click-physical-window-capture-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      compact_window_capture_write(part_path)

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      budget = physical.transport_budget
      capture = CrystalClick::CompactPartPhysicalWindowCapture.read_complete(
        physical,
        CompactPartWriterW278Fixture::ROOT_COLUMN,
      )
      capture.granules.size.should eq(CompactPartWriterW278Fixture::MARK_COUNT)
      after_capture = compact_window_capture_transport_state(budget)

      capture.granules.each_with_index do |granule, mark_index|
        framer = compact_window_capture_framer(physical, capture, mark_index.to_i32, granule.shards)
        framer.should be_a(CrystalClick::CompactJsonObjectSiteFramer)
      end
      captured_setup = compact_window_capture_transport_state(budget)
      captured_setup.should eq({
        after_capture[0],
        after_capture[1] + compact_window_capture_coordinate_records(capture),
        after_capture[2],
        after_capture[3],
      })

      first_granule = capture.granules.first
      before_missing_owner = compact_window_capture_transport_state(budget)
      expect_raises(ArgumentError) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical.mode,
          first_granule.shards,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
          nil,
          nil,
          capture,
          0,
        )
      end
      compact_window_capture_transport_state(budget).should eq(before_missing_owner)

      before_wrong_site = compact_window_capture_transport_state(budget)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical.mode,
          first_granule.shards,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
          physical,
          "root_json:mark=1",
          capture,
          0,
        )
      end
      after_wrong_site = compact_window_capture_transport_state(budget)
      after_wrong_site.should eq({
        before_wrong_site[0],
        before_wrong_site[1] + 2_i64 * first_granule.shards.size.to_i64,
        before_wrong_site[2],
        before_wrong_site[3],
      })

      # Caller-provided detached shards keep the independent source reread.
      direct_granule = capture.granules.first
      CrystalClick::CompactJsonObjectSiteFramer.new(
        physical.mode,
        direct_granule.shards,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        physical,
        "root_json:mark=0",
      )
      direct_read = compact_window_capture_transport_state(budget)
      (direct_read[0] > after_capture[0] || direct_read[1] > after_capture[1] ||
        direct_read[2] > after_capture[2] || direct_read[3] > after_capture[3]).should be_true

      # An externally mutable shard name cannot be used as an authenticated
      # alias of the capture's private window.
      mutated_shards = capture.granules.first.shards
      mutated_name = mutated_shards.first.stream_name.not_nil!
      mutated_name.to_unsafe[0] = 'x'.ord.to_u8
      expect_raises(CrystalClick::CorruptPartError) do
        compact_window_capture_framer(physical, capture, 0, mutated_shards)
      end
      after_mutated_name = compact_window_capture_transport_state(budget)
      after_mutated_name.should eq({
        direct_read[0],
        direct_read[1] + 2_i64 * mutated_shards.size.to_i64,
        direct_read[2],
        direct_read[3],
      })

      forged_shards = capture.granules.first.shards
      payload_index = forged_shards.index { |shard| !shard.bytes.empty? }.not_nil!
      original_shard = forged_shards[payload_index]
      forged_payload = original_shard.bytes
      forged_payload[0] ^= 0x01_u8
      forged_shards[payload_index] = CrystalClick::CompactPartPhysicalShard.new(
        original_shard.slot_index,
        original_shard.stream_name,
        original_shard.logical_start,
        original_shard.logical_end,
        forged_payload,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        compact_window_capture_framer(physical, capture, 0, forged_shards)
      end
      after_payload_mismatch = compact_window_capture_transport_state(budget)
      after_payload_mismatch.should eq({
        after_mutated_name[0],
        after_mutated_name[1] + 2_i64 * forged_shards.size.to_i64,
        after_mutated_name[2],
        after_mutated_name[3],
      })

      foreign = CrystalClick::CompactPartPhysicalContext.open(part_path)
      foreign_shards = capture.granules.first.shards
      foreign_before = compact_window_capture_transport_state(foreign.transport_budget)
      expect_raises(CrystalClick::CorruptPartError) do
        compact_window_capture_framer(foreign, capture, 0, foreign_shards)
      end
      compact_window_capture_transport_state(foreign.transport_budget).should eq({
        foreign_before[0],
        foreign_before[1] + 2_i64 * foreign_shards.size.to_i64,
        foreign_before[2],
        foreign_before[3],
      })
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "treats one full-grid read as a snapshot and remaps the path on the next capture" do
    parent = File.tempname("crystal-click-physical-window-replacement-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      compact_window_capture_write(part_path)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      capture = CrystalClick::CompactPartPhysicalWindowCapture.read_complete(
        physical,
        CompactPartWriterW278Fixture::ROOT_COLUMN,
      )
      first = capture.granules.first

      data_path = File.join(part_path, "data.bin")
      replacement_path = File.join(part_path, "data.bin.replacement")
      replacement = writable_file_bytes(data_path)
      replacement[0] ^= 0x01_u8
      File.open(replacement_path, "wb") { |io| io.write(replacement) }
      File.rename(replacement_path, data_path)

      # The detached authenticated snapshot remains usable for this prepared
      # read, while a new full-grid preparation follows the replacement path.
      compact_window_capture_framer(physical, capture, 0, first.shards)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalWindowCapture.read_complete(
          physical,
          CompactPartWriterW278Fixture::ROOT_COLUMN,
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accounts captured coordinate owners exactly under a finite transport budget" do
    parent = File.tempname("crystal-click-physical-window-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      compact_window_capture_write(part_path)

      measured_budget = CrystalClick::CompressedStreamBudget.read_default
      measured_physical = CrystalClick::CompactPartPhysicalContext.open(part_path, measured_budget)
      measured_capture = CrystalClick::CompactPartPhysicalWindowCapture.read_complete(
        measured_physical,
        CompactPartWriterW278Fixture::ROOT_COLUMN,
      )
      measured = compact_window_capture_transport_state(measured_budget)
      record_limit = measured[1] + compact_window_capture_coordinate_records(measured_capture)
      default_limits = CrystalClick::CompressedStreamLimits.new
      finite_limits = CrystalClick::CompressedStreamLimits.new(
        max_file_bytes: measured[0],
        max_records: record_limit,
        max_decoded_bytes: measured[2],
        max_result_bytes: measured[3],
        max_mark_bytes: default_limits.max_mark_bytes,
        max_frame_compressed_bytes: default_limits.max_frame_compressed_bytes,
        max_frame_decompressed_bytes: default_limits.max_frame_decompressed_bytes,
      )
      finite_budget = CrystalClick::CompressedStreamBudget.new(finite_limits)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path, finite_budget)
      capture = CrystalClick::CompactPartPhysicalWindowCapture.read_complete(
        physical,
        CompactPartWriterW278Fixture::ROOT_COLUMN,
      )
      capture.granules.each_with_index do |granule, mark_index|
        compact_window_capture_framer(physical, capture, mark_index.to_i32, granule.shards)
      end
      compact_window_capture_transport_state(finite_budget).should eq({
        measured[0],
        record_limit,
        measured[2],
        measured[3],
      })

      first = capture.granules.first
      before_fallback = compact_window_capture_transport_state(finite_budget)
      expect_raises(CrystalClick::CorruptPartError, /header-record limit exceeded/) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical.mode,
          first.shards,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
          physical,
          "root_json:mark=0",
        )
      end
      compact_window_capture_transport_state(finite_budget).should eq(before_fallback)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights every selected part before its first callback" do
    parent = File.tempname("crystal-click-physical-window-multiparts-")
    first_part = File.join(parent, "all_1_1_0")
    second_part = File.join(parent, "all_2_2_0")
    begin
      Dir.mkdir(parent)
      compact_window_capture_write_part(first_part)
      compact_window_capture_write_part(second_part, 9_u64)

      second_physical = CrystalClick::CompactPartPhysicalContext.open(second_part)
      # Mark 3 is outside the selected mark-0 candidate set; full-grid
      # preparation on every selected part must still authenticate it.
      bad_frame = compact_window_capture_touched_frames(second_physical, 3).first
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(second_part, bad_frame)

      table = CrystalClick::TypedPartTable.open_selected_typed(
        [first_part, second_part],
        [
          CompactPartWriterW278Fixture::KEY_NAME,
          CompactPartWriterW278Fixture::ROOT_COLUMN,
        ],
      )
      emitted = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[0_i32], [0_i32]]) do |_batch|
          emitted += 1
        end
      end
      emitted.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rechecks between exposed mark batches and can reenter after late corruption" do
    parent = File.tempname("crystal-click-physical-window-late-mutation-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      compact_window_capture_write_part(part_path)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      first_frames = compact_window_capture_touched_frames(physical, 0)
      later_frame = compact_window_capture_touched_frames(physical, 1).find do |index|
        !first_frames.includes?(index)
      end || raise "W278 fixture has no frame unique to mark 1"
      original_data = File.read(File.join(part_path, "data.bin")).to_slice.dup
      original_checksums = File.read(File.join(part_path, "checksums.txt"))

      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [
          CompactPartWriterW278Fixture::KEY_NAME,
          CompactPartWriterW278Fixture::ROOT_COLUMN,
        ],
      )
      emitted = 0
      owned_first_batch = [] of String
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[0_i32, 1_i32]]) do |batch|
          emitted += 1
          owned_first_batch = batch.object_documents_for(CompactPartWriterW278Fixture::ROOT_COLUMN).map do |document|
            document.value_for("id").as_uint64.to_s
          end.to_a
          if emitted == 1
            CompactPhysicalContextW259Fixture.corrupt_frame_payload(part_path, later_frame)
          end
        end
      end
      emitted.should eq(1)
      owned_first_batch.should eq(["1", "2"])

      repeated_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[0_i32, 1_i32]]) do |_batch|
          repeated_callbacks += 1
        end
      end
      repeated_callbacks.should eq(0)

      File.write(File.join(part_path, "data.bin"), original_data)
      File.write(File.join(part_path, "checksums.txt"), original_checksums)
      recovered = 0
      table.scan_typed_candidate_marks([[0_i32, 1_i32]]) do |batch|
        recovered += 1
        if recovered == 1
          batch.object_documents_for(CompactPartWriterW278Fixture::ROOT_COLUMN).map do |document|
            document.value_for("id").as_uint64.to_s
          end.to_a.should eq(owned_first_batch)
        end
      end
      recovered.should eq(2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
