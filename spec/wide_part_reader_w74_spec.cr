require "./spec_helper"

W74_SPEC_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W74_SPEC_VALUES = ["alpha", "", "beta", "a\0b", "tail"]

private def w74_spec_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w74_spec_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w74_spec_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w74_spec_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w74_spec_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w74_spec_literal_frame(bytes : Bytes) : Bytes
  compressed = IO::Memory.new
  literal_length = bytes.size
  if literal_length < 15
    compressed.write_byte((literal_length << 4).to_u8)
  else
    compressed.write_byte(0xf0_u8)
    remainder = literal_length - 15
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
  w74_spec_write_u32(frame, header + 1, compressed_size.to_u32)
  w74_spec_write_u32(frame, header + 5, bytes.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w74_spec_write_u64(frame, 0, checksum[0])
  w74_spec_write_u64(frame, 8, checksum[1])
  frame
end

private def w74_spec_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w74_spec_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w74_spec_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w74_spec_write_varuint(payload, bytes.size.to_u64)
    w74_spec_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    if entry.compressed
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      payload.write_byte(1_u8)
      w74_spec_write_varuint(payload, raw.size.to_u64)
      w74_spec_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w74_spec_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w74_spec_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W74 test fixture mark file is malformed" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w74_spec_read_u64(bytes, offset), w74_spec_read_u64(bytes, offset + 8), w74_spec_read_u64(bytes, offset + 16)}
  end
end

# Re-encode a selected raw stream into one valid LZ4 frame while preserving
# every mark's absolute uncompressed location and row count. The callback can
# then introduce a checksum-consistent semantic corruption.
private def w74_spec_rewrite_stream(part : String, stream : String, & : Bytes, Array(UInt64) -> Bytes) : Nil
  base = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{base}.bin")
  marks_path = File.join(part, "#{base}.mrk2")
  encoded = File.read(data_path).to_slice
  raw = CrystalClick::CompressedBlock.decode_all(encoded).dup
  records = w74_spec_mark_records(part, stream)

  raw_bases = Hash(UInt64, UInt64).new
  compressed_offset = 0_i64
  raw_offset = 0_u64
  while compressed_offset < encoded.size
    raw_bases[compressed_offset.to_u64] = raw_offset
    frame = CrystalClick::CompressedBlock.decode_frame(
      encoded,
      compressed_offset,
      CrystalClick::WidePart::MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES
    )
    raw_offset += frame.output.size.to_u64
    compressed_offset = frame.end_offset
  end
  raw_bases[encoded.size.to_u64] = raw_offset

  starts = records[0, records.size - 1].map do |record|
    frame_start = raw_bases[record[0]]? || raise "W74 test fixture mark does not reference a frame"
    frame_start + record[1]
  end
  raw = yield raw, starts
  frame = w74_spec_literal_frame(raw)
  File.write(data_path, frame)

  marks = Bytes.new(records.size * CrystalClick::WidePart::MARK_SIZE, 0_u8)
  records[0, records.size - 1].each_with_index do |record, index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    w74_spec_write_u64(marks, offset, 0_u64)
    w74_spec_write_u64(marks, offset + 8, starts[index])
    w74_spec_write_u64(marks, offset + 16, record[2])
  end
  terminal_offset = (records.size - 1) * CrystalClick::WidePart::MARK_SIZE
  # ClickHouse plain .mrk2 uses a terminal record at compressed offset zero
  # and the end of the decompressed stream for these single-frame fixtures.
  w74_spec_write_u64(marks, terminal_offset, 0_u64)
  w74_spec_write_u64(marks, terminal_offset + 8, raw.size.to_u64)
  w74_spec_write_u64(marks, terminal_offset + 16, 0_u64)
  File.write(marks_path, marks)
  w74_spec_refresh_checksums(part)
end

private def w74_spec_reject_writer_input(
  parent : String,
  name : String,
  key_name : String,
  keys : Array(UInt64),
  value_name : String,
  values : Array(String),
  rows_per_mark : Int32,
) : Nil
  destination = File.join(parent, name)
  expect_raises(ArgumentError) do
    CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
      destination,
      key_name,
      keys.to_unsafe.to_slice(keys.size),
      value_name,
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: rows_per_mark
    )
  end
  File.exists?(destination).should be_false
