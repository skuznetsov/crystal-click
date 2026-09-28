require "./spec_helper"

W52_STRING_MAP_FIXTURE       = File.expand_path("../test/fixtures/public/wide_map_string_w52/part", __DIR__)
W52_BINARY_KEY               = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W52_LONG_VALUE               = "a longer value crosses the row and mark boundary"
W52_KEYS                     = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W52_MAP_STRING_UINT64_VALUES = [
  [] of Tuple(String, UInt64),
  [{"dup", 0_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64),
  [{W52_BINARY_KEY, 42_u64}, {"雪", 7_u64}] of Tuple(String, UInt64),
  [{"empty", UInt64::MAX}] of Tuple(String, UInt64),
  [] of Tuple(String, UInt64),
  [{"tail", 8_u64}, {"", 9_u64}] of Tuple(String, UInt64),
  [{"end", 0_u64}] of Tuple(String, UInt64),
] of Array(Tuple(String, UInt64))
W52_MAP_STRING_STRING_VALUES = [
  [] of Tuple(String, String),
  [{"dup", ""}, {"dup", "second"}] of Tuple(String, String),
  [{W52_BINARY_KEY, "binary\0value"}, {"", ""}] of Tuple(String, String),
  [{"empty-value", ""}, {"nonempty-value", W52_LONG_VALUE}] of Tuple(String, String),
  [] of Tuple(String, String),
  [{"tail", "emoji💥"}, {"tail", "second duplicate"}] of Tuple(String, String),
  [{"end", "final"}] of Tuple(String, String),
] of Array(Tuple(String, String))

private def w52_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w52_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w52_raw_stream(path, stream)
  raise "W52 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w52_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w52_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w52_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w52_mark_rows(path : String, stream : String) : Array(UInt64)
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W52 mark file is not record-aligned: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    w52_read_u64(bytes, index * CrystalClick::WidePart::MARK_SIZE + 16)
  end
end

private def with_w52_fixture_copy(&)
  parent = File.tempname("crystal-click-w52-map-reader")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(W52_STRING_MAP_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w52_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w52_create_catalog_fixture(root : String) : Nil
  database_uuid = "7b15de9e-f760-4f05-b58d-42ec01627129"
  table_uuid = "cc2ec1b8-49d9-40d1-aed2-b8f05f18a751"
  database_store = w52_catalog_store_path(root, database_uuid)
  table_store = w52_catalog_store_path(root, table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_store)
  FileUtils.mkdir_p(table_store)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `map_u64` Map(String, UInt64),\n    `map_string` Map(String, String)\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W52_STRING_MAP_FIXTURE, File.join(table_store, "all_1_1_0"))
  nil
end

describe "W52 ordered String-key Map reader" do
  it "admits the W52 declarations while rejecting unsupported or malformed String-key Maps" do
    CrystalClick::WidePart.supports_typed_type?("Map(String, UInt64)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(String, String)").should be_true
    [
      "Map(String, LowCardinality(String))",
      "Map(Nullable(String), UInt64)",
      "Map(Nullable(String), String)",
      "Nullable(Map(String, UInt64))",
      "Map( String, UInt64)",
      "Map(String,UInt64)",
      "Map(String, UInt64) trailing",
      "Map(String, Map(String, UInt64))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads exact stock substreams, ordered duplicate keys, binary keys, and later marks" do
    u64_reader = CrystalClick::WidePart.open_typed(W52_STRING_MAP_FIXTURE, "map_u64")
    string_reader = CrystalClick::WidePart.open_typed(W52_STRING_MAP_FIXTURE, "map_string")
    u64_reader.column_type.should eq("Map(String, UInt64)")
    string_reader.column_type.should eq("Map(String, String)")
    u64_reader.row_count.should eq(7_u64)
    string_reader.row_count.should eq(7_u64)
    u64_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    string_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])

    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_u64.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_u64%2Ekeys.size").should eq(
      W52_MAP_STRING_UINT64_VALUES.flatten.map { |key, _value| key.bytesize.to_u64 }
    )
    w52_raw_stream(W52_STRING_MAP_FIXTURE, "map_u64%2Ekeys").should eq(
      w52_string_bytes(W52_MAP_STRING_UINT64_VALUES.flatten.map(&.[0]))
    )
    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_u64%2Evalues").should eq(
      W52_MAP_STRING_UINT64_VALUES.flatten.map(&.[1])
    )
    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_string.size0").should eq([0_u64, 2_u64, 2_u64, 2_u64, 0_u64, 2_u64, 1_u64])
    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_string%2Ekeys.size").should eq(
      W52_MAP_STRING_STRING_VALUES.flatten.map { |key, _value| key.bytesize.to_u64 }
    )
    w52_raw_stream(W52_STRING_MAP_FIXTURE, "map_string%2Ekeys").should eq(
      w52_string_bytes(W52_MAP_STRING_STRING_VALUES.flatten.map(&.[0]))
    )
    w52_raw_u64_stream(W52_STRING_MAP_FIXTURE, "map_string%2Evalues.size").should eq(
      W52_MAP_STRING_STRING_VALUES.flatten.map { |_key, value| value.bytesize.to_u64 }
    )
    w52_raw_stream(W52_STRING_MAP_FIXTURE, "map_string%2Evalues").should eq(
      w52_string_bytes(W52_MAP_STRING_STRING_VALUES.flatten.map(&.[1]))
    )

    expected_mark_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
    [
      "pk", "map_u64.size0", "map_u64%2Ekeys.size", "map_u64%2Ekeys", "map_u64%2Evalues",
      "map_string.size0", "map_string%2Ekeys.size", "map_string%2Ekeys",
      "map_string%2Evalues.size", "map_string%2Evalues",
    ].each do |stream|
      w52_mark_rows(W52_STRING_MAP_FIXTURE, stream).should eq(expected_mark_rows)
    end

    u64_reader.read_map_string_uint64_mark_range("map_u64", 0, u64_reader.mark_count)
      .should eq(W52_MAP_STRING_UINT64_VALUES)
    string_reader.read_map_string_string_mark_range("map_string", 0, string_reader.mark_count)
      .should eq(W52_MAP_STRING_STRING_VALUES)
    u64_reader.read_map_string_uint64_mark_range("map_u64", 1, 2)
      .should eq(W52_MAP_STRING_UINT64_VALUES[2, 4])
    string_reader.read_map_string_string_mark_range("map_string", 1, 2)
      .should eq(W52_MAP_STRING_STRING_VALUES[2, 4])
    u64_reader.read_map_string_uint64_mark_range("map_u64", 3, 1)
      .should eq(W52_MAP_STRING_UINT64_VALUES[6, 1])
    string_reader.read_map_string_string_mark_range("map_string", 3, 1)
      .should eq(W52_MAP_STRING_STRING_VALUES[6, 1])
    u64_reader.map_string_uint64_mark_range_raw_bytes("map_u64", 0, 1).should eq(22_u64)
    u64_reader.map_string_uint64_mark_range_materialization_preflight("map_u64", 0, 1)
      .should eq({22_u64, 70_u64})
    string_reader.map_string_string_mark_range_raw_bytes("map_string", 0, 1).should eq(12_u64)
    string_reader.map_string_string_mark_range_materialization_preflight("map_string", 0, 1)
      .should eq({12_u64, 60_u64})
    expect_raises(CrystalClick::BoundsError) { u64_reader.read_map_string_uint64_mark_range("map_u64", 0, 0) }
    expect_raises(CrystalClick::BoundsError) { string_reader.read_map_string_string_mark_range("map_string", 0, 0) }
  end

  it "returns aligned typed-table batches and catalog values for both shapes" do
    with_w52_fixture_copy do |part_path|
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "map_u64", "map_string"])
      observed_u64 = [] of {UInt64, Array(Tuple(String, UInt64))}
      observed_string = [] of {UInt64, Array(Tuple(String, String))}
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        u64_maps = batch.map_string_uint64s_for("map_u64")
        string_maps = batch.map_string_strings_for("map_string")
        keys.each_with_index do |key, index|
          observed_u64 << {key, u64_maps[index]}
          observed_string << {key, string_maps[index]}
        end
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.map_uint64_strings_for("map_u64") }
      end
      observed_u64.should eq(W52_KEYS.zip(W52_MAP_STRING_UINT64_VALUES).map { |key, value| {key, value} })
      observed_string.should eq(W52_KEYS.zip(W52_MAP_STRING_STRING_VALUES).map { |key, value| {key, value} })
    end

    root = File.tempname("crystal-click-w52-map-catalog")
    Dir.mkdir(root)
    begin
      w52_create_catalog_fixture(root)
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      u64_values = table["map_u64"].values.map { |value| value.as(Array(Tuple(String, UInt64))) }
      string_values = table["map_string"].values.map { |value| value.as(Array(Tuple(String, String))) }
      u64_values.should eq(W52_MAP_STRING_UINT64_VALUES)
      string_values.should eq(W52_MAP_STRING_STRING_VALUES)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a shifted String-key boundary before a typed-table callback" do
    with_w52_fixture_copy do |path|
      stream = "map_string%2Ekeys"
      marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
      original = File.read(marks_path).to_slice.dup
      marks = original.dup
      mark_size = CrystalClick::WidePart::MARK_SIZE
      raise "W52 key marks lack the expected four marks and sentinel" unless marks.size == 5 * mark_size

      original_rows = w52_mark_rows(path, stream)
      original_rows.should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      old_offset = w52_read_u64(marks, mark_size + 8)
      w52_write_u64(marks, mark_size + 8, old_offset + 1_u64)
      File.write(marks_path, marks)
      w52_mark_rows(path, stream).should eq(original_rows)
      File.size(marks_path).should eq(original.size.to_i64)

      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([path], ["pk", "map_string"])
        table.scan_typed(batch_rows: 2) { callback_count += 1 }
      end
      callback_count.should eq(0)
    end
  end

  it "keeps scan delivery streaming when a later selected mark is corrupt" do
    with_w52_fixture_copy do |path|
      stream = "map_string%2Ekeys"
      marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      mark_size = CrystalClick::WidePart::MARK_SIZE
      shifted_offset = mark_size * 2 + 8
      w52_write_u64(marks, shifted_offset, w52_read_u64(marks, shifted_offset) + 1_u64)
      File.write(marks_path, marks)

      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([path], ["pk", "map_string"])
        table.scan_typed(batch_rows: 2) { callback_count += 1 }
      end
      callback_count.should eq(1)
    end
  end
end
