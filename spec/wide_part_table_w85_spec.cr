require "./spec_helper"
require "file_utils"

private def w85_table_roundtrip(label : String, key_a : K, key_b : K, low : T, high : T) : Nil forall K, T
  parent = File.tempname("crystal-click-w85-table-#{label}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  empty_map = [] of Tuple(K, Array(T))
  entries = [{key_a, [] of T}, {key_a, [low, high]}, {key_b, [] of T}] of Tuple(K, Array(T))
  rows = [
    [] of Array(Tuple(K, Array(T))),
    [empty_map] of Array(Tuple(K, Array(T))),
    [entries] of Array(Tuple(K, Array(T))),
    [] of Array(Tuple(K, Array(T))),
    [[{key_b, [low]}] of Tuple(K, Array(T))] of Array(Tuple(K, Array(T))),
    [] of Array(Tuple(K, Array(T))),
  ] of Array(Array(Tuple(K, Array(T))))

  begin
    {% if K == UInt64 %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% elsif K == String %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}

    actual = [] of Array(Array(Tuple(K, Array(T))))
    callbacks = 0
    CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"]).scan_typed do |batch|
      callbacks += 1
      actual.concat(batch.array_map_array_leaf_values_for("payload", K, T).to_a)
    end
    callbacks.should eq(3)
    actual.should eq(rows)

    selected = [] of Array(Array(Tuple(K, Array(T))))
    CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"]).scan_typed_candidate_marks([[1]]) do |batch|
      selected.concat(batch.array_map_array_leaf_values_for("payload", K, T).to_a)
    end
    selected.should eq(rows[2, 2])

    corrupt_part = File.join(parent, "all_2_2_0")
    FileUtils.cp_r(part, corrupt_part)
    stream = "payload%2Evalues.size2"
    base = CrystalClick::StreamName.hash(stream)
    mark_path = File.join(corrupt_part, "#{base}.mrk2")
    marks = File.read(mark_path).to_slice.dup
    mark_offset = CrystalClick::WidePart::MARK_SIZE
    old_compressed_offset = w85_table_read_u64(marks, mark_offset)
    shifted_compressed_offset = old_compressed_offset + 1_u64
    shifted_compressed_offset.should be < File.size(File.join(corrupt_part, "#{base}.bin")).to_u64
    w85_table_write_u64(marks, mark_offset, shifted_compressed_offset)
    File.write(mark_path, marks)

    callbacks = 0
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePartTable.open_selected_typed([corrupt_part], ["pk", "payload"]).scan_typed_candidate_marks([[1]]) do |batch|
        callbacks += 1
        batch.array_map_array_leaf_values_for("payload", K, T)
      end
    end
    callbacks.should eq(0)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w85_table_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w85_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

describe "W85 typed table Array(Map(K, Array(N))) values" do
  it "materializes selected marks for all 20 key and primitive numeric combinations" do
    binary_key = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
    w85_table_roundtrip("u64-u8", 1_u64, 2_u64, 0_u8, UInt8::MAX)
    w85_table_roundtrip("u64-u16", 1_u64, 2_u64, 0_u16, UInt16::MAX)
    w85_table_roundtrip("u64-u32", 1_u64, 2_u64, 0_u32, UInt32::MAX)
    w85_table_roundtrip("u64-u64", 1_u64, 2_u64, 0_u64, UInt64::MAX)
    w85_table_roundtrip("u64-i8", 1_u64, 2_u64, Int8::MIN, Int8::MAX)
    w85_table_roundtrip("u64-i16", 1_u64, 2_u64, Int16::MIN, Int16::MAX)
    w85_table_roundtrip("u64-i32", 1_u64, 2_u64, Int32::MIN, Int32::MAX)
    w85_table_roundtrip("u64-i64", 1_u64, 2_u64, Int64::MIN, Int64::MAX)
    w85_table_roundtrip("u64-f32", 1_u64, 2_u64, -1.25_f32, 3.5_f32)
    w85_table_roundtrip("u64-f64", 1_u64, 2_u64, -1.25_f64, 3.5_f64)
    w85_table_roundtrip("string-u8", "dup", binary_key, 0_u8, UInt8::MAX)
    w85_table_roundtrip("string-u16", "dup", binary_key, 0_u16, UInt16::MAX)
    w85_table_roundtrip("string-u32", "dup", binary_key, 0_u32, UInt32::MAX)
    w85_table_roundtrip("string-u64", "dup", binary_key, 0_u64, UInt64::MAX)
    w85_table_roundtrip("string-i8", "dup", binary_key, Int8::MIN, Int8::MAX)
    w85_table_roundtrip("string-i16", "dup", binary_key, Int16::MIN, Int16::MAX)
    w85_table_roundtrip("string-i32", "dup", binary_key, Int32::MIN, Int32::MAX)
    w85_table_roundtrip("string-i64", "dup", binary_key, Int64::MIN, Int64::MAX)
    w85_table_roundtrip("string-f32", "dup", binary_key, -1.25_f32, 3.5_f32)
    w85_table_roundtrip("string-f64", "dup", binary_key, -1.25_f64, 3.5_f64)
  end
end
