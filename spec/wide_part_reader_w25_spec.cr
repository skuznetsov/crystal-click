require "./spec_helper"

W25_STOCK_MAP_FIXTURE = File.expand_path("../test/fixtures/stock_map_uint64_string_lz4/part", __DIR__)

private def w25_reader_raw_stream(path : String, stream : String) : Array(UInt8)
  file = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded_string = File.read(file)
  encoded = encoded_string.to_slice
  raw = [] of UInt8
  frame_offset = 0_i64
  while frame_offset < encoded.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, frame_offset)
    frame.output.each { |byte| raw << byte }
    frame_offset = frame.end_offset
  end
  raw
end

private def w25_reader_decode_u64s(bytes : Array(UInt8)) : Array(UInt64)
  raise "W25 raw U64 stream is misaligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def with_w25_reader_stock_copy(&)
  parent = File.tempname("crystal-click-w25-map-reader")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(W25_STOCK_MAP_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w25_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w25_reader_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W25 mutation stream cannot encode an empty frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w25_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w25_reader_write_u32(frame, header + 5, raw.size.to_u32)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  8.times do |byte|
    frame[byte] = ((hash[0] >> (byte * 8)) & 0xff_u64).to_u8
    frame[8 + byte] = ((hash[1] >> (byte * 8)) & 0xff_u64).to_u8
  end
  frame
end

private def w25_reader_replace_u64_stream(path : String, stream : String, & : Bytes -> Nil) : Nil
  file = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  raw_values = w25_reader_raw_stream(path, stream)
  raw = Bytes.new(raw_values.size)
  raw_values.each_with_index { |byte, index| raw[index] = byte }
  yield raw
  File.write(file, w25_reader_encode_lz4_frame(raw))
end

private def w25_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def with_w25_reader_catalog_root(&)
  root = File.tempname("crystal-click-w25-map-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w25_reader_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w25_reader_create_catalog_fixture(root : String) : String
  database_uuid = "835e7af8-f57c-42b8-bcb0-863f3de0ca51"
  table_uuid = "1f068934-2439-44ce-9501-c2dc252a9027"
  database_store = w25_reader_catalog_store_path(root, database_uuid)
  table_store = w25_reader_catalog_store_path(root, table_uuid)
  FileUtils.mkdir_p(database_store)
  FileUtils.mkdir_p(table_store)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `id` UInt64,\n    `m` Map(UInt64, String),\n    `a` Array(Tuple(k UInt64, v String))\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  part_path = File.join(table_store, "all_1_1_0")
  FileUtils.cp_r(W25_STOCK_MAP_FIXTURE, part_path)
  part_path
end

describe CrystalClick::WidePart do
  it "admits only the exact top-level Map(UInt64, String) type" do
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, String)").should be_true
    [
      "Map(String, String)",
      "Map(UInt64, UInt64)",
      "Map(UInt64, LowCardinality(String))",
      "Nullable(Map(UInt64, String))",
      "Map( UInt64, String)",
      "Map(UInt64,String)",
      "Map(UInt64, String) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "decodes the pinned stock raw size0 semantics, including empty maps and duplicate keys" do
    reader = CrystalClick::WidePart.open_typed(W25_STOCK_MAP_FIXTURE, "m")
    reader.column_type.should eq("Map(UInt64, String)")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])

    # ClickHouse's MergeTree position-independent Array encoding stores row
    # counts, not cumulative offsets. This raw-byte assertion distinguishes
    # [0, 3, 2, ...] from the incompatible cumulative interpretation.
    w25_reader_decode_u64s(w25_reader_raw_stream(W25_STOCK_MAP_FIXTURE, "m.size0")).should eq(
      [0_u64, 3_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64]
    )
    w25_reader_decode_u64s(w25_reader_raw_stream(W25_STOCK_MAP_FIXTURE, "m%2Ekeys")).should eq(
      [7_u64, 7_u64, 2_u64, 99_u64, 3_u64, 42_u64, 8_u64, 1_u64, 5_u64]
    )
    w25_reader_decode_u64s(w25_reader_raw_stream(W25_STOCK_MAP_FIXTURE, "m%2Evalues.size")).should eq(
      [5_u64, 6_u64, 5_u64, 8_u64, 5_u64, 0_u64, 4_u64, 4_u64, 3_u64]
    )
    w25_reader_raw_stream(W25_STOCK_MAP_FIXTURE, "m%2Evalues").should eq(
      "firstsecondthirdnul\0tailé雪💥lastfin".to_slice.to_a
    )

    expected = [
      [] of Tuple(UInt64, String),
      [{7_u64, "first"}, {7_u64, "second"}, {2_u64, "third"}],
      [{99_u64, "nul\0tail"}, {3_u64, "é雪"}],
      [{42_u64, ""}],
      [] of Tuple(UInt64, String),
      [{8_u64, "💥"}, {1_u64, "last"}],
      [{5_u64, "fin"}],
    ] of Array(Tuple(UInt64, String))

    reader.read_map_uint64_string_mark_range("m", 0, reader.mark_count).should eq(expected)
    reader.read_map_uint64_string_mark_range("m", 1, 2).should eq(expected[2, 4])
    reader.read_map_uint64_string_mark_range("m", 3, 1).should eq(expected[6, 1])
    expect_raises(CrystalClick::BoundsError) { reader.read_map_uint64_string_mark_range("m", 0, 0) }
    expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_string_mark_range("m", 0, 1) }
    expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_string_mark_range("m", 0, 1) }
  end

  it "preserves a nonadjacent duplicate key in stock-shaped positional streams" do
    with_w25_reader_stock_copy do |path|
      # The stock first populated map is [7, 7, 2]. Move only its final two
      # keys, retaining the independently pinned String values.
      w25_reader_replace_u64_stream(path, "m%2Ekeys") do |raw|
        w25_reader_write_u64(raw, 8, 2_u64)
        w25_reader_write_u64(raw, 16, 7_u64)
      end
      rows = CrystalClick::WidePart.open_typed(path, "m").read_map_uint64_string_mark_range("m", 0, 2)
      rows[1].should eq([{7_u64, "first"}, {2_u64, "second"}, {7_u64, "third"}])
    end
  end

  it "scans the stock Map through batches and catalog-owned projections" do
    expected = [
      [] of Tuple(UInt64, String),
      [{7_u64, "first"}, {7_u64, "second"}, {2_u64, "third"}],
      [{99_u64, "nul\0tail"}, {3_u64, "é雪"}],
      [{42_u64, ""}],
      [] of Tuple(UInt64, String),
      [{8_u64, "💥"}, {1_u64, "last"}],
      [{5_u64, "fin"}],
    ] of Array(Tuple(UInt64, String))
    with_w25_reader_stock_copy do |part_path|
      table_reader = CrystalClick::WidePartTable.open_selected_typed([part_path], ["id", "m"])
      observed = [] of {UInt64, Array(Tuple(UInt64, String))}
      table_reader.scan_typed(batch_rows: 3) do |batch|
        identifiers = batch.values_for("id", UInt64)
        maps = batch.map_uint64_strings_for("m")
        identifiers.each_with_index { |id, index| observed << {id, maps[index]} }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_strings_for("m") }
      end
      observed.should eq((1_u64...8_u64).map { |id| {id, expected[(id - 1).to_i]} }.to_a)
    end

    with_w25_reader_catalog_root do |root|
      w25_reader_create_catalog_fixture(root)
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      source_string = ""
      table.scan_typed(["m"]) do |batch|
        batch.map_uint64_strings_for("m").each do |row|
          row.each do |_key, value|
            source_string = value if source_string.empty? && !value.empty?
          end
        end
      end

      selection = table["m"]
      materialized = selection.values.map { |value| value.as(Array(Tuple(UInt64, String))) }
      materialized.should eq(expected)
      materialized[1][0][1].to_unsafe.should_not eq(source_string.to_unsafe)
      materialized[1][0] = {7_u64, "caller-owned replacement"}
      materialized[1] << {9_u64, "caller-owned append"}
      selection.values.map { |value| value.as(Array(Tuple(UInt64, String))) }.should eq(expected)
      expect_raises(CrystalClick::BoundsError) { selection.values(max_string_bytes: 39_u64) }
    end
  end

  it "fails closed on map serialization versions, malformed marks, and entry or byte limits" do
    with_w25_reader_stock_copy do |path|
      serialization_path = File.join(path, "serialization.json")
      serialization = File.read(serialization_path)
      File.write(
        serialization_path,
        serialization.sub(%("types_serialization_versions":{"string":1}), %("types_serialization_versions":{"map":1,"string":1}))
      )
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(path, "m") }
    end

    with_w25_reader_stock_copy do |path|
      mark_path = File.join(path, "#{CrystalClick::StreamName.hash("m.size0")}.mrk2")
      marks = File.read(mark_path).to_slice.dup
      w25_reader_write_u64(marks, 8, 8_u64)
      File.write(mark_path, marks)
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(path, "m") }
    end

    with_w25_reader_stock_copy do |path|
      # Turn the first empty row into one entry while leaving the independent
      # key/value stream marks untouched; per-mark nested alignment must fail.
      w25_reader_replace_u64_stream(path, "m.size0") { |raw| w25_reader_write_u64(raw, 0, 1_u64) }
      reader = CrystalClick::WidePart.open_typed(path, "m")
      expect_raises(CrystalClick::CorruptPartError) { reader.read_map_uint64_string_mark_range("m", 0, 1) }
    end

    with_w25_reader_stock_copy do |path|
      w25_reader_replace_u64_stream(path, "m.size0") { |raw| w25_reader_write_u64(raw, 0, CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1) }
      reader = CrystalClick::WidePart.open_typed(path, "m")
      expect_raises(CrystalClick::CorruptPartError) { reader.read_map_uint64_string_mark_range("m", 0, 1) }
    end

    with_w25_reader_stock_copy do |path|
      w25_reader_replace_u64_stream(path, "m%2Evalues.size") do |raw|
        w25_reader_write_u64(raw, 0, CrystalClick::WidePart::MAX_ARRAY_MARK_BYTES.to_u64 + 1)
      end
      reader = CrystalClick::WidePart.open_typed(path, "m")
      expect_raises(CrystalClick::CorruptPartError) { reader.read_map_uint64_string_mark_range("m", 0, 1) }
      expect_raises(CrystalClick::CorruptPartError) { reader.map_uint64_string_mark_range_raw_bytes("m", 0, 1) }
    end
  end

  it "rejects metadata symlinks that escape the selected part directory" do
    ["columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "count.txt"].each do |name|
      with_w25_reader_stock_copy do |path|
        selected_file = File.join(path, name)
        outside_file = File.join(File.dirname(path), "outside-#{name}")
        File.write(outside_file, File.read(selected_file))
        File.delete(selected_file)
        File.symlink(outside_file, selected_file)

        expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(path, "m") }
      end
    end
  end
end
