require "./spec_helper"
require "./support/compact_mark_file_adapter_w274_fixture"

private def w274_decoded_marks(part : String, mode : CrystalClick::CompactMarkFormat) : Bytes
  name = CompactMarkFileAdapterW274Fixture.compressed_mark_name(mode)
  CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, name)).to_slice)
end

private def w274_write_grid_and_refresh(
  part : String,
  mode : CrystalClick::CompactMarkFormat,
  bytes : Bytes,
) : Nil
  CompactMarkFileAdapterW274Fixture.write_compressed_marks!(part, mode, bytes)
end

private def w274_compressed_physical_size(part : String, mode : CrystalClick::CompactMarkFormat) : Int64
  File.size(File.join(part, CompactMarkFileAdapterW274Fixture.compressed_mark_name(mode)))
end

describe "W274 compressed Compact mark admission adversaries" do
  it "rejects mixed declared and filesystem mark layouts without choosing a precedence" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      CompactMarkFileAdapterW274Fixture.write_plain_sidecar!(part, "data.mrk3", raw)
      CompactMarkFileAdapterW274Fixture.refresh_checksums(part, "data.cmrk3", raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      # The extra MRK3 is intentionally absent from checksums.txt. Looking only
      # at declared entries would miss a conflicting filesystem sidecar.
      File.write(File.join(part, "data.mrk3"), Bytes[0_u8])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects undeclared extra sidecars and unknown compressed-mark suffixes" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      File.write(File.join(part, "data.cmrk4"), Bytes[0_u8])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      File.write(File.join(part, "data.cmrkBogus"), Bytes[0_u8])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      File.delete(File.join(part, "data.cmrk3"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      File.delete(File.join(part, "data.cmrk3"))
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk2", physical, raw)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects symlink and FIFO compressed sidecars before trying to read them" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      path = File.join(part, "data.cmrk3")
      target = File.join(part, "data.bin")
      File.delete(path)
      File.symlink(target, path)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      path = File.join(part, "data.cmrk4")
      File.delete(path)
      status = Process.run("mkfifo", [path])
      status.success?.should be_true
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "requires the checksums compression flag to agree with the physical mark suffix" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      CompactMarkFileAdapterW274Fixture.refresh_checksums(
        part,
        "data.cmrk3",
        raw,
        compressed_flag_override: false
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      File.delete(File.join(part, "data.cmrk3"))
      File.write(File.join(part, "data.mrk3"), physical)
      CompactMarkFileAdapterW274Fixture.refresh_checksums(part, "data.mrk3", raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "rejects declared uncompressed size or raw hash that differs from decoded marks" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(
        part,
        "data.cmrk3",
        physical,
        raw,
        raw_size_override: raw.size.to_u64 + 1_u64
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk4)
      physical = File.read(File.join(part, "data.cmrk4")).to_slice.dup
      expected_hash = CrystalClick::CityHashV1.file_hash(raw)
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(
        part,
        "data.cmrk4",
        physical,
        raw,
        raw_hash_override: {expected_hash[0] ^ 1_u64, expected_hash[1]}
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(
        part,
        "data.cmrk3",
        physical,
        raw,
        raw_size_override: raw.size.to_u64 - 1_u64
      )
      budget = CrystalClick::CompressedStreamBudget.read_default
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, budget)
      end
      budget.decoded_byte_count.should eq(0_i64)
      budget.result_byte_count.should eq(0_i64)
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      actual_hash = CrystalClick::CityHashV1.file_hash(physical)
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(
        part,
        "data.cmrk3",
        physical,
        raw,
        physical_hash_override: {actual_hash[0] ^ 1_u64, actual_hash[1]}
      )
      budget = CrystalClick::CompressedStreamBudget.read_default
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, budget)
      end
      budget.decoded_byte_count.should eq(0_i64)
      budget.result_byte_count.should eq(0_i64)
    end
  end

  it "authenticates the compressed mark frame and rejects truncated streams" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = File.read(File.join(part, "data.cmrk3")).to_slice.dup
      physical[0] ^= 1_u8
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk3", physical, raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk4)
      physical = File.read(File.join(part, "data.cmrk4")).to_slice
      truncated = physical[0, physical.size - 1].dup
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk4", truncated, raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      raw = w274_decoded_marks(part, CrystalClick::CompactMarkFormat::Mrk3)
      physical = CompactMarkFileAdapterW274Fixture.compressed_frames(raw, 13)
      offsets = CompactMarkFileAdapterW274Fixture.compressed_frame_offsets(physical)
      offsets.size.should be > 1
      physical[offsets.last] ^= 1_u8
      # Rebuilding checksums.txt records the changed physical hash; the only
      # broken authentication is the final compressed frame's own checksum.
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk3", physical, raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "validates decoded grid width, terminal EOF, and row-sum invariants" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      raw = w274_decoded_marks(part, mode)
      malformed = raw[0, raw.size - 1].dup
      w274_write_grid_and_refresh(part, mode, malformed)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      raw = w274_decoded_marks(part, mode)
      terminal_offset = CompactPhysicalContextW259Fixture::ROW_COUNTS.size *
                        CompactMarkFileAdapterW274Fixture.mark_width(mode)
      CompactMarkFileAdapterW274Fixture.write_u64(raw, terminal_offset, 0_u64)
      CompactMarkFileAdapterW274Fixture.write_u64(raw, terminal_offset + 8, 0_u64)
      w274_write_grid_and_refresh(part, mode, raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      raw = w274_decoded_marks(part, mode)
      first_row_count_offset = CompactMarkFileAdapterW274Fixture.mark_width(mode) - 8
      CompactMarkFileAdapterW274Fixture.write_u64(raw, first_row_count_offset, 3_u64)
      w274_write_grid_and_refresh(part, mode, raw)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part)
      end
    end
  end

  it "enforces decoded mark-size, decode, result, file, and record budgets" do
    mode = CrystalClick::CompactMarkFormat::Mrk3
    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      # A valid compact LZ4 run advertises 101 raw bytes in a 30-byte physical
      # sidecar. The configured mark cap is crossed by the declared decoded
      # size, before allocating or decoding the body.
      raw_run = Bytes.new(101, 0x41_u8)
      frame = w274_repeated_lz4_frame(raw_run.size)
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk3", frame, raw_run)
      budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_mark_bytes: 100)
      )
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, budget)
      end
      (error.message || "").should match(/mark.*limit/i)
      budget.decoded_byte_count.should eq(0_i64)
    end

    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      raw = w274_decoded_marks(part, mode)
      decoded_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: raw.size - 1)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, decoded_budget)
      end
      decoded_budget.decoded_byte_count.should eq(0_i64)

      result_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_result_bytes: raw.size - 1)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, result_budget)
      end
      result_budget.result_byte_count.should eq(0_i64)

      exact_file_bytes = [
        "checksums.txt", "columns.txt", "count.txt", "data.bin", "data.cmrk3",
      ].sum { |name| File.size(File.join(part, name)) }
      exact_file_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_file_bytes: exact_file_bytes)
      )
      CrystalClick::CompactPartPhysicalContext.open(part, exact_file_budget)
      exact_file_budget.file_byte_count.should eq(exact_file_bytes)

      below_file_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_file_bytes: exact_file_bytes - 1)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, below_file_budget)
      end

      over_record_budget = CrystalClick::CompressedStreamBudget.new(
        CrystalClick::CompressedStreamLimits.new(max_records: 0)
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompactPartPhysicalContext.open(part, over_record_budget)
      end
      over_record_budget.record_count.should eq(0_i64)
    end
  end

  it "applies direct read-all output caps before decode and result reservations" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      path = File.join(part, "data.bin")
      physical_size = File.size(path)
      expected = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)

      exact_budget = CrystalClick::CompressedStreamBudget.read_default
      actual = CrystalClick::CompressedMarkReader.read_all(
        path,
        physical_size,
        exact_budget,
        expected.size.to_i64
      )
      actual.should eq(expected)
      exact_budget.decoded_byte_count.should be > 0_i64
      exact_budget.result_byte_count.should eq(expected.size.to_i64)

      {expected.size.to_i64 - 1_i64, 0_i64}.each do |cap|
        budget = CrystalClick::CompressedStreamBudget.read_default
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompressedMarkReader.read_all(path, physical_size, budget, cap)
        end
        budget.decoded_byte_count.should eq(0_i64)
        budget.result_byte_count.should eq(0_i64)
      end

      negative_budget = CrystalClick::CompressedStreamBudget.read_default
      expect_raises(ArgumentError) do
        CrystalClick::CompressedMarkReader.read_all(path, physical_size, negative_budget, -1_i64)
      end
      negative_budget.file_byte_count.should eq(0_i64)
      negative_budget.decoded_byte_count.should eq(0_i64)
      negative_budget.result_byte_count.should eq(0_i64)
    end
  end

  it "keeps decode work consumptive across repeated failed opens" do
    mode = CrystalClick::CompactMarkFormat::Mrk4
    CompactMarkFileAdapterW274Fixture.with_isolated_part(mode) do |part|
      raw = w274_decoded_marks(part, mode)
      physical = File.read(File.join(part, "data.cmrk4")).to_slice.dup
      physical[0] ^= 1_u8
      CompactMarkFileAdapterW274Fixture.write_compressed_sidecar!(part, "data.cmrk4", physical, raw)
      budget = CrystalClick::CompressedStreamBudget.read_default

      2.times do
        records_before = budget.record_count
        files_before = budget.file_byte_count
        decoded_before = budget.decoded_byte_count
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompactPartPhysicalContext.open(part, budget)
        end
        budget.record_count.should be > records_before
        budget.file_byte_count.should be > files_before
        budget.decoded_byte_count.should be > decoded_before
      end
    end
  end
end

private def w274_repeated_lz4_frame(raw_size : Int) : Bytes
  raise ArgumentError.new("W274 repeated LZ4 control requires at least 20 bytes") if raw_size < 20
  match_size = raw_size - 1
  extra_match = match_size - 19
  payload = IO::Memory.new
  payload.write_byte(0x1f_u8) # one literal, then a match with extension bytes
  payload.write_byte(0x41_u8)
  payload.write_byte(1_u8)
  payload.write_byte(0_u8)
  while extra_match >= 255
    payload.write_byte(255_u8)
    extra_match -= 255
  end
  payload.write_byte(extra_match.to_u8)

  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w274_write_u32(frame, header + 1, compressed_size.to_u32)
  w274_write_u32(frame, header + 5, raw_size.to_u32)
  payload.to_slice.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  CompactMarkFileAdapterW274Fixture.write_u64(frame, 0, checksum[0])
  CompactMarkFileAdapterW274Fixture.write_u64(frame, 8, checksum[1])
  frame
end

private def w274_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (8 * index)) & 0xff_u32).to_u8 }
end
