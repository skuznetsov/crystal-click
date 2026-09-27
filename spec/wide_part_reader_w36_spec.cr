require "./spec_helper"

W36_NULLABLE_INTEGER_PART = File.expand_path("../test/fixtures/public/wide_nullable_integer128/part", __DIR__)
W36_SPARSE_INTEGER_PART   = File.expand_path("../test/fixtures/public/wide_nullable_integer128/sparse/part", __DIR__)
W36_KEYS                  = Array(UInt64).new(32) { |index| index.to_u64 + 1_u64 }
W36_SIGNED_VALUES         = [
  nil.as(Int128?), -9_223_372_036_854_775_809_i128, -18_446_744_073_709_551_617_i128, nil.as(Int128?),
  Int128::MIN, Int128::MAX, -1_i128, 0_i128, nil.as(Int128?), 18_446_744_073_709_551_616_i128,
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128, 0_i128, nil.as(Int128?), 1_i128, Int128::MAX,
  nil.as(Int128?), -1_267_650_600_228_229_401_496_703_205_376_i128,
  1_267_650_600_228_229_401_496_703_205_376_i128, 42_i128, nil.as(Int128?), -1_i128, 0_i128,
  18_446_744_073_709_551_615_i128, Int128::MIN, nil.as(Int128?),
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  1_329_227_995_784_915_872_903_807_060_280_344_576_i128, nil.as(Int128?),
  -12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128, nil.as(Int128?),
] of Int128?
W36_UNSIGNED_VALUES = [
  nil.as(UInt128?), 1_u128, UInt64::MAX.to_u128, nil.as(UInt128?), UInt128::MAX,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128, 18_446_744_073_709_551_616_u128,
  0_u128, nil.as(UInt128?), 18_446_744_073_709_551_617_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128, 0_u128, nil.as(UInt128?), 42_u128,
  UInt128::MAX, nil.as(UInt128?), 1_267_650_600_228_229_401_496_703_205_376_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128, 1_u128, nil.as(UInt128?),
  18_446_744_073_709_551_616_u128, 0_u128, UInt128::MAX,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128,
  1_267_650_600_228_229_401_496_703_205_377_u128, 0_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128, nil.as(UInt128?),
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128, 0_u128, nil.as(UInt128?),
] of UInt128?

