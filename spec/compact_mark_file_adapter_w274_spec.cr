require "./spec_helper"
require "./support/compact_mark_file_adapter_w274_fixture"

private def w274_window_signature(window : CrystalClick::CompactPartPhysicalWindow)
  window.granules.map do |granule|
    {
      granule.mark,
      granule.row_offset,
      granule.row_count,
      granule.shards.map do |shard|
        {shard.slot_index, shard.stream_name, shard.logical_start, shard.logical_end, shard.bytes}
      end,
    }
  end
end

private def w274_assert_all_literal_windows(
  context : CrystalClick::CompactPartPhysicalContext,
  mode : CrystalClick::CompactMarkFormat,
) : Nil
  windows = [
    {"full", 0, 4},
    {"first", 0, 1},
    {"middle", 1, 2},
    {"last", 3, 1},
    {"eof", 4, 0},
  ]
  expected_slots = CompactPhysicalContextW259Fixture.slots(mode)
  expected_marks = CompactPhysicalContextW259Fixture.shards(mode)
  columns = CompactPhysicalContextW259Fixture::COLUMNS.map(&.[0])

  context.columns.should eq(CompactPhysicalContextW259Fixture::COLUMNS)
  expected_roster = CompactPhysicalContextW259Fixture.slots(mode).each_with_index.map do |slot, index|
    {index.to_i32, slot[0], slot[1]}
  end.to_a
  context.physical_roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq(expected_roster)

  columns.each do |column|
    selected_slots = [] of Tuple(Int32, String?)
    expected_slots.each_with_index do |slot, global_index|
      selected_slots << {global_index.to_i32, slot[1]} if slot[0] == column
    end

    windows.each do |_label, first_mark, mark_count|
      actual = context.read_window(column, first_mark, mark_count)
      actual.mode.should eq(mode)
      actual.column.should eq(column)
      actual.first_mark.should eq(first_mark.to_i32)
      actual.row_offset.should eq(CompactPhysicalContextW259Fixture::ROW_COUNTS[0, first_mark].sum)

      granules = actual.granules
      granules.size.should eq(mark_count)
      mark_count.times do |window_offset|
        mark = first_mark + window_offset
        granule = granules[window_offset]
        granule.mark.should eq(mark.to_i32)
        granule.row_offset.should eq(CompactPhysicalContextW259Fixture::ROW_COUNTS[0, mark].sum)
        granule.row_count.should eq(CompactPhysicalContextW259Fixture::ROW_COUNTS[mark])
        granule.shards.size.should eq(selected_slots.size)

        logical_start = 0_i64
        mark.times do |previous_mark|
          expected_marks[previous_mark].each { |shard| logical_start += shard.size.to_i64 }
        end
        expected_marks[mark].each_with_index do |bytes, global_slot|
          next unless expected_slots[global_slot][0] == column
          slot_start = logical_start + expected_marks[mark][0, global_slot].sum(&.size).to_i64
          slot_end = slot_start + bytes.size.to_i64
          local_index = selected_slots.index { |slot| slot[0] == global_slot.to_i32 } ||
                        raise "W274 literal window lost a selected slot"
          shard = granule.shards[local_index]
          shard.slot_index.should eq(global_slot.to_i32)
          shard.stream_name.should eq(expected_slots[global_slot][1])
          shard.logical_start.should eq(slot_start)
          shard.logical_end.should eq(slot_end)
          shard.bytes.should eq(bytes)
        end
      end
    end
  end

  # Explicitly preserve the empty callback identity and terminal position for
  # both layouts; equal logical endpoints do not erase an empty physical slot.
  if mode.mrk3?
    empty = context.read_window("gamma", 0, 1).granules.first.shards.first
    empty.slot_index.should eq(2_i32)
    empty.logical_start.should eq(empty.logical_end)
    empty.bytes.should be_empty
  else
    empty = context.read_window("alpha", 0, 1).granules.first.shards[1]
    empty.slot_index.should eq(1_i32)
    empty.stream_name.should eq("payload")
    empty.logical_start.should eq(empty.logical_end)
    empty.bytes.should be_empty
  end

  nil
end

