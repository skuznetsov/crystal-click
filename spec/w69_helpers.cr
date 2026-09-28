require "./spec_helper"
require "file_utils"

W69_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W69_VALUES = [
  [] of Tuple(UInt64, Array(UInt64?)),
  [
    {7_u64, [nil, 0_u64] of UInt64?},
    {7_u64, [] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [{0_u64, [] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
  [
    {UInt64::MAX, [UInt64::MAX] of UInt64?},
    {0_u64, [0_u64] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [{9_u64, [nil, nil] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
  [
    {9_u64, [nil] of UInt64?},
    {9_u64, [nil] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [{UInt64::MAX, [7_u64] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
] of Array(Tuple(UInt64, Array(UInt64?)))

W69_STREAMS = [
  "payload.size0",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.null",
  "payload%2Evalues",
]

def with_w69_part(& : String ->)
  parent = File.tempname("crystal-click-w69-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
      part,
      "pk",
      W69_KEYS.to_unsafe.to_slice(W69_KEYS.size),
      "payload",
      W69_VALUES.to_unsafe.to_slice(W69_VALUES.size),
      rows_per_mark: 2
    )
    w69_ensure_terminal_mark(part, W69_STREAMS)
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w69_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

def w69_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

def w69_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w69_mark_rows(path : String, stream : String) : Array(UInt64)
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W69 mark file has a partial record for #{stream}" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w69_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

def w69_mark_decompressed_offsets(path : String, stream : String) : Array(UInt64)
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W69 mark file has a partial record for #{stream}" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w69_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 8)
  end
end

def w69_ensure_terminal_mark(path : String, streams : Array(String)) : Nil
  streams.each do |stream|
    marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    rows = w69_mark_rows(path, stream)
    next if rows.last? == 0_u64

    data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
    terminal = Bytes.new(CrystalClick::WidePart::MARK_SIZE, 0_u8)
    w69_write_u64(terminal, 0, File.size(data_path).to_u64)
    File.open(marks_path, "ab") { |file| file.write(terminal) }
  end
end

def w69_shift_mark(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W69 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[offset + byte].to_u64 << (byte * 8) }
  w69_write_u64(marks, offset, compressed_offset + 1_u64)
  File.write(marks_path, marks)
end

def w69_change_mark_rows(path : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W69 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  w69_write_u64(marks, offset + 16, rows)
  File.write(marks_path, marks)
end

# Rewrite one selected writer-fixture LZ4 frame as a literal-only frame and
# refresh its CityHash checksum. The fixture writer emits one frame per mark;
# callers still address the mark's decompressed offset explicitly so this
# helper cannot silently mutate the first slot of a future shared frame.
def w69_rewrite_mark_frame(path : String, stream : String, mark_index : Int, & : Bytes, Int32 -> Nil) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W69 selected mark is missing for #{stream}" if mark_offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[mark_offset + byte].to_u64 << (byte * 8) }
  decompressed_offset = 0_u64
  8.times { |byte| decompressed_offset |= marks[mark_offset + 8 + byte].to_u64 << (byte * 8) }

  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
  raw = frame.output.dup
  raise "W69 selected decompressed offset exceeds writer fixture frame" if decompressed_offset > raw.size.to_u64
  yield raw, decompressed_offset.to_i

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w69_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w69_write_u32(rewritten, header + 5, raw.size.to_u32)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    rewritten[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    rewritten[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      rewritten[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    rewritten[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(rewritten.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(rewritten[header, compressed_size])
  w69_write_u64(rewritten, 0, hash[0])
  w69_write_u64(rewritten, 8, hash[1])
  raise "W69 mutation changed frame size" unless rewritten.size.to_i64 == frame.end_offset - compressed_offset.to_i64
  rewritten.copy_to(encoded.to_unsafe + compressed_offset.to_i, rewritten.size)
  File.write(data_path, encoded)
end

def w69_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "90522051-914f-477f-9ea8-d3c2e18a3fd1"
  table_uuid = "44952915-7c0b-46c8-b70c-22691cdaea59"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Map(UInt64, Array(Nullable(UInt64))))\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end
