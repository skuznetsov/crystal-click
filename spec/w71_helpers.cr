require "./spec_helper"
require "file_utils"

W71_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W71_VALUES = [
  [
    {7_u64, [nil, "", "a\0b"] of String?},
    {7_u64, ["café", "abc"] of String?},
    {7_u64, ["after-null"] of String?},
  ] of Tuple(UInt64, Array(String?)),
  [] of Tuple(UInt64, Array(String?)),
  [{0_u64, [nil, "abc", "wxyz"] of String?}] of Tuple(UInt64, Array(String?)),
  [
    {UInt64::MAX, [] of String?},
    {UInt64::MAX, [] of String?},
  ] of Tuple(UInt64, Array(String?)),
  [
    {UInt64::MAX, [nil, nil] of String?},
    {UInt64::MAX, [nil, nil] of String?},
  ] of Tuple(UInt64, Array(String?)),
  [{9_u64, [] of String?}] of Tuple(UInt64, Array(String?)),
  [
    {9_u64, [nil, "after-null"] of String?},
    {10_u64, ["tail2"] of String?},
  ] of Tuple(UInt64, Array(String?)),
] of Array(Tuple(UInt64, Array(String?)))

W71_STREAMS = [
  "payload.size0",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.null",
  "payload%2Evalues.size",
  "payload%2Evalues",
]

def with_w71_part(& : String ->)
  parent = File.tempname("crystal-click-w71-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_string_pair(
      part,
      "pk",
      W71_KEYS.to_unsafe.to_slice(W71_KEYS.size),
      "payload",
      W71_VALUES.to_unsafe.to_slice(W71_VALUES.size),
      rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w71_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

def w71_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

def w71_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w71_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

def w71_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w71_raw_stream(path, stream)
  raise "W71 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    w71_read_u64(bytes.to_unsafe.to_slice(bytes.size), index * 8)
  end
end

def w71_mark_rows(path : String, stream : String) : Array(UInt64)
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W71 mark file has a partial record for #{stream}" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w71_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

def w71_rewrite_mark_frame(path : String, stream : String, mark_index : Int, & : Bytes, Int32 -> Nil) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W71 selected mark is missing for #{stream}" if mark_offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w71_read_u64(marks, mark_offset)
  decompressed_offset = w71_read_u64(marks, mark_offset + 8)

  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
  raw = frame.output.dup
  raise "W71 selected decompressed offset exceeds writer fixture frame" if decompressed_offset > raw.size.to_u64
  yield raw, decompressed_offset.to_i

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w71_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w71_write_u32(rewritten, header + 5, raw.size.to_u32)

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
  w71_write_u64(rewritten, 0, hash[0])
  w71_write_u64(rewritten, 8, hash[1])
  raise "W71 mutation changed frame size" unless rewritten.size.to_i64 == frame.end_offset - compressed_offset.to_i64
  rewritten.copy_to(encoded.to_unsafe + compressed_offset.to_i, rewritten.size)
  File.write(data_path, encoded)
end

def w71_shift_mark(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W71 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  w71_write_u64(marks, offset, w71_read_u64(marks, offset) + 1_u64)
  File.write(marks_path, marks)
end

def w71_change_mark_rows(path : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W71 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  w71_write_u64(marks, offset + 16, rows)
  File.write(marks_path, marks)
end

def w71_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "4588bba4-f5fc-4d69-b307-a293ce4422dc"
  table_uuid = "a18fcaac-84dc-476e-9eaa-9fddeabcb349"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Map(UInt64, Array(Nullable(String))))\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end
