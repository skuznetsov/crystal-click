require "./spec_helper"

W54_READER_FIXTURE           = File.expand_path("../test/fixtures/public/wide_map_nullable_string_w54/part", __DIR__)
W54_READER_BINARY_KEY        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W54_READER_MAP_UINT64_VALUES = [
  [] of Tuple(UInt64, String?),
  [{7_u64, nil}, {7_u64, ""}] of Tuple(UInt64, String?),
  [{UInt64::MAX, ""}, {0_u64, nil}] of Tuple(UInt64, String?),
  [{1_u64, "x\0y"}] of Tuple(UInt64, String?),
  [] of Tuple(UInt64, String?),
  [{5_u64, nil}, {5_u64, "雪"}] of Tuple(UInt64, String?),
  [{9_u64, "end"}] of Tuple(UInt64, String?),
] of Array(Tuple(UInt64, String?))
W54_READER_MAP_STRING_VALUES = [
  [] of Tuple(String, String?),
  [{"dup", nil}, {"dup", ""}] of Tuple(String, String?),
  [{W54_READER_BINARY_KEY, ""}, {"雪", nil}] of Tuple(String, String?),
  [{"empty", ""}] of Tuple(String, String?),
  [] of Tuple(String, String?),
  [{"tail", nil}, {"", "🐈"}] of Tuple(String, String?),
  [{"end", "last"}] of Tuple(String, String?),
] of Array(Tuple(String, String?))

private def w54r_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w54r_raw_u64(part : String, stream : String) : Array(UInt64)
  bytes = w54r_raw_stream(part, stream)
  raise "W54 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w54r_string_bytes(values : Array(String)) : Array(UInt8)
  values.flat_map { |value| value.to_slice.to_a }
end

private def w54r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w54r_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w54r_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w54r_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w54r_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w54r_lz4_frame(raw : Bytes) : Bytes
  raise "W54 checksum fixture cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w54r_write_u32(frame, header + 1, compressed_size.to_u32)
  w54r_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  8.times { |byte| frame[byte] = ((checksum[0] >> (byte * 8)) & 0xff_u64).to_u8 }
  8.times { |byte| frame[8 + byte] = ((checksum[1] >> (byte * 8)) & 0xff_u64).to_u8 }
  frame
end

