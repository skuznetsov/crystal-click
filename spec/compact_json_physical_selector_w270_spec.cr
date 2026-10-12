require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"
require "../src/crystal_click/compact_json_object_site_framer"

private def w270_physical_selector_pair_at(offset : UInt64) : Tuple(UInt64, UInt64)
  mode = CrystalClick::CompactMarkFormat::Mrk4
  raw = CompactPhysicalContextW259Fixture.raw_bytes(mode)
  queries = CompactPhysicalContextW259Fixture.cumulative_offsets(mode)
  index = queries.index(offset) || raise "missing W259 Compact coordinate query"
  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [CompactPhysicalContextW259Fixture::ROW_COUNTS.sum],
    queries,
    frame_bytes: 7,
  )
  positioned.position_at(index)
end

describe "W270 Compact JSON physical callback selection" do
  it "uses only the requested physical label while retaining the raw logical label and authenticated coordinates" do
    root = File.tempname("crystal-click-w270-physical-selector")
    part = File.join(root, "part")
    Dir.mkdir_p(root)
    begin
      mode = CrystalClick::CompactMarkFormat::Mrk4
      CompactPhysicalContextW259Fixture.build(part, mode)
      physical = CrystalClick::CompactPartPhysicalContext.open(part)
      shards = physical.read_window("alpha", 0, 1).granules.first.shards
      shards.size.should eq(2)
      (shards[0].stream_name || raise "W259 shared callback has no physical name").should eq("shared")
      (shards[1].stream_name || raise "W259 payload callback has no physical name").should eq("payload")
      shards[0].bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      shards[1].bytes.should be_empty

      site = "alpha:JSON/root.shared:occurrence-0"
      framer = CrystalClick::CompactJsonObjectSiteFramer.new(
        mode,
        shards,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        physical,
        site,
      )

      # A matching raw callback name must not rescue a missing physical name.
      # The subsequent exact-name read proves this refusal did not advance.
      expect_raises(CrystalClick::CorruptPartError) do
        framer.take_physical_inline_fragment_slice("canonical.alpha.shared", "shared")
      end

      first = framer.take_physical_inline_fragment_slice("shared", "raw.logical.shared")
      first.canonical_name.should eq("shared")
      first.callback_name.should eq("raw.logical.shared")
      first.bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      first.authenticated_context?.should be_true
      first.relative_start.should eq(0_u64)
      first.relative_end.should eq(2_u64)
      physical.logical_position(w270_physical_selector_pair_at(0_u64)).should eq(0_i64)
      first.local_position_for_pair(w270_physical_selector_pair_at(0_u64), false).should eq(0_i64)
      first.local_position_for_pair(w270_physical_selector_pair_at(2_u64), false).should be_nil

      empty = framer.take_physical_inline_fragment_slice("payload", "raw.logical.payload")
      empty.canonical_name.should eq("payload")
      empty.callback_name.should eq("raw.logical.payload")
      empty.bytes.should be_empty
      empty.authenticated_context?.should be_true
      empty.relative_start.should eq(2_u64)
      empty.relative_end.should eq(2_u64)
      empty.local_position_for_pair(w270_physical_selector_pair_at(2_u64), true).should eq(0_i64)
      first.context_matches?(empty).should be_true

      # Both events are consumed and the logical roster has the right length;
      # only the first callback identity is wrong.
      expect_raises(CrystalClick::CorruptPartError) do
        framer.validate_expected_events!(
          ["shared", "payload"],
          ["raw.logical.mismatch", "raw.logical.payload"],
        )
      end

      framer.validate_expected_events!(
        ["shared", "payload"],
        ["raw.logical.shared", "raw.logical.payload"],
      )
      framer.finish!
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
