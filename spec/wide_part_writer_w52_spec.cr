require "./spec_helper"

W52_WRITER_BINARY_KEY               = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W52_WRITER_LONG_VALUE               = "a longer value crosses the row and mark boundary"
W52_WRITER_KEYS                     = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W52_WRITER_MAP_STRING_UINT64_VALUES = [
  [] of Tuple(String, UInt64),
  [{"dup", 0_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64),
  [{W52_WRITER_BINARY_KEY, 42_u64}, {"雪", 7_u64}] of Tuple(String, UInt64),
  [{"empty", UInt64::MAX}] of Tuple(String, UInt64),
  [] of Tuple(String, UInt64),
  [{"tail", 8_u64}, {"", 9_u64}] of Tuple(String, UInt64),
  [{"end", 0_u64}] of Tuple(String, UInt64),
] of Array(Tuple(String, UInt64))
W52_WRITER_MAP_STRING_STRING_VALUES = [
  [] of Tuple(String, String),
  [{"dup", ""}, {"dup", "second"}] of Tuple(String, String),
  [{W52_WRITER_BINARY_KEY, "binary\0value"}, {"", ""}] of Tuple(String, String),
  [{"empty-value", ""}, {"nonempty-value", W52_WRITER_LONG_VALUE}] of Tuple(String, String),
  [] of Tuple(String, String),
  [{"tail", "emoji💥"}, {"tail", "second duplicate"}] of Tuple(String, String),
  [{"end", "final"}] of Tuple(String, String),
] of Array(Tuple(String, String))

private def w52_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w52_writer_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w52_writer_raw_stream(path, stream)
  raise "W52 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w52_writer_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w52_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w52_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W52 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w52_writer_read_u64(bytes, offset),
      w52_writer_read_u64(bytes, offset + 8),
      w52_writer_read_u64(bytes, offset + 16),
    }
  end
end

private def w52_writer_assert_marks(path : String, stream : String, raw_mark_sizes : Array(Int32)) : Nil
  marks = w52_writer_marks(path, stream)
  marks.size.should eq(raw_mark_sizes.size + 1)
  expected_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  marks.map(&.[2]).should eq(expected_rows)

  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  compressed_offset = 0_i64
  raw_mark_sizes.each_with_index do |raw_size, index|
    marks[index][0].should eq(compressed_offset.to_u64)
    marks[index][1].should eq(0_u64)
    next if raw_size == 0
    frame = CrystalClick::CompressedBlock.decode_frame(
      encoded,
      compressed_offset,
      CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
      CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
    )
    frame.output.size.should eq(raw_size)
    compressed_offset = frame.end_offset
  end
  marks.last[0].should eq(compressed_offset.to_u64)
  marks.last[1].should eq(0_u64)
  marks.last[2].should eq(0_u64)
  compressed_offset.should eq(encoded.size.to_i64)
  nil
end

