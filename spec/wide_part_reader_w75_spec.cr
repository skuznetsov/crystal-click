require "./spec_helper"

W75_READER_KEYS                = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W75_READER_VALUES              = ["alpha", 0_u64, nil, "", "a\0b", nil, UInt64::MAX] of CrystalClick::VariantStringUInt64Value
W75_READER_UINT64_FIRST_VALUES = [42_u64, "s", nil, UInt64::MAX, "", nil, "tail"] of CrystalClick::VariantStringUInt64Value

private def w75_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w75_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w75_reader_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w75_reader_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w75_reader_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w75_reader_literal_frame(bytes : Bytes) : Bytes
  compressed = IO::Memory.new
  if bytes.size < 15
    compressed.write_byte((bytes.size << 4).to_u8)
  else
    compressed.write_byte(0xf0_u8)
    remainder = bytes.size - 15
    while remainder >= 255
      compressed.write_byte(255_u8)
      remainder -= 255
    end
    compressed.write_byte(remainder.to_u8)
  end
  compressed.write(bytes)
  payload = compressed.to_slice
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  w75_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w75_reader_write_u32(frame, header + 5, bytes.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w75_reader_write_u64(frame, 0, checksum[0])
  w75_reader_write_u64(frame, 8, checksum[1])
  frame
end

private def w75_reader_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w75_reader_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w75_reader_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w75_reader_write_varuint(payload, bytes.size.to_u64)
    w75_reader_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    if entry.compressed
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      payload.write_byte(1_u8)
      w75_reader_write_varuint(payload, raw.size.to_u64)
      w75_reader_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  checksums = IO::Memory.new
  checksums << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  checksums.write(w75_reader_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), checksums.to_slice)
end

# Re-encode a stream into one valid frame while preserving each mark's absolute
# decompressed position. This lets corruption cases isolate semantic validation.
private def w75_reader_rewrite_stream(part : String, stream : String, & : Bytes, Array(Int32) -> Bytes) : Nil
  base = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{base}.bin")
  marks_path = File.join(part, "#{base}.mrk2")
  encoded = File.read(data_path).to_slice
  raw = CrystalClick::CompressedBlock.decode_all(encoded).dup
  records_bytes = File.read(marks_path).to_slice
  raise "W75 reader test mark file is malformed" unless records_bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  record_count = records_bytes.size // CrystalClick::WidePart::MARK_SIZE
  records = Array(Tuple(UInt64, UInt64, UInt64)).new(record_count) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w75_reader_read_u64(records_bytes, offset), w75_reader_read_u64(records_bytes, offset + 8), w75_reader_read_u64(records_bytes, offset + 16)}
  end

  frame_bases = Hash(UInt64, UInt64).new
  compressed_offset = 0_i64
  decompressed_offset = 0_u64
  while compressed_offset < encoded.size
    frame_bases[compressed_offset.to_u64] = decompressed_offset
    frame = CrystalClick::CompressedBlock.decode_frame(
      encoded,
      compressed_offset,
      CrystalClick::WidePart::MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES
    )
    decompressed_offset += frame.output.size.to_u64
    compressed_offset = frame.end_offset
  end
  frame_bases[encoded.size.to_u64] = decompressed_offset
  starts = records[0, record_count - 1].map do |record|
    (frame_bases[record[0]]? || raise "W75 reader test mark does not reference a frame").to_i + record[1].to_i
  end
  raw = yield raw, starts
  File.write(data_path, w75_reader_literal_frame(raw))

  marks = Bytes.new(record_count * CrystalClick::WidePart::MARK_SIZE, 0_u8)
  records[0, record_count - 1].each_with_index do |record, index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    w75_reader_write_u64(marks, offset, 0_u64)
    w75_reader_write_u64(marks, offset + 8, starts[index].to_u64)
    w75_reader_write_u64(marks, offset + 16, record[2])
  end
  terminal = (record_count - 1) * CrystalClick::WidePart::MARK_SIZE
  w75_reader_write_u64(marks, terminal, 0_u64)
  w75_reader_write_u64(marks, terminal + 8, raw.size.to_u64)
  w75_reader_write_u64(marks, terminal + 16, 0_u64)
  File.write(marks_path, marks)
  w75_reader_refresh_checksums(part)
end

