require "./spec_helper"

W26_STOCK_MAP_FIXTURE = File.expand_path("../test/fixtures/stock_map_uint64_uint64_lz4/part", __DIR__)

private def w26_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  filename = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(filename).to_slice
  raw = [] of UInt8
  offset = 0_i64
  while offset < encoded.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, offset)
    frame.output.each { |byte| raw << byte }
    offset = frame.end_offset
  end
  raise "misaligned W26 UInt64 stream" unless raw.size % 8 == 0
  Array(UInt64).new(raw.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= raw[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def with_w26_stock_copy(&)
  parent = File.tempname("crystal-click-w26-map-reader")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(W26_STOCK_MAP_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w26_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

describe CrystalClick::WidePart do
  it "recognizes only the exact Map(UInt64, UInt64) spelling" do
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, UInt64)").should be_true
    [
      "Map(UInt32, UInt64)",
      "Map(UInt64, UInt32)",
      "Nullable(Map(UInt64, UInt64))",
      "Map( UInt64, UInt64)",
      "Map(UInt64,UInt64)",
      "Map(UInt64, UInt64) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the pinned stock three-stream Map without losing order or duplicate keys" do
    reader = CrystalClick::WidePart.open_typed(W26_STOCK_MAP_FIXTURE, "m")
    reader.column_type.should eq("Map(UInt64, UInt64)")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w26_raw_u64_stream(W26_STOCK_MAP_FIXTURE, "m.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
    w26_raw_u64_stream(W26_STOCK_MAP_FIXTURE, "m%2Ekeys").should eq([3_u64, 3_u64, 0_u64, UInt64::MAX, 42_u64, 6_u64, 1_u64, 5_u64])
    w26_raw_u64_stream(W26_STOCK_MAP_FIXTURE, "m%2Evalues").should eq([0_u64, UInt64::MAX, 0_u64, 42_u64, UInt64::MAX, 8_u64, 9_u64, 5_u64])

    expected = [
      [] of Tuple(UInt64, UInt64),
      [{3_u64, 0_u64}, {3_u64, UInt64::MAX}],
      [{0_u64, 0_u64}, {UInt64::MAX, 42_u64}],
      [{42_u64, UInt64::MAX}],
      [] of Tuple(UInt64, UInt64),
      [{6_u64, 8_u64}, {1_u64, 9_u64}],
      [{5_u64, 5_u64}],
    ] of Array(Tuple(UInt64, UInt64))
    reader.read_map_uint64_uint64_mark_range("m", 0, 4).should eq(expected)
    reader.read_map_uint64_uint64_mark_range("m", 1, 2).should eq(expected[2, 4])
    reader.read_map_uint64_uint64_mark_range("m", 3, 1).should eq(expected[6, 1])
    # Both flattened children consume 8 bytes per entry and count toward the
    # aggregate materialization preflight, not just the value child.
    reader.map_uint64_uint64_mark_range_raw_bytes("m", 0, 1).should eq(32_u64)
    reader.map_uint64_uint64_mark_range_raw_bytes("m", 1, 1).should eq(48_u64)
    expect_raises(CrystalClick::BoundsError) { reader.read_map_uint64_uint64_mark_range("m", 0, 0) }
    expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_uint64_mark_range("m", 0, 1) }
  end

  it "exposes stock Map rows in aligned typed batches" do
    observed = [] of {UInt64, Array(Tuple(UInt64, UInt64))}
    with_w26_stock_copy do |part_path|
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "m"])
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        maps = batch.map_uint64_uint64s_for("m")
        keys.each_with_index { |key, index| observed << {key, maps[index]} }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.map_uint64_strings_for("m") }
      end
    end
    observed.should eq([
      {0_u64, [] of Tuple(UInt64, UInt64)},
      {2_u64, [{3_u64, 0_u64}, {3_u64, UInt64::MAX}]},
      {4_u64, [{0_u64, 0_u64}, {UInt64::MAX, 42_u64}]},
      {6_u64, [{42_u64, UInt64::MAX}]},
      {9_u64, [] of Tuple(UInt64, UInt64)},
      {11_u64, [{6_u64, 8_u64}, {1_u64, 9_u64}]},
      {13_u64, [{5_u64, 5_u64}]},
    ])
  end

  it "returns caller-owned Map entries from an offline catalog column" do
    root = File.tempname("crystal-click-w26-map-catalog")
    Dir.mkdir(root)
    begin
      database_uuid = "2e948f1e-c0c7-49d5-836f-b31a8dd1f190"
      table_uuid = "bc16c4be-3d6d-418c-a04f-42ce1c8cba9d"
      database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
      table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
      FileUtils.mkdir_p(File.join(root, "metadata"))
      FileUtils.mkdir_p(database_store)
      FileUtils.mkdir_p(table_store)
      File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
      File.write(
        File.join(database_store, "maps.sql"),
        "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `m` Map(UInt64, UInt64)\n)\nENGINE = MergeTree\nORDER BY pk\n"
      )
      File.write(File.join(table_store, "format_version.txt"), "1\n")
      Dir.mkdir(File.join(table_store, "detached"))
      FileUtils.cp_r(W26_STOCK_MAP_FIXTURE, File.join(table_store, "all_1_1_0"))

      column = CrystalClick::OfflineCatalog.open(root)["lab"]["maps"]["m"]
      values = column.values.map { |value| value.as(Array(Tuple(UInt64, UInt64))) }
      values[1].should eq([{3_u64, 0_u64}, {3_u64, UInt64::MAX}])
      values[1][0] = {99_u64, 99_u64}
      values[1] << {100_u64, 100_u64}
      column.values.map { |value| value.as(Array(Tuple(UInt64, UInt64))) }[1].should eq([{3_u64, 0_u64}, {3_u64, UInt64::MAX}])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a child mark whose entry boundary diverges from the other child" do
    with_w26_stock_copy do |path|
      marks_path = File.join(path, "#{CrystalClick::StreamName.hash("m%2Evalues")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # Second granule must begin after two flattened UInt64 values (16 B).
      w26_write_u64(marks, 24, 24_u64)
      File.write(marks_path, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(path, "m").read_map_uint64_uint64_mark_range("m", 0, 2)
      end
    end
  end
end