describe "W52 String-key Map writer" do
  it "writes both exact Wide declarations, child streams, and independently checked marks" do
    parent = File.tempname("crystal-click-w52-map-writer")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "map-string-u64")
    string_path = File.join(parent, "map-string-string")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_uint64_pair(
        u64_path,
        "pk",
        W52_WRITER_KEYS.to_unsafe.to_slice(W52_WRITER_KEYS.size),
        "map_u64",
        W52_WRITER_MAP_STRING_UINT64_VALUES.to_unsafe.to_slice(W52_WRITER_MAP_STRING_UINT64_VALUES.size),
        rows_per_mark: 2
      ).should eq(u64_path)
      CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
        string_path,
        "pk",
        W52_WRITER_KEYS.to_unsafe.to_slice(W52_WRITER_KEYS.size),
        "map_string",
        W52_WRITER_MAP_STRING_STRING_VALUES.to_unsafe.to_slice(W52_WRITER_MAP_STRING_STRING_VALUES.size),
        rows_per_mark: 2
      ).should eq(string_path)

      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "map_u64")
      string_reader = CrystalClick::WidePart.open_typed(string_path, "map_string")
      u64_reader.column_type.should eq("Map(String, UInt64)")
      string_reader.column_type.should eq("Map(String, String)")
      u64_reader.read_map_string_uint64_mark_range("map_u64", 0, u64_reader.mark_count)
        .should eq(W52_WRITER_MAP_STRING_UINT64_VALUES)
      string_reader.read_map_string_string_mark_range("map_string", 0, string_reader.mark_count)
        .should eq(W52_WRITER_MAP_STRING_STRING_VALUES)
      u64_reader.read_map_string_uint64_mark_range("map_u64", 1, 2)
        .should eq(W52_WRITER_MAP_STRING_UINT64_VALUES[2, 4])
      string_reader.read_map_string_string_mark_range("map_string", 1, 2)
        .should eq(W52_WRITER_MAP_STRING_STRING_VALUES[2, 4])

      File.read(File.join(u64_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`map_u64` Map(String, UInt64)\n"
      )
      File.read(File.join(u64_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `map_u64`:\n\tmap_u64.size0\n\tmap_u64%2Ekeys.size\n\tmap_u64%2Ekeys\n\tmap_u64%2Evalues\n"
      )
      File.read(File.join(string_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`map_string` Map(String, String)\n"
      )
      File.read(File.join(string_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n5 substreams for column `map_string`:\n\tmap_string.size0\n\tmap_string%2Ekeys.size\n\tmap_string%2Ekeys\n\tmap_string%2Evalues.size\n\tmap_string%2Evalues\n"
      )
      expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      [u64_path, string_path].each do |path|
        File.read(File.join(path, "serialization.json")).should eq(expected_serialization)
        File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      end

      w52_writer_raw_u64_stream(u64_path, "map_u64.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
      w52_writer_raw_u64_stream(u64_path, "map_u64%2Ekeys.size").should eq(
        W52_WRITER_MAP_STRING_UINT64_VALUES.flatten.map { |key, _value| key.bytesize.to_u64 }
      )
      w52_writer_raw_stream(u64_path, "map_u64%2Ekeys").should eq(
        w52_writer_string_bytes(W52_WRITER_MAP_STRING_UINT64_VALUES.flatten.map(&.[0]))
      )
      w52_writer_raw_u64_stream(u64_path, "map_u64%2Evalues").should eq(
        W52_WRITER_MAP_STRING_UINT64_VALUES.flatten.map(&.[1])
      )
      w52_writer_raw_u64_stream(string_path, "map_string.size0").should eq([0_u64, 2_u64, 2_u64, 2_u64, 0_u64, 2_u64, 1_u64])
      w52_writer_raw_u64_stream(string_path, "map_string%2Ekeys.size").should eq(
        W52_WRITER_MAP_STRING_STRING_VALUES.flatten.map { |key, _value| key.bytesize.to_u64 }
      )
      w52_writer_raw_stream(string_path, "map_string%2Ekeys").should eq(
        w52_writer_string_bytes(W52_WRITER_MAP_STRING_STRING_VALUES.flatten.map(&.[0]))
      )
      w52_writer_raw_u64_stream(string_path, "map_string%2Evalues.size").should eq(
        W52_WRITER_MAP_STRING_STRING_VALUES.flatten.map { |_key, value| value.bytesize.to_u64 }
      )
      w52_writer_raw_stream(string_path, "map_string%2Evalues").should eq(
        w52_writer_string_bytes(W52_WRITER_MAP_STRING_STRING_VALUES.flatten.map(&.[1]))
      )

      {
        "pk"                  => [16, 16, 16, 8],
        "map_u64.size0"       => [16, 16, 16, 8],
        "map_u64%2Ekeys.size" => [16, 24, 16, 8],
        "map_u64%2Ekeys"      => [6, 12, 4, 3],
        "map_u64%2Evalues"    => [16, 24, 16, 8],
      }.each { |stream, raw_sizes| w52_writer_assert_marks(u64_path, stream, raw_sizes) }
      {
        "pk"                       => [16, 16, 16, 8],
        "map_string.size0"         => [16, 16, 16, 8],
        "map_string%2Ekeys.size"   => [16, 32, 16, 8],
        "map_string%2Ekeys"        => [6, 29, 8, 3],
        "map_string%2Evalues.size" => [16, 32, 16, 8],
        "map_string%2Evalues"      => [6, 12 + W52_WRITER_LONG_VALUE.bytesize, "emoji💥second duplicate".bytesize, 5],
      }.each { |stream, raw_sizes| w52_writer_assert_marks(string_path, stream, raw_sizes) }

      [
        {u64_path, ["pk", "map_u64.size0", "map_u64%2Ekeys.size", "map_u64%2Ekeys", "map_u64%2Evalues"]},
        {string_path, ["pk", "map_string.size0", "map_string%2Ekeys.size", "map_string%2Ekeys", "map_string%2Evalues.size", "map_string%2Evalues"]},
      ].each do |path, streams|
        expected_files = ["count.txt", "primary.idx", "serialization.json"]
        streams.each do |stream|
          base = CrystalClick::StreamName.hash(stream)
          expected_files << "#{base}.bin"
          expected_files << "#{base}.mrk2"
        end
        CrystalClick::PartChecksums.open(path).entries.keys.sort.should eq(expected_files.sort)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes empty key and value streams without inventing data frames" do
    parent = File.tempname("crystal-click-w52-map-writer-empty-children")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "empty-u64-entries")
    string_path = File.join(parent, "empty-string-children")
    keys = W52_WRITER_KEYS
    empty_u64_maps = Array.new(keys.size) { [] of Tuple(String, UInt64) }
    empty_string_maps = Array.new(keys.size) { [] of Tuple(String, String) }
    empty_key_value_maps = Array.new(keys.size) { [{"", ""}] of Tuple(String, String) }
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_uint64_pair(
        u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "map_u64",
        empty_u64_maps.to_unsafe.to_slice(empty_u64_maps.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
        string_path, "pk", keys.to_unsafe.to_slice(keys.size), "map_string",
        empty_string_maps.to_unsafe.to_slice(empty_string_maps.size), rows_per_mark: 2
      )
      empty_keys_path = File.join(parent, "empty-string-keys-and-values")
      CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
        empty_keys_path, "pk", keys.to_unsafe.to_slice(keys.size), "map_string",
        empty_key_value_maps.to_unsafe.to_slice(empty_key_value_maps.size), rows_per_mark: 2
      )

      ["map_u64%2Ekeys.size", "map_u64%2Ekeys", "map_u64%2Evalues"].each do |stream|
        File.size(File.join(u64_path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w52_writer_marks(u64_path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
      ["map_string%2Ekeys.size", "map_string%2Ekeys", "map_string%2Evalues.size", "map_string%2Evalues"].each do |stream|
        File.size(File.join(string_path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w52_writer_marks(string_path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
      ["map_string%2Ekeys", "map_string%2Evalues"].each do |stream|
        File.size(File.join(empty_keys_path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w52_writer_marks(empty_keys_path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
      ["map_string%2Ekeys.size", "map_string%2Evalues.size"].each do |stream|
        w52_writer_raw_u64_stream(empty_keys_path, stream).should eq(Array.new(W52_WRITER_KEYS.size, 0_u64))
      end
      CrystalClick::WidePart.open_typed(u64_path, "map_u64")
        .read_map_string_uint64_mark_range("map_u64", 0, 4).should eq(empty_u64_maps)
      CrystalClick::WidePart.open_typed(string_path, "map_string")
        .read_map_string_string_mark_range("map_string", 0, 4).should eq(empty_string_maps)
      CrystalClick::WidePart.open_typed(empty_keys_path, "map_string")
        .read_map_string_string_mark_range("map_string", 0, 4).should eq(empty_key_value_maps)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted primary keys without publishing either new Map shape" do
    parent = File.tempname("crystal-click-w52-map-writer-invalid-key")
    Dir.mkdir(parent)
    begin
      u64_path = File.join(parent, "map-string-u64")
      string_path = File.join(parent, "map-string-string")
      u64_values = [[{"a", 1_u64}]] of Array(Tuple(String, UInt64))
      string_values = [[{"a", "one"}]] of Array(Tuple(String, String))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_uint64_pair(
          u64_path, "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "map_u64",
          u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
          string_path, "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "map_string",
          string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