private def w36_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w36_decode_stream(part : String, name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w36_int128_payload(values : Array(Int128?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = (value || 0_i128).unsafe_as(UInt128)
    16.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u128).to_u8 }
  end
  bytes
end

private def w36_uint128_payload(values : Array(UInt128?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    nested = value || 0_u128
    16.times { |index| bytes << ((nested >> (index * 8)) & 0xff_u128).to_u8 }
  end
  bytes
end

private def w36_mark_entries(part : String, name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.mrk2")).to_slice
  raise "invalid W36 .mrk2 stream: #{name}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w36_read_u64(bytes, offset), w36_read_u64(bytes, offset + 8), w36_read_u64(bytes, offset + 16)}
  end
end

private def w36_assert_stock_marks(name : String, width : Int32) : Nil
  rows = [0_u64, 4_u64, 8_u64, 12_u64, 16_u64, 20_u64, 24_u64, 28_u64, 32_u64]
  counts = [4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(rows.size) do |index|
    {0_u64, rows[index] * width.to_u64, counts[index]}
  end
  w36_mark_entries(W36_NULLABLE_INTEGER_PART, name).should eq(expected)
end

private def w36_frame_offsets(part : String, name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < bytes.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(bytes, offset)
    raise "W36 writer frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "W36 writer stream has trailing bytes" unless offset == bytes.size.to_i64
  offsets
end

private def w36_assert_writer_marks(part : String, name : String) : Nil
  offsets = w36_frame_offsets(part, name)
  offsets.size.should eq(9)
  counts = [4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 4_u64, 0_u64]
  expected = Array({UInt64, UInt64, UInt64}).new(9) do |index|
    {offsets[index], 0_u64, counts[index]}
  end
  w36_mark_entries(part, name).should eq(expected)
end

private def w36_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w36_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w36_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w36_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w36_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W36 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w36_write_u32(frame, header + 1, compressed_size.to_u32)
  w36_write_u32(frame, header + 5, raw.size.to_u32)
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
  w36_write_u64(frame, 0, checksum[0])
  w36_write_u64(frame, 8, checksum[1])
  frame
end

private def w36_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w36_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w36_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w36_write_varuint(payload, file_bytes.size.to_u64)
    w36_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w36_write_varuint(payload, raw.size.to_u64)
      w36_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(w36_encode_lz4_frame(payload.to_slice))
  end
end

private def w36_rewrite_stream_byte(part : String, name : String, offset : Int, value : UInt8) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).dup
  raw[offset] = value
  File.write(path, w36_encode_lz4_frame(raw.to_slice))
  w36_refresh_checksums(part)
end

private def w36_default_serializer(name : String) : String
  %({"kind":"Default","name":"#{name}","num_defaults":0,"num_rows":32})
end

private def w36_set_explicit_nullable_basic_version(part : String) : Nil
  path = File.join(part, "serialization.json")
  original = File.read(path)
  updated = original.sub(%("types_serialization_versions":{"string":1}), %("types_serialization_versions":{"nullable":0,"string":1}))
  raise "W36 fixture did not have the stock String version record" if updated == original
  File.write(path, updated)
  w36_refresh_checksums(part)
end

private def w36_set_serializers(part : String, records : Array(String)) : Nil
  path = File.join(part, "serialization.json")
  original = File.read(path)
  updated = original.sub(%("columns":[]), %("columns":[#{records.join(",")}]))
  raise "W36 fixture did not have an empty serializer list" if updated == original
  File.write(path, updated)
  w36_refresh_checksums(part)
end

describe CrystalClick::WidePart do
  it "admits exact nullable raw 128-bit scalar types without widening generic or recursive gates" do
    CrystalClick::WidePart.supports_typed_type?("Nullable(Int128)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(UInt128)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(Decimal(38, 0))").should be_true
    CrystalClick::WidePart.supports_numeric_type?("Int128").should be_false
    CrystalClick::WidePart.supports_numeric_type?("UInt128").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(Int128))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(UInt128))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(Int128))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(Int256)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nullable(UInt256)").should be_false
  end

  it "reads stock BASIC nullable raw 128-bit streams exactly across marks and the final sentinel" do
    File.read(File.join(W36_NULLABLE_INTEGER_PART, "columns.txt")).should eq(
      "columns format version: 1\n3 columns:\n`pk` UInt64\n`signed` Nullable(Int128)\n`unsigned` Nullable(UInt128)\n"
    )
    File.read(File.join(W36_NULLABLE_INTEGER_PART, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `signed`:\n\tsigned.null\n\tsigned\n2 substreams for column `unsigned`:\n\tunsigned.null\n\tunsigned\n"
    )
    File.read(File.join(W36_NULLABLE_INTEGER_PART, "serialization.json")).should eq(
      %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    )
    File.read(File.join(W36_NULLABLE_INTEGER_PART, "count.txt")).should eq("32")
    File.read(File.join(W36_NULLABLE_INTEGER_PART, "default_compression_codec.txt")).should eq("CODEC(LZ4)")

    expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json"]
    {"pk", "signed.null", "signed", "unsigned.null", "unsigned"}.each do |name|
      expected_files << "#{CrystalClick::StreamName.hash(name)}.bin"
      expected_files << "#{CrystalClick::StreamName.hash(name)}.mrk2"
    end
    Dir.children(W36_NULLABLE_INTEGER_PART).sort.should eq(expected_files.sort)

    signed = CrystalClick::WidePart.open_typed(W36_NULLABLE_INTEGER_PART, "signed")
    unsigned = CrystalClick::WidePart.open_typed(W36_NULLABLE_INTEGER_PART, "unsigned")
    signed.column_type.should eq("Nullable(Int128)")
    unsigned.column_type.should eq("Nullable(UInt128)")
    signed.row_count.should eq(32_u64)
    unsigned.row_count.should eq(32_u64)
    signed.mark_row_counts.should eq(Array(UInt64).new(8, 4_u64))
    unsigned.mark_row_counts.should eq(signed.mark_row_counts)
    signed.read_nullable_int128_raw_mark_range("signed", 0, signed.mark_count).should eq(W36_SIGNED_VALUES)
    unsigned.read_nullable_uint128_raw_mark_range("unsigned", 0, unsigned.mark_count).should eq(W36_UNSIGNED_VALUES)
    signed.read_nullable_int128_raw_mark_range("signed", 1, 2).should eq(W36_SIGNED_VALUES[4, 8])
    unsigned.read_nullable_uint128_raw_mark_range("unsigned", 1, 2).should eq(W36_UNSIGNED_VALUES[4, 8])
    signed.read_nullable_int128_raw_mark_range("signed", 7, 1).should eq(W36_SIGNED_VALUES[28, 4])
    unsigned.read_nullable_uint128_raw_mark_range("unsigned", 7, 1).should eq(W36_UNSIGNED_VALUES[28, 4])

    w36_decode_stream(W36_NULLABLE_INTEGER_PART, "signed.null").should eq(W36_SIGNED_VALUES.map { |value| value.nil? ? 1_u8 : 0_u8 })
    w36_decode_stream(W36_NULLABLE_INTEGER_PART, "unsigned.null").should eq(W36_UNSIGNED_VALUES.map { |value| value.nil? ? 1_u8 : 0_u8 })
    w36_decode_stream(W36_NULLABLE_INTEGER_PART, "signed").should eq(w36_int128_payload(W36_SIGNED_VALUES))
    w36_decode_stream(W36_NULLABLE_INTEGER_PART, "unsigned").should eq(w36_uint128_payload(W36_UNSIGNED_VALUES))
    w36_assert_stock_marks("pk", 8)
    [{"signed.null", 1}, {"signed", 16}, {"unsigned.null", 1}, {"unsigned", 16}].each do |name, width|
      w36_assert_stock_marks(name, width)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_uint128_raw_mark_range("signed", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_int128_raw_mark_range("unsigned", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_numeric_mark_range("signed", 0, 1, Int128) }
    expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_decimal128_raw_mark_range("signed", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_decimal128_raw_mark_range("unsigned", 0, 1) }
  end

  it "allows an omitted Nullable serialization version but rejects a malformed explicit version" do
    # The pinned stock BASIC fixture intentionally omits this version key.
    CrystalClick::WidePart.open_typed(W36_NULLABLE_INTEGER_PART, "signed").column_type.should eq("Nullable(Int128)")

    parent = File.tempname("crystal-click-w36-nullable-version")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    begin
      FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, part)
      serialization_path = File.join(part, "serialization.json")
      original = File.read(serialization_path)
      malformed = original.sub(%("string":1), %("nullable":null,"string":1))
      malformed.should_not eq(original)
      File.write(serialization_path, malformed)
      w36_refresh_checksums(part)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "signed")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "matches complete nullable Default serializer records by name, not array position" do
    parent = File.tempname("crystal-click-w36-serializer-names")
    Dir.mkdir(parent)
    reordered_part = File.join(parent, "reordered")
    begin
      FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, reordered_part)
      w36_set_explicit_nullable_basic_version(reordered_part)
      w36_set_serializers(reordered_part, [
        w36_default_serializer("unsigned"),
        w36_default_serializer("pk"),
        w36_default_serializer("signed"),
      ])

      signed = CrystalClick::WidePart.open_typed(reordered_part, "signed")
      unsigned = CrystalClick::WidePart.open_typed(reordered_part, "unsigned")
      signed.read_nullable_int128_raw_mark_range("signed", 0, signed.mark_count).should eq(W36_SIGNED_VALUES)
      unsigned.read_nullable_uint128_raw_mark_range("unsigned", 0, unsigned.mark_count).should eq(W36_UNSIGNED_VALUES)

      {
        "duplicate" => [w36_default_serializer("unsigned"), w36_default_serializer("pk"), w36_default_serializer("pk")],
        "missing"   => [w36_default_serializer("unsigned"), w36_default_serializer("pk")],
      }.each do |case_name, records|
        malformed_part = File.join(parent, case_name)
        FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, malformed_part)
        w36_set_serializers(malformed_part, records)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(malformed_part, "signed")
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects stock Sparse nullable serialization and never treats its index as a null map" do
    sparse = File.read(File.join(W36_SPARSE_INTEGER_PART, "serialization.json"))
    sparse.should contain(%("nullable":1))
    sparse.should contain(%("kind":"Sparse"))
    File.read(File.join(W36_SPARSE_INTEGER_PART, "columns_substreams.txt")).should contain("signed.sparse.idx")
    File.read(File.join(W36_SPARSE_INTEGER_PART, "columns_substreams.txt")).should contain("unsigned.sparse.idx")
    File.exists?(File.join(W36_SPARSE_INTEGER_PART, "#{CrystalClick::StreamName.hash("signed.sparse.idx")}.bin")).should be_true
    File.exists?(File.join(W36_SPARSE_INTEGER_PART, "#{CrystalClick::StreamName.hash("unsigned.sparse.idx")}.bin")).should be_true
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(W36_SPARSE_INTEGER_PART, "signed") }
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(W36_SPARSE_INTEGER_PART, "unsigned") }
  end

  it "rejects Decimal128 aliases from raw nullable accessors in both directions" do
    parent = File.tempname("crystal-click-w36-decimal-boundary")
    Dir.mkdir(parent)
    decimal_part = File.join(parent, "decimal")
    decimal_values = [nil.as(Int128?), Int128::MIN.as(Int128?), 0_i128.as(Int128?), Int128::MAX.as(Int128?)]
    decimal_keys = [1_u64, 2_u64, 3_u64, 4_u64]
    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(
        decimal_part, "pk", decimal_keys.to_unsafe.to_slice(4), "amount",
        decimal_values.to_unsafe.to_slice(4), 0, 2
      )
      decimal = CrystalClick::WidePart.open_typed(decimal_part, "amount")
      decimal.column_type.should eq("Nullable(Decimal(38, 0))")
      expect_raises(CrystalClick::UnsupportedFormatError) { decimal.read_nullable_int128_raw_mark_range("amount", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { decimal.read_nullable_uint128_raw_mark_range("amount", 0, 1) }

      signed = CrystalClick::WidePart.open_typed(W36_NULLABLE_INTEGER_PART, "signed")
      unsigned = CrystalClick::WidePart.open_typed(W36_NULLABLE_INTEGER_PART, "unsigned")
      expect_raises(CrystalClick::UnsupportedFormatError) { signed.read_nullable_decimal128_raw_mark_range("signed", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { unsigned.read_nullable_decimal128_raw_mark_range("unsigned", 0, 1) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "materializes both nullable raw columns in table batches and bounded row windows" do
    parent = File.tempname("crystal-click-w36-table")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, part_path)
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "signed", "unsigned"])
      observed = [] of {UInt64, Int128?, UInt128?}
      table.scan_typed(batch_rows: 7) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int128_raw_for("signed")
        unsigned = batch.nullable_uint128_raw_for("unsigned")
        keys.each_index { |index| observed << {keys[index], signed[index], unsigned[index]} }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("signed", Int128) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("unsigned", UInt128) }
      end
      observed.should eq(W36_KEYS.each_index.map { |index| {W36_KEYS[index], W36_SIGNED_VALUES[index], W36_UNSIGNED_VALUES[index]} }.to_a)

      window = [] of {UInt64, Int128?, UInt128?}
      table.scan_typed_window(6_u64, max_rows: 11) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int128_raw_for("signed")
        unsigned = batch.nullable_uint128_raw_for("unsigned")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      window.should eq(W36_KEYS[6, 11].each_index.map do |index|
        row = index + 6
        {W36_KEYS[row], W36_SIGNED_VALUES[row], W36_UNSIGNED_VALUES[row]}
      end.to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an invalid decoded null flag before exposing a table batch" do
    parent = File.tempname("crystal-click-w36-invalid-null-map")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, part)
      w36_rewrite_stream_byte(part, "signed.null", 0, 2_u8)
      reader = CrystalClick::WidePart.open_typed(part, "signed")
      expect_raises(CrystalClick::CorruptPartError, "null-map") do
        reader.read_nullable_int128_raw_mark_range("signed", 0, 1)
      end

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "null-map") do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "signed", "unsigned"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes exact Nullable(Int128) and Nullable(UInt128) pairs with null maps and sentinel marks" do
    parent = File.tempname("crystal-click-w36-writers")
    Dir.mkdir(parent)
    signed_part = File.join(parent, "signed")
    unsigned_part = File.join(parent, "unsigned")
    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_int128_pair(
        signed_part, "pk", W36_KEYS.to_unsafe.to_slice(W36_KEYS.size), "payload",
        W36_SIGNED_VALUES.to_unsafe.to_slice(W36_SIGNED_VALUES.size), 4
      ).should eq(signed_part)
      CrystalClick::WidePartWriter.write_uint64_nullable_uint128_pair(
        unsigned_part, "pk", W36_KEYS.to_unsafe.to_slice(W36_KEYS.size), "payload",
        W36_UNSIGNED_VALUES.to_unsafe.to_slice(W36_UNSIGNED_VALUES.size), 4
      ).should eq(unsigned_part)

      [
        {signed_part, "Nullable(Int128)", W36_SIGNED_VALUES.map { |value| value.nil? ? 1_u8 : 0_u8 }, w36_int128_payload(W36_SIGNED_VALUES)},
        {unsigned_part, "Nullable(UInt128)", W36_UNSIGNED_VALUES.map { |value| value.nil? ? 1_u8 : 0_u8 }, w36_uint128_payload(W36_UNSIGNED_VALUES)},
      ].each do |part, type, nulls, payload|
        File.read(File.join(part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type}\n")
        File.read(File.join(part, "columns_substreams.txt")).should eq("columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n")
        File.read(File.join(part, "count.txt")).should eq("32")
        File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        w36_decode_stream(part, "payload.null").should eq(nulls)
        w36_decode_stream(part, "payload").should eq(payload)
        w36_assert_writer_marks(part, "pk")
        w36_assert_writer_marks(part, "payload.null")
        w36_assert_writer_marks(part, "payload")
      end
      CrystalClick::WidePart.open_typed(signed_part, "payload").read_nullable_int128_raw_mark_range("payload", 0, 8).should eq(W36_SIGNED_VALUES)
      CrystalClick::WidePart.open_typed(unsigned_part, "payload").read_nullable_uint128_raw_mark_range("payload", 0, 8).should eq(W36_UNSIGNED_VALUES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not publish nullable raw parts after writer preflight failures" do
    parent = File.tempname("crystal-click-w36-writer-preflight")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    signed = [nil.as(Int128?), Int128::MAX.as(Int128?)]
    unsigned = [nil.as(UInt128?), UInt128::MAX.as(UInt128?)]
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_int128_pair(
          File.join(parent, "length-mismatch"), "pk", keys.to_unsafe.to_slice(2), "payload", signed.to_unsafe.to_slice(1), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_uint128_pair(
          File.join(parent, "unsorted"), "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "payload", unsigned.to_unsafe.to_slice(2), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-nullable-int128"), "pk", keys.to_unsafe.to_slice(2), "payload", signed.to_unsafe.to_slice(2), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-nullable-uint128"), "pk", keys.to_unsafe.to_slice(2), "payload", unsigned.to_unsafe.to_slice(2), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "returns owned nullable Int128 and UInt128 catalog values and scans a bounded window" do
    root = File.tempname("crystal-click-w36-offline-catalog")
    database_uuid = "36360000-0000-4000-8000-000000000001"
    table_uuid = "36360000-0000-4000-8000-000000000002"
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
        `signed` Nullable(Int128),
        `unsigned` Nullable(UInt128)
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W36_NULLABLE_INTEGER_PART, part_path)

    begin
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"signed", "Nullable(Int128)"},
        {"unsigned", "Nullable(UInt128)"},
      ])
      signed_selection = table["signed"]
      unsigned_selection = table["unsigned"]
      signed_selection.values.map(&.as(Int128?)).should eq(W36_SIGNED_VALUES)
      unsigned_selection.values.map(&.as(UInt128?)).should eq(W36_UNSIGNED_VALUES)
      expect_raises(CrystalClick::BoundsError) { signed_selection.values(max_rows: 31_u64) }

      owned_signed = signed_selection.values
      owned_unsigned = unsigned_selection.values
      owned_signed[0] = 0_i128.as(Int128?)
      owned_unsigned[0] = UInt128::MAX.as(UInt128?)
      signed_selection.values.map(&.as(Int128?)).should eq(W36_SIGNED_VALUES)
      unsigned_selection.values.map(&.as(UInt128?)).should eq(W36_UNSIGNED_VALUES)

      window = [] of {UInt64, Int128?, UInt128?}
      table.scan_typed_window(["pk", "signed", "unsigned"], 7_u64, max_rows: 10) do |batch|
        keys = batch.values_for("pk", UInt64)
        signed = batch.nullable_int128_raw_for("signed")
        unsigned = batch.nullable_uint128_raw_for("unsigned")
        keys.each_index { |index| window << {keys[index], signed[index], unsigned[index]} }
      end
      window.should eq(W36_KEYS[7, 10].each_index.map do |index|
        row = index + 7
        {W36_KEYS[row], W36_SIGNED_VALUES[row], W36_UNSIGNED_VALUES[row]}
      end.to_a)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
