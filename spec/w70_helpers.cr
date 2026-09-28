require "./spec_helper"
require "file_utils"

W70_KEYS   = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
W70_VALUES = [
  [
    {"dup", [nil, "", "a\0b", "café"] of String?},
    {"dup", ["tail"] of String?},
    {"dup", ["dup-third"] of String?},
  ] of Tuple(String, Array(String?)),
  [] of Tuple(String, Array(String?)),
  [{"empty_array", [] of String?}] of Tuple(String, Array(String?)),
  [
    {"x", ["x3"] of String?},
    {"x2", ["x2", "x2b"] of String?},
  ] of Tuple(String, Array(String?)),
  [
    {"later", [nil, nil] of String?},
    {"later2", [nil] of String?},
  ] of Tuple(String, Array(String?)),
  [{"later", [nil] of String?}] of Tuple(String, Array(String?)),
  [
    {"tail", ["after-null", ""] of String?},
    {"tail2", ["tail2"] of String?},
  ] of Tuple(String, Array(String?)),
] of Array(Tuple(String, Array(String?)))

W70_STREAMS = [
  "m.size0",
  "m%2Ekeys.size",
  "m%2Ekeys",
  "m%2Evalues.size1",
  "m%2Evalues.null",
  "m%2Evalues.size",
  "m%2Evalues",
]

def with_w70_part(& : String ->)
  parent = File.tempname("crystal-click-w70-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
      part,
      "id",
      W70_KEYS.to_unsafe.to_slice(W70_KEYS.size),
      "m",
      W70_VALUES.to_unsafe.to_slice(W70_VALUES.size),
      rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w70_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

def w70_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

def w70_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w70_mark_rows(path : String, stream : String) : Array(UInt64)
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W70 mark file has a partial record for #{stream}" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w70_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

def w70_mark_decompressed_offsets(path : String, stream : String) : Array(UInt64)
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W70 mark file has a partial record for #{stream}" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w70_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 8)
  end
end

def w70_ensure_terminal_mark(path : String, streams : Array(String)) : Nil
  streams.each do |stream|
    marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    rows = w70_mark_rows(path, stream)
    next if rows.last? == 0_u64

    data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
    terminal = Bytes.new(CrystalClick::WidePart::MARK_SIZE, 0_u8)
    w70_write_u64(terminal, 0, File.size(data_path).to_u64)
    File.open(marks_path, "ab") { |file| file.write(terminal) }
  end
end

def w70_shift_mark(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W70 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w70_read_u64(marks, offset)
  w70_write_u64(marks, offset, compressed_offset + 1_u64)
  File.write(marks_path, marks)
end

def w70_change_mark_rows(path : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W70 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  w70_write_u64(marks, offset + 16, rows)
  File.write(marks_path, marks)
end

# Rewrite one selected writer-fixture LZ4 frame without changing its length.
# The callback receives the entire raw block and the mark's decompressed offset.
def w70_rewrite_mark_frame(path : String, stream : String, mark_index : Int, & : Bytes, Int32 -> Nil) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W70 selected mark is missing for #{stream}" if mark_offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w70_read_u64(marks, mark_offset)
  decompressed_offset = w70_read_u64(marks, mark_offset + 8)

  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
  raw = frame.output.dup
  raise "W70 selected decompressed offset exceeds writer fixture frame" if decompressed_offset > raw.size.to_u64
  yield raw, decompressed_offset.to_i

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w70_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w70_write_u32(rewritten, header + 5, raw.size.to_u32)

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
  w70_write_u64(rewritten, 0, hash[0])
  w70_write_u64(rewritten, 8, hash[1])
  raise "W70 mutation changed frame size" unless rewritten.size.to_i64 == frame.end_offset - compressed_offset.to_i64
  rewritten.copy_to(encoded.to_unsafe + compressed_offset.to_i, rewritten.size)
  File.write(data_path, encoded)
end
