require "./spec_helper"

W32_ARRAY_NULLABLE_STRING_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_nullable_string/part", __DIR__)

private def w32_expected_values : Array(Array(String?))
  [
    [] of String?,
    [] of String?,
    [nil, "", "a\x00b"] of String?,
    ["", String.new(Bytes[0x42_u8, 0xff_u8])] of String?,
    [nil, nil] of String?,
    [nil] of String?,
    [] of String?,
    [] of String?,
    ["", ""] of String?,
    [""] of String?,
    ["é", "tail\x00x"] of String?,
  ]
end

private def w32_raw_stream(part : String, name : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  decoded = [] of UInt8
  offset = 0_i64
  while offset < encoded.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, offset)
    frame.output.each { |byte| decoded << byte }
    offset = frame.end_offset
  end
  decoded
end

private def w32_u64s(bytes : Array(UInt8)) : Array(UInt64)
  raise "W32 U64 stream is misaligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w32_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w32_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w32_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w32_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w32_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W32 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w32_write_u32(frame, header + 1, compressed_size.to_u32)
  w32_write_u32(frame, header + 5, raw.size.to_u32)
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
  w32_write_u64(frame, 0, checksum[0])
  w32_write_u64(frame, 8, checksum[1])
  frame
end

private def w32_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w32_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w32_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w32_write_varuint(payload, file_bytes.size.to_u64)
    w32_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w32_write_varuint(payload, raw.size.to_u64)
      w32_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w32_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w32_copy_fixture(parent : String, name : String) : String
  part = File.join(parent, name)
  FileUtils.cp_r(W32_ARRAY_NULLABLE_STRING_FIXTURE, part)
  part
end

private def w32_rewrite_stream_byte(part : String, stream : String, offset : Int, value : UInt8) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).dup
  raw[offset] = value
  File.write(path, w32_encode_lz4_frame(raw))
  w32_refresh_checksums(part)
end

private def w32_replace_raw_stream(part : String, stream : String, raw : Bytes) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  File.write(path, w32_encode_lz4_frame(raw))
end

private def w32_write_mark_offset(part : String, stream : String, record : Int, value : UInt64) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  w32_write_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 8, value)
  File.write(path, marks)
  w32_refresh_checksums(part)
end

