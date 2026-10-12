require "file_utils"
require "../../scripts/support/compact_json_w263_fixture"
require "../../scripts/support/compact_physical_context_w259_fixture"
require "./compact_json_recursive_public_w263_fixture"

# Copy-only mutations for the authenticated native W263 Compact matrix. The
# original capture is never rewritten; all transport/checksum updates are
# confined to explicitly created temporary part copies.
module CompactJsonRecursivePublicW263MutantFixture
  extend self

  ARRAY_LABEL          = "obj_v3_dyn_v3_map_with_buckets_mrk4_s0_variant_basic"
  ARRAY_MAP_MRK3_LABEL = "obj_v3_dyn_v3_map_with_buckets_mrk3_s0_variant_basic"

  alias Inventory = Array(Tuple(String, Int64, String))

  def authenticated_copy(
    label : String,
  ) : Tuple(String, String, String, Inventory)
    root = CompactJsonRecursivePublicW263Fixture.evidence_root
    evidence = CompactJsonRecursivePublicW263Fixture.authenticate(root)
    source = CompactJsonRecursivePublicW263Fixture.source_part(evidence, label)
    CompactJsonRecursivePublicW263Fixture.assert_native_json_rows!(evidence[0], label)

    parent = File.tempname("crystal-click-w263-recursive-public-mutant-")
    Dir.mkdir(parent, 0o700)
    copied = File.join(parent, CompactJsonW263Fixture::PART_NAME)
    FileUtils.cp_r(source[:path], copied)
    CompactJsonW263Fixture.assert_native_inventory!(copied, source[:inventory])
    {parent, copied, source[:path], source[:inventory]}
  end

  def authenticated_candidate_pair(
    label : String,
  ) : Tuple(String, String, String, String, String, Inventory)
    root = CompactJsonRecursivePublicW263Fixture.evidence_root
    evidence = CompactJsonRecursivePublicW263Fixture.authenticate(root)
    source = CompactJsonRecursivePublicW263Fixture.source_part(evidence, label)
    CompactJsonRecursivePublicW263Fixture.assert_native_json_rows!(evidence[0], label)

    parent = File.tempname("crystal-click-w263-recursive-public-candidates-")
    Dir.mkdir(parent, 0o700)
    first_parent = File.join(parent, "candidate-a")
    second_parent = File.join(parent, "candidate-b")
    Dir.mkdir(first_parent, 0o700)
    Dir.mkdir(second_parent, 0o700)
    first = File.join(first_parent, "all_1_1_0")
    second = File.join(second_parent, "all_2_2_0")
    FileUtils.cp_r(source[:path], first)
    FileUtils.cp_r(source[:path], second)
    CompactJsonW263Fixture.assert_native_inventory!(first, source[:inventory])
    CompactJsonW263Fixture.assert_native_inventory!(second, source[:inventory])
    {parent, first, second, source[:path], label, source[:inventory]}
  end

  # Reorders two callbacks within exactly one Object site, preserving the
  # complete physical slot roster and data bytes while refreshing the copied
  # part's checksummed metadata envelope.
  def swap_site_callbacks!(part_path : String, column : String, left : String, right : String) : Nil
    swap_column_callbacks!(part_path, column, "#{column}.#{left}", "#{column}.#{right}")
  end

  # Nested tuple/array child sites are represented as escaped stream prefixes
  # under the top-level physical column, so callers supply both identities.
  def swap_column_callbacks!(part_path : String, column : String, left_name : String, right_name : String) : Nil
    before = CrystalClick::CompactPartPhysicalContext.open(part_path)
    before_names = site_names(before, column)
    left_index = before_names.index(left_name) || raise "#{left_name} is absent from the selected physical site"
    right_index = before_names.index(right_name) || raise "#{right_name} is absent from the selected physical site"
    left_index.should_not eq(right_index)

    blocks = substream_blocks(before)
    column_index = blocks.index { |entry| entry[0] == column } ||
                   raise "#{column} callback block is absent"
    streams = blocks[column_index][1]
    left_stream_index = streams.index(left_name) || raise "#{left_name} callback is absent"
    right_stream_index = streams.index(right_name) || raise "#{right_name} callback is absent"
    held = streams[left_stream_index]
    streams[left_stream_index] = streams[right_stream_index]
    streams[right_stream_index] = held
    write_substream_blocks!(part_path, blocks)

    after = CrystalClick::CompactPartPhysicalContext.open(part_path)
    after.mode.mrk4?.should eq(before.mode.mrk4?)
    after.row_count.should eq(before.row_count)
    after.mark_row_counts.should eq(before.mark_row_counts)
    expected = before_names.dup
    expected[left_index] = right_name
    expected[right_index] = left_name
    site_names(after, column).should eq(expected)
    nil
  end

  # Moves two unique callback names across top-level physical-column blocks
  # without changing slot count or byte geometry. The existing serializer
  # rewrites valid metadata and refreshes the copied checksum envelope, making
  # the site-to-parent association disagree with the authenticated roster.
  def swap_callbacks_across_columns!(
    part_path : String,
    left_column : String,
    left_name : String,
    right_column : String,
    right_name : String,
  ) : Nil
    before = CrystalClick::CompactPartPhysicalContext.open(part_path)
    left_names = site_names(before, left_column)
    right_names = site_names(before, right_column)
    left_index = left_names.index(left_name) || raise "#{left_name} is absent from #{left_column}"
    right_index = right_names.index(right_name) || raise "#{right_name} is absent from #{right_column}"

    blocks = substream_blocks(before)
    left_column_index = blocks.index { |entry| entry[0] == left_column } ||
                        raise "#{left_column} callback block is absent"
    right_column_index = blocks.index { |entry| entry[0] == right_column } ||
                         raise "#{right_column} callback block is absent"
    left_streams = blocks[left_column_index][1]
    right_streams = blocks[right_column_index][1]
    left_index = left_streams.index(left_name) || raise "#{left_name} callback is absent"
    right_index = right_streams.index(right_name) || raise "#{right_name} callback is absent"
    left_streams[left_index] = right_name
    right_streams[right_index] = left_name
    write_substream_blocks!(part_path, blocks)

    after = CrystalClick::CompactPartPhysicalContext.open(part_path)
    after.mode.mrk4?.should eq(before.mode.mrk4?)
    after.row_count.should eq(before.row_count)
    after.mark_row_counts.should eq(before.mark_row_counts)
    expected_left = left_names.dup
    expected_right = right_names.dup
    expected_left[left_index] = right_name
    expected_right[right_index] = left_name
    site_names(after, left_column).should eq(expected_left)
    site_names(after, right_column).should eq(expected_right)
    nil
  end

  # A narrow source-provenance seam for testing that an extent cannot borrow a
  # caller-created shard which merely repeats an authenticated shard's slot
  # identity and coordinates but substitutes its bytes.
  def assert_recursive_extent_provenance!(part_path : String) : Nil
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    shards = physical.read_window("root", 0, 1).granules.first.shards
    authentic = shards.find { |shard| !shard.bytes.empty? } ||
                raise CrystalClick::CorruptPartError.new("root mark has no nonempty provenance shard")
    authentic_bytes = authentic.bytes
    authentic_context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
      physical,
      "root",
      [authentic],
    )
    start, finish = authentic_context.append_authenticated_extent!(authentic, 0, authentic_bytes)
    start.should eq(0_u64)
    finish.should eq(authentic_bytes.size.to_u64)
    same_site_context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
      physical,
      "root",
      [authentic],
    )
    same_site_context.append_authenticated_extent!(authentic, 0, authentic_bytes)
    authentic_context.same_path?(same_site_context).should be_true

    sibling_site_context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
      physical,
      "root/tuple[0]",
      [authentic],
    )
    sibling_site_context.append_authenticated_extent!(authentic, 0, authentic_bytes)
    authentic_context.same_path?(sibling_site_context).should be_false
    provenance_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    authentic_slice = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
      "root.object_structure",
      "root.object_structure",
      start,
      finish,
      authentic_bytes,
      authentic_context,
      provenance_budget,
    )
    sibling_slice = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
      "root.object_structure",
      "root.object_structure",
      start,
      finish,
      authentic_bytes,
      sibling_site_context,
      provenance_budget,
    )
    authentic_slice.context.same_path?(same_site_context).should be_true
    authentic_slice.context.same_path?(sibling_slice.context).should be_false
    authentic_context.validate_path_bytes!(
      start,
      authentic_bytes,
      provenance_budget,
    )

    copied_physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    copied_shards = copied_physical.read_window("root", 0, 1).granules.first.shards
    copied_authentic = copied_shards.find { |shard| !shard.bytes.empty? } ||
                       raise CrystalClick::CorruptPartError.new("root mark has no nonempty provenance shard")
    altered = copied_authentic.bytes
    altered[0] = altered[0] ^ 0x01_u8
    forged = CrystalClick::CompactPartPhysicalShard.new(
      copied_authentic.slot_index,
      copied_authentic.stream_name,
      copied_authentic.logical_start,
      copied_authentic.logical_end,
      altered,
    )
    forged_context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
      copied_physical,
      "root",
      [copied_authentic],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      forged_start, _forged_finish = forged_context.append_authenticated_extent!(forged, 0, altered)
      forged_context.validate_path_bytes!(
        forged_start,
        altered,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
    end
    nil
  end

  # The parent-granule binding is intentionally tested through the physical
  # context boundary: a site ledger may use only the exact selected-column
  # mark, row grid, source offset, roster, and bytes authenticated here.
  def assert_parent_granule_provenance!(part_path : String) : Nil
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    authentic = physical.read_window("root", 0, 1).granules.first
    authentic_shards = authentic.shards
    physical.validate_parent_granule!("root", authentic, authentic_shards)
    authentic_shards.size.should be > 1

    expect_raises(CrystalClick::CorruptPartError) do
      physical.validate_parent_granule!("docs", authentic, authentic_shards)
    end

    reordered_shards = authentic_shards.dup
    first_shard = reordered_shards[0]
    reordered_shards[0] = reordered_shards[1]
    reordered_shards[1] = first_shard
    expect_raises(CrystalClick::CorruptPartError) do
      physical.validate_parent_granule!("root", authentic, reordered_shards)
    end

    wrong_mark_physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    next_mark = wrong_mark_physical.read_window("root", 1, 1).granules.first
    next_mark.shards.map { |shard| {shard.logical_start, shard.logical_end} }.should_not eq(
      authentic_shards.map { |shard| {shard.logical_start, shard.logical_end} }
    )
    relabeled = CrystalClick::CompactPartPhysicalGranule.new(
      authentic.mark,
      authentic.row_offset,
      authentic.row_count,
      next_mark.shards,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      wrong_mark_physical.validate_parent_granule!("root", relabeled, relabeled.shards)
    end

    wrong_rows = CrystalClick::CompactPartPhysicalGranule.new(
      authentic.mark,
      authentic.row_offset,
      authentic.row_count + 1_u64,
      authentic_shards,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      physical.validate_parent_granule!("root", wrong_rows, wrong_rows.shards)
    end

    wrong_offset = CrystalClick::CompactPartPhysicalGranule.new(
      authentic.mark,
      authentic.row_offset + 1_u64,
      authentic.row_count,
      authentic_shards,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      physical.validate_parent_granule!("root", wrong_offset, wrong_offset.shards)
    end

    payload_physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    payload_granule = payload_physical.read_window("root", 0, 1).granules.first
    payload_shards = payload_granule.shards
    changed_index = payload_shards.index { |shard| !shard.bytes.empty? } ||
                    raise CrystalClick::CorruptPartError.new("root mark has no nonempty provenance shard")
    original = payload_shards[changed_index]
    changed_bytes = original.bytes
    changed_bytes[0] = changed_bytes[0] ^ 0x01_u8
    payload_shards[changed_index] = CrystalClick::CompactPartPhysicalShard.new(
      original.slot_index,
      original.stream_name,
      original.logical_start,
      original.logical_end,
      changed_bytes,
    )
    changed_granule = CrystalClick::CompactPartPhysicalGranule.new(
      payload_granule.mark,
      payload_granule.row_offset,
      payload_granule.row_count,
      payload_shards,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      payload_physical.validate_parent_granule!("root", changed_granule, changed_granule.shards)
    end

    budget = CrystalClick::CompressedStreamBudget.read_default
    budgeted_physical = CrystalClick::CompactPartPhysicalContext.open(part_path, budget)
    budgeted_granule = budgeted_physical.read_window("root", 0, 1).granules.first
    required_records = budgeted_granule.shards.size.to_i64
    remaining_records = budget.limits.max_records - budget.record_count
    remaining_records.should be >= required_records
    # Leave one fewer record than this parent roster needs. Rejection must be
    # a non-mutating preflight, not a partial descriptor reservation.
    budget.reserve_records(remaining_records - required_records + 1_i64)
    records_before = budget.record_count
    expect_raises(CrystalClick::CorruptPartError, /header-record limit exceeded/) do
      budgeted_physical.validate_parent_granule!("root", budgeted_granule, budgeted_granule.shards)
    end
    budget.record_count.should eq(records_before)
    nil
  end

  # Resolve source pairs through callback-local extents rather than treating
  # a recursive Compact site's noncontiguous callbacks as one rebased range.
  # This uses the deterministic W259 Compact fixture, not a native capture or
  # a native-writer compatibility claim.
  def assert_recursive_coordinate_pair_resolution! : Nil
    parent = File.tempname("crystal-click-w263-recursive-coordinate-")
    part_path = File.join(parent, CompactJsonW263Fixture::PART_NAME)
    Dir.mkdir_p(parent)
    begin
      CompactPhysicalContextW259Fixture.build(part_path, CrystalClick::CompactMarkFormat::Mrk4)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      positioned = recursive_coordinate_positions
      selected = physical.read_window("alpha", 0, 4).granules.map { |granule| granule.shards[0] }
      selected.map { |shard| {shard.logical_start, shard.logical_end} }.should eq([
        {0_i64, 2_i64},
        {4_i64, 4_i64},
        {10_i64, 12_i64},
        {14_i64, 16_i64},
      ])

      context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
        physical,
        "alpha:JSON/root.shared:occurrence-0",
        selected,
      )
      codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
      slices = [] of CrystalClick::ObjectSharedInlineCallbackReadSlice
      starts = [0_u64, 2_u64, 2_u64, 4_u64]
      ends = [2_u64, 2_u64, 4_u64, 6_u64]
      selected.each_with_index do |shard, index|
        start, finish = context.append_authenticated_extent!(shard, 0_i32, shard.bytes)
        {start, finish}.should eq({starts[index], ends[index]})
        slices << CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
          "canonical.alpha.shared.#{index}",
          "raw.alpha.shared.#{index}",
          start,
          finish,
          shard.bytes,
          context,
          codec_budget,
        )
      end
      context.path_data_size.should eq(6_i64)

      # The source interval at [2,4) is a real neighboring beta.shared
      # callback. Its pair resolves inside beta but cannot be borrowed by the
      # first alpha callback despite sharing one physical data.bin domain.
      beta_shard = physical.read_window("beta", 0, 1).granules.first.shards.first
      beta_context = CrystalClick::CompactRecursiveObjectSharedInlineCoordinateContext.new(
        physical,
        "beta:JSON/root.shared:occurrence-0",
        [beta_shard],
      )
      beta_start, beta_end = beta_context.append_authenticated_extent!(beta_shard, 0_i32, beta_shard.bytes)
      beta_slice = CrystalClick::ObjectSharedInlineCallbackReadSlice.new(
        "canonical.beta.shared",
        "raw.beta.shared",
        beta_start,
        beta_end,
        beta_shard.bytes,
        beta_context,
        codec_budget,
      )

      slices[0].resolve_pair(recursive_pair_at(positioned, 1_u64)).should eq(1_i64)
      beta_slice.resolve_pair(recursive_pair_at(positioned, 3_u64)).should eq(1_i64)
      expect_raises(CrystalClick::CorruptPartError) do
        slices[0].resolve_pair(recursive_pair_at(positioned, 3_u64))
      end

      # The empty callback owns its terminal point, while later disjoint
      # extents remain anchored at their original whole-data coordinates.
      slices[1].resolve_pair(recursive_pair_at(positioned, 4_u64)).should eq(0_i64)
      slices[2].resolve_pair(recursive_pair_at(positioned, 10_u64)).should eq(0_i64)
      slices[2].resolve_pair(recursive_pair_at(positioned, 11_u64)).should eq(1_i64)
      slices[3].resolve_pair(recursive_pair_at(positioned, 14_u64)).should eq(0_i64)
      slices[3].resolve_pair(recursive_pair_at(positioned, 16_u64)).should eq(2_i64)
      # Offset 10 is a real endpoint of the neighbouring nonempty extent and
      # therefore aliases the first callback's valid terminal coordinate.
      # Offset 11 is strictly inside that neighbouring extent and must not be
      # borrowed by the first callback.
      expect_raises(CrystalClick::CorruptPartError) do
        slices[0].resolve_pair(recursive_pair_at(positioned, 11_u64))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
    nil
  end

  # Exercise only the source lifecycle admission gate. The synthetic direct
  # capture consumes the authentic MRK4 callback sequence but intentionally
  # does not claim to decode or validate an Object document.
  def assert_prepared_source_gate!(part_path : String) : Nil
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.mrk4?.should be_true
    granule = physical.read_window("root", 0, 1).granules.first
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(physical, "root", granule, budget)
    source = ledger.site_source("root")

    expect_raises(CrystalClick::UnsupportedFormatError, /completed parent and site lifecycles/) do
      source.validate_prepared_source_gate!(budget)
    end

    shards = granule.shards
    event_names = shards.map do |shard|
      shard.stream_name || raise CrystalClick::CorruptPartError.new("native MRK4 callback is unnamed")
    end
    first_name = event_names.first? || raise CrystalClick::CorruptPartError.new("native root has no MRK4 callbacks")
    source.with_grammar_extent(first_name) do |bytes|
      {0, bytes.size}
    end
    source.begin_body_capture!
    ledger.finish_prefixes!
    ledger.begin_array_sizes!(0)
    ledger.finish_array_sizes!
    shards.each_with_index do |shard, index|
      next if index == 0
      name = event_names[index]
      source.take_exact(name, shard.bytes.size)
    end
    source.finish!
    source.validate_expected_events!(event_names)
    ledger.finish_mark!(event_names)
    ledger.complete?.should be_true

    source.validate_prepared_source_gate!(budget)
    foreign_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    expect_raises(ArgumentError, /exact capture budget operation/) do
      source.validate_prepared_source_gate!(foreign_budget)
    end
    nil
  end

  # Change only the last mark's Array(JSON) size0 lane inside the explicitly
  # selected MAP MRK3 copy. This cell has no persisted Advanced coordinate
  # pairs, so the changed logical tape is re-encoded and every outer MRK3
  # coordinate is remapped against the new literal-frame layout.
  def rewrite_docs_last_mark_sizes!(
    part_path : String,
    values : Tuple(UInt64, UInt64),
    label : String,
  ) : Nil
    label.should eq(ARRAY_MAP_MRK3_LABEL)
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.mrk3?.should be_true
    physical.row_count.should eq(CompactJsonW263Fixture::ROWS.to_u64)
    physical.mark_row_counts.should eq(CompactJsonW263Fixture::MARK_ROWS)
    original_columns = physical.columns
    original_rows = physical.mark_row_counts
    original_roster = physical.physical_roster.map do |slot|
      {slot.index, slot.column_name, slot.stream_name}
    end

    mark_index = physical.granule_count - 1
    shard, prefix_size, lane = docs_last_mark_size_lane!(part_path, mark_index)
    shard.stream_name.should be_nil
    shard.logical_start.should be >= 0_i64
    lane.size.should eq(16)
    read_u64_le(lane, 0).should eq(1_u64)
    read_u64_le(lane, 8).should eq(4_u64)

    original_raw = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, "data.bin"),
      File.size(File.join(part_path, "data.bin")).to_i64,
    )
    raw = original_raw.dup
    offset = shard.logical_start.to_i + prefix_size
    raw[offset, lane.size].should eq(lane)
    prefix_bytes = raw[shard.logical_start.to_i, prefix_size].dup
    write_u64_le(raw, offset, values[0])
    write_u64_le(raw, offset + 8, values[1])

    raw.size.should eq(original_raw.size)
    raw.each_index do |index|
      next if index >= offset && index < offset + lane.size
      raw[index].should eq(original_raw[index])
    end

    rewrite_mrk3_tape!(part_path, physical, raw)
    reopened = CrystalClick::CompactPartPhysicalContext.open(part_path)
    reopened.mode.mrk3?.should be_true
    reopened.row_count.should eq(physical.row_count)
    reopened.granule_count.should eq(physical.granule_count)
    reopened.columns.should eq(original_columns)
    reopened.mark_row_counts.should eq(original_rows)
    reopened.physical_roster.map do |slot|
      {slot.index, slot.column_name, slot.stream_name}
    end.should eq(original_roster)

    rewritten_raw = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, "data.bin"),
      File.size(File.join(part_path, "data.bin")).to_i64,
    )
    rewritten_raw.should eq(raw)
    changed_shard, changed_prefix, changed_lane = docs_last_mark_size_lane!(part_path, mark_index)
    changed_prefix.should eq(prefix_size)
    rewritten_raw[changed_shard.logical_start.to_i, changed_prefix].should eq(prefix_bytes)
    changed_lane.size.should eq(16)
    read_u64_le(changed_lane, 0).should eq(values[0])
    read_u64_le(changed_lane, 8).should eq(values[1])
    nil
  end

  # Reconstruct expected parent association by repartitioning only the
  # independent fixture's flattened child literals. This is not learned from
  # a decoded part or from a generated codec result.
  def redistributed_docs_signatures : Array(String)
    flattened = [] of CrystalClick::BinaryValue
    CompactJsonW263Fixture.docs_values.each do |row|
      flattened.concat(row.elements)
    end
    counts = CompactJsonW263Fixture::DOC_COUNTS.dup
    counts[6] = 4
    counts[7] = 1
    offset = 0
    counts.map do |count|
      children = flattened[offset, count]
      offset += count
      child_signatures = children.map { |child| CompactJsonW263Fixture.value_signature(child) }
      "#{CompactJsonW263Fixture.docs_type.name}[#{child_signatures.join(";")}]"
    end
  end

  def assert_original_unchanged!(source_path : String, inventory : Inventory) : Nil
    CompactJsonW263Fixture.assert_native_inventory!(source_path, inventory)
    nil
  end

  private def site_names(
    physical : CrystalClick::CompactPartPhysicalContext,
    column : String,
  ) : Array(String)
    names = physical.physical_roster.select { |slot| slot.column_name == column }.map do |slot|
      slot.stream_name || raise CrystalClick::CorruptPartError.new("physical site has an unnamed callback")
    end
    names
  end

  private def substream_blocks(
    physical : CrystalClick::CompactPartPhysicalContext,
  ) : Array({String, Array(String)})
    physical.columns.map do |column, _type|
      streams = physical.physical_roster.select { |slot| slot.column_name == column }.map do |slot|
        slot.stream_name || raise CrystalClick::CorruptPartError.new("MRK4 roster contains an unnamed callback")
      end
      {column, streams}
    end
  end

  private def write_substream_blocks!(part_path : String, blocks : Array({String, Array(String)})) : Nil
    File.write(
      File.join(part_path, "columns_substreams.txt"),
      CompactPhysicalContextW259Fixture.substreams_text(blocks),
    )
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
    nil
  end

  # Parse the selected MRK3 parent prefix using its authenticated whole-column
  # shard, then capture the exact size0 lane immediately after that prefix.
  # `source.position` is the local captured byte count, not a guessed physical
  # slot size or the start of the whole-column mark interval.
  private def docs_last_mark_size_lane!(
    part_path : String,
    mark_index : Int,
  ) : Tuple(CrystalClick::CompactPartPhysicalShard, Int32, Bytes)
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.mrk3?.should be_true
    granule = physical.read_window("docs", mark_index, 1).granules.first
    granule.row_count.should eq(CompactJsonW263Fixture::MARK_ROWS[mark_index])
    granule.shards.size.should eq(1)
    shard = granule.shards.first

    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    schema = CrystalClick::StorageColumnSchema.parse(CompactJsonW263Fixture.docs_type.name)
    plan = CrystalClick::CompactRecursiveJsonSchemaPlan.new(schema, "docs", limits, budget)
    plan.json_sites.size.should eq(1)
    plan.array_sites.size.should eq(1)
    json_site = plan.json_sites.first
    array_site = plan.array_sites.first
    ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(physical, "docs", granule, budget)
    source = ledger.site_source(json_site.key)
    transport_budget = CrystalClick::CompressedStreamBudget.read_default
    profile = CrystalClick::CompactSerializationProfile.open(
      part_path,
      physical.columns,
      "docs",
      CompactJsonW263Fixture.docs_type,
      physical.row_count,
      transport_budget,
    )
    profile.map_basic.should be_true
    nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
      0_u64,
      profile.ordinary_profile,
    )
    prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
      source,
      json_site.descriptor,
      json_site.descriptor_depth,
      json_site.physical_prefix,
      json_site.callback_prefix,
      json_site.array_level,
      nested_context,
      budget,
      true,
    )
    # Advanced shared mark rows (and their persisted compressed-coordinate
    # pairs) begin at shared_data_version 2. This captured S0 MAP cell is
    # deliberately kept below that boundary before its tape is re-encoded.
    prefix.structures.object.shared_data_version.should be <= 1_u64
    source.begin_body_capture!
    ledger.finish_prefixes!
    ledger.begin_array_sizes!(plan.array_sites.size)
    prefix_size = source.position
    if granule.row_count > Int32::MAX.to_u64 // 8_u64
      raise CrystalClick::CorruptPartError.new("recursive Compact Array-size lane exceeds its supported byte domain")
    end
    lane_size = (granule.row_count * 8_u64).to_i32
    lane = ledger.capture_array_size_lane(array_site.callback_name, lane_size)
    ledger.finish_array_sizes!
    {shard, prefix_size, lane}
  end

  # Re-encode only the authenticated MAP MRK3 copy. Persist every original
  # mark's whole-column logical start through the writer's exact position
  # planner, then rebuild all records (including one terminal coordinate per
  # slot) without changing declarations, row counts or physical slot order.
  private def rewrite_mrk3_tape!(
    part_path : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    raw : Bytes,
  ) : Nil
    slots = physical.physical_roster
    raise "W263 MAP MRK3 fixture has no physical slots" if slots.empty?

    slot_positions = slots.map do |slot|
      window = physical.read_window(slot.column_name, 0, physical.granule_count)
      unless window.granules.size == physical.granule_count
        raise "W263 MAP MRK3 source column has an incomplete mark window"
      end
      window.granules.map do |granule|
        shard = granule.shards.find { |candidate| candidate.slot_index == slot.index } ||
                raise CrystalClick::CorruptPartError.new("W263 MAP MRK3 slot has no authenticated whole-column shard")
        shard.logical_start
      end
    end

    queries = [] of UInt64
    physical.granule_count.times do |mark_index|
      slots.each_with_index do |_slot, slot_index|
        logical_start = slot_positions[slot_index][mark_index]
        raise CrystalClick::CorruptPartError.new("W263 MAP MRK3 slot starts before logical data") if logical_start < 0
        queries << logical_start.to_u64
      end
    end
    slots.size.times { queries << raw.size.to_u64 }

    remapped = CrystalClick::CompressedMarkWriter.plan_literal_positions(raw.size.to_i64, queries)
    new_data = CrystalClick::CompressedMarkWriter.encode_all(raw)
    record_width = slots.size * 16 + 8
    record_count = physical.granule_count + 1
    new_marks = Bytes.new(record_width * record_count, 0_u8)
    mapping_index = 0
    record_count.times do |mark_index|
      slots.size.times do |slot_index|
        compressed_offset, decompressed_offset = remapped[mapping_index]
        mark_offset = mark_index * record_width + slot_index * 16
        write_u64_le(new_marks, mark_offset, compressed_offset)
        write_u64_le(new_marks, mark_offset + 8, decompressed_offset)
        mapping_index += 1
      end
      row_count = mark_index == physical.granule_count ? 0_u64 : physical.mark_row_counts[mark_index]
      write_u64_le(new_marks, mark_index * record_width + slots.size * 16, row_count)
    end
    mapping_index.should eq(remapped.size)
    remapped.size.should eq(record_count * slots.size)

    File.write(File.join(part_path, "data.bin"), new_data)
    File.write(File.join(part_path, "data.mrk3"), new_marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    actual_raw = CrystalClick::CompressedMarkReader.read_all(
      File.join(part_path, "data.bin"),
      File.size(File.join(part_path, "data.bin")).to_i64,
    )
    actual_raw.should eq(raw)
    nil
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    raise CrystalClick::CorruptPartError.new("W263 copied size0 lane is truncated") if offset < 0 || offset > bytes.size - 8
    value = 0_u64
    8.times do |index|
      value |= bytes[offset + index].to_u64 << (index * 8)
    end
    value
  end

  private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
    raise CrystalClick::CorruptPartError.new("W263 copied size0 lane is truncated") if offset < 0 || offset > bytes.size - 8
    8.times do |index|
      bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
    end
    nil
  end

  private def recursive_coordinate_positions : CrystalClick::CompressedMarkPositionFiles
    raw = CompactPhysicalContextW259Fixture.raw_bytes(CrystalClick::CompactMarkFormat::Mrk4)
    queries = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 6_u64, 10_u64, 11_u64,
               12_u64, 14_u64, 15_u64, 16_u64, raw.size.to_u64]
    CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw,
      [0_u64, raw.size.to_u64],
      [CompactPhysicalContextW259Fixture::ROW_COUNTS.sum],
      queries,
      frame_bytes: 7,
    )
  end

  private def recursive_pair_at(
    positioned : CrystalClick::CompressedMarkPositionFiles,
    logical_offset : UInt64,
  ) : Tuple(UInt64, UInt64)
    raw = CompactPhysicalContextW259Fixture.raw_bytes(CrystalClick::CompactMarkFormat::Mrk4)
    queries = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 6_u64, 10_u64, 11_u64,
               12_u64, 14_u64, 15_u64, 16_u64, raw.size.to_u64]
    index = queries.index(logical_offset) || raise "missing recursive W263 coordinate query"
    positioned.position_at(index)
  end
end
