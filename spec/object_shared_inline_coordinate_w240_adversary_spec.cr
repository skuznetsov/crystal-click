require "./spec_helper"

private def w240_inline_coordinate_with_lane(
  raw : Bytes,
  frame_bytes : Int = 32,
  position_queries : Array(UInt64) = [] of UInt64,
  &
) : Nil
  encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [1_u64],
    position_queries,
    frame_bytes: frame_bytes,
    budget: CrystalClick::CompressedStreamBudget.write_default,
  )
  files = encoded.files
  data_path = File.tempname("crystal-click-w240-inline-coordinate-data")
  marks_path = File.tempname("crystal-click-w240-inline-coordinate-marks")
  begin
    File.open(data_path, "wb") { |io| io.write(files.data) }
    File.open(marks_path, "wb") { |io| io.write(files.marks) }
    input = CrystalClick::ObjectSharedPhysicalLaneInput.new(
      data_path,
      marks_path,
      files.data.size.to_i64,
      files.marks.size.to_i64,
    )
    codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    lane = CrystalClick::ObjectSharedPhysicalLaneReader.new(
      "data",
      input,
      [1_u64],
      codec_budget,
      CrystalClick::CompressedStreamBudget.read_default,
    )
    yield lane, codec_budget, encoded
  ensure
    File.delete(data_path) if File.exists?(data_path)
    File.delete(marks_path) if File.exists?(marks_path)
  end
end

