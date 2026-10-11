require "./spec_helper"
require "../scripts/support/compact_json_w263_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_static_json_mrk3_compact_w263_fixture"

private def w263_mrk3_compact_expect_corrupt_tape_mutation(
  mark_index : Int32,
  tape_offset : Int32,
  expected_byte : UInt8,
  replacement_byte : UInt8,
  expected_logical_start : Int64,
  expected_tape_size : Int32,
  expected_error_fragment : String,
) : Nil
  source = CompactStaticJsonMrk3CompactW263Fixture.source_part(:compact)
  CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
  original = CompactStaticJsonMrk3CompactW263Fixture.raw_mark_evidence(source[:path], mark_index)
  original[:logical_start].should eq(expected_logical_start)
  original[:raw].size.should eq(expected_tape_size)
  original[:raw][tape_offset].should eq(expected_byte)

  temporary_root, copied_part = CompactStaticJsonMrk3CompactW263Fixture.copy_part(source[:path])
  begin
    CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
    changed = CompactStaticJsonMrk3CompactW263Fixture.mutate_tape_byte!(
      copied_part,
      mark_index,
      tape_offset,
      expected_byte,
      replacement_byte,
    )
    changed[:logical_start].should eq(expected_logical_start)
    changed[:tape_size].should eq(expected_tape_size)

    # Reopen the checksum-refreshed private part before asking the JSON reader
    # to classify the grammar mutation. This separates tape grammar refusal
    # from outer inventory, mark-index, and compressed-frame transport errors.
    physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
    physical.mode.mrk3?.should be_true
    physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
    observed = physical.read_window("root", mark_index, 1).granules.first
      .shards.first
    observed.logical_start.should eq(expected_logical_start)
    observed.bytes.size.should eq(expected_tape_size)
    observed.byte_at(tape_offset).should eq(replacement_byte)

    reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      copied_part,
      "root",
      CompactStaticJsonMrk3CompactW263Fixture.json_type,
    )
    reader.row_count.should eq(6_u64)
    reader.mark_count.should eq(3)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
    error = expect_raises(CrystalClick::CorruptPartError) do
      reader.read_marks(reader.mark_count, 0)
    end
    error.message.not_nil!.should contain(expected_error_fragment)
    expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
      reader.prepared_context
    end
  ensure
    FileUtils.rm_rf(temporary_root)
    CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
  end
end

private def w263_mrk3_compact_overlap?(
  frame : CrystalClick::CompressedFrameDescriptor,
  span : Tuple(Int64, Int64),
) : Bool
  frame.logical_start < span[1] && span[0] < frame.logical_end
end

private def w263_mrk3_compact_selected_later_root_frame(part_path : String) : Int32
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.granule_count.should eq(3)
  physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
  marks = physical.read_window("root", 0, physical.granule_count).granules
  marks.size.should eq(3)

  first_spans = marks[0, 2].flat_map do |mark|
    mark.shards.map { |shard| {shard.logical_start, shard.logical_end} }
  end
  last_spans = marks[2].shards.map { |shard| {shard.logical_start, shard.logical_end} }
  last_spans.should_not be_empty

  data = File.read(File.join(part_path, "data.bin")).to_slice
  index = CrystalClick::CompressedFrameIndex.new(
    data,
    CrystalClick::CompressedStreamLimits.new,
    CrystalClick::CompressedStreamBudget.read_default,
  )
  candidates = [] of Int32
  index.frames.each_with_index do |frame, frame_index|
    next unless last_spans.any? { |span| w263_mrk3_compact_overlap?(frame, span) }
    next if first_spans.any? { |span| w263_mrk3_compact_overlap?(frame, span) }
    candidates << frame_index.to_i32
  end
  candidates.last? || raise("W263 COMPACT source has no frame confined to the final root mark")
end

