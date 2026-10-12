require "./spec_helper"
require "./support/compact_part_writer_w264_fixture"
require "./support/compact_part_writer_w265_fixture"

private def w265_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

describe CrystalClick::CompactPartWriter do
  it "writes the static recursive callback roster as plain MRK4 with complete EOF" do
    fixture = CompactPartWriterW264Fixture
    parent = File.tempname("crystal-click-w265-compact-mrk4-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW264Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      checksums = CrystalClick::PartChecksums.open(part_path)
      checksums.entry("columns_substreams.txt").should be_nil

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
      physical.row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)
      physical.granule_count.should eq(4_i32)
      physical.physical_roster.map do |slot|
        {slot.index, slot.column_name, slot.stream_name}
      end.should eq([
        {0_i32, "pk", "pk"},
        {1_i32, "u", "u"},
        {2_i32, "text", "text"},
        {3_i32, "maybe", "maybe.null"},
        {4_i32, "maybe", "maybe"},
        {5_i32, "gap", "gap.size0"},
        {6_i32, "gap", "gap.null"},
        {7_i32, "gap", "gap"},
        {8_i32, "arr", "arr.size0"},
        {9_i32, "arr", "arr.null"},
        {10_i32, "arr", "arr"},
        {11_i32, "pair", "pair%2E1"},
        {12_i32, "pair", "pair%2E2.null"},
        {13_i32, "pair", "pair%2E2"},
        {14_i32, "lookup", "lookup.size0"},
        {15_i32, "lookup", "lookup%2Ekeys"},
        {16_i32, "lookup", "lookup%2Evalues"},
      ])

      detached_roster = physical.physical_roster
      detached_roster[6] = CrystalClick::CompactPhysicalSlot.new(6, "forged", "forged")
      detached_roster[0] = CrystalClick::CompactPhysicalSlot.new(0, "forged", "forged")
      detached_roster.pop
      physical.physical_roster.size.should eq(17)
      physical.physical_roster[6].stream_name.should eq("gap.null")
      physical.physical_roster[0].column_name.should eq("pk")

      marks_text = File.read(File.join(part_path, "data.mrk4"))
      marks = marks_text.to_slice
      marks.size.should eq(1_400)
      slot_count = 17
      record_width = slot_count * 16 + 8
      record_width.should eq(280)
      4.times do |mark|
        row_count_offset = mark * record_width + slot_count * 16
        w265_read_u64_le(marks, row_count_offset).should eq(2_u64)
      end

      # The terminal record carries an EOF pair for every callback slot,
      # including empty child lanes, followed by the terminal zero row count.
      data_size = File.size(File.join(part_path, "data.bin")).to_u64
      terminal_offset = 4 * record_width
      slot_count.times do |slot|
        pair_offset = terminal_offset + slot * 16
        w265_read_u64_le(marks, pair_offset).should eq(data_size)
        w265_read_u64_le(marks, pair_offset + 8).should eq(0_u64)
      end
      w265_read_u64_le(marks, terminal_offset + slot_count * 16).should eq(0_u64)

      # The first mark of `gap` has two empty arrays. The nullable-child and
      # value callbacks are distinct persisted slots despite both being empty.
      gap_shards = physical.read_window("gap", 0, 1).granules.first.shards
      gap_shards.map { |shard| {shard.slot_index, shard.stream_name} }.should eq([
        {5_i32, "gap.size0"},
        {6_i32, "gap.null"},
        {7_i32, "gap"},
      ])
      gap_shards[1].bytes.should be_empty
      gap_shards[1].logical_start.should eq(gap_shards[1].logical_end)
      gap_shards[2].bytes.should be_empty
      gap_shards[2].logical_start.should eq(gap_shards[2].logical_end)
      physical.read_window("gap", physical.granule_count, 0).granules.should be_empty

      pk_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
        part_path,
        CompactPartWriterW264Fixture::KEY_NAME,
        CrystalClick::BinaryDataType.primitive("UInt64"),
      )
      pk_reader.read_marks(0, pk_reader.mark_count).flatten.map(&.as_uint64)
        .should eq(CompactPartWriterW264Fixture::KEYS)

      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, name, fixture.types[name])
        reader.mark_count.should eq(4)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        reader.read_marks(0, reader.mark_count).flatten
          .map { |value| fixture.row_signature(value) }
          .should eq(fixture.signatures_for(name))
      end

      selected = ["pk"] + CompactPartWriterW264Fixture::COLUMN_NAMES
      table = CrystalClick::CompactPartTable.open_selected_typed([part_path], selected)
      table.columns.should eq(selected)
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])
      scanned_keys = [] of UInt64
      scanned_values = Hash(String, Array(String)).new do |values, name|
        values[name] = [] of String
      end
      scan_callbacks = 0
      table.scan_typed do |batch|
        scan_callbacks += 1
        scanned_keys.concat(batch.values_for("pk"))
        CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
          scanned_values[name].concat(fixture.batch_signatures(batch, name))
        end
      end
      scan_callbacks.should eq(4)
      scanned_keys.should eq(CompactPartWriterW264Fixture::KEYS)
      CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
        scanned_values[name].should eq(fixture.signatures_for(name))
      end

      candidate_keys = [] of UInt64
      candidate_gaps = [] of String
      table.scan_typed_candidate_marks([[1, 3]]) do |batch|
        candidate_keys.concat(batch.values_for("pk"))
        candidate_gaps.concat(fixture.batch_signatures(batch, "gap"))
      end
      candidate_keys.should eq([103_u64, 104_u64, 107_u64, 108_u64])
      candidate_gaps.should eq(
        fixture.signatures_for("gap")[2, 2] + fixture.signatures_for("gap")[6, 2],
      )
      eof_callbacks = 0
      table.scan_typed_window(CompactPartWriterW264Fixture::ROW_COUNT.to_u64, 1) do |_batch|
        eof_callbacks += 1
      end
      eof_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps the no-option writer on the existing plain MRK3 layout" do
    fixture = CompactPartWriterW264Fixture
    parent = File.tempname("crystal-click-w265-compact-mrk3-default-")
    default_path = File.join(parent, "default", "all_1_1_0")
    explicit_path = File.join(parent, "explicit", "all_1_1_0")
    begin
      Dir.mkdir(parent)
      Dir.mkdir(File.join(parent, "default"))
      Dir.mkdir(File.join(parent, "explicit"))
      CrystalClick::CompactPartWriter.write_uint64_columns(
        explicit_path,
        CompactPartWriterW264Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
      )
      CrystalClick::CompactPartWriter.write_uint64_columns(
        default_path,
        CompactPartWriterW264Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      )

      default_context = CrystalClick::CompactPartPhysicalContext.open(default_path)
      explicit_context = CrystalClick::CompactPartPhysicalContext.open(explicit_path)
      default_context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      explicit_context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      default_context.physical_roster.size.should eq(8)
      default_context.granule_count.should eq(4_i32)
      File.size(File.join(default_path, "data.mrk3")).should eq(680_i64)
      File.exists?(File.join(default_path, "data.mrk4")).should be_false
      File.exists?(File.join(default_path, "columns_substreams.txt")).should be_false
      File.read(File.join(default_path, "data.bin")).should eq(File.read(File.join(explicit_path, "data.bin")))
      File.read(File.join(default_path, "data.mrk3")).should eq(File.read(File.join(explicit_path, "data.mrk3")))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "binds detached MRK4 callback-plan views and rejects a mismatched backend input roster" do
    fixture = CompactPartWriterW264Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    key_type = CrystalClick::BinaryDataType.primitive("UInt64")
    key_granules = fixture.keys.each_slice(CompactPartWriterW264Fixture::ROWS_PER_MARK).map do |slice|
      slice.map { |value| CrystalClick::BinaryValue.uint64(value) }
    end.to_a
    inputs = [] of CrystalClick::CompactStaticColumnInput
    inputs << CrystalClick::CompactStaticColumnInput.new("pk", key_type, key_granules)
    fixture.columns.each { |column| inputs << column.static_input }
    plan = CrystalClick::CompactStaticWritePlan.new(
      inputs,
      limits,
      CrystalClick::CompactMarkFormat::Mrk4,
    )

    expected_substreams = plan.substreams
    detached_substreams = plan.substreams
    detached_substreams[0][1][0] = "forged"
    detached_substreams.pop
    plan.substreams.should eq(expected_substreams)

    detached_plans = plan.column_plans
    detached_plans.reverse!
    detached_plans.pop
    plan.column_plans.map(&.column_name).should eq(inputs.map(&.name))
    detached_names = plan.column_plans[4].callback_names
    detached_names[0] = "forged-callback"
    plan.column_plans[4].callback_names.should eq(["gap.size0", "gap.null", "gap"])

    # The exact plan remains usable after callers mutate every returned
    # container. This is the positive consumer-side binding control.
    encoded = CrystalClick::CompactStaticWriter.encode(
      inputs,
      [2_u64, 2_u64, 2_u64, 2_u64],
      limits,
      CompactPartWriterW264Fixture::FRAME_BYTES,
      CrystalClick::CompressedStreamBudget.write_default,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      plan,
    )
    encoded.marks_size.should eq(1_400)

    reordered = inputs.dup
    reordered[1], reordered[2] = reordered[2], reordered[1]
    expect_raises(ArgumentError, /plan is bound to different column inputs/) do
      CrystalClick::CompactStaticWriter.encode(
        reordered,
        [2_u64, 2_u64, 2_u64, 2_u64],
        limits,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
        CrystalClick::BinaryCodecBudget.new(limits, true),
        plan,
      )
    end

    wrong_name = inputs.dup
    original = inputs[1]
    wrong_name[1] = CrystalClick::CompactStaticColumnInput.new(
      "renamed",
      original.type,
      original.granules,
    )
    expect_raises(ArgumentError, /plan is bound to different column inputs/) do
      CrystalClick::CompactStaticWriter.encode(
        wrong_name,
        [2_u64, 2_u64, 2_u64, 2_u64],
        limits,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
        CrystalClick::BinaryCodecBudget.new(limits, true),
        plan,
      )
    end

    wrong_descriptor = inputs.dup
    wrong_descriptor[1] = CrystalClick::CompactStaticColumnInput.new(
      original.name,
      CrystalClick::BinaryDataType.primitive("UInt8"),
      original.granules,
    )
    expect_raises(ArgumentError, /plan is bound to different column inputs/) do
      CrystalClick::CompactStaticWriter.encode(
        wrong_descriptor,
        [2_u64, 2_u64, 2_u64, 2_u64],
        limits,
        CompactPartWriterW264Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.write_default,
        CrystalClick::BinaryCodecBudget.new(limits, true),
        plan,
      )
    end
  end

  it "uses the actual MRK4 callback count for the mark-byte cap" do
    parent = File.tempname("crystal-click-w265-mark-budget-")
    mrk3_path = File.join(parent, "mrk3", "all_1_1_0")
    mrk4_path = File.join(parent, "mrk4", "all_1_1_0")
    begin
      Dir.mkdir(parent)
      Dir.mkdir(File.join(parent, "mrk3"))
      Dir.mkdir(File.join(parent, "mrk4"))
      cap = CrystalClick::CompressedStreamLimits.new(max_mark_bytes: 1_000)

      CompactPartWriterW265Fixture.write(
        mrk3_path,
        CrystalClick::CompactMarkFormat::Mrk3,
        transport_limits: cap,
      )
      File.size(File.join(mrk3_path, "data.mrk3")).should eq(680_i64)
      CrystalClick::CompactPartPhysicalContext.open(mrk3_path).physical_roster.size.should eq(8)

      expect_raises(CrystalClick::UnsupportedFormatError, /mark-size limit/) do
        CompactPartWriterW265Fixture.write(
          mrk4_path,
          CrystalClick::CompactMarkFormat::Mrk4,
          transport_limits: cap,
        )
      end
      File.exists?(mrk4_path).should be_false
      Dir.children(File.join(parent, "mrk4")).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects checksum-valid MRK4 child coordinates and checksum-file-unchanged callback-roster mismatches" do
    parent = File.tempname("crystal-click-w265-mrk4-mutants-")
    source = File.join(parent, "source")
    child_mutant = File.join(parent, "child-mutant")
    roster_mutant = File.join(parent, "roster-mutant")
    begin
      Dir.mkdir(parent)
      CompactPartWriterW265Fixture.write(source)
      CompactPartWriterW265Fixture.copy_part(source, child_mutant)
      CompactPartWriterW265Fixture.copy_part(source, roster_mutant)

      # Child coordinates are changed in data.mrk4 and that checksum is
      # resealed; the reader must still reject their semantic mismatch.
      source_marks = File.read(File.join(source, "data.mrk4")).to_slice
      CompactPartWriterW265Fixture.mutate_gap_child_start!(child_mutant)
      child_marks = File.read(File.join(child_mutant, "data.mrk4")).to_slice
      child_marks.size.should eq(source_marks.size)
      child_difference_offsets = [] of Int32
      source_marks.size.times do |index|
        child_difference_offsets << index.to_i32 if source_marks[index] != child_marks[index]
      end
      child_pair_offset = 2 * CompactPartWriterW265Fixture::RECORD_WIDTH + 7 * 16
      child_difference_offsets.should_not be_empty
      child_difference_offsets.each do |offset|
        offset.should be >= child_pair_offset
        offset.should be < child_pair_offset + 16
      end
      null_pair_offset = 2 * CompactPartWriterW265Fixture::RECORD_WIDTH + 6 * 16
      w265_read_u64_le(child_marks, child_pair_offset)
        .should eq(w265_read_u64_le(source_marks, null_pair_offset))
      w265_read_u64_le(child_marks, child_pair_offset + 8)
        .should eq(w265_read_u64_le(source_marks, null_pair_offset + 8))
      File.read(File.join(source, "data.bin")).should eq(File.read(File.join(child_mutant, "data.bin")))
      child_checksums = CrystalClick::PartChecksums.open(child_mutant)
      child_marks_entry = child_checksums.entry("data.mrk4").not_nil!
      child_marks_entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(child_marks))
      CrystalClick::CompactBinaryBulkColumnReader.open(
        child_mutant,
        "pk",
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ).read_marks(0, 4).flatten.map(&.as_uint64).should eq(CompactPartWriterW264Fixture::KEYS)
      gap_type = CompactPartWriterW264Fixture.types["gap"]
      gap_reader = CrystalClick::CompactBinaryBulkColumnReader.open(child_mutant, "gap", gap_type)
      expect_raises(CrystalClick::CorruptPartError) { gap_reader.read_marks(2, 1) }

      # The sidecar is intentionally outside checksums.txt. Keep the checksum
      # file unchanged while mutating its roster and require metadata rejection.
      source_roster = File.read(File.join(source, "columns_substreams.txt"))
      source_checksums = File.read(File.join(source, "checksums.txt"))
      CompactPartWriterW265Fixture.mutate_gap_roster!(roster_mutant)
      File.read(File.join(roster_mutant, "data.bin")).should eq(File.read(File.join(source, "data.bin")))
      File.read(File.join(roster_mutant, "data.mrk4")).should eq(File.read(File.join(source, "data.mrk4")))
      File.read(File.join(roster_mutant, "checksums.txt")).should eq(source_checksums)
      mutated_roster = File.read(File.join(roster_mutant, "columns_substreams.txt"))
      mutated_roster.should_not eq(source_roster)
      mutated_roster.bytesize.should eq(source_roster.bytesize)
      roster_checksums = CrystalClick::PartChecksums.open(roster_mutant)
      roster_checksums.entry("columns_substreams.txt").should be_nil
      CrystalClick::CompactBinaryBulkColumnReader.open(
        roster_mutant,
        "pk",
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ).read_marks(0, 4).flatten.map(&.as_uint64).should eq(CompactPartWriterW264Fixture::KEYS)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactBinaryBulkColumnReader.open(roster_mutant, "gap", gap_type)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
