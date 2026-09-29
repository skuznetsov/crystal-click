require "./spec_helper"
require "file_utils"

private alias W84TableU64ArrayU64Map = Array(Tuple(UInt64, Array(UInt64)))
private alias W84TableU64ArrayStringMap = Array(Tuple(UInt64, Array(String)))
private alias W84TableStringArrayU64Map = Array(Tuple(String, Array(UInt64)))
private alias W84TableStringArrayStringMap = Array(Tuple(String, Array(String)))

private def w84_table_write_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w84_table_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w84_table_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w84_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w84_table_literal_frame(raw : Bytes) : Bytes
  literals = IO::Memory.new
  if raw.size < 15
    literals.write_byte((raw.size << 4).to_u8)
  else
    literals.write_byte(0xf0_u8)
    remaining = raw.size - 15
    while remaining >= 255
      literals.write_byte(255_u8)
      remaining -= 255
    end
    literals.write_byte(remaining.to_u8)
  end
  literals.write(raw)
  payload = literals.to_slice
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w84_table_write_u32(frame, header + 1, compressed_size.to_u32)
  w84_table_write_u32(frame, header + 5, raw.size.to_u32)
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  8.times { |byte| frame[byte] = ((checksum[0] >> (byte * 8)) & 0xff_u64).to_u8 }
  8.times { |byte| frame[8 + byte] = ((checksum[1] >> (byte * 8)) & 0xff_u64).to_u8 }
  frame
end

private def w84_table_write_combined_checksums(part : String, source_a : String, source_b : String, b_streams : Array(String)) : Nil
  entries = CrystalClick::PartChecksums.open(source_a).entries.dup
  b_names = b_streams.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end
  source_b_entries = CrystalClick::PartChecksums.open(source_b).entries
  b_names.each { |name| entries[name] = source_b_entries[name].not_nil! }

  payload = IO::Memory.new
  names = entries.keys.sort
  w84_table_write_var_uint(payload, names.size.to_u64)
  names.each do |name|
    entry = entries[name]
    w84_table_write_var_uint(payload, name.bytesize.to_u64)
    payload << name
    w84_table_write_var_uint(payload, entry.physical_size)
    w84_table_write_u64(payload, entry.file_hash[0])
    w84_table_write_u64(payload, entry.file_hash[1])
    if entry.compressed
      payload.write_byte(1_u8)
      w84_table_write_var_uint(payload, entry.uncompressed_size || raise("compressed checksum entry has no raw size"))
      w84_table_write_u64(payload, 0_u64)
      w84_table_write_u64(payload, 0_u64)
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w84_table_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w84_table_build_two_string_key_columns(parent : String, large_key : String) : String
  source_a = File.join(parent, "source-a", "all_1_1_0")
  source_b = File.join(parent, "source-b", "all_1_1_0")
  destination = File.join(parent, "combined", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(source_a))
  FileUtils.mkdir_p(File.dirname(source_b))
  FileUtils.mkdir_p(File.dirname(destination))
  Dir.mkdir(destination)
  keys = [0_u64, 1_u64]
  rows = [
    [] of W84TableStringArrayU64Map,
    [[{large_key, [7_u64]}] of Tuple(String, Array(UInt64))] of W84TableStringArrayU64Map,
  ] of Array(W84TableStringArrayU64Map)
  row_slice = rows.to_unsafe.to_slice(rows.size)
  CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
    source_a, "pk", keys.to_unsafe.to_slice(keys.size), "payload_a", row_slice, rows_per_mark: 1
  )
  CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
    source_b, "pk", keys.to_unsafe.to_slice(keys.size), "payload_b", row_slice, rows_per_mark: 1
  )

  Dir.each_child(source_a) do |name|
    FileUtils.cp(File.join(source_a, name), File.join(destination, name)) unless name == "checksums.txt"
  end
  b_streams = [
    "payload_b.size0", "payload_b.size1", "payload_b%2Ekeys.size", "payload_b%2Ekeys",
    "payload_b%2Evalues.size2", "payload_b%2Evalues",
  ]
  b_streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["bin", "mrk2"].each do |extension|
      name = "#{base}.#{extension}"
      FileUtils.cp(File.join(source_b, name), File.join(destination, name))
    end
  end

  type = "Array(Map(String, Array(UInt64)))"
  File.write(
    File.join(destination, "columns.txt"),
    "columns format version: 1\n3 columns:\n`pk` UInt64\n`payload_a` #{type}\n`payload_b` #{type}\n"
  )
  streams_a = [
    "payload_a.size0", "payload_a.size1", "payload_a%2Ekeys.size", "payload_a%2Ekeys",
    "payload_a%2Evalues.size2", "payload_a%2Evalues",
  ]
  substreams = IO::Memory.new
  substreams << "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n"
  [{"payload_a", streams_a}, {"payload_b", b_streams}].each do |column, streams|
    substreams << "#{streams.size} substreams for column `#{column}`:\n"
    streams.each { |stream| substreams << "\t#{stream}\n" }
  end
  File.write(File.join(destination, "columns_substreams.txt"), substreams.to_s)
  w84_table_write_combined_checksums(destination, source_a, source_b, b_streams)
  destination
