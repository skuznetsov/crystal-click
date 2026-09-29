require "./spec_helper"
require "./w69_helpers"
require "file_utils"

private alias W82TableU64StringMap = Array(Tuple(UInt64, String))
private alias W82TableStringStringMap = Array(Tuple(String, String))
private alias W82TableU64NullableStringMap = Array(Tuple(UInt64, String?))
private alias W82TableStringNullableStringMap = Array(Tuple(String, String?))
private alias W82TableU64StringArray = Array(Array(Tuple(UInt64, String)))

private def w82_table_write_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w82_table_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w82_table_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w82_table_literal_frame(raw : Bytes) : Bytes
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
  w82_table_write_u32(frame, header + 1, compressed_size.to_u32)
  w82_table_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  8.times { |byte| frame[byte] = ((checksum[0] >> (byte * 8)) & 0xff_u64).to_u8 }
  8.times { |byte| frame[8 + byte] = ((checksum[1] >> (byte * 8)) & 0xff_u64).to_u8 }
  frame
end

private def w82_table_write_combined_checksums(part : String, source_a : String, source_b : String, b_streams : Array(String)) : Nil
  entries = CrystalClick::PartChecksums.open(source_a).entries.dup
  b_names = b_streams.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end
  source_b_entries = CrystalClick::PartChecksums.open(source_b).entries
  b_names.each { |name| entries[name] = source_b_entries[name].not_nil! }

  payload = IO::Memory.new
  names = entries.keys.sort
  w82_table_write_var_uint(payload, names.size.to_u64)
  names.each do |name|
    entry = entries[name]
    w82_table_write_var_uint(payload, name.bytesize.to_u64)
    payload << name
    w82_table_write_var_uint(payload, entry.physical_size)
    w82_table_write_u64(payload, entry.file_hash[0])
    w82_table_write_u64(payload, entry.file_hash[1])
    if entry.compressed
      payload.write_byte(1_u8)
      w82_table_write_var_uint(payload, entry.uncompressed_size || raise("compressed checksum entry has no raw size"))
      w82_table_write_u64(payload, 0_u64)
      w82_table_write_u64(payload, 0_u64)
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w82_table_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w82_table_build_two_string_map_columns(parent : String, large_value : String) : String
  source_a = File.join(parent, "source-a", "all_1_1_0")
  source_b = File.join(parent, "source-b", "all_1_1_0")
  destination = File.join(parent, "combined", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(source_a))
  FileUtils.mkdir_p(File.dirname(source_b))
  FileUtils.mkdir_p(File.dirname(destination))
  Dir.mkdir(destination)
  keys = [1_u64, 2_u64]
  values = [
    [] of W82TableU64StringMap,
    [[{1_u64, large_value}] of Tuple(UInt64, String)],
  ] of W82TableU64StringArray
  value_slice = values.to_unsafe.to_slice(values.size)
  CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
    source_a, "pk", keys.to_unsafe.to_slice(keys.size), "payload_a", value_slice, rows_per_mark: 1
  )
  CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
    source_b, "pk", keys.to_unsafe.to_slice(keys.size), "payload_b", value_slice, rows_per_mark: 1
  )

  Dir.each_child(source_a) do |name|
    FileUtils.cp(File.join(source_a, name), File.join(destination, name)) unless name == "checksums.txt"
  end
  b_streams = ["payload_b.size0", "payload_b.size1", "payload_b%2Ekeys", "payload_b%2Evalues.size", "payload_b%2Evalues"]
  b_streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["bin", "mrk2"].each do |extension|
      name = "#{base}.#{extension}"
      FileUtils.cp(File.join(source_b, name), File.join(destination, name))
    end
  end

  File.write(File.join(destination, "columns.txt"),
    "columns format version: 1\n3 columns:\n`pk` UInt64\n`payload_a` Array(Map(UInt64, String))\n`payload_b` Array(Map(UInt64, String))\n")
  streams_a = ["payload_a.size0", "payload_a.size1", "payload_a%2Ekeys", "payload_a%2Evalues.size", "payload_a%2Evalues"]
  substreams = IO::Memory.new
  substreams << "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n"
  [{"payload_a", streams_a}, {"payload_b", b_streams}].each do |column, streams|
    substreams << "#{streams.size} substreams for column `#{column}`:\n"
    streams.each { |stream| substreams << "\t#{stream}\n" }
  end
  File.write(File.join(destination, "columns_substreams.txt"), substreams.to_s)
  w82_table_write_combined_checksums(destination, source_a, source_b, b_streams)
  destination
