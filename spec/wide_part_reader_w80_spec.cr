require "./wide_part_w80_helpers"

private def w80_reader_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w80_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

describe CrystalClick::WidePart do
  it "reads exact Array(Map(String, UInt64)) rows and bounded ordered maps by mark" do
    with_w80_part do |_parent, part|
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Map(String, UInt64))")
      reader.row_count.should eq(5_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_array_map_string_uint64_mark_range("payload", 0, reader.mark_count)
        .should eq(W80_ROWS)
      reader.read_array_map_string_uint64_mark_range("payload", 1, 2)
        .should eq(W80_ROWS[2, 3])
      reader.read_array_map_string_uint64_mark_range("payload", 2, 1)
        .should eq([W80_ROWS[4]])

      reader.array_map_string_uint64_mark_range_materialization_preflight("payload", 0, 1)
        .should eq({payload_bytes: 22_u64, charge_bytes: 230_u64})
      reader.array_map_string_uint64_mark_range_materialization_preflight("payload", 1, 1)
        .should eq({payload_bytes: 19_u64, charge_bytes: 251_u64})
      reader.array_map_string_uint64_mark_range_materialization_preflight("payload", 2, 1)
        .should eq({payload_bytes: 0_u64, charge_bytes: 64_u64})
      reader.array_map_string_uint64_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq({payload_bytes: 41_u64, charge_bytes: 545_u64})

      expect_raises(CrystalClick::BoundsError) do
        reader.read_array_map_string_uint64_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.array_map_string_uint64_mark_range_materialization_preflight("payload", reader.mark_count, 1)
      end
    end
  end

  it "preflights corruption in a later selected mark before returning any rows" do
    with_w80_part do |parent, part|
      corrupted = File.join(parent, "corrupt-later-mark")
      FileUtils.cp_r(part, corrupted)
      marks_path = File.join(
        corrupted,
        "#{CrystalClick::StreamName.hash("payload%2Evalues")}.mrk2"
      )
      marks = File.read(marks_path).to_slice.dup
      later_mark_offset = CrystalClick::WidePart::MARK_SIZE + 8
      original = w80_reader_u64(marks, later_mark_offset)
      w80_reader_write_u64(marks, later_mark_offset, original + 8_u64)
      File.write(marks_path, marks)

      reader = CrystalClick::WidePart.open_typed(corrupted, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_map_string_uint64_mark_range("payload", 0, 2)
      end
    end
  end

  it "rejects unsupported Array(Map) serialization versions before opening streams" do
    with_w80_part do |parent, part|
      unsupported = File.join(parent, "unsupported-serialization")
      FileUtils.cp_r(part, unsupported)
      File.write(
        File.join(unsupported, "serialization.json"),
        %({"version":2,"columns":[],"types_serialization_versions":{"string":1},"propagate_types_serialization_versions_to_nested_types":true})
      )

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(unsupported, "payload")
      end
    end
  end

  it "rejects malformed Array(Map) serialization metadata" do
    with_w80_part do |parent, part|
      malformed = File.join(parent, "malformed-serialization")
      FileUtils.cp_r(part, malformed)
      File.write(File.join(malformed, "serialization.json"), "{not-json")

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(malformed, "payload")
      end
    end
  end

  it "pins Array(Map) to LZ4 with plain mrk2 marks" do
    with_w80_part do |parent, part|
      non_lz4 = File.join(parent, "non-lz4")
      FileUtils.cp_r(part, non_lz4)
      File.write(File.join(non_lz4, "default_compression_codec.txt"), "CODEC(ZSTD(1))")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(non_lz4, "payload")
      end

      compressed_marks = File.join(parent, "compressed-marks")
      FileUtils.cp_r(part, compressed_marks)
      mark_stem = CrystalClick::StreamName.hash("payload.size0")
      File.rename(
        File.join(compressed_marks, "#{mark_stem}.mrk2"),
        File.join(compressed_marks, "#{mark_stem}.cmrk2")
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(compressed_marks, "payload")
      end
    end
  end
end
