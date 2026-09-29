require "./spec_helper"
require "file_utils"

private def w85_write_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w85_write_scalar(io : IO, value : T) : Nil forall T
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w85_u64_stream(values : Array(UInt64)) : Array(UInt8)
  io = IO::Memory.new
  values.each { |value| w85_write_u64(io, value) }
  io.to_slice.to_a
end

private def w85_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w85_writer_reader_roundtrip(
  label : String,
  key_a : K,
  key_b : K,
  low : T,
  high : T,
) : Nil forall K, T
  parent = File.tempname("crystal-click-w85-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 3_u64, 4_u64]
  empty_map = [] of Tuple(K, Array(T))
  entries = [{key_a, [] of T}, {key_a, [low, high]}, {key_b, [] of T}] of Tuple(K, Array(T))
  rows = [
    [] of Array(Tuple(K, Array(T))),
    [empty_map] of Array(Tuple(K, Array(T))),
    [entries] of Array(Tuple(K, Array(T))),
    [] of Array(Tuple(K, Array(T))),
  ] of Array(Array(Tuple(K, Array(T))))

  begin
    {% if K == UInt64 %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_numeric_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% elsif K == String %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_numeric_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      {% raise "W85 test supports only UInt64 and String keys" %}
    {% end %}

    reader = CrystalClick::WidePart.open_typed(destination, "payload")
    {% if K == UInt64 %}
      reader.read_array_map_uint64_array_numeric_mark_range("payload", 0, reader.mark_count, T).should eq(rows)
      reader.read_array_map_uint64_array_numeric_mark_range("payload", 1, 1, T).should eq(rows[2, 2])
    {% elsif K == String %}
      reader.read_array_map_string_array_numeric_mark_range("payload", 0, reader.mark_count, T).should eq(rows)
      reader.read_array_map_string_array_numeric_mark_range("payload", 1, 1, T).should eq(rows[2, 2])
    {% end %}
    reader.mark_row_counts.should eq([2_u64, 2_u64])
    reader.column_type.should eq("Array(Map(#{K}, Array(#{T})))")

    expected = {} of String => Array(UInt8)
    expected["payload.size0"] = w85_u64_stream([0_u64, 1_u64, 1_u64, 0_u64])
    expected["payload.size1"] = w85_u64_stream([0_u64, 3_u64])
    {% if K == UInt64 %}
      expected["payload%2Ekeys"] = w85_u64_stream([key_a, key_a, key_b])
    {% elsif K == String %}
      key_sizes = IO::Memory.new
      key_bytes = IO::Memory.new
      [key_a, key_a, key_b].each do |key|
        w85_write_u64(key_sizes, key.bytesize.to_u64)
        key_bytes.write(key.to_slice)
      end
      expected["payload%2Ekeys.size"] = key_sizes.to_slice.to_a
      expected["payload%2Ekeys"] = key_bytes.to_slice.to_a
    {% end %}
    expected["payload%2Evalues.size2"] = w85_u64_stream([0_u64, 2_u64, 0_u64])
    leaf = IO::Memory.new
    w85_write_scalar(leaf, low)
    w85_write_scalar(leaf, high)
    expected["payload%2Evalues"] = leaf.to_slice.to_a
    expected.each do |stream, raw|
      w85_raw_stream(destination, stream).should eq(raw)
    end
    substreams = File.read(File.join(destination, "columns_substreams.txt"))
    expected.keys.each { |stream| substreams.should contain("\t#{stream}\n") }
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W85 Array(Map(K, Array(N))) writer and reader" do
  it "round-trips all 20 primitive numeric combinations with exact raw leaf bytes" do
    binary_key = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])

    w85_writer_reader_roundtrip("u64-u8", 1_u64, 2_u64, 0_u8, UInt8::MAX)
    w85_writer_reader_roundtrip("u64-u16", 1_u64, 2_u64, 0_u16, UInt16::MAX)
    w85_writer_reader_roundtrip("u64-u32", 1_u64, 2_u64, 0_u32, UInt32::MAX)
    w85_writer_reader_roundtrip("u64-u64", 1_u64, 2_u64, 0_u64, UInt64::MAX)
    w85_writer_reader_roundtrip("u64-i8", 1_u64, 2_u64, Int8::MIN, Int8::MAX)
    w85_writer_reader_roundtrip("u64-i16", 1_u64, 2_u64, Int16::MIN, Int16::MAX)
    w85_writer_reader_roundtrip("u64-i32", 1_u64, 2_u64, Int32::MIN, Int32::MAX)
    w85_writer_reader_roundtrip("u64-i64", 1_u64, 2_u64, Int64::MIN, Int64::MAX)
    w85_writer_reader_roundtrip("u64-f32", 1_u64, 2_u64, -1.25_f32, 3.5_f32)
    w85_writer_reader_roundtrip("u64-f64", 1_u64, 2_u64, -1.25_f64, 3.5_f64)

    w85_writer_reader_roundtrip("string-u8", "dup", binary_key, 0_u8, UInt8::MAX)
    w85_writer_reader_roundtrip("string-u16", "dup", binary_key, 0_u16, UInt16::MAX)
    w85_writer_reader_roundtrip("string-u32", "dup", binary_key, 0_u32, UInt32::MAX)
    w85_writer_reader_roundtrip("string-u64", "dup", binary_key, 0_u64, UInt64::MAX)
    w85_writer_reader_roundtrip("string-i8", "dup", binary_key, Int8::MIN, Int8::MAX)
    w85_writer_reader_roundtrip("string-i16", "dup", binary_key, Int16::MIN, Int16::MAX)
    w85_writer_reader_roundtrip("string-i32", "dup", binary_key, Int32::MIN, Int32::MAX)
    w85_writer_reader_roundtrip("string-i64", "dup", binary_key, Int64::MIN, Int64::MAX)
    w85_writer_reader_roundtrip("string-f32", "dup", binary_key, -1.25_f32, 3.5_f32)
    w85_writer_reader_roundtrip("string-f64", "dup", binary_key, -1.25_f64, 3.5_f64)
  end
end