private def w75_reader_with_writer_part(& : String ->)
  parent = File.tempname("crystal-click-w75-dynamic-reader")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
      part,
      "pk",
      W75_READER_KEYS.to_unsafe.to_slice(W75_READER_KEYS.size),
      "payload",
      W75_READER_VALUES.to_unsafe.to_slice(W75_READER_VALUES.size),
      rows_per_mark: 3
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w75_reader_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "6d72946b-4035-48b1-993a-048c686e2c76"
  table_uuid = "882a5f94-03b7-48dc-8db0-3c98e927629f"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Dynamic)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe "W75 standalone Dynamic(String, UInt64, NULL) reader" do
  it "reads exact mixed identities from the canonical two-arm profile" do
    w75_reader_with_writer_part do |part|
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_dynamic_string_uint64_mark_range("payload", 0, reader.mark_count).should eq(W75_READER_VALUES)
      reader.read_dynamic_string_uint64_mark_range("payload", 1, 1).should eq(["", "a\0b", nil])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_dynamic_string_mark_range("payload", 1, 1)
      end
    end
  end

  it "exposes mixed values through typed table batches and rejects the String-only accessor" do
    w75_reader_with_writer_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of CrystalClick::VariantStringUInt64Value
      table.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.dynamic_string_uint64_for("payload"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.dynamic_strings_for("payload")
        end
      end
      observed.should eq(W75_READER_VALUES)

      # The second mark contains String and NULL only; the part is still mixed.
      table.scan_typed_window(3_u64, 2) do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.dynamic_strings_for("payload")
        end
      end
    end
  end

  it "preserves mixed value identity and order through OfflineCatalog values" do
    w75_reader_with_writer_part do |part|
      root = File.tempname("crystal-click-w75-dynamic-catalog")
      begin
        table = w75_reader_catalog_table(root, part)
        table.materialize_selected_values("payload").should eq(W75_READER_VALUES)
        table["payload"].values.should eq(W75_READER_VALUES)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "uses canonical tags even when UInt64 is the first input row" do
    parent = File.tempname("crystal-click-w75-dynamic-u64-first")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    begin
      CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
        part,
        "pk",
        W75_READER_KEYS.to_unsafe.to_slice(W75_READER_KEYS.size),
        "payload",
        W75_READER_UINT64_FIRST_VALUES.to_unsafe.to_slice(W75_READER_UINT64_FIRST_VALUES.size),
        rows_per_mark: 3
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_dynamic_string_uint64_mark_range("payload", 0, reader.mark_count).should eq(W75_READER_UINT64_FIRST_VALUES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects later-mark bad tags and statistics inconsistent with the tag totals before callbacks" do
    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.variant_discr") do |raw, starts|
        starts.size.should eq(3)
        corrupted = raw.dup
        corrupted[starts[1] + 4] = 0_u8
        corrupted
      end
      callbacks = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 3) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.dynamic_structure") do |raw, starts|
        starts.size.should eq(3)
        raw[13].should eq(3_u8)
        corrupted = raw.dup
        corrupted[14] = 1_u8
        corrupted
      end
      callbacks = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 3) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.dynamic_structure") do |raw, starts|
        starts.size.should eq(3)
        corrupted = raw.dup
        corrupted[9] = 0x04_u8 # Noncanonical dictionary order/type code.
        corrupted
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end
  end

  it "rejects a shifted sparse UInt64 child offset before exposing that mark" do
    w75_reader_with_writer_part do |part|
      marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.UInt64")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # The third row granule carries the final UInt64 value; shift only that
      # child's decompressed cursor while preserving the parent row marks.
      shifted_mark = CrystalClick::WidePart::MARK_SIZE * 2 + 8
      w75_reader_write_u64(marks, shifted_mark, w75_reader_read_u64(marks, shifted_mark) + 1_u64)
      File.write(marks_path, marks)
      w75_reader_refresh_checksums(part)

      yielded_rows = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 3) do |batch|
          yielded_rows += batch.dynamic_string_uint64_for("payload").size
        end
      end
      yielded_rows.should eq(0)
    end
  end

  it "rejects all-NULL and UInt64-only Dynamic structures instead of decoding tag 1 heuristically" do
    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.dynamic_structure") do |raw, _starts|
        corrupted = raw.dup
        corrupted[8] = 0_u8
        corrupted
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end

    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.dynamic_structure") do |raw, _starts|
        corrupted = raw.dup
        corrupted[8] = 1_u8
        corrupted[9] = 0x04_u8
        corrupted
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end
  end

  it "rejects a missing mixed-arm child stream at open" do
    w75_reader_with_writer_part do |part|
      metadata_path = File.join(part, "columns_substreams.txt")
      metadata = File.read(metadata_path)
      metadata = metadata.sub("7 substreams for column `payload`:", "6 substreams for column `payload`:")
      metadata = metadata.sub("\tpayload.UInt64\n", "")
      File.write(metadata_path, metadata)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end
  end

  it "rejects String size and raw-child disagreement before exposing the affected mark" do
    w75_reader_with_writer_part do |part|
      w75_reader_rewrite_stream(part, "payload.String.size") do |raw, starts|
        starts.size.should eq(3)
        raw.size.should eq(24)
        corrupted = raw.dup
        # The second mark contains two Strings of lengths zero and three.
        w75_reader_write_u64(corrupted, 16, 4_u64)
        corrupted
      end
      yielded_rows = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 3) do |batch|
          yielded_rows += batch.dynamic_string_uint64_for("payload").size
        end
      end
      yielded_rows.should eq(3)
    end
  end

  it "rejects nonempty SharedVariant payloads" do
    w75_reader_with_writer_part do |part|
      shared_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.SharedVariant")}.bin")
      File.write(shared_path, w75_reader_literal_frame(Bytes[0_u8]))
      w75_reader_refresh_checksums(part)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end
  end
end