if ENV["CRYSTAL_CLICK_W263_COMPACT_EVIDENCE_ROOT"]?
  describe "Compact static root-JSON MRK3 COMPACT Dynamic adversaries (W263)" do
    it "rejects a checksum-valid unknown outer Variant mode" do
      # The mode word is the first eight-byte callback in each native mark.
      w263_mrk3_compact_expect_corrupt_tape_mutation(
        0,
        38,
        1_u8,
        2_u8,
        16_i64,
        80,
        "Dynamic discriminator mode is unknown",
      )
    end

    it "rejects an unknown inner COMPACT frame format after transport authentication" do
      # Mark 2 is a genuine uniform-tag frame: row count 2, format 1,
      # canonical String index 1. Change only its format byte to 2.
      w263_mrk3_compact_expect_corrupt_tape_mutation(
        2,
        55,
        1_u8,
        2_u8,
        201_i64,
        84,
        "unknown Dynamic COMPACT granule format",
      )
    end

    it "rejects zero, short, or long declared frame row counts" do
      # The serialized frame in mark 2 is `02 01 01`; only its VarUInt row
      # count is changed, so these remain transport-valid tape mutations.
      {
        {0_u8, "row count must be positive"},
        {1_u8, "rows do not equal its mark rows"},
        {3_u8, "rows do not equal its mark rows"},
      }.each do |replacement, message|
        w263_mrk3_compact_expect_corrupt_tape_mutation(
          2,
          54,
          2_u8,
          replacement,
          201_i64,
          84,
          message,
        )
      end
    end

    it "rejects out-of-roster tags in both row-tag and uniform COMPACT frames" do
      # String index 1 is authenticated by the source roster. 254 is neither
      # that index nor NULL 255 in either representation.
      w263_mrk3_compact_expect_corrupt_tape_mutation(
        0,
        56,
        1_u8,
        254_u8,
        16_i64,
        80,
        "outside the parsed canonical arm roster",
      )
      w263_mrk3_compact_expect_corrupt_tape_mutation(
        2,
        56,
        1_u8,
        254_u8,
        201_i64,
        84,
        "outside the parsed canonical arm roster",
      )
    end

    it "rejects a late all-NULL mark corruption before EOF-first publication" do
      # The first mark remains valid. The second, all-NULL mark is changed to
      # the invalid non-NULL index 254 before EOF-first preparation completes.
      w263_mrk3_compact_expect_corrupt_tape_mutation(
        1,
        56,
        255_u8,
        254_u8,
        112_i64,
        73,
        "outside the parsed canonical arm roster",
      )
    end

    it "requires EOF-first preparation to authenticate a later selected frame" do
      source = CompactStaticJsonMrk3CompactW263Fixture.source_part(:compact)
      CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      frame_index = w263_mrk3_compact_selected_later_root_frame(source[:path])
      temporary_root, copied_part = CompactStaticJsonMrk3CompactW263Fixture.copy_part(source[:path])
      begin
        CompactJsonW263Fixture.assert_native_inventory!(copied_part, source[:inventory])
        CompactPhysicalContextW259Fixture.corrupt_frame_payload(copied_part, frame_index)

        # A mark-0 physical read is the clean transport control; the selected
        # last-mark-only frame is disjoint from both earlier root intervals.
        physical = CrystalClick::CompactPartPhysicalContext.open(copied_part)
        physical.read_window("root", 0, 1).granules.first.shards.first.bytes.should eq(
          CompactStaticJsonMrk3CompactW263Fixture.raw_mark_evidence(source[:path], 0)[:raw],
        )

        reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          copied_part,
          "root",
          CompactStaticJsonMrk3CompactW263Fixture.json_type,
        )
        reader.mark_count.should eq(3)
        expect_raises(CrystalClick::CorruptPartError, /compressed frame checksum mismatch/) do
          reader.read_marks(reader.mark_count, 0)
        end
        expect_raises(ArgumentError, /has not completed EOF-first preparation/) do
          reader.prepared_context
        end
      ensure
        FileUtils.rm_rf(temporary_root)
        CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
      end
    end
  end
end
