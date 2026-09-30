require "./spec_helper"
require "file_utils"

private W97_CONSUMER_TYPE      = "Tuple(flag Bool, byte UInt8, text String)"
private W97_CONSUMER_ROW_COUNT = 257

private def w97_consumer_columns : Array(CrystalClick::WideTupleLeafColumn)
  raw_codes = Array(UInt8).new(W97_CONSUMER_ROW_COUNT) { |index| (index % 256).to_u8 }
  flags = raw_codes.map { |code| code != 0_u8 }
  text = Array(String).new(W97_CONSUMER_ROW_COUNT) do |index|
    if index % 3 == 0
      ""
    else
      String.new(Bytes[0x62_u8, raw_codes[index], 0x00_u8, 0xff_u8])
    end
  end

  [
    CrystalClick::WideTupleLeafColumn.new("flag", flags),
    CrystalClick::WideTupleLeafColumn.new("byte", raw_codes),
    CrystalClick::WideTupleLeafColumn.new("text", text),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w97_consumer_type_name(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w97_consumer_keys : Array(UInt64)
  Array(UInt64).new(W97_CONSUMER_ROW_COUNT) { |index| index.to_u64 + 1_u64 }
end

private def w97_consumer_create_part(parent : String, keys : Array(UInt64), columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  destination = File.join(parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w97_consumer_type_name(columns),
    columns,
    rows_per_mark: 2
  )
end

private def w97_consumer_catalog(root : String, keys : Array(UInt64), columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  metadata_path = File.join(root, "metadata")
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(File.join(root, "store"))

  database_uuid = "97000000-0000-4000-8000-000000000001"
  table_uuid = "97000000-0000-4000-8000-000000000002"
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{w97_consumer_type_name(columns)}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  w97_consumer_create_part(table_path, keys, columns)
end

private def w97_consumer_index(key : UInt64) : Int32
  raise "unexpected W97 consumer key #{key}" if key == 0_u64 || key > W97_CONSUMER_ROW_COUNT.to_u64
  (key - 1_u64).to_i32
end

private def w97_consumer_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |index| value |= bytes[offset + index].to_u32 << (index * 8) }
  value
end

private def w97_consumer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w97_consumer_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w97_consumer_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w97_consumer_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w97_consumer_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w97_consumer_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W97 checksum fixture cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w97_consumer_write_u32(frame, header + 1, compressed_size.to_u32)
  w97_consumer_write_u32(frame, header + 5, raw.size.to_u32)
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
  w97_consumer_write_u64(frame, 0, checksum[0])
  w97_consumer_write_u64(frame, 8, checksum[1])
  frame
end

private def w97_consumer_rewrite_checksums(part : String, raw_overrides : Hash(String, Bytes) = Hash(String, Bytes).new) : Nil
  checksums = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w97_consumer_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = checksums.entries[name]
    w97_consumer_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w97_consumer_write_varuint(payload, file_bytes.size.to_u64)
    w97_consumer_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = if override = raw_overrides[name]?
              override
            else
              file_bytes.empty? ? file_bytes : CrystalClick::CompressedBlock.decode_all(file_bytes)
            end
      payload.write_byte(1_u8)
      w97_consumer_write_varuint(payload, raw.size.to_u64)
      w97_consumer_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  frame = w97_consumer_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
  nil
end

private def w97_consumer_corrupt_final_bool_frame(part : String) : Nil
  stream = "payload%2Eflag"
  hash = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{hash}.bin")
  marks_path = File.join(part, "#{hash}.mrk2")
  marks = File.read(marks_path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W97 Bool corruption fixture has malformed marks" unless marks.size % mark_size == 0
  entries = marks.size // mark_size
  raise "W97 Bool corruption fixture needs a data mark and sentinel" if entries < 2

  last_mark_index = entries - 2
  frame_offset = w97_consumer_read_u64(marks, last_mark_index * mark_size).to_i
  encoded = File.read(data_path).to_slice.dup
  original_raw = CrystalClick::CompressedBlock.decode_all(encoded).to_slice.dup
  raise "W97 final Bool frame offset is out of bounds" if frame_offset < 0 || frame_offset + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE > encoded.size
  compressed_size = w97_consumer_read_u32(encoded, frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1).to_i
  frame_size = CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size
  raise "W97 final Bool frame extent is out of bounds" if frame_size < CrystalClick::CompressedBlock::FRAME_HEADER_SIZE || frame_offset + frame_size > encoded.size

  decompressed_size_offset = frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5
  original_decompressed_size = w97_consumer_read_u32(encoded, decompressed_size_offset)
  raise "W97 final Bool mark should contain one byte" unless original_decompressed_size == 1_u32
  w97_consumer_write_u32(encoded, decompressed_size_offset, original_decompressed_size + 1_u32)
  checksum_range = encoded[frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size]
  checksum = CrystalClick::CityHashV1.hash128(checksum_range)
  w97_consumer_write_u64(encoded, frame_offset, checksum[0])
  w97_consumer_write_u64(encoded, frame_offset + 8, checksum[1])
  File.write(data_path, encoded)
  w97_consumer_rewrite_checksums(part, {"#{hash}.bin" => original_raw})
  nil
end

private def w97_consumer_assert_row(row : CrystalClick::WideTupleRow, index : Int) : Nil
  expected_code = (index % 256).to_u8
  row.type_name.should eq(W97_CONSUMER_TYPE)
  row.field_count.should eq(3)
  row.fields.map(&.type_name).should eq(["Bool", "UInt8", "String"])
  row.value_as("flag", Bool).should eq(expected_code != 0_u8)
  row.value_as("byte", UInt8).should eq(expected_code)
  expected_text = if index % 3 == 0
                    ""
                  else
                    String.new(Bytes[0x62_u8, expected_code, 0x00_u8, 0xff_u8])
                  end
  row.value_as("text", String).should eq(expected_text)
  expect_raises(CrystalClick::UnsupportedFormatError) { row.value_as("flag", UInt8) }
  expect_raises(CrystalClick::UnsupportedFormatError) { row.value_as("byte", Bool) }
  nil
end

describe "W97 named Bool Tuple consumers" do
  it "preserves nominal Bool across typed ranges, table scans, windows, candidates, and catalog values" do
    keys = w97_consumer_keys
    columns = w97_consumer_columns
    parent = File.tempname("crystal-click-w97-bool-consumers")
    Dir.mkdir(parent)
    begin
      part = w97_consumer_create_part(parent, keys, columns)
      physical = CrystalClick::WidePart.open_typed(part, "payload")
      physical.mark_row_counts.should eq((Array.new(128, 2_u64) + [1_u64]))

      full = physical.read_tuple_mark_range("payload", 0, physical.mark_count)
      full.type_name.should eq(W97_CONSUMER_TYPE)
      full.row_count.should eq(W97_CONSUMER_ROW_COUNT)
      W97_CONSUMER_ROW_COUNT.times do |index|
        expected_code = (index % 256).to_u8
        full.value_as("flag", index, Bool).should eq(expected_code != 0_u8)
        full.value_as("byte", index, UInt8).should eq(expected_code)
      end

      selected = physical.read_tuple_mark_range("payload", 127, 2)
      selected.row_count.should eq(3)
      [254, 255, 256].each_with_index do |index, local_index|
        selected.value_as("flag", local_index, Bool).should eq((index % 256).to_u8 != 0_u8)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      full_indices = [] of Int32
      table.scan_typed do |batch|
        rows = batch.tuple_rows_for("payload")
        batch_keys = batch.values_for("pk")
        rows.each_with_index do |row, offset|
          index = w97_consumer_index(batch_keys[offset])
          w97_consumer_assert_row(row, index)
          full_indices << index
        end
        nil
      end
      full_indices.should eq((0...W97_CONSUMER_ROW_COUNT).map(&.to_i32))

      window_indices = [] of Int32
      table.scan_typed_window(100_u64, 5) do |batch|
        batch_keys = batch.values_for("pk")
        rows = batch.tuple_rows_for("payload")
        rows.each_with_index do |row, offset|
          index = w97_consumer_index(batch_keys[offset])
          window_indices << index
          w97_consumer_assert_row(row, index)
        end
        nil
      end
      window_indices.should eq([100, 101, 102, 103, 104])

      sparse_indices = [] of Int32
      table.scan_typed_candidate_marks([[0_i32, 128_i32]]) do |batch|
        batch_keys = batch.values_for("pk")
        rows = batch.tuple_rows_for("payload")
        rows.each_with_index do |row, offset|
          index = w97_consumer_index(batch_keys[offset])
          sparse_indices << index
          w97_consumer_assert_row(row, index)
        end
        nil
      end
      sparse_indices.should eq([0, 1, 256])

      damaged_parent = File.tempname("crystal-click-w97-bool-lazy")
      Dir.mkdir(damaged_parent)
      begin
        damaged_part = w97_consumer_create_part(damaged_parent, keys, columns)
        w97_consumer_corrupt_final_bool_frame(damaged_part)
        damaged_reader = CrystalClick::WidePart.open_typed(damaged_part, "payload")
        early = damaged_reader.read_tuple_mark_range("payload", 0, 1)
        early.row_count.should eq(2)
        early.value_as("flag", 0, Bool).should be_false
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          damaged_reader.each_tuple_mark_range("payload", 0, damaged_reader.mark_count) do |data, _mark_index|
            data.row_count.should be > 0
            callbacks += 1
            nil
          end
        end
        callbacks.should eq(128)
        expect_raises(CrystalClick::CorruptPartError) do
          damaged_reader.read_tuple_mark_range("payload", 128, 1)
        end
      ensure
        FileUtils.rm_rf(damaged_parent)
      end

      catalog_root = File.tempname("crystal-click-w97-bool-catalog")
      Dir.mkdir(catalog_root)
      begin
        w97_consumer_catalog(catalog_root, keys, columns).should_not be_empty
        values = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]["payload"].values(max_tuple_cells: 2_000_u64)
        values.size.should eq(W97_CONSUMER_ROW_COUNT)
        values.each_with_index do |value, index|
          w97_consumer_assert_row(value.as(CrystalClick::WideTupleRow), index)
        end
      ensure
        FileUtils.rm_rf(catalog_root)
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.tuples_for("payload")
          nil
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
