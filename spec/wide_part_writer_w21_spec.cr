require "./spec_helper"

private def w21_writer_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w21_writer_decoded_u64(path : String, stream : String) : Array(UInt64)
  bytes = CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  )
  raise "W21 test stream is not UInt64-aligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) { |index| w21_writer_u64(bytes, index * 8) }
end

private def w21_writer_decoded_bytes(path : String, stream : String) : Array(UInt8)
  CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  ).to_a
end

private def w21_writer_mark_rows(path : String, stream : String) : Array(UInt64)
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W21 test mark file is malformed" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w21_writer_u64(bytes, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

private def w21_writer_encode_u64(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times { |byte| bytes[index * 8 + byte] = (value >> (byte * 8)).to_u8 }
  end
  bytes.to_a
end

describe CrystalClick::WidePartWriter do
  it "writes only Array(UInt64) streams with outer-row marks and exact staged readback" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-u64")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    values = [
      [100_u64, 101_u64],
      [] of UInt64,
      [0_u64, UInt64::MAX],
      [42_u64],
      [7_u64, 8_u64, 9_u64],
      [] of UInt64,
      [5_u64],
    ] of Array(UInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      key_part = CrystalClick::WidePart.open(destination, "pk")
      payload_part = CrystalClick::WidePart.open_typed(destination, "payload")
      key_part.read_uint64.should eq(keys)
      payload_part.column_type.should eq("Array(UInt64)")
      payload_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      payload_part.read_array_uint64_mark_range("payload", 0, payload_part.mark_count).should eq(values)
      payload_part.read_array_uint64_mark_range("payload", 1, 2).should eq(values[2, 4])

      # Every stream's MRK2 row-count grid remains in outer rows, even though
      # the flattened payload advances by a different number of UInt64 values.
      ["pk", "payload.size0", "payload"].each do |stream|
        w21_writer_mark_rows(destination, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      end
      w21_writer_decoded_u64(destination, "payload.size0").should eq([2_u64, 0_u64, 2_u64, 1_u64, 3_u64, 0_u64, 1_u64])
      flattened = values.flatten
      w21_writer_decoded_u64(destination, "payload").should eq(flattened)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(UInt64)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.size0\n\tpayload\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      w21_writer_encode_u64(values.map(&.size.to_u64)).should eq(w21_writer_decoded_bytes(destination, "payload.size0"))
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("payload.size")}.bin")).should be_false
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")

      expected_checksum_names = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "payload.size0", "payload"}.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_checksum_names << "#{base}.bin"
        expected_checksum_names << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksum_names.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Array(String) nested lengths and binary-safe flattened strings across outer marks" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-string")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
    invalid_utf8 = String.new(Bytes[0xff_u8, 0_u8])
    values = [
      ["", "alpha"],
      [] of String,
      [binary, ""],
      ["é"],
      ["last", invalid_utf8],
      [] of String,
      ["z"],
    ] of Array(String)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      key_part = CrystalClick::WidePart.open(destination, "pk")
      payload_part = CrystalClick::WidePart.open_typed(destination, "payload")
      key_part.read_uint64.should eq(keys)
      payload_part.column_type.should eq("Array(String)")
      payload_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      payload_part.read_array_string_mark_range("payload", 0, payload_part.mark_count).should eq(values)
      payload_part.read_array_string_mark_range("payload", 1, 2).should eq(values[2, 4])

      ["pk", "payload.size0", "payload.size", "payload"].each do |stream|
        w21_writer_mark_rows(destination, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      end
      outer_sizes = values.map { |row| row.size.to_u64 }
      nested = values.flatten
      nested_sizes = nested.map { |value| value.bytesize.to_u64 }
      raw = nested.join.to_slice.to_a
      w21_writer_decoded_u64(destination, "payload.size0").should eq(outer_sizes)
      w21_writer_decoded_u64(destination, "payload.size").should eq(nested_sizes)
      w21_writer_decoded_bytes(destination, "payload").should eq(raw)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size\n\tpayload\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("payload.null")}.bin")).should be_false
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps all-empty Array(UInt64) and zero-byte nested String marks without fake frames" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-empty")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    empty_arrays = [[] of UInt64, [] of UInt64, [] of UInt64]
    empty_string_arrays = [[] of String, [] of String, [] of String]
    empty_string_values = [[""], ["", ""], [] of String] of Array(String)
    array_destination = File.join(parent, "array")
    empty_string_array_destination = File.join(parent, "empty-string-arrays")
    string_destination = File.join(parent, "strings")

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        array_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        empty_arrays.to_unsafe.to_slice(empty_arrays.size), rows_per_mark: 1
      )
      array_part = CrystalClick::WidePart.open_typed(array_destination, "payload")
      array_part.read_array_uint64_mark_range("payload", 0, array_part.mark_count).should eq(empty_arrays)
      File.size(File.join(array_destination, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0_i64)
      w21_writer_mark_rows(array_destination, "payload").should eq([1_u64, 1_u64, 1_u64, 0_u64])

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        empty_string_array_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        empty_string_arrays.to_unsafe.to_slice(empty_string_arrays.size), rows_per_mark: 1
      )
      empty_string_array_part = CrystalClick::WidePart.open_typed(empty_string_array_destination, "payload")
      empty_string_array_part.read_array_string_mark_range("payload", 0, empty_string_array_part.mark_count).should eq(empty_string_arrays)
      File.size(File.join(empty_string_array_destination, "#{CrystalClick::StreamName.hash("payload.size")}.bin")).should eq(0_i64)
      File.size(File.join(empty_string_array_destination, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0_i64)

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        string_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        empty_string_values.to_unsafe.to_slice(empty_string_values.size), rows_per_mark: 1
      )
      string_part = CrystalClick::WidePart.open_typed(string_destination, "payload")
      string_part.read_array_string_mark_range("payload", 0, string_part.mark_count).should eq(empty_string_values)
      File.size(File.join(string_destination, "#{CrystalClick::StreamName.hash("payload")}.bin")).should eq(0_i64)
      w21_writer_decoded_u64(string_destination, "payload.size").should eq([0_u64, 0_u64, 0_u64])
      w21_writer_mark_rows(string_destination, "payload").should eq([1_u64, 1_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an oversized flattened-element mark before creating a stage or publishing" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-elements-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    values = [Array(UInt64).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1).to_i, 7_u64)]

    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("Array nested element count exceeds per-mark limit")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces the flattened-element cap for Array(String), including empty strings" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-string-elements-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    values = [Array(String).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1).to_i, "")]

    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("Array nested element count exceeds per-mark limit")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects oversized Array(String) raw bytes before creating a stage or publishing" do
    parent = File.tempname("crystal-click-wide-writer-w21-array-bytes-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    oversized = String.new(Bytes.new((CrystalClick::WidePart::MAX_ARRAY_MARK_BYTES + 1).to_i, 0_u8))
    values = [[oversized]] of Array(String)

    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("Array nested bytes exceed per-mark limit")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