describe "W240 authenticated inline callback coordinates" do
  it "rejects same-sized forged bytes at path, tape, and callback-slice boundaries" do
    raw = Bytes[0x10_u8, 0x11_u8, 0x20_u8, 0x21_u8, 0x22_u8, 0x23_u8, 0x30_u8, 0x31_u8]
    w240_inline_coordinate_with_lane(raw) do |lane, budget, _encoded|
      context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 2_i64, 6_i64)
      forged = Bytes[0xee_u8, 0x21_u8, 0x22_u8, 0x23_u8]
      events = [CrystalClick::ObjectSharedPathSubstreamEvent.new("callback", 0_u64)] of CrystalClick::ObjectSharedPathSubstreamEvent

      expect_raises(CrystalClick::CorruptPartError, /authenticated Data interval/) do
        CrystalClick::ObjectSharedPathStreams.new(
          forged,
          events,
          context,
          [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
          budget,
        )
      end

      expect_raises(CrystalClick::CorruptPartError, /authenticated Data interval/) do
        CrystalClick::ObjectSharedPathTapeReader.new(
          forged,
          events,
          budget,
          context,
        )
      end

      expect_raises(CrystalClick::CorruptPartError, /authenticated Data interval/) do
        CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          "canonical.callback",
          "callback",
          0_u64,
          forged.size.to_u64,
          forged,
          context,
          budget,
        )
      end
    end
  end

  it "accepts the exact authenticated path bytes and charges comparisons to one budget" do
    raw = Bytes[0x10_u8, 0x11_u8, 0x20_u8, 0x21_u8, 0x22_u8, 0x23_u8, 0x30_u8, 0x31_u8]
    w240_inline_coordinate_with_lane(raw) do |lane, budget, _encoded|
      context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 2_i64, 6_i64)
      valid = raw[2, 4]
      events = [CrystalClick::ObjectSharedPathSubstreamEvent.new("callback", 0_u64)] of CrystalClick::ObjectSharedPathSubstreamEvent
      streams = CrystalClick::ObjectSharedPathStreams.new(
        valid,
        events,
        context,
        [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
        budget,
      )
      streams.data.should eq(valid)
      budget.wire_byte_count.should be >= valid.size.to_i64
    end
  end

  it "resolves real compressed coordinates through nonzero frame and path bases at 32- and 64-byte limits" do
    [32, 64].each do |frame_bytes|
      raw = Bytes.new(frame_bytes * 3 + 7) { |index| ((index * 37 + 11) % 251).to_u8 }
      logical_query = (frame_bytes * 2 + 3).to_u64
      w240_inline_coordinate_with_lane(
        raw,
        frame_bytes,
        [logical_query],
      ) do |lane, budget, encoded|
        pair = encoded.position_at(0)
        pair[0].should be > 0_u64
        pair[1].should be > 0_u64
        lane.logical_position(pair[0], pair[1]).should eq(logical_query.to_i64)

        path_start = frame_bytes.to_i64 + 1_i64
        context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(
          lane,
          path_start,
          raw.size.to_i64,
        )
        path_bytes = raw[path_start.to_i, raw.size - path_start.to_i]
        context.resolve_path_position(pair).should eq(logical_query.to_i64)

        events = [CrystalClick::ObjectSharedPathSubstreamEvent.new("raw.callback", 0_u64)] of CrystalClick::ObjectSharedPathSubstreamEvent
        streams = CrystalClick::ObjectSharedPathStreams.new(
          path_bytes,
          events,
          context,
          [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
          budget,
        )
        tape = CrystalClick::ObjectSharedPathTapeReader.new(
          streams.data,
          streams.events,
          budget,
          context,
        )
        slice = tape.take_inline_fragment_slice("canonical.callback", "raw.callback")
        slice.resolve_pair(pair).should eq((logical_query.to_i64 - path_start))
        slice.bytes.should eq(path_bytes)
        budget.wire_byte_count.should be >= path_bytes.size.to_i64
      end
    end
  end

  it "resolves only captured callback segments and admits a terminal only at the final segment" do
    raw = Bytes.new(32) { |index| (0x40 + index).to_u8 }
    queries = [2_u64, 3_u64, 4_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64] of UInt64
    w240_inline_coordinate_with_lane(raw, 32, queries) do |lane, budget, encoded|
      context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 0_i64, raw.size.to_i64)
      left_bytes = raw[2, 2]
      right_bytes = raw[6, 2]
      left = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.left", "raw.left", 2_u64, 4_u64, left_bytes, context, budget,
      )
      right = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.right", "raw.right", 6_u64, 8_u64, right_bytes, context, budget,
      )
      view = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
        "data",
        ["canonical.left", "canonical.right"],
        ["raw.left", "raw.right"],
        [left, right],
        budget,
      )

      view.logical_position(encoded.position_at(0)).should eq(0_i64)
      view.logical_position(encoded.position_at(1)).should eq(1_i64)
      view.logical_position(encoded.position_at(3)).should eq(2_i64)
      view.logical_position(encoded.position_at(4)).should eq(3_i64)
      # Offset 8 is the final role endpoint and is a valid terminal coordinate.
      view.logical_position(encoded.position_at(5)).should eq(4_i64)

      # Offset 4 is a non-final segment endpoint; 5 is a gap; 9/10 are outside
      # the role (including an adjacent role's coordinate), even though all
      # are valid coordinates in the authenticated containing Data lane.
      [2, 6, 7].each do |query_index|
        expect_raises(CrystalClick::CorruptPartError) do
          view.logical_position(encoded.position_at(query_index))
        end
      end
      narrow_context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 2_i64, 8_i64)
      expect_raises(CrystalClick::CorruptPartError) do
        narrow_context.resolve_path_position(encoded.position_at(7))
      end
      view.materialize_bytes(budget).to_a.should eq([0x42_u8, 0x43_u8, 0x46_u8, 0x47_u8])
    end
  end

  it "rejects raw callback identity substitution, overlap, and out-of-order role segments" do
    raw = Bytes.new(16) { |index| (0x70 + index).to_u8 }
    w240_inline_coordinate_with_lane(raw) do |lane, budget, _encoded|
      context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 0_i64, raw.size.to_i64)
      first = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.first", "raw.first", 1_u64, 3_u64, raw[1, 2], context, budget,
      )
      second = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.second", "raw.second", 2_u64, 4_u64, raw[2, 2], context, budget,
      )
      later = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.later", "raw.later", 5_u64, 7_u64, raw[5, 2], context, budget,
      )

      expect_raises(CrystalClick::CorruptPartError, /source-scheduled role/) do
        CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
          "data",
          ["canonical.first"],
          ["raw.substituted"],
          [first],
          budget,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, /overlap or are out of source order/) do
        CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
          "data",
          ["canonical.first", "canonical.second"],
          ["raw.first", "raw.second"],
          [first, second],
          budget,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, /overlap or are out of source order/) do
        CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
          "data",
          ["canonical.later", "canonical.first"],
          ["raw.later", "raw.first"],
          [later, first],
          budget,
        )
      end
    end
  end

  it "reports inline chunk row overruns as corruption instead of unsigned underflow" do
    record = CrystalClick::ObjectSharedChunkStructure.new(
      3_u64,
      [] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    raw = CrystalClick::ObjectSharedChunkStructureCodec.encode(record)
    prefix_size = raw.size - CrystalClick::ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i

    w240_inline_coordinate_with_lane(raw) do |lane, budget, _encoded|
      context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(
        lane,
        0_i64,
        raw.size.to_i64,
      )
      role_views = Hash(String, CrystalClick::ObjectSharedInlineRoleReadView).new
      CrystalClick::ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.each do |role|
        start = case role
                when "structure_prefix" then 0
                when "structure_suffix" then prefix_size
                else                         raw.size
                end
        finish = case role
                 when "structure_prefix" then prefix_size
                 when "structure_suffix" then raw.size
                 else                         raw.size
                 end
        segment = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          role,
          role,
          start.to_u64,
          finish.to_u64,
          raw[start, finish - start],
          context,
          budget,
        )
        role_views[role] = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
          role,
          [role],
          [role],
          [segment],
          budget,
        )
      end

      expect_raises(CrystalClick::CorruptPartError, /exceed the occurrence grid/) do
        CrystalClick::ObjectSharedPhysicalBucketDecoder.decode_inline(
          2,
          role_views,
          1_u64,
          1_u64,
          budget,
        )
      end
    end
  end

  it "rejects Copy roles captured from different authenticated Data paths" do
    raw = Bytes[0x81_u8]
    w240_inline_coordinate_with_lane(raw) do |lane, budget, _encoded|
      first_context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 0_i64, 1_i64)
      other_context = CrystalClick::ObjectSharedInlineDataCoordinateContext.new(lane, 0_i64, 0_i64)
      views = Hash(String, CrystalClick::ObjectSharedInlineRoleReadView).new
      ["sizes", "indexes", "values"].each_with_index do |role, index|
        context = index == 2 ? other_context : first_context
        segment = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          role,
          role,
          0_u64,
          0_u64,
          Bytes.empty,
          context,
          budget,
        )
        views[role] = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
          role,
          [role],
          [role],
          [segment],
          budget,
        )
      end

      expect_raises(CrystalClick::CorruptPartError, /do not share one authenticated Data path/) do
        CrystalClick::ObjectSharedAdvancedCopyLayout.decode_inline(
          views,
          [] of Array(CrystalClick::ObjectSharedPhysicalParentMark),
          [] of UInt64,
          budget,
        )
      end
    end
  end
end
