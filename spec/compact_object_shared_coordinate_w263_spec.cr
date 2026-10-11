require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"

private def w263_with_compact_physical_context(&)
  root = File.tempname("crystal-click-w263-coordinate")
  part = File.join(root, "part")
  Dir.mkdir_p(root)
  begin
    CompactPhysicalContextW259Fixture.build(part, CrystalClick::CompactMarkFormat::Mrk4)
    yield CrystalClick::CompactPartPhysicalContext.open(part)
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w263_positioned_data : CrystalClick::CompressedMarkPositionFiles
  raw = CompactPhysicalContextW259Fixture.raw_bytes(CrystalClick::CompactMarkFormat::Mrk4)
  queries = [0_u64, 1_u64, 2_u64, 4_u64, 6_u64, 10_u64, 11_u64, 12_u64,
             14_u64, 15_u64, 16_u64, raw.size.to_u64]
  CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    [0_u64, raw.size.to_u64],
    [8_u64],
    queries,
    frame_bytes: 7,
  )
end

private def w263_pair_at(
  positioned : CrystalClick::CompressedMarkPositionFiles,
  logical_offset : UInt64,
) : Tuple(UInt64, UInt64)
  queries = [0_u64, 1_u64, 2_u64, 4_u64, 6_u64, 10_u64, 11_u64, 12_u64,
             14_u64, 15_u64, 16_u64,
             CompactPhysicalContextW259Fixture.raw_bytes(CrystalClick::CompactMarkFormat::Mrk4).size.to_u64]
  index = queries.index(logical_offset) || raise "missing W263 coordinate query"
  positioned.position_at(index)
end

