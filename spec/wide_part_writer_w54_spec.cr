require "./spec_helper"

W54_WRITER_KEYS                              = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W54_WRITER_BINARY_KEY                        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES = [
  [] of Tuple(UInt64, String?),
  [{7_u64, nil}, {7_u64, ""}] of Tuple(UInt64, String?),
  [{UInt64::MAX, ""}, {0_u64, nil}] of Tuple(UInt64, String?),
  [{1_u64, "x\0y"}] of Tuple(UInt64, String?),
  [] of Tuple(UInt64, String?),
  [{5_u64, nil}, {5_u64, "雪"}] of Tuple(UInt64, String?),
  [{9_u64, "end"}] of Tuple(UInt64, String?),
] of Array(Tuple(UInt64, String?))
W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES = [
  [] of Tuple(String, String?),
  [{"dup", nil}, {"dup", ""}] of Tuple(String, String?),
  [{W54_WRITER_BINARY_KEY, ""}, {"雪", nil}] of Tuple(String, String?),
  [{"empty", ""}] of Tuple(String, String?),
  [] of Tuple(String, String?),
  [{"tail", nil}, {"", "🐈"}] of Tuple(String, String?),
  [{"end", "last"}] of Tuple(String, String?),
] of Array(Tuple(String, String?))

private def w54_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w54_writer_raw_u64(path : String, stream : String) : Array(UInt64)
  bytes = w54_writer_raw_stream(path, stream)
  raise "W54 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w54_writer_string_bytes(values : Array(String)) : Array(UInt8)
  values.flat_map { |value| value.to_slice.to_a }
end

private def w54_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W54 writer marks are malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    read_u64 = ->(base : Int32) do
      value = 0_u64
      8.times { |byte| value |= bytes[offset + base + byte].to_u64 << (byte * 8) }
      value
    end
    {read_u64.call(0), read_u64.call(8), read_u64.call(16)}
  end
end

private def w54_writer_assert_marks(path : String, stream : String, raw_mark_sizes : Array(Int32)) : Nil
  marks = w54_writer_marks(path, stream)
  marks.size.should eq(raw_mark_sizes.size + 1)
  marks.map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
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