private def w32_catalog_root(&)
  root = File.tempname("crystal-click-w32-catalog")
  Dir.mkdir(root)
  database_uuid = "15f4e73a-1770-426c-901f-624bd8a85c97"
  table_uuid = "876a3f2d-97bb-4550-b0a9-fb114a2514bf"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_store)
  FileUtils.mkdir_p(table_store)
  tick = 96.chr
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    #{tick}pk#{tick} UInt64,\n    #{tick}a#{tick} Array(Nullable(String))\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W32_ARRAY_NULLABLE_STRING_FIXTURE, File.join(table_store, "all_1_1_0"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits the exact Array(Nullable(String)) spelling while rejecting unsupported variants" do
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(String))").should be_true
    [
      "Array(Nullable(LowCardinality(String)))",
      "Nullable(Array(Nullable(String)))",
      "Array( Nullable(String))",
      "Array(Nullable(String)) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock nullable String arrays by outer-row marks and preserves NULL, empty, and binary values" do
    expected = w32_expected_values
    reader = CrystalClick::WidePart.open_typed(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a")
    reader.column_type.should eq("Array(Nullable(String))")
    reader.row_count.should eq(11_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_nullable_string_mark_range("a", 0, reader.mark_count).should eq(expected)
    reader.read_array_nullable_string_mark_range("a", 1, 2).should eq(expected[2, 4])
    reader.read_array_nullable_string_mark_range("a", 5, 1).should eq(expected[10, 1])
    reader.read_array_nullable_string_mark_range_with_raw_bytes("a", 0, reader.mark_count)[1].should eq(13_u64)
    reader.array_nullable_string_mark_range_preflight("a", 0, 1).should eq({0_u64, 64_u64})
    w32_u64s(w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a.size0")).should eq([0_u64, 0_u64, 3_u64, 2_u64, 2_u64, 1_u64, 0_u64, 0_u64, 2_u64, 1_u64, 2_u64])
    w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    w32_u64s(w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a.size")).should eq([0_u64, 0_u64, 3_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 2_u64, 6_u64])
    w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a").should eq("a\x00bB".to_slice.to_a + [0xff_u8] + "é".to_slice.to_a + "tail\x00x".to_slice.to_a)
  end

  it "exposes the selected Array(Nullable(String)) through table batches and the offline catalog" do
    expected = w32_expected_values
    keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64]
    observed = [] of {UInt64, Array(String?)}
    parent = File.tempname("crystal-click-w32-table")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      FileUtils.cp_r(W32_ARRAY_NULLABLE_STRING_FIXTURE, part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
      table.scan_typed(batch_rows: 3) do |batch|
        ids = batch.values_for("pk", UInt64)
        values = batch.array_nullable_strings_for("a")
        ids.each_with_index { |id, index| observed << {id, values[index].dup} }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
    observed.should eq(keys.each_with_index.map { |key, index| {key, expected[index]} }.to_a)

    w32_catalog_root do |root|
      column = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["a"]
      values = column.values.map { |value| value.as(Array(String?)) }
      values.should eq(expected)
      values[2][1] = "caller mutation"
      column.values.map { |value| value.as(Array(String?)) }.should eq(expected)
    end
  end

  it "writes nullable String arrays that independently match stock raw streams and reader output" do
    expected = w32_expected_values
    keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64]
    parent = File.tempname("crystal-click-w32-writer")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_nullable_string_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "a",
        expected.to_unsafe.to_slice(expected.size),
        rows_per_mark: 2
      )
      reader = CrystalClick::WidePart.open_typed(part, "a")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_nullable_string_mark_range("a", 0, reader.mark_count).should eq(expected)
      w32_u64s(w32_raw_stream(part, "a.size0")).should eq([0_u64, 0_u64, 3_u64, 2_u64, 2_u64, 1_u64, 0_u64, 0_u64, 2_u64, 1_u64, 2_u64])
      w32_raw_stream(part, "a.null").should eq(w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a.null"))
      w32_u64s(w32_raw_stream(part, "a.size")).should eq([0_u64, 0_u64, 3_u64, 0_u64, 2_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 2_u64, 6_u64])
      w32_raw_stream(part, "a").should eq(w32_raw_stream(W32_ARRAY_NULLABLE_STRING_FIXTURE, "a"))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "consumes nested String bytes beneath NULL while preserving the visible nil" do
    expected = w32_expected_values
    parent = File.tempname("crystal-click-w32-null-payload")
    Dir.mkdir(parent)
    begin
      part = w32_copy_fixture(parent, "all_1_1_0")

      size_raw = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(part, "#{CrystalClick::StreamName.hash("a.size")}.bin")).to_slice
      ).dup
      # Element 0 of the first nonempty mark is NULL in a.null; give its nested
      # String slot one byte, as Nullable serialization still consumes it.
      w32_write_u64(size_raw, 0, 1_u64)
      w32_replace_raw_stream(part, "a.size", size_raw)

      original_string_bytes = w32_raw_stream(part, "a")
      string_raw = Bytes.new(original_string_bytes.size + 1, 0_u8)
      string_raw[0] = 0x5a_u8
      original_string_bytes.each_with_index { |byte, index| string_raw[index + 1] = byte }
      w32_replace_raw_stream(part, "a", string_raw)

      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("a")}.mrk2")
      marks = File.read(mark_path).to_slice.dup
      [5_u64, 5_u64, 5_u64, 5_u64, 13_u64].each_with_index do |offset, index|
        record = index + 2
        w32_write_u64(marks, record * CrystalClick::WidePart::MARK_SIZE + 8, offset + 1)
      end
      File.write(mark_path, marks)
      w32_refresh_checksums(part)

      reader = CrystalClick::WidePart.open_typed(part, "a")
      reader.read_array_nullable_string_mark_range("a", 0, reader.mark_count).should eq(expected)
      reader.read_array_nullable_string_mark_range_with_raw_bytes("a", 0, reader.mark_count)[1].should eq(14_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-updated invalid NULL flag before exposing a table callback" do
    parent = File.tempname("crystal-click-w32-invalid-null")
    Dir.mkdir(parent)
    begin
      part = w32_copy_fixture(parent, "all_1_1_0")
      # The first flattened NULL slot belongs to mark 1; preserve stream size,
      # recompute the LZ4 frame checksum, and rewrite checksums.txt hashes.
      w32_rewrite_stream_byte(part, "a.null", 0, 2_u8)
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "a").read_array_nullable_string_mark_range("a", 1, 1)
      end
      (error.message || "").should contain("null-map")

      callbacks = 0
      table_error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
        table.scan_typed_candidate_marks([[1]]) do |_batch|
          callbacks += 1
        end
      end
      (table_error.message || "").should contain("null-map")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects checksum-updated shifted nested marks before exposing a table callback" do
    parent = File.tempname("crystal-click-w32-shifted-mark")
    Dir.mkdir(parent)
    begin
      part = w32_copy_fixture(parent, "all_1_1_0")
      w32_write_mark_offset(part, "a.null", 2, 6_u64)
      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
        table.scan_typed_candidate_marks([[2]]) do |_batch|
          callbacks += 1
        end
      end
      (error.message || "").should contain("mark")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
