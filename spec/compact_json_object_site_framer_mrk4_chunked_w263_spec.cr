require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"
require "../src/crystal_click/compact_json_object_site_framer"

private def w263_chunked_framer_physical_context(
  &block : String, CrystalClick::CompactPartPhysicalContext ->
) : Nil
  root = File.tempname("crystal-click-w263-framer-chunked")
  part = File.join(root, "part")
  Dir.mkdir_p(root)
  begin
    CompactPhysicalContextW259Fixture.build(part, CrystalClick::CompactMarkFormat::Mrk4)
    block.call(part, CrystalClick::CompactPartPhysicalContext.open(part))
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w263_chunked_framer_budget : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
end

private def w263_chunked_framer_pair_at(offset : UInt64) : Tuple(UInt64, UInt64)
  raw = CompactPhysicalContextW259Fixture.raw_bytes(CrystalClick::CompactMarkFormat::Mrk4)
  queries = CompactPhysicalContextW259Fixture.cumulative_offsets(CrystalClick::CompactMarkFormat::Mrk4)
  index = queries.index(offset) || raise "missing Compact W259 coordinate query"
  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [CompactPhysicalContextW259Fixture::ROW_COUNTS.sum],
    queries,
    frame_bytes: 7,
  )
  positioned.position_at(index)
end

private def w263_chunked_framer_change_first_source_byte!(part_path : String) : Nil
  mode = CrystalClick::CompactMarkFormat::Mrk4
  raw = CompactPhysicalContextW259Fixture.raw_bytes(mode)
  raw[0] = raw[0] ^ 1_u8
  queries = CompactPhysicalContextW259Fixture.cumulative_offsets(mode)
  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [CompactPhysicalContextW259Fixture::ROW_COUNTS.sum],
    queries,
    frame_bytes: 7,
  )
  File.write(File.join(part_path, "data.bin"), positioned.files.data)
  File.write(File.join(part_path, "data.mrk4"), CompactPhysicalContextW259Fixture.mark_bytes(mode, positioned.positions))
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  nil
end

private def w263_chunked_framer_alpha_zero(
  physical : CrystalClick::CompactPartPhysicalContext,
) : Tuple(Array(CrystalClick::CompactPartPhysicalShard), String, String)
  granule = physical.read_window("alpha", 0, 1).granules.first
  unless granule.shards.size == 2
    raise "expected the two authenticated alpha callback shards"
  end
  first = granule.shards[0].stream_name || raise "first alpha shard is unnamed"
  second = granule.shards[1].stream_name || raise "second alpha shard is unnamed"
  {granule.shards, first, second}
end

