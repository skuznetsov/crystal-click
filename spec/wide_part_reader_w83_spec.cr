require "./spec_helper"
require "file_utils"

private alias W83ReaderUInt64BoolMap = Array(Tuple(UInt64, Bool))
private alias W83ReaderUInt64NullableBoolMap = Array(Tuple(UInt64, Bool?))

private def w83_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w83_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w83_reader_encode_literal_frame(raw : Bytes) : Bytes
  token_and_literals = IO::Memory.new
  if raw.size < 15
    token_and_literals.write_byte((raw.size << 4).to_u8)
  else
    token_and_literals.write_byte(0xf0_u8)
    remaining = raw.size - 15
    while remaining >= 255
      token_and_literals.write_byte(255_u8)
      remaining -= 255
    end
    token_and_literals.write_byte(remaining.to_u8)
  end
  token_and_literals.write(raw)
  payload = token_and_literals.to_slice
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w83_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w83_reader_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w83_reader_write_u64(frame, 0, checksum[0])
  w83_reader_write_u64(frame, 8, checksum[1])
  frame
end

private def w83_reader_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w83_reader_rewrite_mark_byte(part : String, stream : String, mark_index : Int, value : UInt8) : Nil
  base = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{base}.bin")
  mark_bytes = File.read(File.join(part, "#{base}.mrk2")).to_slice
  raise "W83 reader test mark file is malformed" unless mark_bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  record_count = mark_bytes.size // CrystalClick::WidePart::MARK_SIZE
  raise "W83 reader test mark has no following boundary" unless mark_index + 1 < record_count
  start_offset = w83_reader_read_u64(mark_bytes, mark_index * CrystalClick::WidePart::MARK_SIZE).to_i
  end_offset = w83_reader_read_u64(mark_bytes, (mark_index + 1) * CrystalClick::WidePart::MARK_SIZE).to_i
  encoded = File.read(data_path).to_slice.dup
  raise "W83 reader test selected an empty frame" unless end_offset > start_offset
  frame = encoded[start_offset, end_offset - start_offset]
  raw = CrystalClick::CompressedBlock.decode_all(frame)
  raise "W83 reader test expected one Bool byte" unless raw.size == 1
  replacement = w83_reader_encode_literal_frame(Bytes[value])
  raise "W83 reader test replacement changed compressed frame size" unless replacement.size == frame.size
  replacement.copy_to(encoded[start_offset, replacement.size])
  File.write(data_path, encoded)
end

private def w83_reader_write_u64_bool_part(path : String) : Array(Array(Array(Tuple(UInt64, Bool))))
  keys = [0_u64, 1_u64]
  values = [
    [[{10_u64, false}] of Tuple(UInt64, Bool)] of W83ReaderUInt64BoolMap,
    [[{11_u64, true}] of Tuple(UInt64, Bool)] of W83ReaderUInt64BoolMap,
  ] of Array(W83ReaderUInt64BoolMap)
  CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
    path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
  )
  values
end

describe "W83 Array(Map) Bool leaf reader semantics" do
  it "decodes a noncanonical non-null Bool byte before the selected-mark callback" do
    parent = File.tempname("crystal-click-w83-reader-noncanonical-bool")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    begin
      values = w83_reader_write_u64_bool_part(part_path)
      w83_reader_rewrite_mark_byte(part_path, "payload%2Evalues", 0, 2_u8)
      expected = values.dup
      expected[0][0][0] = {10_u64, true}

      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.read_array_map_uint64_bool_mark_range("payload", 0, part.mark_count).should eq(expected)

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "payload"])
      callbacks = 0
      observed = [] of Array(Array(Tuple(UInt64, Bool)))
      table.scan_typed_candidate_marks([[0]]) do |batch|
        callbacks += 1
        observed.concat(batch.array_map_uint64_bools_for("payload").to_a)
      end
      callbacks.should eq(1)
      observed.should eq(expected[0, 1])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a corrupt selected Bool value frame before the callback" do
    parent = File.tempname("crystal-click-w83-reader-corrupt-bool-frame")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    begin
      w83_reader_write_u64_bool_part(part_path)
      data_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Evalues")}.bin")
      encoded = File.read(data_path).to_slice.dup
      encoded[CrystalClick::CompressedBlock::CHECKSUM_SIZE].should eq(CrystalClick::CompressedBlock::METHOD_LZ4)
      encoded.size.should be > CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
      4.times { |index| encoded[CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1 + index] = 0_u8 }
      File.write(data_path, encoded)

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      (error.message || "").should contain("compressed frame size is invalid")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves NULL for a noncanonical nested Bool byte hidden beneath NULL" do
    parent = File.tempname("crystal-click-w83-reader-null-hidden-bool")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [0_u64, 1_u64]
    values = [
      [[{10_u64, nil}] of Tuple(UInt64, Bool?)] of W83ReaderUInt64NullableBoolMap,
      [[{11_u64, false}] of Tuple(UInt64, Bool?)] of W83ReaderUInt64NullableBoolMap,
    ] of Array(W83ReaderUInt64NullableBoolMap)
    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
      )
      w83_reader_rewrite_mark_byte(part_path, "payload%2Evalues", 0, 2_u8)

      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.read_array_map_uint64_nullable_bool_mark_range("payload", 0, part.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
