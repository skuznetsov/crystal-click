require "./spec_helper"

W38_NULLABLE_INTEGER_FIXTURE = File.expand_path("../test/fixtures/public/wide_nullable_integer256/part", __DIR__)
W38_KEYS                     = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64]

W38_ZERO_WORDS   = {0_u64, 0_u64, 0_u64, 0_u64}
W38_ONES_WORDS   = {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64}
W38_SIGNED_WORDS = [
  W38_ZERO_WORDS,
  W38_ONES_WORDS,
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xffffffffffffffd6_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0xc000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x55205cd751c67eeb_u64, 0xa31f165a9fea013a_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xaadfa328ae398115_u64, 0x5ce0e9a56015fec5_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  W38_ZERO_WORDS,
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
]
W38_UNSIGNED_WORDS = [
  W38_ZERO_WORDS,
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  W38_ONES_WORDS,
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  W38_ZERO_WORDS,
  {0xfffffffffffffffe_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x0000000000000002_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xfffffffffffffffd_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  W38_ZERO_WORDS,
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
]
W38_SIGNED_NULLS   = [true, false, false, false, false, false, false, false, false, false, false, true, false]
W38_UNSIGNED_NULLS = [true, false, false, false, true, false, false, false, false, false, false, true, false]

private def w38_signed_values : Array(CrystalClick::Int256Value?)
  Array(CrystalClick::Int256Value?).new(W38_SIGNED_WORDS.size) do |index|
    if W38_SIGNED_NULLS[index]
      nil
    else
      words = W38_SIGNED_WORDS[index]
      CrystalClick::Int256Value.from_words(words[0], words[1], words[2], words[3])
    end
  end
end

private def w38_unsigned_values : Array(CrystalClick::UInt256Value?)
  Array(CrystalClick::UInt256Value?).new(W38_UNSIGNED_WORDS.size) do |index|
    if W38_UNSIGNED_NULLS[index]
      nil
    else
      words = W38_UNSIGNED_WORDS[index]
      CrystalClick::UInt256Value.from_words(words[0], words[1], words[2], words[3])
    end
  end
end

private def w38_words_payload(words : Array({UInt64, UInt64, UInt64, UInt64}), nulls : Array(Bool)) : Array(UInt8)
  bytes = [] of UInt8
  words.each_with_index do |row, index|
    selected = nulls[index] ? W38_ZERO_WORDS : row
    {selected[0], selected[1], selected[2], selected[3]}.each do |word|
      8.times { |byte| bytes << ((word >> (byte * 8)) & 0xff_u64).to_u8 }
    end
  end
  bytes
end

private def w38_null_map(nulls : Array(Bool)) : Array(UInt8)
  nulls.map { |is_null| is_null ? 1_u8 : 0_u8 }
end

private def w38_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w38_decode_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w38_mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid W38 .mrk2 stream: #{logical_name}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w38_read_u64(bytes, offset), w38_read_u64(bytes, offset + 8), w38_read_u64(bytes, offset + 16)}
  end
end

private def w38_assert_stock_marks(part : String, logical_name : String, width : Int32) : Nil
  raw_offsets = [0_u64, 2_u64, 4_u64, 6_u64, 8_u64, 10_u64, 12_u64, 13_u64].map { |rows| rows * width.to_u64 }
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {0_u64, raw_offsets[index], row_counts[index]}
  end
  w38_mark_entries(part, logical_name).should eq(expected)
end

private def w38_frame_offsets(part : String, logical_name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < bytes.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(bytes, offset)
    raise "W38 writer frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "W38 writer stream has trailing bytes" unless offset == bytes.size.to_i64
  offsets
end

private def w38_assert_writer_marks(part : String, logical_name : String) : Nil
  offsets = w38_frame_offsets(part, logical_name)
  offsets.size.should eq(8)
  row_counts = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(8) do |index|
    {offsets[index], 0_u64, row_counts[index]}
  end
  w38_mark_entries(part, logical_name).should eq(expected)
end

private def w38_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w38_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w38_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w38_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w38_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W38 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w38_write_u32(frame, header + 1, compressed_size.to_u32)
  w38_write_u32(frame, header + 5, raw.size.to_u32)
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
  w38_write_u64(frame, 0, checksum[0])
  w38_write_u64(frame, 8, checksum[1])
  frame
end

private def w38_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w38_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w38_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w38_write_varuint(payload, file_bytes.size.to_u64)
    w38_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w38_write_varuint(payload, raw.size.to_u64)
      w38_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w38_encode_lz4_frame(payload.to_slice))
  end
end

private def w38_rewrite_stream_raw(part : String, logical_name : String, raw : Bytes) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  File.write(path, w38_encode_lz4_frame(raw))
  w38_refresh_checksums(part)
end

private def w38_rewrite_stream_byte(part : String, logical_name : String, offset : Int, value : UInt8) : Nil
  raw = w38_decode_stream(part, logical_name)
  raw[offset] = value
  w38_rewrite_stream_raw(part, logical_name, raw.to_unsafe.to_slice(raw.size))
end

private def w38_rewrite_mark_rows(part : String, logical_name : String, mark_index : Int, rows : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice.dup
  w38_write_u64(bytes, mark_index * CrystalClick::WidePart::MARK_SIZE + 16, rows)
  File.write(path, bytes)
  w38_refresh_checksums(part)
end

private def w38_set_serialization(part : String, json : String) : Nil
  File.write(File.join(part, "serialization.json"), json)
  w38_refresh_checksums(part)
end

private def w38_default_serializer(name : String) : String
  %({"kind":"Default","name":"#{name}","num_defaults":0,"num_rows":13})
end

private def w38_set_serializers(part : String, records : Array(String)) : Nil
  path = File.join(part, "serialization.json")
  original = File.read(path)
  updated = original.sub(%("columns":[]), %("columns":[#{records.join(",")}]))
  raise "W38 fixture did not have an empty serializer list" if updated == original
  w38_set_serialization(part, updated)
end

describe CrystalClick::WidePart do
  it "admits only the exact BASIC Nullable raw 256-bit scalar types" do
    CrystalClick::WidePart.supports_typed_type?("Nullable(Int256)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(UInt256)").should be_true
    CrystalClick::WidePart.catalog_type("Nullable(Int256)").should eq("Nullable(Int256)")
    CrystalClick::WidePart.catalog_type("Nullable(UInt256)").should eq("Nullable(UInt256)")

    CrystalClick::WidePart.supports_numeric_type?("Int256").should be_false
    CrystalClick::WidePart.supports_numeric_type?("UInt256").should be_false
    CrystalClick::WidePart.supports_nullable_numeric_type?("Nullable(Int256)").should be_false
    CrystalClick::WidePart.supports_nullable_numeric_type?("Nullable(UInt256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Int256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(UInt256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Int256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(UInt256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(Int256))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(UInt256))").should be_false
    CrystalClick::WidePart.catalog_type("Array(Nullable(Int256))").should be_nil
    CrystalClick::WidePart.catalog_type("Array(Nullable(UInt256))").should be_nil
  end

  it "reads stock BASIC Nullable raw 256-bit streams exactly across marks and the final sentinel" do
    File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "columns.txt")).should eq(
      "columns format version: 1\n3 columns:\n`pk` UInt64\n`i` Nullable(Int256)\n`u` Nullable(UInt256)\n"
    )
    File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `i`:\n\ti.null\n\ti\n2 substreams for column `u`:\n\tu.null\n\tu\n"
    )
    File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "serialization.json")).should eq(
      %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    )
    File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "count.txt")).should eq("13")
    File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "default_compression_codec.txt")).should eq("CODEC(LZ4)")

    expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json"]
    {"pk", "i.null", "i", "u.null", "u"}.each do |name|
      expected_files << "#{CrystalClick::StreamName.hash(name)}.bin"
      expected_files << "#{CrystalClick::StreamName.hash(name)}.mrk2"
    end
    Dir.children(W38_NULLABLE_INTEGER_FIXTURE).sort.should eq(expected_files.sort)

    signed = CrystalClick::WidePart.open_typed(W38_NULLABLE_INTEGER_FIXTURE, "i")
    unsigned = CrystalClick::WidePart.open_typed(W38_NULLABLE_INTEGER_FIXTURE, "u")
    signed.column_type.should eq("Nullable(Int256)")
    unsigned.column_type.should eq("Nullable(UInt256)")
    signed.row_count.should eq(13_u64)
    unsigned.row_count.should eq(13_u64)
    signed.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    unsigned.mark_row_counts.should eq(signed.mark_row_counts)
    signed.read_nullable_int256_raw_mark_range("i", 0, signed.mark_count).should eq(w38_signed_values)
    unsigned.read_nullable_uint256_raw_mark_range("u", 0, unsigned.mark_count).should eq(w38_unsigned_values)
    signed.read_nullable_int256_raw_mark_range("i", 2, 3).should eq(w38_signed_values[4, 6])
    unsigned.read_nullable_uint256_raw_mark_range("u", 2, 3).should eq(w38_unsigned_values[4, 6])
    signed.read_nullable_int256_raw_mark_range("i", 6, 1).should eq(w38_signed_values[12, 1])
    unsigned.read_nullable_uint256_raw_mark_range("u", 6, 1).should eq(w38_unsigned_values[12, 1])

    w38_decode_stream(W38_NULLABLE_INTEGER_FIXTURE, "i.null").should eq(w38_null_map(W38_SIGNED_NULLS))
    w38_decode_stream(W38_NULLABLE_INTEGER_FIXTURE, "u.null").should eq(w38_null_map(W38_UNSIGNED_NULLS))
    w38_decode_stream(W38_NULLABLE_INTEGER_FIXTURE, "i").should eq(w38_words_payload(W38_SIGNED_WORDS, W38_SIGNED_NULLS))
    w38_decode_stream(W38_NULLABLE_INTEGER_FIXTURE, "u").should eq(w38_words_payload(W38_UNSIGNED_WORDS, W38_UNSIGNED_NULLS))
    { {"pk", 8}, {"i.null", 1}, {"i", 32}, {"u.null", 1}, {"u", 32} }.each do |name, width|
      w38_assert_stock_marks(W38_NULLABLE_INTEGER_FIXTURE, name, width)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_uint256_raw_mark_range("i", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_int256_raw_mark_range("u", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_numeric_mark_range("i", 0, 1, CrystalClick::Int256Value) }
    expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_numeric_mark_range("u", 0, 1, CrystalClick::UInt256Value) }
    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_decimal256_raw_mark_range("i", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_decimal256_raw_mark_range("u", 0, 1) }
  end

  it "allows stock BASIC serialization metadata but rejects malformed explicit Nullable versions" do
    # The stock BASIC part deliberately has no explicit nullable serializer version.
    CrystalClick::WidePart.open_typed(W38_NULLABLE_INTEGER_FIXTURE, "i").column_type.should eq("Nullable(Int256)")

    parent = File.tempname("crystal-click-w38-nullable-version")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    begin
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, part)
      original = File.read(File.join(part, "serialization.json"))
      malformed = original.sub(%("string":1), %("nullable":null,"string":1))
      malformed.should_not eq(original)
      w38_set_serialization(part, malformed)
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(part, "i") }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsupported Nullable and nested type serializer versions before reading values" do
    parent = File.tempname("crystal-click-w38-serialization-guards")
    Dir.mkdir(parent)
    original = File.read(File.join(W38_NULLABLE_INTEGER_FIXTURE, "serialization.json"))
    replacements = {
      "nullable-v1"          => original.sub(%("string":1), %("nullable":1,"string":1)),
      "string-v2"            => original.sub(%("string":1), %("string":2)),
      "missing-string"       => original.sub(%("types_serialization_versions":{"string":1}), %("types_serialization_versions":{})),
      "unknown-type-version" => original.sub(%("string":1), %("string":1,"opaque":1)),
      "missing-columns"      => original.sub(%("version":1), %("missing_columns":[],"version":1)),
    }
    begin
      replacements.each do |case_name, malformed|
        malformed.should_not eq(original)
        part = File.join(parent, case_name)
        FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, part)
        w38_set_serialization(part, malformed)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part, "i")
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "matches complete Default serializer records by declared name, not array position" do
    parent = File.tempname("crystal-click-w38-serializer-names")
    Dir.mkdir(parent)
    begin
      reordered = File.join(parent, "reordered")
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, reordered)
      w38_set_serializers(reordered, [w38_default_serializer("u"), w38_default_serializer("pk"), w38_default_serializer("i")])
      CrystalClick::WidePart.open_typed(reordered, "i").read_nullable_int256_raw_mark_range("i", 0, 7).should eq(w38_signed_values)
      CrystalClick::WidePart.open_typed(reordered, "u").read_nullable_uint256_raw_mark_range("u", 0, 7).should eq(w38_unsigned_values)

      {
        "duplicate" => [w38_default_serializer("u"), w38_default_serializer("pk"), w38_default_serializer("pk")],
        "missing"   => [w38_default_serializer("u"), w38_default_serializer("pk")],
      }.each do |case_name, records|
        malformed = File.join(parent, case_name)
        FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, malformed)
        w38_set_serializers(malformed, records)
        expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(malformed, "i") }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects stock Sparse Nullable256 serialization instead of interpreting its index as a null map" do
    sparse = File.expand_path("../test/fixtures/public/wide_nullable_integer256/sparse/part", __DIR__)
    File.read(File.join(sparse, "serialization.json")).should contain(%("nullable":1))
    File.read(File.join(sparse, "serialization.json")).should contain(%("kind":"Sparse"))
    File.read(File.join(sparse, "columns_substreams.txt")).should contain("i.sparse.idx")
    File.read(File.join(sparse, "columns_substreams.txt")).should contain("u.sparse.idx")
    File.exists?(File.join(sparse, "#{CrystalClick::StreamName.hash("i.sparse.idx")}.bin")).should be_true
    File.exists?(File.join(sparse, "#{CrystalClick::StreamName.hash("u.sparse.idx")}.bin")).should be_true
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(sparse, "i") }
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(sparse, "u") }
  end

  it "rejects Decimal256 from Nullable raw Int256 and UInt256 accessors in both directions" do
    parent = File.tempname("crystal-click-w38-decimal-boundary")
    Dir.mkdir(parent)
    decimal_part = File.join(parent, "decimal")
    keys = [1_u64, 2_u64, 3_u64]
    decimal_values = [nil.as(CrystalClick::Decimal256Value?), CrystalClick::Decimal256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64).as(CrystalClick::Decimal256Value?), CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX).as(CrystalClick::Decimal256Value?)]
    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(
        decimal_part, "pk", keys.to_unsafe.to_slice(3), "amount", decimal_values.to_unsafe.to_slice(3), 0
      )
      decimal = CrystalClick::WidePart.open_typed(decimal_part, "amount")
      decimal.column_type.should eq("Nullable(Decimal(76, 0))")
      expect_raises(CrystalClick::UnsupportedFormatError) { decimal.read_nullable_int256_raw_mark_range("amount", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { decimal.read_nullable_uint256_raw_mark_range("amount", 0, 1) }

      signed = CrystalClick::WidePart.open_typed(W38_NULLABLE_INTEGER_FIXTURE, "i")
      unsigned = CrystalClick::WidePart.open_typed(W38_NULLABLE_INTEGER_FIXTURE, "u")
      expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_decimal256_raw_mark_range("i", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_decimal256_raw_mark_range("u", 0, 1) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartTable do
  it "materializes distinct Nullable256 raw arrays in aligned batches and later-mark row windows" do
    parent = File.tempname("crystal-click-w38-table")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "i", "u"])
      observed = [] of {UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int256_raw_for("i")
        unsigned = batch.nullable_uint256_raw_for("u")
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_uint256_raw_for("i") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_int256_raw_for("u") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("i", CrystalClick::Int256Value) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("u", CrystalClick::UInt256Value) }
        keys.each_index { |index| observed << {keys[index], signed[index], unsigned[index]} }
      end
      observed.should eq(Array({UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}).new(13) do |index|
        {W38_KEYS[index], w38_signed_values[index], w38_unsigned_values[index]}
      end)

      window = [] of {UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}
      table.scan_typed_window(5_u64, max_rows: 6) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int256_raw_for("i")
        unsigned = batch.nullable_uint256_raw_for("u")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      expected_window = Array({UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}).new(6) do |index|
        row = index + 5
        {W38_KEYS[row], w38_signed_values[row], w38_unsigned_values[row]}
      end
      window.should eq(expected_window)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid null flags, absent paired marks, and shifted child marks before callback" do
    parent = File.tempname("crystal-click-w38-table-corruption")
    Dir.mkdir(parent)
    begin
      invalid_flag = File.join(parent, "invalid-flag", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(invalid_flag))
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, invalid_flag)
      w38_rewrite_stream_byte(invalid_flag, "i.null", 0, 2_u8)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([invalid_flag], ["pk", "i", "u"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      missing_mark = File.join(parent, "missing-mark", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(missing_mark))
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, missing_mark)
      File.delete(File.join(missing_mark, "#{CrystalClick::StreamName.hash("i.null")}.mrk2"))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([missing_mark], ["pk", "i", "u"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      shifted_mark = File.join(parent, "shifted-mark", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(shifted_mark))
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, shifted_mark)
      w38_rewrite_mark_rows(shifted_mark, "i", 0, 1_u64)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([shifted_mark], ["pk", "i", "u"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a short nested 32-byte stream before exposing any candidate batch" do
    parent = File.tempname("crystal-click-w38-short-payload")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, part)
      raw = w38_decode_stream(part, "i")
      raw.size.should eq(13 * 32)
      short_raw = raw[0, raw.size - 1]
      w38_rewrite_stream_raw(part, "i", short_raw.to_unsafe.to_slice(short_raw.size))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "i", "u"])
        table.scan_typed_candidate_marks([[6]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact BASIC Nullable Int256 and UInt256 parts with independent raw-stream and mark oracles" do
    parent = File.tempname("crystal-click-w38-writers")
    Dir.mkdir(parent)
    signed_part = File.join(parent, "signed")
    unsigned_part = File.join(parent, "unsigned")
    signed_values = w38_signed_values
    unsigned_values = w38_unsigned_values
    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_int256_pair(
        signed_part, "pk", W38_KEYS.to_unsafe.to_slice(13), "payload", signed_values.to_unsafe.to_slice(13), 2
      ).should eq(signed_part)
      CrystalClick::WidePartWriter.write_uint64_nullable_uint256_pair(
        unsigned_part, "pk", W38_KEYS.to_unsafe.to_slice(13), "payload", unsigned_values.to_unsafe.to_slice(13), 2
      ).should eq(unsigned_part)

      [
        {signed_part, "Nullable(Int256)", W38_SIGNED_NULLS, W38_SIGNED_WORDS, true},
        {unsigned_part, "Nullable(UInt256)", W38_UNSIGNED_NULLS, W38_UNSIGNED_WORDS, false},
      ].each do |part, type, nulls, words, signed|
        File.read(File.join(part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type}\n")
        File.read(File.join(part, "columns_substreams.txt")).should eq("columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n")
        File.read(File.join(part, "serialization.json")).should eq(%({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
        File.read(File.join(part, "count.txt")).should eq("13")
        File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        w38_decode_stream(part, "payload.null").should eq(w38_null_map(nulls))
        w38_decode_stream(part, "payload").should eq(w38_words_payload(words, nulls))
        {"pk", "payload.null", "payload"}.each do |name|
          w38_assert_writer_marks(part, name)
        end
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        if signed
          reader.read_nullable_int256_raw_mark_range("payload", 0, 7).should eq(signed_values)
        else
          reader.read_nullable_uint256_raw_mark_range("payload", 0, 7).should eq(unsigned_values)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects inferred nullable 256-bit writers and invalid explicit inputs without publication" do
    parent = File.tempname("crystal-click-w38-writer-preflight")
    Dir.mkdir(parent)
    signed_values = w38_signed_values
    unsigned_values = w38_unsigned_values
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-int256"), "pk", W38_KEYS.to_unsafe.to_slice(13), "payload", signed_values.to_unsafe.to_slice(13), 2
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-uint256"), "pk", W38_KEYS.to_unsafe.to_slice(13), "payload", unsigned_values.to_unsafe.to_slice(13), 2
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_int256_pair(
          File.join(parent, "mismatched"), "pk", W38_KEYS.to_unsafe.to_slice(13), "payload", signed_values.to_unsafe.to_slice(12), 2
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_uint256_pair(
          File.join(parent, "unsorted"), "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "payload", [nil.as(CrystalClick::UInt256Value?), CrystalClick::UInt256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64).as(CrystalClick::UInt256Value?)].to_unsafe.to_slice(2), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "returns owned nullable raw 256-bit catalog values and scans a bounded window" do
    root = File.tempname("crystal-click-w38-offline-catalog")
    database_uuid = "38380000-0000-4000-8000-000000000001"
    table_uuid = "38380000-0000-4000-8000-000000000002"
    metadata_path = File.join(root, "metadata")
    database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
    table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
    part_path = File.join(table_path, "all_1_1_0")
    FileUtils.mkdir_p(metadata_path)
    FileUtils.mkdir_p(database_path)
    File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(database_path, "events.sql"), <<-DDL)
    ATTACH TABLE _ UUID '#{table_uuid}'
    (
        `pk` UInt64,
        `i` Nullable(Int256),
        `u` Nullable(UInt256)
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W38_NULLABLE_INTEGER_FIXTURE, part_path)

    begin
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"i", "Nullable(Int256)"},
        {"u", "Nullable(UInt256)"},
      ])
      signed_selection = table["i"]
      unsigned_selection = table["u"]
      signed_selection.values.map(&.as(CrystalClick::Int256Value?)).should eq(w38_signed_values)
      unsigned_selection.values.map(&.as(CrystalClick::UInt256Value?)).should eq(w38_unsigned_values)
      expect_raises(CrystalClick::BoundsError) { signed_selection.values(max_rows: 12_u64) }

      owned_signed = signed_selection.values
      owned_unsigned = unsigned_selection.values
      owned_signed[0] = CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64).as(CrystalClick::Int256Value?)
      owned_unsigned[0] = CrystalClick::UInt256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX).as(CrystalClick::UInt256Value?)
      signed_selection.values.map(&.as(CrystalClick::Int256Value?)).should eq(w38_signed_values)
      unsigned_selection.values.map(&.as(CrystalClick::UInt256Value?)).should eq(w38_unsigned_values)

      window = [] of {UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}
      table.scan_typed_window(["pk", "i", "u"], 5_u64, max_rows: 6) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int256_raw_for("i")
        unsigned = batch.nullable_uint256_raw_for("u")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      window.should eq(Array({UInt64, CrystalClick::Int256Value?, CrystalClick::UInt256Value?}).new(6) do |index|
        row = index + 5
        {W38_KEYS[row], w38_signed_values[row], w38_unsigned_values[row]}
      end)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