describe "W263 Compact MRK4 chunked site-framer coordinate ownership" do
  it "attaches the exact physical path, preserves cumulative offsets, and consumes an empty final event" do
    w263_chunked_framer_physical_context do |_part, physical|
      shards, first_name, empty_name = w263_chunked_framer_alpha_zero(physical)
      first_name.should eq("shared")
      empty_name.should eq("payload")
      shards[0].bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      shards[1].bytes.should be_empty

      framer = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical.mode,
        shards,
        w263_chunked_framer_budget,
        physical,
        "alpha:JSON/root.shared:occurrence-0",
      )
      first = framer.take_inline_fragment_slice("canonical.alpha.shared", first_name)
      empty = framer.take_inline_fragment_slice("canonical.alpha.payload", empty_name)

      first.authenticated_context?.should be_true
      first.relative_start.should eq(0_u64)
      first.relative_end.should eq(2_u64)
      first.bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      empty.authenticated_context?.should be_true
      empty.relative_start.should eq(2_u64)
      empty.relative_end.should eq(2_u64)
      empty.bytes.should be_empty
      first.context_matches?(empty).should be_true

      # Coordinates stay in the original whole-data domain; only the detached
      # callback slice returns the corresponding path-local offset.
      physical.logical_position(w263_chunked_framer_pair_at(0_u64)).should eq(0_i64)
      first.local_position_for_pair(w263_chunked_framer_pair_at(0_u64), false).should eq(0_i64)
      first.local_position_for_pair(w263_chunked_framer_pair_at(2_u64), false).should be_nil
      empty.local_position_for_pair(w263_chunked_framer_pair_at(2_u64), true).should eq(0_i64)

      framer.validate_expected_events!([first_name, empty_name])
      framer.finish!
    end
  end

  it "preserves callback-local offsets when no authenticated path coordinates are supplied" do
    w263_chunked_framer_physical_context do |_part, physical|
      shards, first_name, empty_name = w263_chunked_framer_alpha_zero(physical)
      framer = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical.mode,
        shards,
        w263_chunked_framer_budget,
      )

      first = framer.take_inline_fragment_slice("canonical.alpha.shared", first_name)
      empty = framer.take_inline_fragment_slice("canonical.alpha.payload", empty_name)

      first.authenticated_context?.should be_false
      first.relative_start.should eq(0_u64)
      first.relative_end.should eq(first.bytes.size.to_u64)
      first.bytes.should eq(Bytes[0x61_u8, 0x30_u8])
      empty.authenticated_context?.should be_false
      empty.relative_start.should eq(0_u64)
      empty.relative_end.should eq(0_u64)
      empty.bytes.should be_empty

      framer.validate_expected_events!([first_name, empty_name])
      framer.finish!
    end
  end

  it "requires paired physical/site provenance, rejects foreign sources, and separates site identities" do
    w263_chunked_framer_physical_context do |part, physical_a|
      shards_a, first_name, empty_name = w263_chunked_framer_alpha_zero(physical_a)
      expect_raises(ArgumentError) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical_a.mode,
          shards_a,
          w263_chunked_framer_budget,
          physical_a,
          nil,
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical_a.mode,
          shards_a,
          w263_chunked_framer_budget,
          nil,
          "alpha:JSON/root.shared:occurrence-0",
        )
      end

      site = "alpha:JSON/root.shared:occurrence-0"
      framer_a = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical_a.mode,
        shards_a,
        w263_chunked_framer_budget,
        physical_a,
        site,
      )
      slice_a = framer_a.take_inline_fragment_slice("canonical.alpha.shared", first_name)

      same_owner = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical_a.mode,
        shards_a,
        w263_chunked_framer_budget,
        physical_a,
        site,
      )
      same_slice = same_owner.take_inline_fragment_slice("canonical.alpha.shared", first_name)
      slice_a.context_matches?(same_slice).should be_true

      # A second site identity over the same authenticated source is valid; it
      # must not alias the first site's callback provenance.
      other_site = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical_a.mode,
        shards_a,
        w263_chunked_framer_budget,
        physical_a,
        "alpha:JSON/root.tuple[0]:occurrence-0",
      )
      other_site_slice = other_site.take_inline_fragment_slice("canonical.alpha.shared", first_name)
      slice_a.context_matches?(other_site_slice).should be_false

      foreign_part = File.join(File.dirname(part), "foreign-part")
      CompactPhysicalContextW259Fixture.build(foreign_part, CrystalClick::CompactMarkFormat::Mrk4)
      w263_chunked_framer_change_first_source_byte!(foreign_part)
      physical_b = CrystalClick::CompactPartPhysicalContext.open(foreign_part)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactJsonObjectSiteFramer.new(
          physical_b.mode,
          shards_a,
          w263_chunked_framer_budget,
          physical_b,
          site,
        )
      end
      shards_b, first_name_b, _empty_name_b = w263_chunked_framer_alpha_zero(physical_b)
      first_name_b.should eq(first_name)
      shards_b[0].bytes.should_not eq(shards_a[0].bytes)
      foreign_owner = CrystalClick::CompactJsonObjectSiteFramer.new(
        physical_b.mode,
        shards_b,
        w263_chunked_framer_budget,
        physical_b,
        site,
      )
      foreign_slice = foreign_owner.take_inline_fragment_slice("canonical.alpha.shared", first_name_b)
      slice_a.context_matches?(foreign_slice).should be_false

      [framer_a, same_owner, other_site, foreign_owner].each do |framer|
        framer.take_inline_fragment_slice("canonical.alpha.payload", empty_name)
        framer.validate_expected_events!([first_name, empty_name])
        framer.finish!
      end
    end
  end
end
