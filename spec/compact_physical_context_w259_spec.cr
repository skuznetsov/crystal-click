require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"

private def cpw259_with_valid_part(mode : CrystalClick::CompactMarkFormat, &)
  root = File.tempname("crystal-click-w259-physical")
  part = File.join(root, "part")
  Dir.mkdir_p(root)
  begin
    CompactPhysicalContextW259Fixture.build(part, mode)
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "Compact physical mark-grid windows (W259)" do
  it "exposes exact columns, globally flattened slot identity, and ordered mrk3 windows" do
    cpw259_with_valid_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      context.row_count.should eq(8_u64)
      context.granule_count.should eq(4_i32)
      context.columns.should eq(CompactPhysicalContextW259Fixture::COLUMNS)
      context.physical_roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq([
        {0_i32, "alpha", nil},
        {1_i32, "beta", nil},
        {2_i32, "gamma", nil},
      ])

      # A decoy sidecar cannot turn a mrk3 whole-column slot into nested
      # substream slots; the mode is determined by the mark extension.
      File.write(File.join(part, "columns_substreams.txt"),
        CompactPhysicalContextW259Fixture.substreams_text)
      CompactPhysicalContextW259Fixture.refresh_checksums(part)
      unchanged = CrystalClick::CompactPartPhysicalContext.open(part)
      unchanged.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      unchanged.physical_roster.map(&.stream_name).should eq([nil, nil, nil])

      cpw259_assert_all_windows(unchanged, CrystalClick::CompactMarkFormat::Mrk3)
    end
  end

  it "keeps same-named mrk4 streams as distinct global slots across column blocks" do
    cpw259_with_valid_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
      context.row_count.should eq(8_u64)
      context.granule_count.should eq(4_i32)
      context.columns.should eq(CompactPhysicalContextW259Fixture::COLUMNS)
      context.physical_roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq([
        {0_i32, "alpha", "shared"},
        {1_i32, "alpha", "payload"},
        {2_i32, "beta", "shared"},
        {3_i32, "gamma", "offsets"},
      ])

      repeated = context.physical_roster.select { |slot| slot.stream_name == "shared" }
      repeated.map(&.index).should eq([0_i32, 2_i32])
      repeated.map(&.column_name).should eq(["alpha", "beta"])
      cpw259_assert_all_windows(context, CrystalClick::CompactMarkFormat::Mrk4)

      # The alpha payload and gamma offsets are empty in mark zero. They remain
      # separate adjacent slots, and the next nonempty shard starts at the same
      # logical coordinate rather than causing identity coalescing.
      alpha_first = context.read_window("alpha", 0, 1).granules.first.shards
      alpha_first.map(&.slot_index).should eq([0_i32, 1_i32])
      alpha_first[1].logical_start.should eq(alpha_first[1].logical_end)
      alpha_first[1].bytes.should be_empty
      gamma_first = context.read_window("gamma", 0, 1).granules.first.shards.first
      gamma_first.logical_start.should eq(gamma_first.logical_end)
      gamma_first.bytes.should be_empty
    end
  end

  it "returns a detached zero-length EOF window and rejects outside selections" do
    cpw259_with_valid_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      eof = context.read_window("alpha", 4, 0)
      eof.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
      eof.column.should eq("alpha")
      eof.first_mark.should eq(4_i32)
      eof.row_offset.should eq(8_u64)
      eof.granules.should be_empty

      expect_raises(ArgumentError) { context.read_window("alpha", -1, 1) }
      expect_raises(ArgumentError) { context.read_window("alpha", 0, -1) }
      expect_raises(ArgumentError) { context.read_window("alpha", 5, 0) }
      expect_raises(ArgumentError) { context.read_window("alpha", 3, 2) }
      expect_raises(ArgumentError) { context.read_window("alpha", Int64::MAX, 0) }
      expect_raises(ArgumentError) { context.read_window("alpha", 0, Int64::MAX) }
      expect_raises(ArgumentError) { context.read_window("missing", 0, 1) }

      selected = context.read_window("beta", 1, 1)
      before = selected.granules.first.shards.first.bytes
      before.should eq("b1".to_slice)
      before[0] = 'X'.ord.to_u8
      context.read_window("beta", 1, 1).granules.first.shards.first.bytes.should eq("b1".to_slice)

      columns_snapshot = context.columns
      columns_snapshot.clear
      context.columns.should eq(CompactPhysicalContextW259Fixture::COLUMNS)
      roster_snapshot = context.physical_roster
      roster_snapshot.clear
      context.physical_roster.size.should eq(4)
    end
  end
end

private def cpw259_assert_all_windows(
  context : CrystalClick::CompactPartPhysicalContext,
  mode : CrystalClick::CompactMarkFormat,
) : Nil
  windows = [
    {"full", 0_i32, 4_i32},
    {"first", 0_i32, 1_i32},
    {"middle", 1_i32, 2_i32},
    {"last", 3_i32, 1_i32},
    {"eof", 4_i32, 0_i32},
  ]
  expected_slots = CompactPhysicalContextW259Fixture.slots(mode)
  expected_marks = CompactPhysicalContextW259Fixture.shards(mode)
  columns = CompactPhysicalContextW259Fixture::COLUMNS.map(&.[0])

  columns.each do |column|
    selected = [] of Tuple(Int32, String?)
    expected_slots.each_with_index do |slot, global_index|
      selected << {global_index.to_i32, slot[1]} if slot[0] == column
    end
    windows.each do |_label, first_mark, mark_count|
      actual = context.read_window(column, first_mark, mark_count)
      actual.mode.should eq(mode)
      actual.column.should eq(column)
      actual.first_mark.should eq(first_mark)
      expected_row_offset = CompactPhysicalContextW259Fixture::ROW_COUNTS[0, first_mark].sum
      actual.row_offset.should eq(expected_row_offset)
      actual.granules.size.should eq(mark_count)

      mark_count.times do |window_offset|
        mark = first_mark + window_offset
        granule = actual.granules[window_offset]
        granule.mark.should eq(mark)
        granule.row_offset.should eq(CompactPhysicalContextW259Fixture::ROW_COUNTS[0, mark].sum)
        granule.row_count.should eq(CompactPhysicalContextW259Fixture::ROW_COUNTS[mark])
        granule.shards.size.should eq(selected.size)

        global_logical_start = 0_i64
        mark.times do |previous_mark|
          expected_marks[previous_mark].each { |shard| global_logical_start += shard.size.to_i64 }
        end
        expected_marks[mark].each_with_index do |bytes, global_slot|
          next unless expected_slots[global_slot][0] == column
          slot_offset = expected_marks[mark][0, global_slot].sum(&.size).to_i64
          global_logical_start_for_slot = global_logical_start + slot_offset
          selected_position = selected.index { |entry| entry[0] == global_slot.to_i32 } || raise "missing W259 selected slot"
          local_index = selected_position
          shard = granule.shards[local_index]
          global_end = global_logical_start_for_slot + bytes.size.to_i64

          # These offsets are intentionally literal-derived from the fixture
          # byte tape, independent of CompactPartPhysicalContext's mark parser.
          shard.slot_index.should eq(global_slot.to_i32)
          shard.stream_name.should eq(expected_slots[global_slot][1])
          shard.logical_start.should eq(global_logical_start_for_slot)
          shard.logical_end.should eq(global_end)
          shard.bytes.should eq(bytes)
        end
      end
    end
  end
  nil
end
