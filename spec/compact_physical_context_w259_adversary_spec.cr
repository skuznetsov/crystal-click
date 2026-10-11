require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"

private def cpw259_with_part(mode : CrystalClick::CompactMarkFormat, &)
  root = File.tempname("crystal-click-w259-adversary")
  part = File.join(root, "part")
  Dir.mkdir_p(root)
  begin
    CompactPhysicalContextW259Fixture.build(part, mode)
    yield part
  ensure
    FileUtils.rm_rf(root)
  end
end

private def cpw259_replace(path : String, name : String, bytes : Bytes, refresh_checksums : Bool = true) : Nil
  File.write(File.join(path, name), bytes)
  CompactPhysicalContextW259Fixture.refresh_checksums(path) if refresh_checksums
end

describe "W259 Compact physical context adversarial admission" do
  it "bounds row-count parsing before subtraction and preserves UInt64 boundary values" do
    CrystalClick::WidePart.parse_count_metadata("0", 0_u64).should eq(0_u64)
    CrystalClick::WidePart.parse_count_metadata("1\n", 1_u64).should eq(1_u64)
    CrystalClick::WidePart.parse_count_metadata("18446744073709551615", UInt64::MAX).should eq(UInt64::MAX)

    # A small caller-supplied maximum must not underflow during decimal
    # accumulation; it is a format refusal, never a leaked arithmetic error.
    { {"9", 1_u64}, {"1", 0_u64}, {"10", 1_u64} }.each do |text, limit|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.parse_count_metadata(text, limit)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePart.parse_count_metadata("", UInt64::MAX)
    end
    {"00", "01", "-1", "+1", "1 ", "18446744073709551616"}.each do |text|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.parse_count_metadata(text, UInt64::MAX)
      end
    end
  end

  it "keeps stream names unique within a column block but distinct across columns" do
    columns = CrystalClick::WidePart.parse_columns_metadata(
      CompactPhysicalContextW259Fixture.columns_text
    )
    parsed = CrystalClick::WidePart.parse_columns_substreams_metadata(
      CompactPhysicalContextW259Fixture.substreams_text,
      columns
    )
    parsed.map(&.[1]).should eq([["shared", "payload"], ["shared"], ["offsets"]])

    duplicate_within_alpha = [
      {"alpha", ["shared", "shared"]},
      {"beta", ["shared"]},
      {"gamma", ["offsets"]},
    ] of {String, Array(String)}
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.parse_columns_substreams_metadata(
        CompactPhysicalContextW259Fixture.substreams_text(duplicate_within_alpha),
        columns
      )
    end
  end

  it "guards the public raw roster constructors without imposing global stream-name uniqueness" do
    columns = CompactPhysicalContextW259Fixture::COLUMNS
    substreams = CompactPhysicalContextW259Fixture::MRK4_SUBSTREAMS

    mrk3 = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      columns
    )
    mrk3.roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq([
      {0_i32, "alpha", nil},
      {1_i32, "beta", nil},
      {2_i32, "gamma", nil},
    ])
    expect_raises(ArgumentError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk3,
        columns,
        substreams
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        columns
      )
    end

    mrk4 = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      columns,
      substreams
    )
    mrk4.roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq([
      {0_i32, "alpha", "shared"},
      {1_i32, "alpha", "payload"},
      {2_i32, "beta", "shared"},
      {3_i32, "gamma", "offsets"},
    ])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        columns,
        [
          {"alpha", ["shared", "shared"]},
          {"beta", ["shared"]},
          {"gamma", ["offsets"]},
        ] of {String, Array(String)}
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        columns,
        [
          {"alpha", [] of String},
          {"beta", ["shared"]},
          {"gamma", ["offsets"]},
        ] of {String, Array(String)}
      )
    end

    duplicate_columns = [
      {"alpha", "String"},
      {"alpha", "UInt64"},
    ] of {String, String}
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk3,
        duplicate_columns
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        duplicate_columns,
        [
          {"alpha", ["shared"]},
          {"alpha", ["payload"]},
        ] of {String, Array(String)}
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactColumnsSubstreams.new(
        CrystalClick::CompactMarkFormat::Mrk4,
        columns,
        [
          {"beta", ["shared"]},
          {"alpha", ["shared", "payload"]},
          {"gamma", ["offsets"]},
        ] of {String, Array(String)}
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPhysicalSlot.new(-1, "alpha", "shared")
    end

    # Both outer collections and their names are copied at this public seam.
    mutable_columns = [{"alpha", "String"}, {"beta", "String"}] of {String, String}
    mutable_streams = [{"alpha", ["shared"]}, {"beta", ["shared"]}] of {String, Array(String)}
    detached = CrystalClick::CompactColumnsSubstreams.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      mutable_columns,
      mutable_streams
    )
    mutable_columns[0] = {"changed", "UInt64"}
    mutable_streams[0][1][0] = "changed"
    detached.columns.should eq([{"alpha", "String"}, {"beta", "String"}])
    detached.roster.map(&.stream_name).should eq(["shared", "shared"])
  end

  it "guards public physical shard carriers and detaches caller-owned collections" do
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartPhysicalWindow.new(
        CrystalClick::CompactMarkFormat::Mrk3,
        "alpha",
        -1,
        0_u64,
        [] of CrystalClick::CompactPartPhysicalGranule
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartPhysicalGranule.new(
        -1,
        0_u64,
        1_u64,
        [] of CrystalClick::CompactPartPhysicalShard
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartPhysicalShard.new(-1, nil, 0_i64, 0_i64, Bytes.empty)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartPhysicalShard.new(0, nil, 2_i64, 1_i64, Bytes.empty)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, 1_i64, Bytes.empty)
    end

    source_bytes = "ab".to_slice.dup
    shard = CrystalClick::CompactPartPhysicalShard.new(2, "shared", 4_i64, 6_i64, source_bytes)
    granule = CrystalClick::CompactPartPhysicalGranule.new(1, 2_u64, 3_u64, [shard])
    window = CrystalClick::CompactPartPhysicalWindow.new(
      CrystalClick::CompactMarkFormat::Mrk4,
      "beta",
      1,
      2_u64,
      [granule]
    )
    source_bytes[0] = 'X'.ord.to_u8
    caller_granules = window.granules
    caller_granules.clear
    window.granules.size.should eq(1)
    window.granules.first.shards.first.bytes.should eq("ab".to_slice)
  end

  it "leaves a strictly-inside empty interval untouched and decodes overlapping ranges once" do
    root = File.tempname("crystal-click-w259-ranges")
    Dir.mkdir_p(root)
    begin
      raw = "0123456789".to_slice
      encoded = CrystalClick::CompressedMarkWriter.encode(
        raw,
        [0_u64, raw.size.to_u64],
        [1_u64],
        frame_bytes: raw.size
      )
      data_path = File.join(root, "data.bin")
      File.write(data_path, encoded.data)

      empty_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(
          max_records: 2,
          max_decoded_bytes: 0,
          max_result_bytes: 0
        )
      )
      empty = CrystalClick::CompressedMarkReader.read_ranges(
        data_path,
        encoded.data.size.to_i64,
        [{5_i64, 5_i64}],
        empty_budget
      )
      empty.size.should eq(1)
      empty.first.should be_empty
      empty_budget.decoded_byte_count.should eq(0_i64)
      empty_budget.result_byte_count.should eq(0_i64)

      nonempty_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 0)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read_ranges(
          data_path,
          encoded.data.size.to_i64,
          [{5_i64, 6_i64}],
          nonempty_budget
        )
      end
      nonempty_budget.decoded_byte_count.should eq(0_i64)

      overlap_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(
          max_records: 4,
          max_decoded_bytes: raw.size,
          max_result_bytes: 10
        )
      )
      overlapping = CrystalClick::CompressedMarkReader.read_ranges(
        data_path,
        encoded.data.size.to_i64,
        [{1_i64, 4_i64}, {2_i64, 6_i64}, {1_i64, 4_i64}],
        overlap_budget
      )
      overlapping.map { |bytes| String.new(bytes) }.should eq(["123", "2345", "123"])
      overlap_budget.decoded_byte_count.should eq(raw.size.to_i64)
      overlap_budget.result_byte_count.should eq(10_i64)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects an intra-column duplicate roster and a column-order mismatch without merging slots" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      duplicate = [
        {"alpha", ["shared", "payload", "shared"]},
        {"beta", ["shared"]},
        {"gamma", ["offsets"]},
      ] of {String, Array(String)}
      cpw259_replace(
        part,
        "columns_substreams.txt",
        CompactPhysicalContextW259Fixture.substreams_text(duplicate).to_slice
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      swapped = [
        {"beta", ["shared"]},
        {"alpha", ["shared", "payload"]},
        {"gamma", ["offsets"]},
      ] of {String, Array(String)}
      cpw259_replace(
        part,
        "columns_substreams.txt",
        CompactPhysicalContextW259Fixture.substreams_text(swapped).to_slice
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects truncated, count-mismatched, and nonterminal adaptive grids" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      mark_name = CompactPhysicalContextW259Fixture.mark_name(CrystalClick::CompactMarkFormat::Mrk3)
      marks = File.read(File.join(part, mark_name)).to_slice
      cpw259_replace(part, mark_name, marks[0, marks.size - 1])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      cpw259_replace(part, "count.txt", "9\n".to_slice)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      mode = CrystalClick::CompactMarkFormat::Mrk3
      name = CompactPhysicalContextW259Fixture.mark_name(mode)
      marks = File.read(File.join(part, name)).to_slice.dup
      width = CompactPhysicalContextW259Fixture.slots(mode).size * 16 + 8
      CompactPhysicalContextW259Fixture.write_u64(marks, 4 * width + width - 8, 1_u64)
      CompactPhysicalContextW259Fixture.rewrite_marks(part, mode, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects descending and nonzero-first logical coordinates and non-physical terminal aliases" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    name = CompactPhysicalContextW259Fixture.mark_name(mode)

    cpw259_with_part(mode) do |part|
      marks = File.read(File.join(part, name)).to_slice.dup
      # Slot 2 follows slot 1 in global physical order; move it back to slot 0.
      CompactPhysicalContextW259Fixture.copy_position(marks, mode, 0, 0, 0, 2)
      CompactPhysicalContextW259Fixture.rewrite_marks(part, mode, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(mode) do |part|
      marks = File.read(File.join(part, name)).to_slice.dup
      # Reuse a valid later frame coordinate, but make the first global slot nonzero.
      CompactPhysicalContextW259Fixture.copy_position(marks, mode, 0, 1, 0, 0)
      CompactPhysicalContextW259Fixture.rewrite_marks(part, mode, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(mode) do |part|
      data = File.read(File.join(part, "data.bin")).to_slice
      compressed_offset, decompressed_offset = CompactPhysicalContextW259Fixture.last_frame_end_position(data)
      marks = File.read(File.join(part, name)).to_slice.dup
      terminal_mark = CompactPhysicalContextW259Fixture::ROW_COUNTS.size
      CompactPhysicalContextW259Fixture.set_position(
        marks,
        mode,
        terminal_mark,
        0,
        compressed_offset,
        decompressed_offset
      )
      # The last-frame end aliases logical EOF, but Compact requires the
      # terminal tuple to use the physical data.bin EOF coordinate exactly.
      CompactPhysicalContextW259Fixture.rewrite_marks(part, mode, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects zero and out-of-domain real mark row counts" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    name = CompactPhysicalContextW259Fixture.mark_name(mode)
    width = CompactPhysicalContextW259Fixture.slots(mode).size * 16 + 8
    {0_u64, Int32::MAX.to_u64 + 1_u64}.each do |invalid_rows|
      cpw259_with_part(mode) do |part|
        marks = File.read(File.join(part, name)).to_slice.dup
        CompactPhysicalContextW259Fixture.write_u64(marks, width - 8, invalid_rows)
        CompactPhysicalContextW259Fixture.rewrite_marks(part, mode, marks)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompactPartPhysicalContext.open(part)
        end
      end
    end
  end

  it "refuses compressed mark payloads instead of parsing frame bytes as coordinates" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      compressed = CrystalClick::CompressedMarkWriter.encode(
        "m".to_slice,
        [0_u64, 1_u64],
        [1_u64],
        frame_bytes: 4
      )
      compressed.marks.size.should_not eq(0)
      CompactPhysicalContextW259Fixture.rewrite_marks(
        part,
        CrystalClick::CompactMarkFormat::Mrk3,
        compressed.data
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "authenticates selected payload frames and leaves untouched frames unauthenticated" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, 0)
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      expect_raises(CrystalClick::CorruptPartError) do
        context.read_window("alpha", 0, 1)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      # The later damaged frame does not overlap alpha's first two-byte shard.
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, 2)
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      first = context.read_window("alpha", 0, 1).granules.first.shards.first
      first.bytes.should eq("A0".to_slice)
    end
  end

  it "retains budget consumed by failed physical-window reads" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_result_bytes: 0)
      )
      context = CrystalClick::CompactPartPhysicalContext.open(part, budget)
      initial_records = budget.record_count
      initial_file_bytes = budget.file_byte_count

      2.times do
        expect_raises(CrystalClick::CorruptPartError) do
          context.read_window("alpha", 0, 1)
        end
        budget.record_count.should be > initial_records
        budget.file_byte_count.should be > initial_file_bytes
        budget.result_byte_count.should eq(0_i64)
        initial_records = budget.record_count
        initial_file_bytes = budget.file_byte_count
      end
    end
  end

  it "charges selected mrk4 slot descriptors for an empty EOF window before file work" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      budget = CrystalClick::CompressedStreamBudget.new
      context = CrystalClick::CompactPartPhysicalContext.open(part, budget)

      # The fixture declares two alpha slots. Leave one record available so
      # opening succeeds but the empty selected window cannot describe both.
      selected_slot_count = 2_i64
      remaining_records = budget.limits.max_records - budget.record_count
      remaining_records.should be >= selected_slot_count
      budget.reserve_records(remaining_records - 1_i64)
      budget.record_count.should eq(budget.limits.max_records - 1_i64)
      records_before = budget.record_count
      file_bytes_before = budget.file_byte_count

      error = expect_raises(CrystalClick::CorruptPartError) do
        context.read_window("alpha", context.granule_count, 0)
      end
      (error.message || "").should eq("compressed stream header-record limit exceeded")
      budget.record_count.should eq(records_before)
      budget.file_byte_count.should eq(file_bytes_before)
    end
  end

  it "rejects mixed or unsupported mark extensions rather than guessing a mode" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      File.copy(File.join(part, "data.mrk3"), File.join(part, "data.mrk4"))
      CompactPhysicalContextW259Fixture.refresh_checksums(part)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      File.rename(File.join(part, "data.mrk3"), File.join(part, "data.mrk2"))
      CompactPhysicalContextW259Fixture.refresh_checksums(part)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects unsafe or stale selected files before returning any physical window" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      checksum = File.join(part, "checksums.txt")
      File.delete(checksum)
      File.symlink(File.join(part, "columns.txt"), checksum)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      File.write(File.join(part, "columns.txt"), CompactPhysicalContextW259Fixture.columns_text + "\n")
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      data = File.join(part, "data.bin")
      target = File.tempname("crystal-click-w259-outside-data")
      begin
        File.copy(data, target)
        File.delete(data)
        File.symlink(target, data)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompactPartPhysicalContext.open(part).read_window("alpha", 0, 1)
        end
      ensure
        FileUtils.rm_rf(target)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      checksums = File.join(part, "checksums.txt")
      File.delete(checksums)
      Dir.mkdir(checksums)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      columns = File.join(part, "columns.txt")
      File.delete(columns)
      Dir.mkdir(columns)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects a nonregular direct compressed-range input before any stream read" do
    root = File.tempname("crystal-click-w259-nonregular-range")
    Dir.mkdir_p(root)
    begin
      data_path = File.join(root, "data-directory")
      Dir.mkdir(data_path)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read_ranges(
          data_path,
          64_i64,
          [{0_i64, 0_i64}],
          CrystalClick::CompressedStreamBudget.read_default
        )
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps one supplied budget consumptive across metadata failures and retries" do
    cpw259_with_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      checksum_size = File.size(File.join(part, "checksums.txt"))
      budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_file_bytes: checksum_size)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, budget)
      end
      consumed = budget.file_byte_count
      consumed.should eq(checksum_size)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, budget)
      end
      budget.file_byte_count.should eq(consumed)
    end
  end
end