end

private def with_w82_u64_nullable_table_part(& : String, Array(Array(Array(Tuple(UInt64, String?)))) ->)
  parent = File.tempname("crystal-click-w82-table")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  binary = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
  values = [
    [] of W82TableU64NullableStringMap,
    [([] of Tuple(UInt64, String?)), ([] of Tuple(UInt64, String?))],
    [[{9_u64, binary}] of Tuple(UInt64, String?), [] of Tuple(UInt64, String?)],
    [] of W82TableU64NullableStringMap,
    [[{UInt64::MAX, nil}, {0_u64, ""}] of Tuple(UInt64, String?)],
  ] of Array(W82TableU64NullableStringMap)
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_string_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
    yield part, values
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W82 typed table Array(Map) String-leaf batches" do
  it "materializes all four exact shapes, keeps binary and nullable values, and checks accessor types" do
    parent = File.tempname("crystal-click-w82-table-shapes")
    Dir.mkdir(parent)
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
    binary_key = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    binary_value = String.new(Bytes[0_u8, 0xfd_u8, 0x82_u8])
    u64_strings = [
      [] of W82TableU64StringMap,
      [([] of Tuple(UInt64, String)), [{7_u64, ""}, {7_u64, binary_value}] of Tuple(UInt64, String)],
      [[{9_u64, binary_value}] of Tuple(UInt64, String), [] of Tuple(UInt64, String)],
      [] of W82TableU64StringMap,
      [[{UInt64::MAX, ""}] of Tuple(UInt64, String)],
    ] of Array(W82TableU64StringMap)
    string_strings = [
      [] of W82TableStringStringMap,
      [([] of Tuple(String, String)), [{"dup", ""}, {"dup", binary_value}] of Tuple(String, String)],
      [[{binary_key, binary_value}] of Tuple(String, String), [] of Tuple(String, String)],
      [] of W82TableStringStringMap,
      [[{"", ""}] of Tuple(String, String)],
    ] of Array(W82TableStringStringMap)
    u64_nullable = [
      [] of W82TableU64NullableStringMap,
      [([] of Tuple(UInt64, String?)), [{7_u64, ""}, {7_u64, binary_value}] of Tuple(UInt64, String?)],
      [[{9_u64, binary_value}] of Tuple(UInt64, String?), [] of Tuple(UInt64, String?)],
      [] of W82TableU64NullableStringMap,
      [[{UInt64::MAX, nil}, {0_u64, ""}] of Tuple(UInt64, String?)],
    ] of Array(W82TableU64NullableStringMap)
    string_nullable = [
      [] of W82TableStringNullableStringMap,
      [([] of Tuple(String, String?)), [{"dup", ""}, {"dup", binary_value}] of Tuple(String, String?)],
      [[{binary_key, binary_value}] of Tuple(String, String?), [] of Tuple(String, String?)],
      [] of W82TableStringNullableStringMap,
      [[{"", nil}, {"tail", ""}] of Tuple(String, String?)],
    ] of Array(W82TableStringNullableStringMap)

    begin
      part_u64 = File.join(parent, "u64", "all_1_1_0")
      part_string = File.join(parent, "string", "all_1_1_0")
      part_nullable_u64 = File.join(parent, "nullable-u64", "all_1_1_0")
      part_nullable_string = File.join(parent, "nullable-string", "all_1_1_0")
      [part_u64, part_string, part_nullable_u64, part_nullable_string].each do |part|
        FileUtils.mkdir_p(File.dirname(part))
      end
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
        part_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_strings.to_unsafe.to_slice(u64_strings.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_string_pair(
        part_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_strings.to_unsafe.to_slice(string_strings.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_string_pair(
        part_nullable_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_nullable.to_unsafe.to_slice(u64_nullable.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_string_pair(
        part_nullable_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_nullable.to_unsafe.to_slice(string_nullable.size), rows_per_mark: 2
      )

      actual_u64 = [] of Array(Array(Tuple(UInt64, String)))
      CrystalClick::WidePartTable.open_selected_typed([part_u64], ["pk", "payload"]).scan_typed(batch_rows: 1) do |batch|
        actual_u64.concat(batch.array_map_uint64_strings_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_map_string_strings_for("payload") }
      end
      actual_u64.should eq(u64_strings)
      actual_u64[1][1][1][1].to_slice.should eq(binary_value.to_slice)

      actual_string = [] of Array(Array(Tuple(String, String)))
      CrystalClick::WidePartTable.open_selected_typed([part_string], ["pk", "payload"]).scan_typed do |batch|
        actual_string.concat(batch.array_map_string_strings_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_map_uint64_strings_for("payload") }
      end
      actual_string.should eq(string_strings)
      string_strings[2][0][0][0].to_slice.should eq(binary_key.to_slice)

      actual_nullable_u64 = [] of Array(Array(Tuple(UInt64, String?)))
      CrystalClick::WidePartTable.open_selected_typed([part_nullable_u64], ["pk", "payload"]).scan_typed do |batch|
        actual_nullable_u64.concat(batch.array_map_uint64_nullable_strings_for("payload").to_a)
      end
      actual_nullable_u64.should eq(u64_nullable)
      u64_nullable[4][0][0][1].should be_nil
      u64_nullable[4][0][1][1].should eq("")

      actual_nullable_string = [] of Array(Array(Tuple(String, String?)))
      CrystalClick::WidePartTable.open_selected_typed([part_nullable_string], ["pk", "payload"]).scan_typed do |batch|
        actual_nullable_string.concat(batch.array_map_string_nullable_strings_for("payload").to_a)
      end
      actual_nullable_string.should eq(string_nullable)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights the second selected mark before the first callback" do
    with_w82_u64_nullable_table_part do |part, expected|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callbacks = 0
      seen = [] of Array(Array(Tuple(UInt64, String?)))
      table.scan_typed_candidate_marks([[0, 1]]) do |batch|
        callbacks += 1
        seen.concat(batch.array_map_uint64_nullable_strings_for("payload").to_a)
      end
      callbacks.should eq(2)
      seen.should eq(expected[0, 4])
    end

    ["payload%2Evalues.size", "payload%2Evalues.null"].each do |stream|
      with_w82_u64_nullable_table_part do |part, _expected|
        w69_shift_mark(part, stream, 1)
        corrupted_table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          corrupted_table.scan_typed_candidate_marks([[0, 1]]) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    end
  end

  it "aggregates later-mark charges across selected W82 columns before any callback" do
    parent = File.tempname("crystal-click-w82-table-aggregate")
    Dir.mkdir(parent)
    begin
      large_value = String.new(Bytes.new(34 * 1024 * 1024, 0x41_u8))
      part = w82_table_build_two_string_map_columns(parent, large_value)
      limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      charge_a = CrystalClick::WidePart.open_typed(part, "payload_a").array_map_string_leaf_mark_range_materialization_preflight("payload_a", 1, 1)[:charge_bytes]
      charge_b = CrystalClick::WidePart.open_typed(part, "payload_b").array_map_string_leaf_mark_range_materialization_preflight("payload_b", 1, 1)[:charge_bytes]
      charge_a.should be < limit
      charge_b.should be < limit
      (charge_a + charge_b).should be > limit
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload_a", "payload_b"])
      callbacks = 0

      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[0, 1]]) do |_batch|
          callbacks += 1
        end
      end
      error.message.should eq("selected W82 Array(Map) columns exceed aggregate materialization limit")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