end

private def w74_spec_with_values_part(keys : Slice(UInt64), values : Slice(String), rows_per_mark : Int32, & : String ->)
  parent = File.tempname("crystal-click-w74-dynamic")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
      part,
      "pk",
      keys,
      "payload",
      values,
      rows_per_mark: rows_per_mark
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w74_spec_with_writer_part(& : String ->)
  w74_spec_with_values_part(
    W74_SPEC_KEYS.to_unsafe.to_slice(W74_SPEC_KEYS.size),
    W74_SPEC_VALUES.to_unsafe.to_slice(W74_SPEC_VALUES.size),
    2
  ) do |part|
    yield part
  end
end

private def w74_spec_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
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

describe "W74 standalone Dynamic(String-only) reader" do
  it "admits only ClickHouse's exact Dynamic declaration" do
    CrystalClick::WidePart.supports_typed_type?("Dynamic").should be_true
    CrystalClick::WidePart.supports_typed_type?("Dynamic(String)").should be_false
  end

  it "reads writer parts through typed batches, including embedded NUL and empty Strings" do
    w74_spec_with_writer_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of String
      table.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.dynamic_strings_for("payload"))
      end
      observed.should eq(W74_SPEC_VALUES)
      table.part_mark_row_counts.first.should eq([2_u64, 2_u64, 1_u64])

      ranged = [] of String
      range_marks = [] of Int32
      table.scan_typed_window(2_u64, 2) do |batch|
        ranged.concat(batch.dynamic_strings_for("payload"))
        range_marks << batch.mark_index
      end
      ranged.should eq(["beta", "a\0b"])
      range_marks.should eq([1])

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_dynamic_string_mark_range("payload", 0, reader.mark_count).should eq(W74_SPEC_VALUES)
      reader.dynamic_string_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq(W74_SPEC_VALUES.sum(&.bytesize).to_u64)
    end
  end

  it "reads all-empty String dictionaries across marks and a multi-byte row statistic" do
    keys = Array(UInt64).new(130) { |index| (index + 1).to_u64 }
    values = Array(String).new(130) { "" }
    w74_spec_with_values_part(
      keys.to_unsafe.to_slice(keys.size),
      values.to_unsafe.to_slice(values.size),
      64
    ) do |part|
      File.size(File.join(part, "#{CrystalClick::StreamName.hash("payload.String")}.bin")).should eq(0)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      table.part_mark_row_counts.first.should eq([64_u64, 64_u64, 2_u64])
      observed = [] of String
      table.scan_typed(batch_rows: 64) do |batch|
        observed.concat(batch.dynamic_strings_for("payload"))
      end
      observed.should eq(values)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_dynamic_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.dynamic_string_mark_range_materialization_preflight("payload", 0, reader.mark_count).should eq(0_u64)
    end
  end

  it "rejects trailing Dynamic V3 structure bytes before yielding a batch" do
    w74_spec_with_writer_part do |part|
      w74_spec_rewrite_stream(part, "payload.dynamic_structure") do |raw, _starts|
        extended = Bytes.new(raw.size + 1)
        raw.copy_to(extended)
        extended[raw.size] = 0_u8
        extended
      end

      callbacks = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects a changed later-mark discriminator before exposing that mark" do
    w74_spec_with_writer_part do |part|
      w74_spec_rewrite_stream(part, "payload.variant_discr") do |raw, starts|
        mark_start = starts[1].to_i
        mark_end = starts[2].to_i
        raise "W74 test fixture discriminator mark is empty" if mark_end <= mark_start
        corrupted = raw.dup
        corrupted[mark_end - 1] = 0_u8
        corrupted
      end

      yielded_rows = 0
      expect_raises(CrystalClick::Error) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 2) do |batch|
          yielded_rows += batch.dynamic_strings_for("payload").size
        end
      end
      yielded_rows.should eq(2)
    end
  end

  it "rejects a shifted later-mark discriminator offset before exposing that mark" do
    w74_spec_with_writer_part do |part|
      w74_spec_rewrite_stream(part, "payload.variant_discr") do |raw, starts|
        starts.size.should eq(3)
        raw[8, 6].should eq(Bytes[2_u8, 1_u8, 1_u8, 2_u8, 1_u8, 1_u8])
        raw
      end

      marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.variant_discr")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # Mark 2 is the exclusive end of the second row granule. Leave mark 1
      # intact so the first granule can be yielded before the second fails.
      later_mark_offset = CrystalClick::WidePart::MARK_SIZE * 2 + 8
      w74_spec_write_u64(marks, later_mark_offset, w74_spec_read_u64(marks, later_mark_offset) + 1_u64)
      File.write(marks_path, marks)
      w74_spec_refresh_checksums(part)

      yielded_rows = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 2) do |batch|
          yielded_rows += batch.dynamic_strings_for("payload").size
        end
      end
      yielded_rows.should eq(2)
    end
  end

  it "rejects child mark-row disagreement before a typed scan can yield" do
    w74_spec_with_writer_part do |part|
      marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.String")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      w74_spec_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
      File.write(marks_path, marks)
      w74_spec_refresh_checksums(part)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects nonempty SharedVariant bytes even when file checksums are consistent" do
    w74_spec_with_writer_part do |part|
      shared_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.SharedVariant")}.bin")
      File.file?(shared_path).should be_true
      File.write(shared_path, w74_spec_literal_frame(Bytes[0_u8]))
      w74_spec_refresh_checksums(part)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    end
  end

  it "materializes Dynamic Strings through OfflineCatalog" do
    w74_spec_with_writer_part do |part|
      root = File.tempname("crystal-click-w74-dynamic-catalog")
      begin
        table = w74_spec_catalog_table(root, part)
        observed = table.materialize_selected_values("payload").map(&.as(String))
        observed.should eq(W74_SPEC_VALUES)
        table["payload"].values.map(&.as(String)).should eq(W74_SPEC_VALUES)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects checksum-consistent Dynamic dictionary and row-stat corruption" do
    [
      {"dictionary type code", 9, 0x01_u8, CrystalClick::UnsupportedFormatError},
      {"String row statistic", 12, 0x04_u8, CrystalClick::CorruptPartError},
    ].each do |label, byte_offset, replacement, error_type|
      w74_spec_with_writer_part do |part|
        w74_spec_rewrite_stream(part, "payload.dynamic_structure") do |raw, _starts|
          raw.size.should eq(14)
          raw[8, 6].should eq(Bytes[1_u8, 0x15_u8, 1_u8, 0_u8, 5_u8, 0_u8])
          corrupted = raw.dup
          corrupted[byte_offset] = replacement
          corrupted
        end

        callbacks = 0
        expect_raises(error_type) do
          table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
          table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0), label
      end
    end
  end

  it "rejects Dynamic writer inputs before publishing and preserves destination collisions" do
    parent = File.tempname("crystal-click-w74-dynamic-writer")
    Dir.mkdir(parent)
    begin
      w74_spec_reject_writer_input(parent, "mismatched-rows", "pk", [1_u64, 2_u64], "payload", ["x"], 2)
      w74_spec_reject_writer_input(parent, "unsorted-keys", "pk", [2_u64, 1_u64], "payload", ["x", "y"], 2)
      w74_spec_reject_writer_input(parent, "invalid-name", "bad.name", [1_u64], "payload", ["x"], 2)
      w74_spec_reject_writer_input(parent, "oversize-granule", "pk", [1_u64], "payload", ["x"], 65_537)

      collision = File.join(parent, "existing-destination")
      File.write(collision, "preserve this user data")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
          collision,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "payload",
          ["x"].to_unsafe.to_slice(1),
          rows_per_mark: 2
        )
      end
      File.read(collision).should eq("preserve this user data")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