private def w54_writer_expected_files(streams : Array(String)) : Array(String)
  expected = ["count.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected << "#{base}.bin" << "#{base}.mrk2"
  end
  expected.sort
end

describe "W54 Nullable(String)-value Map writer" do
  it "writes exact UInt64-key and String-key shapes with null/empty distinction, duplicates, and marks" do
    parent = File.tempname("crystal-click-w54-map-writer")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "map-u64-nullable-string")
    string_path = File.join(parent, "map-string-nullable-string")
    u64_streams = [
      "pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.null",
      "payload%2Evalues.size", "payload%2Evalues",
    ]
    string_streams = [
      "pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys",
      "payload%2Evalues.null", "payload%2Evalues.size", "payload%2Evalues",
    ]
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_string_pair(
        u64_path, "pk", W54_WRITER_KEYS.to_unsafe.to_slice(W54_WRITER_KEYS.size), "payload",
        W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES.to_unsafe.to_slice(W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES.size),
        rows_per_mark: 2
      ).should eq(u64_path)
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_string_pair(
        string_path, "pk", W54_WRITER_KEYS.to_unsafe.to_slice(W54_WRITER_KEYS.size), "payload",
        W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES.to_unsafe.to_slice(W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES.size),
        rows_per_mark: 2
      ).should eq(string_path)

      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      string_reader = CrystalClick::WidePart.open_typed(string_path, "payload")
      u64_reader.column_type.should eq("Map(UInt64, Nullable(String))")
      string_reader.column_type.should eq("Map(String, Nullable(String))")
      u64_reader.read_map_uint64_nullable_string_mark_range("payload", 0, 4)
        .should eq(W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES)
      string_reader.read_map_string_nullable_string_mark_range("payload", 0, 4)
        .should eq(W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES)
      u64_reader.read_map_uint64_nullable_string_mark_range("payload", 1, 2)
        .should eq(W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES[2, 4])
      string_reader.read_map_string_nullable_string_mark_range("payload", 1, 2)
        .should eq(W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES[2, 4])

      File.read(File.join(u64_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(UInt64, Nullable(String))\n"
      )
      File.read(File.join(u64_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" \
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys\n" \
        "\tpayload%2Evalues.null\n\tpayload%2Evalues.size\n\tpayload%2Evalues\n"
      )
      File.read(File.join(string_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Nullable(String))\n"
      )
      File.read(File.join(string_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" \
        "6 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys.size\n" \
        "\tpayload%2Ekeys\n\tpayload%2Evalues.null\n\tpayload%2Evalues.size\n\tpayload%2Evalues\n"
      )
      [u64_path, string_path].each do |path|
        File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        File.read(File.join(path, "serialization.json")).should eq(
          %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
        )
      end

      u64_flat = W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES.flatten
      w54_writer_raw_u64(u64_path, "payload.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
      w54_writer_raw_u64(u64_path, "payload%2Ekeys").should eq(u64_flat.map(&.[0]))
      w54_writer_raw_stream(u64_path, "payload%2Evalues.null").should eq(
        u64_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 }
      )
      w54_writer_raw_u64(u64_path, "payload%2Evalues.size").should eq(
        u64_flat.map { |_key, value| value ? value.bytesize.to_u64 : 0_u64 }
      )
      w54_writer_raw_stream(u64_path, "payload%2Evalues").should eq(
        w54_writer_string_bytes(u64_flat.compact_map { |_key, value| value })
      )

      string_flat = W54_WRITER_MAP_STRING_NULLABLE_STRING_VALUES.flatten
      w54_writer_raw_u64(string_path, "payload.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
      w54_writer_raw_u64(string_path, "payload%2Ekeys.size").should eq(
        string_flat.map { |key, _value| key.bytesize.to_u64 }
      )
      w54_writer_raw_stream(string_path, "payload%2Ekeys").should eq(
        w54_writer_string_bytes(string_flat.map(&.[0]))
      )
      w54_writer_raw_stream(string_path, "payload%2Evalues.null").should eq(
        string_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 }
      )
      w54_writer_raw_u64(string_path, "payload%2Evalues.size").should eq(
        string_flat.map { |_key, value| value ? value.bytesize.to_u64 : 0_u64 }
      )
      w54_writer_raw_stream(string_path, "payload%2Evalues").should eq(
        w54_writer_string_bytes(string_flat.compact_map { |_key, value| value })
      )

      u64_mark_sizes = {
        "pk" => [16, 16, 16, 8], "payload.size0" => [16, 16, 16, 8],
        "payload%2Ekeys" => [16, 24, 16, 8], "payload%2Evalues.null" => [2, 3, 2, 1],
        "payload%2Evalues.size" => [16, 24, 16, 8], "payload%2Evalues" => [0, 3, 3, 3],
      }
      string_mark_sizes = {
        "pk" => [16, 16, 16, 8], "payload.size0" => [16, 16, 16, 8],
        "payload%2Ekeys.size" => [16, 24, 16, 8], "payload%2Ekeys" => [6, 12, 4, 3],
        "payload%2Evalues.null" => [2, 3, 2, 1], "payload%2Evalues.size" => [16, 24, 16, 8],
        "payload%2Evalues" => [0, 0, 4, 4],
      }
      u64_mark_sizes.each { |stream, raw_sizes| w54_writer_assert_marks(u64_path, stream, raw_sizes) }
      string_mark_sizes.each { |stream, raw_sizes| w54_writer_assert_marks(string_path, stream, raw_sizes) }
      CrystalClick::PartChecksums.open(u64_path).entries.keys.sort.should eq(w54_writer_expected_files(u64_streams))
      CrystalClick::PartChecksums.open(string_path).entries.keys.sort.should eq(w54_writer_expected_files(string_streams))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps empty maps and blank keys with nullable empty values distinct without empty data frames" do
    parent = File.tempname("crystal-click-w54-map-writer-empty")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "all-empty-u64")
    string_path = File.join(parent, "blank-string-keys")
    empty_u64_maps = Array.new(W54_WRITER_KEYS.size) { [] of Tuple(UInt64, String?) }
    blank_string_maps = [
      [{"", nil}] of Tuple(String, String?),
      [{"", ""}] of Tuple(String, String?),
      [{"", nil}, {"", ""}] of Tuple(String, String?),
      [] of Tuple(String, String?),
      [{"", ""}] of Tuple(String, String?),
      [{"", nil}] of Tuple(String, String?),
      [{"", ""}] of Tuple(String, String?),
    ] of Array(Tuple(String, String?))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_string_pair(
        u64_path, "pk", W54_WRITER_KEYS.to_unsafe.to_slice(W54_WRITER_KEYS.size), "payload",
        empty_u64_maps.to_unsafe.to_slice(empty_u64_maps.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_string_pair(
        string_path, "pk", W54_WRITER_KEYS.to_unsafe.to_slice(W54_WRITER_KEYS.size), "payload",
        blank_string_maps.to_unsafe.to_slice(blank_string_maps.size), rows_per_mark: 2
      )

      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      u64_reader.read_map_uint64_nullable_string_mark_range("payload", 0, 4).should eq(empty_u64_maps)
      ["payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues.size", "payload%2Evalues"].each do |stream|
        File.size(File.join(u64_path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w54_writer_marks(u64_path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
      w54_writer_raw_u64(u64_path, "payload.size0").should eq(Array.new(W54_WRITER_KEYS.size, 0_u64))

      string_reader = CrystalClick::WidePart.open_typed(string_path, "payload")
      string_reader.read_map_string_nullable_string_mark_range("payload", 0, 4).should eq(blank_string_maps)
      w54_writer_raw_u64(string_path, "payload.size0").should eq([1_u64, 1_u64, 2_u64, 0_u64, 1_u64, 1_u64, 1_u64])
      w54_writer_raw_u64(string_path, "payload%2Ekeys.size").should eq(Array.new(7, 0_u64))
      w54_writer_raw_stream(string_path, "payload%2Evalues.null").should eq([1_u8, 0_u8, 1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w54_writer_raw_u64(string_path, "payload%2Evalues.size").should eq(Array.new(7, 0_u64))
      ["payload%2Ekeys", "payload%2Evalues"].each do |stream|
        File.size(File.join(string_path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w54_writer_marks(string_path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted primary keys and preserves an existing destination" do
    parent = File.tempname("crystal-click-w54-map-writer-safety")
    Dir.mkdir(parent)
    begin
      bad_keys = [2_u64, 1_u64]
      u64_values = [[{1_u64, nil}] of Tuple(UInt64, String?), [{1_u64, ""}] of Tuple(UInt64, String?)]
      string_values = [[{"a", nil}] of Tuple(String, String?), [{"b", ""}] of Tuple(String, String?)]
      u64_path = File.join(parent, "unsorted-u64")
      string_path = File.join(parent, "unsorted-string")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_string_pair(
          u64_path, "pk", bad_keys.to_unsafe.to_slice(2), "payload", u64_values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_nullable_string_pair(
          string_path, "pk", bad_keys.to_unsafe.to_slice(2), "payload", string_values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)

      existing = File.join(parent, "existing")
      File.write(existing, "preserve")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_string_pair(
          existing, "pk", W54_WRITER_KEYS.to_unsafe.to_slice(W54_WRITER_KEYS.size), "payload",
          W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES.to_unsafe.to_slice(W54_WRITER_MAP_UINT64_NULLABLE_STRING_VALUES.size),
          rows_per_mark: 2
        )
      end
      File.read(existing).should eq("preserve")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
