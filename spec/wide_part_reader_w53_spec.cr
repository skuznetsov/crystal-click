require "./spec_helper"

W53_NULLABLE_MAP_FIXTURE              = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
W53_NULLABLE_MAP_BINARY_KEY           = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W53_NULLABLE_MAP_KEYS                 = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W53_MAP_UINT64_NULLABLE_UINT64_VALUES = [
  [] of Tuple(UInt64, UInt64?),
  [{7_u64, nil}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [{UInt64::MAX, 42_u64}, {0_u64, nil}] of Tuple(UInt64, UInt64?),
  [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [] of Tuple(UInt64, UInt64?),
  [{5_u64, nil}, {5_u64, UInt64::MAX}] of Tuple(UInt64, UInt64?),
  [{9_u64, 0_u64}] of Tuple(UInt64, UInt64?),
] of Array(Tuple(UInt64, UInt64?))
W53_MAP_STRING_NULLABLE_UINT64_VALUES = [
  [] of Tuple(String, UInt64?),
  [{"dup", nil}, {"dup", 0_u64}] of Tuple(String, UInt64?),
  [{W53_NULLABLE_MAP_BINARY_KEY, UInt64::MAX}, {"雪", nil}] of Tuple(String, UInt64?),
  [{"empty", 0_u64}, {"empty", nil}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"tail", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [{"end", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))

private def w53_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin"))
  CrystalClick::CompressedBlock.decode_all(encoded.to_slice).to_a
end

private def w53_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w53_raw_stream(path, stream)
  raise "W53 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w53_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w53_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w53_null_bytes(values : Array(Array(Tuple(K, UInt64?)))) : Array(UInt8) forall K
  values.flatten.map { |_key, value| value.nil? ? 1_u8 : 0_u8 }
end

private def w53_nullable_u64_values(values : Array(Array(Tuple(K, UInt64?)))) : Array(UInt64) forall K
  values.flatten.map { |_key, value| value || 0_u64 }
end

private def w53_string_key_sizes(values : Array(Array(Tuple(String, UInt64?)))) : Array(UInt64)
  values.flatten.map { |key, _value| key.bytesize.to_u64 }
end

private def w53_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w53_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w53_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w53_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w53_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W53 checksum fixture cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w53_write_u32(frame, header + 1, compressed_size.to_u32)
  w53_write_u32(frame, header + 5, raw.size.to_u32)
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

private def w53_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w53_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w53_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w53_write_varuint(payload, file_bytes.size.to_u64)
    w53_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w53_write_varuint(payload, raw.size.to_u64)
      w53_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w53_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w53_copy_fixture(parent : String, name : String) : String
  part = File.join(parent, name)
  FileUtils.cp_r(W53_NULLABLE_MAP_FIXTURE, part)
  part
end

describe "W53 Nullable-value Map reader" do
  it "admits only the exact top-level nullable-value Map declarations" do
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, Nullable(UInt64))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(String, Nullable(UInt64))").should be_true
    [
      "Map(UInt32, Nullable(UInt64))",
      "Map(UInt64, Nullable(UInt32))",
      "Map(Nullable(UInt64), UInt64)",
      "Nullable(Map(UInt64, Nullable(UInt64)))",
      "Map(UInt64, Map(String, Nullable(UInt64)))",
      "Map(UInt64, Nullable(String))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "decodes stock physical nullable streams and exact full and later mark ranges" do
    u64_reader = CrystalClick::WidePart.open_typed(W53_NULLABLE_MAP_FIXTURE, "map_u64")
    string_reader = CrystalClick::WidePart.open_typed(W53_NULLABLE_MAP_FIXTURE, "map_string")
    u64_reader.column_type.should eq("Map(UInt64, Nullable(UInt64))")
    string_reader.column_type.should eq("Map(String, Nullable(UInt64))")
    u64_reader.row_count.should eq(7_u64)
    string_reader.row_count.should eq(7_u64)
    u64_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    string_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])

    u64_flat = W53_MAP_UINT64_NULLABLE_UINT64_VALUES.flatten
    w53_raw_u64_stream(W53_NULLABLE_MAP_FIXTURE, "map_u64.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
    w53_raw_u64_stream(W53_NULLABLE_MAP_FIXTURE, "map_u64%2Ekeys").should eq(u64_flat.map(&.[0]))
    w53_raw_stream(W53_NULLABLE_MAP_FIXTURE, "map_u64%2Evalues.null").should eq(
      w53_null_bytes(W53_MAP_UINT64_NULLABLE_UINT64_VALUES)
    )
    w53_raw_stream(W53_NULLABLE_MAP_FIXTURE, "map_u64%2Evalues").should eq(
      w53_u64_bytes(w53_nullable_u64_values(W53_MAP_UINT64_NULLABLE_UINT64_VALUES))
    )

    string_flat = W53_MAP_STRING_NULLABLE_UINT64_VALUES.flatten
    w53_raw_u64_stream(W53_NULLABLE_MAP_FIXTURE, "map_string.size0").should eq([0_u64, 2_u64, 2_u64, 2_u64, 0_u64, 2_u64, 1_u64])
    w53_raw_u64_stream(W53_NULLABLE_MAP_FIXTURE, "map_string%2Ekeys.size").should eq(
      w53_string_key_sizes(W53_MAP_STRING_NULLABLE_UINT64_VALUES)
    )
    w53_raw_stream(W53_NULLABLE_MAP_FIXTURE, "map_string%2Ekeys").should eq(
      w53_string_bytes(string_flat.map(&.[0]))
    )
    w53_raw_stream(W53_NULLABLE_MAP_FIXTURE, "map_string%2Evalues.null").should eq(
      w53_null_bytes(W53_MAP_STRING_NULLABLE_UINT64_VALUES)
    )
    w53_raw_stream(W53_NULLABLE_MAP_FIXTURE, "map_string%2Evalues").should eq(
      w53_u64_bytes(w53_nullable_u64_values(W53_MAP_STRING_NULLABLE_UINT64_VALUES))
    )

    expected_mark_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
    [
      "pk", "map_u64.size0", "map_u64%2Ekeys", "map_u64%2Evalues.null", "map_u64%2Evalues",
      "map_string.size0", "map_string%2Ekeys.size", "map_string%2Ekeys",
      "map_string%2Evalues.null", "map_string%2Evalues",
    ].each do |stream|
      marks = File.read(File.join(W53_NULLABLE_MAP_FIXTURE, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
      marks.size.should eq(5 * CrystalClick::WidePart::MARK_SIZE)
      rows = Array(UInt64).new(5) do |index|
        offset = index * CrystalClick::WidePart::MARK_SIZE + 16
        value = 0_u64
        8.times { |byte| value |= marks[offset + byte].to_u64 << (byte * 8) }
        value
      end
      rows.should eq(expected_mark_rows)
    end

    u64_reader.read_map_uint64_nullable_uint64_mark_range("map_u64", 0, u64_reader.mark_count)
      .should eq(W53_MAP_UINT64_NULLABLE_UINT64_VALUES)
    string_reader.read_map_string_nullable_uint64_mark_range("map_string", 0, string_reader.mark_count)
      .should eq(W53_MAP_STRING_NULLABLE_UINT64_VALUES)
    u64_reader.read_map_uint64_nullable_uint64_mark_range("map_u64", 1, 2)
      .should eq(W53_MAP_UINT64_NULLABLE_UINT64_VALUES[2, 4])
    string_reader.read_map_string_nullable_uint64_mark_range("map_string", 1, 2)
      .should eq(W53_MAP_STRING_NULLABLE_UINT64_VALUES[2, 4])
    u64_reader.read_map_uint64_nullable_uint64_mark_range("map_u64", 3, 1)
      .should eq(W53_MAP_UINT64_NULLABLE_UINT64_VALUES[6, 1])
    string_reader.read_map_string_nullable_uint64_mark_range("map_string", 3, 1)
      .should eq(W53_MAP_STRING_NULLABLE_UINT64_VALUES[6, 1])
  end

  it "rejects a checksum-valid Nullable child mark whose row boundary is misaligned" do
    parent = File.tempname("crystal-click-w53-map-null-mark")
    Dir.mkdir(parent)
    begin
      part = w53_copy_fixture(parent, "misaligned-null-map")
      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("map_u64%2Evalues.null")}.mrk2")
      marks = File.read(mark_path).to_slice.dup
      # Make the second nullable child mark claim one row and the next claim
      # three, preserving the total part row count. Refreshing checksums
      # isolates the selected-mark alignment invariant from checksum rejection.
      w53_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
      w53_write_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
      File.write(mark_path, marks)
      w53_refresh_checksums(part)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "map_u64")
      end
      (error.message || "").should contain("selected substreams have different mark row counts")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-valid non-boolean Nullable Map value flag" do
    parent = File.tempname("crystal-click-w53-map-null-flag")
    Dir.mkdir(parent)
    begin
      part = w53_copy_fixture(parent, "invalid-null-flag")
      stream_name = "map_u64%2Evalues.null"
      raw = w53_raw_stream(part, stream_name)
      raw[0] = 2_u8
      path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.bin")
      File.write(path, w53_encode_lz4_frame(raw.to_unsafe.to_slice(raw.size)))
      w53_refresh_checksums(part)

      reader = CrystalClick::WidePart.open_typed(part, "map_u64")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_nullable_uint64_mark_range("map_u64", 0, 1)
      end
      (error.message || "").should contain("null-map byte is not boolean")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
