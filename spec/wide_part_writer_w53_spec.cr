require "./spec_helper"

W53_WRITER_KEYS                              = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES = [
  [] of Tuple(UInt64, UInt64?),
  [{7_u64, nil}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [{UInt64::MAX, 42_u64}, {0_u64, nil}] of Tuple(UInt64, UInt64?),
  [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [] of Tuple(UInt64, UInt64?),
  [{5_u64, nil}, {5_u64, UInt64::MAX}] of Tuple(UInt64, UInt64?),
  [{9_u64, 0_u64}] of Tuple(UInt64, UInt64?),
] of Array(Tuple(UInt64, UInt64?))
W53_WRITER_BINARY_KEY                        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES = [
  [] of Tuple(String, UInt64?),
  [{"dup", nil}, {"dup", 0_u64}] of Tuple(String, UInt64?),
  [{W53_WRITER_BINARY_KEY, UInt64::MAX}, {"雪", nil}] of Tuple(String, UInt64?),
  [{"empty", 0_u64}, {"empty", nil}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"tail", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [{"end", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))
W53_WRITER_MAP_STRING_NULLABLE_UINT64_BLANK_KEYS = [
  [{"", nil}] of Tuple(String, UInt64?),
  [{"", 0_u64}] of Tuple(String, UInt64?),
  [{"", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"", UInt64::MAX}] of Tuple(String, UInt64?),
  [{"", nil}] of Tuple(String, UInt64?),
  [{"", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))

private def w53_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin"))
  CrystalClick::CompressedBlock.decode_all(encoded.to_slice).to_a
end

private def w53_writer_raw_u64(path : String, stream : String) : Array(UInt64)
  bytes = w53_writer_raw_stream(path, stream)
  raise "W53 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w53_writer_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  values.flat_map do |value|
    Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
end

private def w53_writer_string_bytes(values : Array(String)) : Array(UInt8)
  values.flat_map { |value| value.to_slice.to_a }
end

private def w53_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W53 writer marks are malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    base = index * CrystalClick::WidePart::MARK_SIZE
    read_u64 = ->(offset : Int32) do
      value = 0_u64
      8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
      value
    end
    {read_u64.call(base), read_u64.call(base + 8), read_u64.call(base + 16)}
  end
end

private def w53_writer_expected_files(streams : Array(String)) : Array(String)
  expected = ["count.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected << "#{base}.bin" << "#{base}.mrk2"
  end
  expected.sort
end

describe "W53 Nullable-value Map writer" do
  it "writes both exact nullable Map shapes with independent child and mark inventory" do
    parent = File.tempname("crystal-click-w53-map-writer")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "map-u64-nullable")
    string_path = File.join(parent, "map-string-nullable")
    u64_streams = [
      "pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues",
    ]
    string_streams = [
      "pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys",
      "payload%2Evalues.null", "payload%2Evalues",
    ]
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
        u64_path, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
        W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES.to_unsafe.to_slice(W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES.size),
        rows_per_mark: 2
      ).should eq(u64_path)
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
        string_path, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
        W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES.to_unsafe.to_slice(W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES.size),
        rows_per_mark: 2
      ).should eq(string_path)

      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      string_reader = CrystalClick::WidePart.open_typed(string_path, "payload")
      u64_reader.column_type.should eq("Map(UInt64, Nullable(UInt64))")
      string_reader.column_type.should eq("Map(String, Nullable(UInt64))")
      u64_reader.read_map_uint64_nullable_uint64_mark_range("payload", 0, 4)
        .should eq(W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES)
      string_reader.read_map_string_nullable_uint64_mark_range("payload", 0, 4)
        .should eq(W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES)
      u64_reader.read_map_uint64_nullable_uint64_mark_range("payload", 1, 2)
        .should eq(W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES[2, 4])
      string_reader.read_map_string_nullable_uint64_mark_range("payload", 1, 2)
        .should eq(W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES[2, 4])

      File.read(File.join(u64_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(UInt64, Nullable(UInt64))\n"
      )
      File.read(File.join(u64_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" \
        "4 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys\n\tpayload%2Evalues.null\n\tpayload%2Evalues\n"
      )
      File.read(File.join(string_path, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Nullable(UInt64))\n"
      )
      File.read(File.join(string_path, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" \
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys.size\n\tpayload%2Ekeys\n\tpayload%2Evalues.null\n\tpayload%2Evalues\n"
      )
      [u64_path, string_path].each do |path|
        File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
        File.read(File.join(path, "serialization.json")).should eq(
          %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
        )
        CrystalClick::PartChecksums.open(path).entries.keys.sort.should eq(
          w53_writer_expected_files(path == u64_path ? u64_streams : string_streams)
        )
        Dir.children(path).sort.should eq(
          (w53_writer_expected_files(path == u64_path ? u64_streams : string_streams) + [
            "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt",
          ]).sort
        )
      end

      u64_flat = W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES.flatten
      w53_writer_raw_u64(u64_path, "payload.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
      w53_writer_raw_u64(u64_path, "payload%2Ekeys").should eq(u64_flat.map(&.[0]))
      w53_writer_raw_stream(u64_path, "payload%2Evalues.null").should eq(
        u64_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 }
      )
      w53_writer_raw_stream(u64_path, "payload%2Evalues").should eq(
        w53_writer_u64_bytes(u64_flat.map { |_key, value| value || 0_u64 })
      )
      string_flat = W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES.flatten
      w53_writer_raw_u64(string_path, "payload.size0").should eq([0_u64, 2_u64, 2_u64, 2_u64, 0_u64, 2_u64, 1_u64])
      w53_writer_raw_u64(string_path, "payload%2Ekeys.size").should eq(
        string_flat.map { |key, _value| key.bytesize.to_u64 }
      )
      w53_writer_raw_stream(string_path, "payload%2Ekeys").should eq(
        w53_writer_string_bytes(string_flat.map(&.[0]))
      )
      w53_writer_raw_stream(string_path, "payload%2Evalues.null").should eq(
        string_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 }
      )
      w53_writer_raw_stream(string_path, "payload%2Evalues").should eq(
        w53_writer_u64_bytes(string_flat.map { |_key, value| value || 0_u64 })
      )

      [{u64_path, u64_streams}, {string_path, string_streams}].each do |(path, streams)|
        streams.each do |stream|
          w53_writer_marks(path, stream).map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-empty Map children across every mark without inventing child bytes" do
    parent = File.tempname("crystal-click-w53-map-writer-empty")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "empty-u64")
    string_path = File.join(parent, "empty-string")
    u64_values = Array.new(W53_WRITER_KEYS.size) { [] of Tuple(UInt64, UInt64?) }
    string_values = Array.new(W53_WRITER_KEYS.size) { [] of Tuple(String, UInt64?) }
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
        u64_path, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
        u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
        string_path, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
        string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 2
      )

      [
        {u64_path, u64_values.as(Array(Array(Tuple(UInt64, UInt64?)))), ["payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues"]},
        {string_path, string_values.as(Array(Array(Tuple(String, UInt64?)))), ["payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues"]},
      ].each do |path, values, children|
        children.each do |stream|
          File.size(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
          w53_writer_marks(path, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
          w53_writer_marks(path, stream).map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
        end
        reader = CrystalClick::WidePart.open_typed(path, "payload")
        if path == u64_path
          reader.read_map_uint64_nullable_uint64_mark_range("payload", 0, 4).should eq(values)
        else
          reader.read_map_string_nullable_uint64_mark_range("payload", 0, 4).should eq(values)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves entries when all String keys are empty and the raw key stream is zero bytes" do
    parent = File.tempname("crystal-click-w53-map-writer-blank-keys")
    Dir.mkdir(parent)
    path = File.join(parent, "blank-keys")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
        path, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
        W53_WRITER_MAP_STRING_NULLABLE_UINT64_BLANK_KEYS.to_unsafe.to_slice(
          W53_WRITER_MAP_STRING_NULLABLE_UINT64_BLANK_KEYS.size
        ), rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_string_nullable_uint64_mark_range("payload", 0, 4)
        .should eq(W53_WRITER_MAP_STRING_NULLABLE_UINT64_BLANK_KEYS)
      w53_writer_raw_u64(path, "payload%2Ekeys.size").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      # Empty keys have zero bytes each, so their size entries are all zero too;
      # the row with duplicate empty keys proves size0 and value children
      # still carry nonempty map entries.
      w53_writer_raw_u64(path, "payload.size0").should eq([1_u64, 1_u64, 2_u64, 0_u64, 1_u64, 1_u64, 1_u64])
      File.size(File.join(path, "#{CrystalClick::StreamName.hash("payload%2Ekeys")}.bin")).should eq(0_i64)
      w53_writer_raw_stream(path, "payload%2Evalues.null").should eq([1_u8, 0_u8, 1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w53_writer_raw_stream(path, "payload%2Evalues").should eq(
        w53_writer_u64_bytes([0_u64, 0_u64, 0_u64, 0_u64, UInt64::MAX, 0_u64, 0_u64])
      )
      w53_writer_marks(path, "payload%2Ekeys").map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      w53_writer_marks(path, "payload%2Ekeys").map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      w53_writer_marks(path, "payload%2Ekeys.size").map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted primary keys and never overwrites an existing destination" do
    parent = File.tempname("crystal-click-w53-map-writer-safety")
    Dir.mkdir(parent)
    unsorted_u64 = File.join(parent, "unsorted-u64")
    unsorted_string = File.join(parent, "unsorted-string")
    existing_u64 = File.join(parent, "existing-u64")
    existing_string = File.join(parent, "existing-string")
    bad_keys = [2_u64, 1_u64]
    u64_values = [[{1_u64, nil}] of Tuple(UInt64, UInt64?), [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?)]
    string_values = [[{"a", nil}] of Tuple(String, UInt64?), [{"b", 0_u64}] of Tuple(String, UInt64?)]
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
          unsorted_u64, "pk", bad_keys.to_unsafe.to_slice(bad_keys.size), "payload",
          u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
          unsorted_string, "pk", bad_keys.to_unsafe.to_slice(bad_keys.size), "payload",
          string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
        )
      end
      File.exists?(unsorted_u64).should be_false
      File.exists?(unsorted_string).should be_false

      File.write(existing_u64, "preserve-u64")
      File.write(existing_string, "preserve-string")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
          existing_u64, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
          W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES.to_unsafe.to_slice(W53_WRITER_MAP_UINT64_NULLABLE_UINT64_VALUES.size),
          rows_per_mark: 2
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
          existing_string, "pk", W53_WRITER_KEYS.to_unsafe.to_slice(W53_WRITER_KEYS.size), "payload",
          W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES.to_unsafe.to_slice(W53_WRITER_MAP_STRING_NULLABLE_UINT64_VALUES.size),
          rows_per_mark: 2
        )
      end
      File.read(existing_u64).should eq("preserve-u64")
      File.read(existing_string).should eq("preserve-string")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