describe "W274 compressed Compact mark source parity" do
  it "retains a parsed compressed-entry raw hash while plain entries have none" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      sidecar = CompactMarkFileAdapterW274Fixture.compressed_mark_name(mode)
      physical = File.read(File.join(part, sidecar)).to_slice
      raw_marks = CrystalClick::CompressedBlock.decode_all(physical)
      checksums = CrystalClick::PartChecksums.parse(File.read(File.join(part, "checksums.txt")).to_slice)
      entry = checksums.entry(sidecar).not_nil!

      entry.compressed.should be_true
      entry.uncompressed_size.should eq(raw_marks.size.to_u64)
      entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(physical))
      entry.uncompressed_hash.should eq(CrystalClick::CityHashV1.file_hash(raw_marks))
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode, compressed: false) do |part|
      plain_name = CompactMarkFileAdapterW274Fixture.mark_name(mode)
      checksums = CrystalClick::PartChecksums.parse(File.read(File.join(part, "checksums.txt")).to_slice)
      entry = checksums.entry(plain_name).not_nil!

      entry.compressed.should be_false
      entry.uncompressed_hash.should be_nil
      CrystalClick::PartChecksums::Entry.new(24_u64, false, nil).uncompressed_hash.should be_nil
    end
  end

  it "copies the optional raw hash into the detached PartStreamSource entry snapshot" do
    mode = CrystalClick::CompactMarkFormat::Mrk4
    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      sidecar = CompactMarkFileAdapterW274Fixture.compressed_mark_name(mode)
      physical = File.read(File.join(part, sidecar)).to_slice
      raw_marks = CrystalClick::CompressedBlock.decode_all(physical)
      checksums = CrystalClick::PartChecksums.parse(File.read(File.join(part, "checksums.txt")).to_slice)
      expected_raw_hash = CrystalClick::CityHashV1.file_hash(raw_marks)
      source = CrystalClick::PartStreamSource.new(part, checksums)

      source_entry = source.checksum_entry(sidecar).not_nil!
      source_entry.uncompressed_hash.should eq(expected_raw_hash)
      source_entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(physical))

      # Replacing the parser-owned table entry must not alter the detached
      # source snapshot, including its newly retained trailing hash field.
      checksums.entries[sidecar] = CrystalClick::PartChecksums::Entry.new(
        source_entry.physical_size,
        source_entry.compressed,
        source_entry.uncompressed_size,
        source_entry.file_hash
      )
      checksums.entry(sidecar).not_nil!.uncompressed_hash.should be_nil
      source.checksum_entry(sidecar).not_nil!.uncompressed_hash.should eq(expected_raw_hash)
    end
  end

  {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4}.each do |mode|
    it "preserves every #{mode} column window, empty slot, row, and terminal from the plain grid" do
      CompactMarkFileAdapterW274Fixture.with_isolated_part(mode, compressed: false) do |plain_part|
        CompactMarkFileAdapterW274Fixture.with_isolated_part(mode, compressed: true) do |compressed_part|
          plain = CrystalClick::CompactPartPhysicalContext.open(plain_part)
          compressed = CrystalClick::CompactPartPhysicalContext.open(compressed_part)

          plain.mode.should eq(mode)
          compressed.mode.should eq(mode)
          plain.row_count.should eq(8_u64)
          compressed.row_count.should eq(8_u64)
          plain.granule_count.should eq(4_i32)
          compressed.granule_count.should eq(4_i32)

          w274_assert_all_literal_windows(plain, mode)
          w274_assert_all_literal_windows(compressed, mode)

          columns = CompactPhysicalContextW259Fixture::COLUMNS.map(&.[0])
          selections = [{0, 4}, {0, 1}, {1, 2}, {3, 1}, {4, 0}]
          columns.each do |column|
            selections.each do |first_mark, mark_count|
              plain_window = plain.read_window(column, first_mark, mark_count)
              compressed_window = compressed.read_window(column, first_mark, mark_count)
              w274_window_signature(compressed_window).should eq(w274_window_signature(plain_window))
            end
          end
        end
      end
    end
  end

  {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4}.each do |mode|
    it "preserves #{mode} windows when UInt64 mark fields cross multi-frame boundaries" do
      CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
        mark_name = CompactMarkFileAdapterW274Fixture.compressed_mark_name(mode)
        existing = File.read(File.join(part, mark_name)).to_slice
        raw_marks = CrystalClick::CompressedBlock.decode_all(existing)
        physical = CompactMarkFileAdapterW274Fixture.compressed_frames(raw_marks, 13)

        frame_offsets = CompactMarkFileAdapterW274Fixture.compressed_frame_offsets(physical)
        frame_offsets.size.should be > 1
        boundaries = CompactMarkFileAdapterW274Fixture.internal_frame_uncompressed_boundaries(physical)
        boundaries.should_not be_empty
        boundaries.any? { |boundary| boundary % 8 != 0 }.should be_true

        CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, mark_name, physical, raw_marks)
        context = CrystalClick::CompactPartPhysicalContext.open(part)
        context.mode.should eq(mode)
        context.row_count.should eq(8_u64)
        context.granule_count.should eq(4_i32)
        w274_assert_all_literal_windows(context, mode)
      end
    end
  end
end
