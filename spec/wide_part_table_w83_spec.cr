require "./spec_helper"
require "file_utils"

private alias W83TableUInt64BoolMap = Array(Tuple(UInt64, Bool))
private alias W83TableStringBoolMap = Array(Tuple(String, Bool))
private alias W83TableUInt64NullableBoolMap = Array(Tuple(UInt64, Bool?))
private alias W83TableStringNullableBoolMap = Array(Tuple(String, Bool?))

private def w83_table_write_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w83_table_set_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w83_table_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w83_table_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w83_table_literal_frame(raw : Bytes) : Bytes
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
  w83_table_write_u32(frame, header + 1, compressed_size.to_u32)
  w83_table_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w83_table_set_u64(frame, 0, checksum[0])
  w83_table_set_u64(frame, 8, checksum[1])
  frame
end

private def w83_table_write_combined_checksums(part : String, source_a : String, source_b : String, b_streams : Array(String)) : Nil
  entries = CrystalClick::PartChecksums.open(source_a).entries.dup
  b_names = b_streams.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end
  source_b_entries = CrystalClick::PartChecksums.open(source_b).entries
  b_names.each { |name| entries[name] = source_b_entries[name].not_nil! }

  payload = IO::Memory.new
  names = entries.keys.sort
  w83_table_write_var_uint(payload, names.size.to_u64)
  names.each do |name|
    entry = entries[name]
    w83_table_write_var_uint(payload, name.bytesize.to_u64)
    payload << name
    w83_table_write_var_uint(payload, entry.physical_size)
    w83_table_write_u64(payload, entry.file_hash[0])
    w83_table_write_u64(payload, entry.file_hash[1])
    if entry.compressed
      payload.write_byte(1_u8)
      w83_table_write_var_uint(payload, entry.uncompressed_size || raise("compressed checksum entry has no raw size"))
      w83_table_write_u64(payload, 0_u64)
      w83_table_write_u64(payload, 0_u64)
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w83_table_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w83_table_build_two_large_string_key_bool_columns(parent : String, large_key : String) : String
  source_a = File.join(parent, "source-a", "all_1_1_0")
  source_b = File.join(parent, "source-b", "all_1_1_0")
  destination = File.join(parent, "combined", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(source_a))
  FileUtils.mkdir_p(File.dirname(source_b))
  FileUtils.mkdir_p(File.dirname(destination))
  Dir.mkdir(destination)
  keys = [0_u64]
  map_values = [{large_key, true}] of Tuple(String, Bool)
  row_values = [map_values] of W83TableStringBoolMap
  values = [row_values] of Array(W83TableStringBoolMap)
  CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
    source_a, "pk", keys.to_unsafe.to_slice(keys.size), "payload_a", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
  )
  CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
    source_b, "pk", keys.to_unsafe.to_slice(keys.size), "payload_b", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
  )

  Dir.each_child(source_a) do |name|
    FileUtils.cp(File.join(source_a, name), File.join(destination, name)) unless name == "checksums.txt"
  end
  b_streams = ["payload_b.size0", "payload_b.size1", "payload_b%2Ekeys.size", "payload_b%2Ekeys", "payload_b%2Evalues"]
  b_streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["bin", "mrk2"].each do |extension|
      name = "#{base}.#{extension}"
      FileUtils.cp(File.join(source_b, name), File.join(destination, name))
    end
  end

  File.write(
    File.join(destination, "columns.txt"),
    "columns format version: 1\n3 columns:\n`pk` UInt64\n`payload_a` Array(Map(String, Bool))\n`payload_b` Array(Map(String, Bool))\n"
  )
  streams_a = ["payload_a.size0", "payload_a.size1", "payload_a%2Ekeys.size", "payload_a%2Ekeys", "payload_a%2Evalues"]
  substreams = IO::Memory.new
  substreams << "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n"
  [{"payload_a", streams_a}, {"payload_b", b_streams}].each do |column, streams|
    substreams << "#{streams.size} substreams for column `#{column}`:\n"
    streams.each { |stream| substreams << "\t#{stream}\n" }
  end
  File.write(File.join(destination, "columns_substreams.txt"), substreams.to_s)
  w83_table_write_combined_checksums(destination, source_a, source_b, b_streams)
  destination
end

