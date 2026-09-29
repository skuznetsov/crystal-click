require "./spec_helper"
require "file_utils"

private alias W84ReaderMapUInt64ArrayUInt64 = Array(Tuple(UInt64, Array(UInt64)))
private alias W84ReaderMapUInt64ArrayString = Array(Tuple(UInt64, Array(String)))
private alias W84ReaderMapStringArrayUInt64 = Array(Tuple(String, Array(UInt64)))
private alias W84ReaderMapStringArrayString = Array(Tuple(String, Array(String)))

private def w84_reader_temp_part(name : String) : Tuple(String, String)
  parent = File.tempname(name)
  Dir.mkdir(parent)
  {parent, File.join(parent, "part")}
end

private def w84_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w84_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w84_reader_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w84_reader_encode_literal_frame(raw : Bytes) : Bytes
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
  w84_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w84_reader_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w84_reader_write_u64(frame, 0, checksum[0])
  w84_reader_write_u64(frame, 8, checksum[1])
  frame
end

private def w84_reader_rewrite_u64_value(part : String, stream : String, mark_index : Int, value : UInt64) : Nil
  base = CrystalClick::StreamName.hash(stream)
  data_path = File.join(part, "#{base}.bin")
  mark_bytes = File.read(File.join(part, "#{base}.mrk2")).to_slice
  raise "W84 reader mark file is malformed" unless mark_bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  record_count = mark_bytes.size // CrystalClick::WidePart::MARK_SIZE
  raise "W84 reader selected mark has no following boundary" unless mark_index + 1 < record_count
  start_offset = w84_reader_read_u64(mark_bytes, mark_index * CrystalClick::WidePart::MARK_SIZE).to_i
  end_offset = w84_reader_read_u64(mark_bytes, (mark_index + 1) * CrystalClick::WidePart::MARK_SIZE).to_i
  encoded = File.read(data_path).to_slice.dup
  raise "W84 reader selected an empty frame" unless end_offset > start_offset
  frame = encoded[start_offset, end_offset - start_offset]
  raw = CrystalClick::CompressedBlock.decode_all(frame).dup
  raise "W84 reader expected one UInt64 count" unless raw.size == 8
  w84_reader_write_u64(raw, 0, value)
  replacement = w84_reader_encode_literal_frame(raw)
  raise "W84 reader replacement changed compressed frame size" unless replacement.size == frame.size
  replacement.copy_to(encoded[start_offset, replacement.size])
  File.write(data_path, encoded)
end

describe "W84 Array(Map(K, Array(V))) reader" do
  it "reads every exact pairing, including ranges where all child streams are empty" do
    parent, destination = w84_reader_temp_part("crystal-click-w84-empty-reader")
    keys = [1_u64, 2_u64]

    begin
      rows_uu = [
        [] of W84ReaderMapUInt64ArrayUInt64,
        [[] of Tuple(UInt64, Array(UInt64))] of W84ReaderMapUInt64ArrayUInt64,
      ] of Array(W84ReaderMapUInt64ArrayUInt64)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows_uu.to_unsafe.to_slice(rows_uu.size), rows_per_mark: 1
      )
      reader_uu = CrystalClick::WidePart.open_typed(destination, "payload")
      reader_uu.read_array_map_uint64_array_uint64_mark_range("payload", 0, 2).should eq(rows_uu)
      reader_uu.array_map_array_leaf_mark_range_materialization_preflight("payload", 0, 2)[:payload_bytes].should eq(0_u64)

      FileUtils.rm_rf(destination)
      rows_us = [
        [] of W84ReaderMapUInt64ArrayString,
        [[] of Tuple(UInt64, Array(String))] of W84ReaderMapUInt64ArrayString,
      ] of Array(W84ReaderMapUInt64ArrayString)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows_us.to_unsafe.to_slice(rows_us.size), rows_per_mark: 1
      )
      reader_us = CrystalClick::WidePart.open_typed(destination, "payload")
      reader_us.read_array_map_uint64_array_string_mark_range("payload", 0, 2).should eq(rows_us)
      reader_us.array_map_array_leaf_mark_range_materialization_preflight("payload", 0, 2)[:payload_bytes].should eq(0_u64)

      FileUtils.rm_rf(destination)
      rows_su = [
        [] of W84ReaderMapStringArrayUInt64,
        [[] of Tuple(String, Array(UInt64))] of W84ReaderMapStringArrayUInt64,
      ] of Array(W84ReaderMapStringArrayUInt64)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows_su.to_unsafe.to_slice(rows_su.size), rows_per_mark: 1
      )
      reader_su = CrystalClick::WidePart.open_typed(destination, "payload")
      reader_su.read_array_map_string_array_uint64_mark_range("payload", 0, 2).should eq(rows_su)
      reader_su.array_map_array_leaf_mark_range_materialization_preflight("payload", 0, 2)[:payload_bytes].should eq(0_u64)

      FileUtils.rm_rf(destination)
      rows_ss = [
        [] of W84ReaderMapStringArrayString,
        [[] of Tuple(String, Array(String))] of W84ReaderMapStringArrayString,
      ] of Array(W84ReaderMapStringArrayString)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows_ss.to_unsafe.to_slice(rows_ss.size), rows_per_mark: 1
      )
      reader_ss = CrystalClick::WidePart.open_typed(destination, "payload")
      reader_ss.read_array_map_string_array_string_mark_range("payload", 0, 2).should eq(rows_ss)
      reader_ss.array_map_array_leaf_mark_range_materialization_preflight("payload", 0, 2)[:payload_bytes].should eq(0_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a corrupt third-axis count before returning selected rows" do
    parent, destination = w84_reader_temp_part("crystal-click-w84-corrupt-size2")
    keys = [1_u64, 2_u64]
    rows = [
      [[{7_u64, [11_u64]}] of Tuple(UInt64, Array(UInt64))] of W84ReaderMapUInt64ArrayUInt64,
      [] of W84ReaderMapUInt64ArrayUInt64,
    ] of Array(W84ReaderMapUInt64ArrayUInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      w84_reader_rewrite_u64_value(destination, "payload%2Evalues.size2", 0, 2_u64)

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_array_map_uint64_array_uint64_mark_range("payload", 0, 2)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a legacy sibling column in the bounded W84 serializer inventory" do
    parent, destination = w84_reader_temp_part("crystal-click-w84-mixed-schema")
    keys = [1_u64]
    rows = [[] of W84ReaderMapUInt64ArrayUInt64]

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      columns_path = File.join(destination, "columns.txt")
      columns = File.read(columns_path)
      columns = columns.sub("2 columns:\n", "3 columns:\n") + "`legacy` String\n"
      File.write(columns_path, columns)

      expect_raises(CrystalClick::UnsupportedFormatError, /exact W84 payload columns/) do
        CrystalClick::WidePart.open_typed(destination, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires stock String serialization metadata even for numeric-only W84 payloads" do
    parent, destination = w84_reader_temp_part("crystal-click-w84-numeric-serialization")
    keys = [1_u64]
    rows = [[] of W84ReaderMapUInt64ArrayUInt64]

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      serialization_path = File.join(destination, "serialization.json")
      serialization = File.read(serialization_path)
      serialization.should contain(%("types_serialization_versions":{"string":1}))
      File.write(
        serialization_path,
        serialization.sub(%("types_serialization_versions":{"string":1}), %("types_serialization_versions":{}))
      )

      expect_raises(CrystalClick::UnsupportedFormatError, /W84 requires nested String serialization version 1/) do
        CrystalClick::WidePart.open_typed(destination, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