private def w54r_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w54r_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w54r_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w54r_write_varuint(payload, file_bytes.size.to_u64)
    w54r_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w54r_write_varuint(payload, raw.size.to_u64)
      w54r_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w54r_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w54r_shift_mark_decompressed_offset(part : String, stream : String, mark_index : Int, delta : Int64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  shifted = w54r_read_u64(marks, offset).to_i64 + delta
  raise "W54 mark mutation underflowed" if shifted < 0
  w54r_write_u64(marks, offset, shifted.to_u64)
  File.write(path, marks)
  w54r_refresh_checksums(part)
end

describe "W54 Nullable(String)-value Map reader" do
  it "admits only the exact UInt64- and String-key declarations" do
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, Nullable(String))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(String, Nullable(String))").should be_true
    [
      "Map(UInt32, Nullable(String))",
      "Map(UInt64, Nullable(FixedString(3)))",
      "Map(String, Nullable(FixedString(3)))",
      "Map(Nullable(UInt64), String)",
      "Nullable(Map(UInt64, Nullable(String)))",
      "Map(UInt64, Map(String, Nullable(String)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "decodes stock nullable String children, duplicates, binary data, and exact later ranges" do
    u64_reader = CrystalClick::WidePart.open_typed(W54_READER_FIXTURE, "map_u64")
    string_reader = CrystalClick::WidePart.open_typed(W54_READER_FIXTURE, "map_string")
    u64_reader.column_type.should eq("Map(UInt64, Nullable(String))")
    string_reader.column_type.should eq("Map(String, Nullable(String))")
    u64_reader.row_count.should eq(7_u64)
    string_reader.row_count.should eq(7_u64)
    u64_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    string_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])

    u64_flat = W54_READER_MAP_UINT64_VALUES.flatten
    w54r_raw_u64(W54_READER_FIXTURE, "map_u64.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
    w54r_raw_u64(W54_READER_FIXTURE, "map_u64%2Ekeys").should eq(u64_flat.map(&.[0]))
    w54r_raw_stream(W54_READER_FIXTURE, "map_u64%2Evalues.null").should eq(u64_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 })
    w54r_raw_u64(W54_READER_FIXTURE, "map_u64%2Evalues.size").should eq(
      u64_flat.map { |_key, value| value ? value.bytesize.to_u64 : 0_u64 }
    )
    w54r_raw_stream(W54_READER_FIXTURE, "map_u64%2Evalues").should eq(
      w54r_string_bytes(u64_flat.compact_map { |_key, value| value })
    )

    string_flat = W54_READER_MAP_STRING_VALUES.flatten
    w54r_raw_u64(W54_READER_FIXTURE, "map_string.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
    w54r_raw_u64(W54_READER_FIXTURE, "map_string%2Ekeys.size").should eq(string_flat.map { |key, _value| key.bytesize.to_u64 })
    w54r_raw_stream(W54_READER_FIXTURE, "map_string%2Ekeys").should eq(w54r_string_bytes(string_flat.map(&.[0])))
    w54r_raw_stream(W54_READER_FIXTURE, "map_string%2Evalues.null").should eq(string_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 })
    w54r_raw_u64(W54_READER_FIXTURE, "map_string%2Evalues.size").should eq(
      string_flat.map { |_key, value| value ? value.bytesize.to_u64 : 0_u64 }
    )
    w54r_raw_stream(W54_READER_FIXTURE, "map_string%2Evalues").should eq(
      w54r_string_bytes(string_flat.compact_map { |_key, value| value })
    )

    u64_reader.read_map_uint64_nullable_string_mark_range("map_u64", 0, 4).should eq(W54_READER_MAP_UINT64_VALUES)
    string_reader.read_map_string_nullable_string_mark_range("map_string", 0, 4).should eq(W54_READER_MAP_STRING_VALUES)
    u64_reader.read_map_uint64_nullable_string_mark_range("map_u64", 1, 2).should eq(W54_READER_MAP_UINT64_VALUES[2, 4])
    string_reader.read_map_string_nullable_string_mark_range("map_string", 1, 2).should eq(W54_READER_MAP_STRING_VALUES[2, 4])
    u64_reader.read_map_uint64_nullable_string_mark_range("map_u64", 3, 1).should eq(W54_READER_MAP_UINT64_VALUES[6, 1])
    string_reader.read_map_string_nullable_string_mark_range("map_string", 3, 1).should eq(W54_READER_MAP_STRING_VALUES[6, 1])
  end

  it "charges W54 size/null metadata, physical payload, and row/entry slots" do
    u64_reader = CrystalClick::WidePart.open_typed(W54_READER_FIXTURE, "map_u64")
    string_reader = CrystalClick::WidePart.open_typed(W54_READER_FIXTURE, "map_string")
    u64_reader.map_uint64_nullable_string_mark_range_materialization_preflight("map_u64", 0, 4).should eq({145_u64, 329_u64})
    string_reader.map_string_nullable_string_mark_range_materialization_preflight("map_string", 0, 4).should eq({169_u64, 353_u64})
  end

  it "rejects a checksum-valid non-boolean nullable String Map flag before returning values" do
    parent = File.tempname("crystal-click-w54-map-null-flag")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W54_READER_FIXTURE, part)
    begin
      stream_name = "map_u64%2Evalues.null"
      path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.bin")
      encoded = File.read(path).to_slice
      first = CrystalClick::CompressedBlock.decode_frame(
        encoded, 0, CrystalClick::WidePart::MAX_FRAME_COMPRESSED_BYTES.to_i64,
        CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_i64
      )
      raw = first.output.to_slice.dup
      raw[0] = 2_u8
      replacement = w54r_lz4_frame(raw)
      replacement.size.should eq(first.end_offset)
      rewritten = Bytes.new(encoded.size)
      replacement.copy_to(rewritten)
      encoded[first.end_offset.to_i, encoded.size - first.end_offset.to_i].copy_to(
        rewritten[replacement.size, rewritten.size - replacement.size]
      )
      File.write(path, rewritten)
      w54r_refresh_checksums(part)

      reader = CrystalClick::WidePart.open_typed(part, "map_u64")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_nullable_string_mark_range("map_u64", 0, 1)
      end
      (error.message || "").should contain("null-map byte is not boolean")

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "map_u64"])
      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 3) do |_batch|
          callback_count += 1
        end
      end
      callback_count.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects shifted nullable String value-size and raw-value mark boundaries before callbacks" do
    [
      {"map_u64%2Evalues.size", 1, -8_i64, 3},
      {"map_u64%2Evalues", 2, -1_i64, 3},
    ].each do |stream, boundary_mark, delta, batch_rows|
      parent = File.tempname("crystal-click-w54-map-mark-boundary")
      Dir.mkdir(parent)
      part = File.join(parent, "all_1_1_0")
      FileUtils.cp_r(W54_READER_FIXTURE, part)
      begin
        # Move only an aligned child boundary backward. The String size child
        # uses an 8-byte boundary after mark zero; the raw child has 3 bytes
        # through mark one. Later marks remain ordered, so the part opens.
        w54r_shift_mark_decompressed_offset(part, stream, boundary_mark, delta)
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "map_u64"])
        callback_rows = [] of Tuple(String, Int32, Array(UInt64))
        expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed(batch_rows: batch_rows) do |batch|
            callback_rows << {stream, batch.mark_index, batch.values_for("pk", UInt64).to_a}
          end
        end
        affected_mark = (boundary_mark - 1).to_i32
        expected_callbacks = if affected_mark == 0
                               [] of Tuple(String, Int32, Array(UInt64))
                             else
                               [{stream, 0_i32, [1_u64, 2_u64]}]
                             end
        callback_rows.should eq(expected_callbacks)
        affected_row_keys = affected_mark == 0 ? [1_u64, 2_u64] : [4_u64, 6_u64]
        callback_rows.flat_map(&.[2]).any? { |key| affected_row_keys.includes?(key) }.should be_false
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