describe "W83 typed table Array(Map) Bool-leaf batches" do
  it "materializes the four exact Bool and Nullable(Bool) shapes with typed accessors" do
    parent = File.tempname("crystal-click-w83-table-shapes")
    Dir.mkdir(parent)
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
    binary_key = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    u64_bools = [
      [] of W83TableUInt64BoolMap,
      [([] of Tuple(UInt64, Bool)), [{7_u64, false}, {7_u64, true}] of Tuple(UInt64, Bool)],
      [[{9_u64, true}] of Tuple(UInt64, Bool), [] of Tuple(UInt64, Bool)],
      [] of W83TableUInt64BoolMap,
      [[{UInt64::MAX, false}] of Tuple(UInt64, Bool), [] of Tuple(UInt64, Bool)],
    ] of Array(W83TableUInt64BoolMap)
    string_bools = [
      [] of W83TableStringBoolMap,
      [([] of Tuple(String, Bool)), [{"", false}, {binary_key, true}] of Tuple(String, Bool)],
      [[{binary_key, false}] of Tuple(String, Bool), [] of Tuple(String, Bool)],
      [] of W83TableStringBoolMap,
      [[{"dup", true}, {"dup", false}] of Tuple(String, Bool), [] of Tuple(String, Bool)],
    ] of Array(W83TableStringBoolMap)
    u64_nullable_bools = [
      [] of W83TableUInt64NullableBoolMap,
      [([] of Tuple(UInt64, Bool?)), [{7_u64, nil}, {7_u64, false}, {7_u64, true}] of Tuple(UInt64, Bool?)],
      [[{9_u64, nil}] of Tuple(UInt64, Bool?), [] of Tuple(UInt64, Bool?)],
      [] of W83TableUInt64NullableBoolMap,
      [[{UInt64::MAX, nil}, {0_u64, false}] of Tuple(UInt64, Bool?), [] of Tuple(UInt64, Bool?)],
    ] of Array(W83TableUInt64NullableBoolMap)
    string_nullable_bools = [
      [] of W83TableStringNullableBoolMap,
      [([] of Tuple(String, Bool?)), [{"", nil}, {binary_key, false}, {binary_key, true}] of Tuple(String, Bool?)],
      [[{binary_key, nil}] of Tuple(String, Bool?), [] of Tuple(String, Bool?)],
      [] of W83TableStringNullableBoolMap,
      [[{"dup", nil}, {"dup", false}] of Tuple(String, Bool?), [] of Tuple(String, Bool?)],
    ] of Array(W83TableStringNullableBoolMap)

    part_u64 = File.join(parent, "uint64-bool", "all_1_1_0")
    part_string = File.join(parent, "string-bool", "all_1_1_0")
    part_nullable_u64 = File.join(parent, "uint64-nullable-bool", "all_1_1_0")
    part_nullable_string = File.join(parent, "string-nullable-bool", "all_1_1_0")
    begin
      [part_u64, part_string, part_nullable_u64, part_nullable_string].each do |part|
        FileUtils.mkdir_p(File.dirname(part))
      end
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
        part_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_bools.to_unsafe.to_slice(u64_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
        part_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_bools.to_unsafe.to_slice(string_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        part_nullable_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_nullable_bools.to_unsafe.to_slice(u64_nullable_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(
        part_nullable_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_nullable_bools.to_unsafe.to_slice(string_nullable_bools.size), rows_per_mark: 2
      )

      actual_u64 = [] of Array(Array(Tuple(UInt64, Bool)))
      CrystalClick::WidePartTable.open_selected_typed([part_u64], ["pk", "payload"]).scan_typed(batch_rows: 1) do |batch|
        actual_u64.concat(batch.array_map_uint64_bools_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_map_string_bools_for("payload") }
      end
      actual_u64.should eq(u64_bools)

      actual_string = [] of Array(Array(Tuple(String, Bool)))
      CrystalClick::WidePartTable.open_selected_typed([part_string], ["pk", "payload"]).scan_typed do |batch|
        actual_string.concat(batch.array_map_string_bools_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_map_uint64_bools_for("payload") }
      end
      actual_string.should eq(string_bools)
      actual_string[1][1][1][0].to_slice.should eq(binary_key.to_slice)

      actual_nullable_u64 = [] of Array(Array(Tuple(UInt64, Bool?)))
      CrystalClick::WidePartTable.open_selected_typed([part_nullable_u64], ["pk", "payload"]).scan_typed do |batch|
        actual_nullable_u64.concat(batch.array_map_uint64_nullable_bools_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_map_uint64_bools_for("payload") }
      end
      actual_nullable_u64.should eq(u64_nullable_bools)
      actual_nullable_u64[1][1][0][1].should be_nil

      actual_nullable_string = [] of Array(Array(Tuple(String, Bool?)))
      CrystalClick::WidePartTable.open_selected_typed([part_nullable_string], ["pk", "payload"]).scan_typed do |batch|
        actual_nullable_string.concat(batch.array_map_string_nullable_bools_for("payload").to_a)
      end
      actual_nullable_string.should eq(string_nullable_bools)
      actual_nullable_string[1][1][1][0].to_slice.should eq(binary_key.to_slice)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "aggregates selected W83 leaf charges before callbacks" do
    parent = File.tempname("crystal-click-w83-table-aggregate")
    Dir.mkdir(parent)
    begin
      large_key = String.new(Bytes.new(34 * 1024 * 1024, 0x41_u8))
      part = w83_table_build_two_large_string_key_bool_columns(parent, large_key)
      limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      charge_a = CrystalClick::WidePart.open_typed(part, "payload_a").array_map_bool_leaf_mark_range_materialization_preflight("payload_a", 0, 1)[:charge_bytes]
      charge_b = CrystalClick::WidePart.open_typed(part, "payload_b").array_map_bool_leaf_mark_range_materialization_preflight("payload_b", 0, 1)[:charge_bytes]
      charge_a.should be < limit
      charge_b.should be < limit
      (charge_a + charge_b).should be > limit
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload_a", "payload_b"])
      callbacks = 0

      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[0]]) do |_batch|
          callbacks += 1
        end
      end
      error.message.should eq("selected W82/W83 Array(Map) leaf columns exceed aggregate materialization limit")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