end

describe "W84 typed table Array(Map(K, Array(V))) batches" do
  it "projects all four exact key/leaf combinations with an exact typed accessor" do
    parent = File.tempname("crystal-click-w84-table-shapes")
    Dir.mkdir(parent)
    keys = [0_u64, 1_u64, 2_u64]
    begin
      part_uu = File.join(parent, "uu", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part_uu))
      uu = [
        [] of W84TableU64ArrayU64Map,
        [[{7_u64, [] of UInt64}, {7_u64, [11_u64, 12_u64]}] of Tuple(UInt64, Array(UInt64))] of W84TableU64ArrayU64Map,
        [] of W84TableU64ArrayU64Map,
      ] of Array(W84TableU64ArrayU64Map)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        part_uu, "pk", keys.to_unsafe.to_slice(keys.size), "payload", uu.to_unsafe.to_slice(uu.size), rows_per_mark: 2
      )
      actual_uu = [] of Array(Array(Tuple(UInt64, Array(UInt64))))
      CrystalClick::WidePartTable.open_selected_typed([part_uu], ["pk", "payload"]).scan_typed do |batch|
        actual_uu.concat(batch.array_map_array_leaf_values_for("payload", UInt64, UInt64).to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.array_map_array_leaf_values_for("payload", String, UInt64)
        end
      end
      actual_uu.should eq(uu)

      part_us = File.join(parent, "us", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part_us))
      binary = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
      us = [
        [] of W84TableU64ArrayStringMap,
        [[{7_u64, [] of String}, {7_u64, ["", binary]}] of Tuple(UInt64, Array(String))] of W84TableU64ArrayStringMap,
        [] of W84TableU64ArrayStringMap,
      ] of Array(W84TableU64ArrayStringMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_string_pair(
        part_us, "pk", keys.to_unsafe.to_slice(keys.size), "payload", us.to_unsafe.to_slice(us.size), rows_per_mark: 2
      )
      actual_us = [] of Array(Array(Tuple(UInt64, Array(String))))
      CrystalClick::WidePartTable.open_selected_typed([part_us], ["pk", "payload"]).scan_typed do |batch|
        actual_us.concat(batch.array_map_array_leaf_values_for("payload", UInt64, String).to_a)
      end
      actual_us.should eq(us)
      actual_us[1][0][1][1][1].to_slice.should eq(binary.to_slice)

      part_su = File.join(parent, "su", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part_su))
      binary_key = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
      su = [
        [] of W84TableStringArrayU64Map,
        [[{"dup", [] of UInt64}, {binary_key, [13_u64]}] of Tuple(String, Array(UInt64))] of W84TableStringArrayU64Map,
        [] of W84TableStringArrayU64Map,
      ] of Array(W84TableStringArrayU64Map)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
        part_su, "pk", keys.to_unsafe.to_slice(keys.size), "payload", su.to_unsafe.to_slice(su.size), rows_per_mark: 2
      )
      actual_su = [] of Array(Array(Tuple(String, Array(UInt64))))
      CrystalClick::WidePartTable.open_selected_typed([part_su], ["pk", "payload"]).scan_typed do |batch|
        actual_su.concat(batch.array_map_array_leaf_values_for("payload", String, UInt64).to_a)
      end
      actual_su.should eq(su)
      actual_su[1][0][1][0].to_slice.should eq(binary_key.to_slice)

      part_ss = File.join(parent, "ss", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part_ss))
      binary_value = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
      ss = [
        [] of W84TableStringArrayStringMap,
        [[{"dup", [] of String}, {"dup", ["", binary_value]}] of Tuple(String, Array(String))] of W84TableStringArrayStringMap,
        [] of W84TableStringArrayStringMap,
      ] of Array(W84TableStringArrayStringMap)
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_string_pair(
        part_ss, "pk", keys.to_unsafe.to_slice(keys.size), "payload", ss.to_unsafe.to_slice(ss.size), rows_per_mark: 2
      )
      actual_ss = [] of Array(Array(Tuple(String, Array(String))))
      CrystalClick::WidePartTable.open_selected_typed([part_ss], ["pk", "payload"]).scan_typed do |batch|
        actual_ss.concat(batch.array_map_array_leaf_values_for("payload", String, String).to_a)
      end
      actual_ss.should eq(ss)
      actual_ss[1][0][1][1][1].to_slice.should eq(binary_value.to_slice)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights combined nested charges through later marks before any callback" do
    parent = File.tempname("crystal-click-w84-table-late-preflight")
    Dir.mkdir(parent)
    begin
      large_key = String.new(Bytes.new(34 * 1024 * 1024, 0x41_u8))
      part = w84_table_build_two_string_key_columns(parent, large_key)
      reader_a = CrystalClick::WidePart.open_typed(part, "payload_a")
      reader_b = CrystalClick::WidePart.open_typed(part, "payload_b")
      charge_a = reader_a.array_map_array_leaf_mark_range_materialization_preflight("payload_a", 1, 1)[:charge_bytes]
      charge_b = reader_b.array_map_array_leaf_mark_range_materialization_preflight("payload_b", 1, 1)[:charge_bytes]
      limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      charge_a.should be < limit
      charge_b.should be < limit
      (charge_a + charge_b).should be > limit

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload_a", "payload_b"]).scan_typed do |_batch|
          callbacks += 1
        end
      end
      error.message.not_nil!.should contain("Array(Map)")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects corruption in a selected middle values.size2 mark before any callback" do
    parent = File.tempname("crystal-click-w84-table-middle-mark")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      keys = [10_u64, 11_u64, 12_u64]
      rows = [
        [] of W84TableU64ArrayU64Map,
        [[{7_u64, [1_u64]}] of Tuple(UInt64, Array(UInt64))] of W84TableU64ArrayU64Map,
        [[{8_u64, [2_u64, 3_u64]}] of Tuple(UInt64, Array(UInt64))] of W84TableU64ArrayU64Map,
      ] of Array(W84TableU64ArrayU64Map)
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )

      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("payload%2Evalues.size2")}.mrk2")
      marks = File.read(mark_path).to_slice.dup
      marks.size.should eq(4 * CrystalClick::WidePart::MARK_SIZE)
      # Three one-row data records are followed by a sentinel. Corrupt the
      # selected middle data record's compressed offset while preserving size.
      w84_table_write_u64(marks, CrystalClick::WidePart::MARK_SIZE, UInt64::MAX)
      File.write(mark_path, marks)

      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"]).scan_typed_candidate_marks([[0, 1, 2]]) do |_batch|
          callbacks += 1
        end
      end
      error.message.not_nil!.should eq("mark compressed offset exceeds data")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