describe "Compact Object inline coordinate provenance (W263)" do
  it "retains the whole-data resolver and frame descriptors in the checked grid census" do
    w263_with_compact_physical_context do |physical|
      positioned = w263_positioned_data
      physical.logical_position(w263_pair_at(positioned, 10_u64)).should eq(10_i64)
      physical.logical_position(w263_pair_at(positioned, 21_u64)).should eq(21_i64)

      # The fixture's 21 logical bytes are emitted as three seven-byte frames.
      # Keep the pre-W263 grid census explicit so omitting the retained frame
      # descriptors cannot pass by merely retaining the resolver object.
      slots = physical.physical_roster.size.to_u64
      marks = physical.granule_count.to_u64
      coordinate_count = (marks + 1_u64) * slots
      prior_grid_bytes = instance_sizeof(CrystalClick::CompactMarkIndex).to_u64 +
                         instance_sizeof(Array(Int64)).to_u64 +
                         coordinate_count * sizeof(Int64).to_u64 +
                         instance_sizeof(Array(UInt64)).to_u64 +
                         marks * sizeof(UInt64).to_u64
      retained = physical.retained_grid_workspace_bytes
      retained.should be >= prior_grid_bytes
      expected_frame_owner = instance_sizeof(CrystalClick::CompressedFrameIndex).to_u64 +
                             instance_sizeof(Array(CrystalClick::CompressedFrameDescriptor)).to_u64 +
                             3_u64 * sizeof(CrystalClick::CompressedFrameDescriptor).to_u64
      (retained - prior_grid_bytes).should eq(expected_frame_owner)
    end
  end

  it "maps authenticated detached shards in original coordinates and narrows per callback" do
    w263_with_compact_physical_context do |physical|
      positioned = w263_positioned_data
      window = physical.read_window("alpha", 0, 4)
      # mrk4 slot 0 is alpha.shared. Its source intervals are [0,2), [4,4),
      # [10,12), [14,16): non-contiguous, and the second callback is empty.
      shards = window.granules.map { |granule| granule.shards[0] }
      path = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared:occurrence-0",
        shards,
      )
      path.path_data_size.should eq(6_i64)
      path.same_path?(path).should be_true
      path.site_identity.should eq("alpha:JSON/root.shared:occurrence-0")

      same_site = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared:occurrence-0",
        shards,
      )
      exposed_identity = path.site_identity
      exposed_identity.to_unsafe[0] = 'x'.ord.to_u8
      path.site_identity.should eq("alpha:JSON/root.shared:occurrence-0")
      path.same_path?(same_site).should be_true

      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      path.validate_path_bytes!(
        0_u64,
        Bytes[0x61_u8, 0x30_u8, 0x61_u8, 0x32_u8, 0x61_u8, 0x33_u8],
        budget,
      )

      other_site = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.tuple[0]:occurrence-1",
        shards,
      )
      # The nominal SQL type is JSON in both identities; source-site identity
      # must still prevent callback provenance from aliasing.
      path.same_path?(other_site).should be_false

      slices = [] of CrystalClick::ObjectSharedInlineCallbackReadSlice
      starts = [0_u64, 2_u64, 2_u64, 4_u64]
      ends = [2_u64, 2_u64, 4_u64, 6_u64]
      shards.each_with_index do |shard, index|
        slices << CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          "canonical.alpha.shared.#{index}",
          "raw.alpha.shared.#{index}",
          starts[index],
          ends[index],
          shard.bytes,
          path,
          budget,
        )
      end
      role = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
        "alpha.shared",
        ["canonical.alpha.shared.0", "canonical.alpha.shared.1",
         "canonical.alpha.shared.2", "canonical.alpha.shared.3"],
        ["raw.alpha.shared.0", "raw.alpha.shared.1",
         "raw.alpha.shared.2", "raw.alpha.shared.3"],
        slices,
        budget,
      )

      role.logical_position(w263_pair_at(positioned, 0_u64)).should eq(0_i64)
      role.logical_position(w263_pair_at(positioned, 1_u64)).should eq(1_i64)
      role.logical_position(w263_pair_at(positioned, 10_u64)).should eq(2_i64)
      role.logical_position(w263_pair_at(positioned, 11_u64)).should eq(3_i64)
      role.logical_position(w263_pair_at(positioned, 14_u64)).should eq(4_i64)
      role.logical_position(w263_pair_at(positioned, 16_u64)).should eq(6_i64)

      # Whole-data-valid pairs at a non-final boundary, an empty non-final
      # callback, and the adjacent beta.shared / gap intervals are not members
      # of this role. The final endpoint alone is admitted as a terminal.
      [2_u64, 4_u64, 6_u64, 12_u64, 21_u64].each do |offset|
        expect_raises(CrystalClick::CorruptPartError) do
          role.logical_position(w263_pair_at(positioned, offset))
        end
      end

      # A source endpoint/empty point must not alias the start of the next
      # callback merely because both have the same concatenated path offset.
      [2_u64, 4_u64].each do |offset|
        path.callback_position(w263_pair_at(positioned, offset), 2_u64, 4_u64, false).should be_nil
      end

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          "canonical.forged",
          "raw.forged",
          0_u64,
          2_u64,
          Bytes[0xee_u8, 0x30_u8],
          path,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end

      source = shards[0]
      forged = CrystalClick::CompactPartPhysicalShard.new(
        source.slot_index,
        source.stream_name,
        source.logical_start,
        source.logical_end,
        Bytes[0xee_u8, 0x30_u8],
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
          physical,
          "alpha:JSON/root.shared:forged-shard",
          [forged],
        )
      end
    end
  end

  it "authenticates ordered path shards from multiple physical callback slots" do
    w263_with_compact_physical_context do |physical|
      window = physical.read_window("alpha", 0, 2)
      # mrk4 alternates the two alpha callback slots per mark. Their exact
      # source ranges are [0,2), [2,2), [4,4), [4,6), yielding a0a1 without
      # rebasing or pretending that the path is one physical lane.
      shards = window.granules.flat_map { |granule| granule.shards }.first(4)
      shards.map { |shard| {shard.slot_index, shard.logical_start, shard.logical_end} }.should eq([
        {0, 0_i64, 2_i64},
        {1, 2_i64, 2_i64},
        {0, 4_i64, 4_i64},
        {1, 4_i64, 6_i64},
      ])
      context = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared+payload:occurrence-0",
        shards,
      )
      context.path_data_size.should eq(4_i64)

      expected_shard_bytes = 0_u64
      shards.each do |shard|
        expected_shard = instance_sizeof(CrystalClick::CompactPartPhysicalShard).to_u64 +
                         (shard.logical_end - shard.logical_start).to_u64
        if name = shard.stream_name
          expected_shard += instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64
        end
        shard.retained_workspace_bytes.should eq(expected_shard)
        expected_shard_bytes += expected_shard
      end

      identity_bytes = context.site_identity.bytesize.to_u64
      expected_context_bytes = instance_sizeof(CrystalClick::CompactObjectSharedInlineCoordinateContext).to_u64 +
                               instance_sizeof(String).to_u64 + identity_bytes + 1_u64 +
                               instance_sizeof(Array(CrystalClick::CompactPartPhysicalShard)).to_u64 +
                               shards.size.to_u64 * sizeof(Pointer(CrystalClick::CompactPartPhysicalShard)).to_u64 +
                               instance_sizeof(Array(UInt64)).to_u64 +
                               shards.size.to_u64 * sizeof(UInt64).to_u64 +
                               expected_shard_bytes
      context.retained_workspace_bytes.should eq(expected_context_bytes)

      context.validate_path_bytes!(
        0_u64,
        Bytes[0x61_u8, 0x30_u8, 0x61_u8, 0x31_u8],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )

      out_of_order = [shards[0], shards[3], shards[2]]
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
          physical,
          "alpha:JSON/root.shared+payload:out-of-order",
          out_of_order,
        )
      end
    end
  end

  it "distinguishes a final empty endpoint from the same non-final empty callback" do
    w263_with_compact_physical_context do |physical|
      positioned = w263_positioned_data
      window = physical.read_window("alpha", 0, 4)
      shards = window.granules.map { |granule| granule.shards[0] }
      empty = shards[1]
      empty_context = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared:empty-final",
        [empty],
      )
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      empty_slice = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.empty",
        "raw.empty",
        0_u64,
        0_u64,
        Bytes.empty,
        empty_context,
        budget,
      )
      empty_role = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
        "empty.final",
        ["canonical.empty"],
        ["raw.empty"],
        [empty_slice],
        budget,
      )
      empty_role.logical_position(w263_pair_at(positioned, 4_u64)).should eq(0_i64)

      # The same original whole-data coordinate cannot be accepted as the
      # endpoint of an empty callback when another callback follows it.
      nonfinal_context = CrystalClick::CompactObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared:empty-nonfinal",
        [empty, shards[2]],
      )
      nonfinal_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      nonfinal_empty = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.empty.nonfinal",
        "raw.empty.nonfinal",
        0_u64,
        0_u64,
        Bytes.empty,
        nonfinal_context,
        nonfinal_budget,
      )
      nonfinal_next = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.next",
        "raw.next",
        0_u64,
        2_u64,
        shards[2].bytes,
        nonfinal_context,
        nonfinal_budget,
      )
      nonfinal_role = CrystalClick::ObjectSharedInlineRoleReadView.from_captured_schedule(
        "empty.nonfinal",
        ["canonical.empty.nonfinal", "canonical.next"],
        ["raw.empty.nonfinal", "raw.next"],
        [nonfinal_empty, nonfinal_next],
        nonfinal_budget,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        nonfinal_role.logical_position(w263_pair_at(positioned, 4_u64))
      end
    end
  end
end
