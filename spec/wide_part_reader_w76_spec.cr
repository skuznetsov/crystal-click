require "./spec_helper"

W76_READER_W26_FIXTURE = File.expand_path("../test/fixtures/stock_map_uint64_uint64_lz4/part", __DIR__)
W76_READER_W52_FIXTURE = File.expand_path("../test/fixtures/public/wide_map_string_w52/part", __DIR__)
W76_READER_BINARY_KEY  = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])

private def w76_reader_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w76_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def with_w76_reader_u8_fixture(&)
  parent = File.tempname("crystal-click-w76-reader")
  Dir.mkdir(parent)
  path = File.join(parent, "u8-map")
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  rows = [
    [] of Tuple(UInt64, UInt8),
    [{7_u64, 0_u8}, {7_u64, UInt8::MAX}] of Tuple(UInt64, UInt8),
    [] of Tuple(UInt64, UInt8),
    [] of Tuple(UInt64, UInt8),
    [{UInt64::MAX, 17_u8}] of Tuple(UInt64, UInt8),
    [{0_u64, 44_u8}] of Tuple(UInt64, UInt8),
    [{42_u64, 5_u8}] of Tuple(UInt64, UInt8),
  ] of Array(Tuple(UInt64, UInt8))
  CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "m",
    rows.to_unsafe.to_slice(rows.size),
    rows_per_mark: 2
  )
  begin
    yield path, rows
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W76 scalar-numeric Map reader admission" do
  it "admits a narrow numeric value beside UInt64 Map keys" do
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, UInt8)").should be_true
  end

  it "admits a primitive Float32 value beside String Map keys" do
    CrystalClick::WidePart.supports_typed_type?("Map(String, Float32)").should be_true
    CrystalClick::WidePart.map_uint64_numeric_value_type("Map(UInt64, UInt8)").should eq("UInt8")
    CrystalClick::WidePart.map_string_numeric_value_type("Map(String, Float32)").should eq("Float32")
  end

  it "keeps scalar-numeric Map admission exact and bounded" do
    [
      "Map(UInt64, UInt128)",
      "Map(UInt64, Nullable(UInt8))",
      "Map(String, Decimal32(2))",
      "Map(String, Float32) trailing",
      "Map(String,Float32)",
      "Map( String, Float32)",
      "Nullable(Map(UInt64, UInt8))",
      "Map(UInt32, UInt8)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WidePart.supports_numeric_map_type?(type).should be_false
    end
  end

  it "reads narrow UInt8 rows including an empty middle mark and a later selected mark" do
    with_w76_reader_u8_fixture do |path, rows|
      reader = CrystalClick::WidePart.open_typed(path, "m")
      reader.column_type.should eq("Map(UInt64, UInt8)")
      reader.read_map_uint64_numeric_mark_range("m", 0, reader.mark_count, UInt8).should eq(rows)
      reader.read_map_uint64_numeric_mark_range("m", 1, 1, UInt8).should eq(rows[2, 2])
      reader.read_map_uint64_numeric_mark_range("m", 2, 1, UInt8).should eq(rows[4, 2])
      reader.map_uint64_numeric_mark_range_materialization_preflight("m", 1, 1, UInt8)
        .should eq({0_u64, 128_u64})
    end
  end

  it "retains the W26/W52 UInt64 Map controls through the generic numeric path" do
    uint64_reader = CrystalClick::WidePart.open_typed(W76_READER_W26_FIXTURE, "m")
    uint64_reader.read_map_uint64_numeric_mark_range("m", 1, 1, UInt64).should eq([
      [{0_u64, 0_u64}, {UInt64::MAX, 42_u64}] of Tuple(UInt64, UInt64),
      [{42_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
    ])
    uint64_reader.map_uint64_numeric_mark_range_materialization_preflight("m", 0, 1, UInt64)
      .should eq({32_u64, 192_u64})

    string_reader = CrystalClick::WidePart.open_typed(W76_READER_W52_FIXTURE, "map_u64")
    string_reader.read_map_string_numeric_mark_range("map_u64", 1, 1, UInt64).should eq([
      [{W76_READER_BINARY_KEY, 42_u64}, {"雪", 7_u64}] of Tuple(String, UInt64),
      [{"empty", UInt64::MAX}] of Tuple(String, UInt64),
    ])
    string_reader.map_string_numeric_mark_range_materialization_preflight("map_u64", 0, 1, UInt64)
      .should eq({22_u64, 182_u64})
  end

  it "rejects a child mark row-count corruption on the empty middle mark" do
    with_w76_reader_u8_fixture do |path, _rows|
      parent = File.tempname("crystal-click-w76-reader-corrupt")
      Dir.mkdir(parent)
      corrupted = File.join(parent, "bad-u8-map")
      FileUtils.cp_r(path, corrupted)
      begin
        mark_path = File.join(corrupted, "#{CrystalClick::StreamName.hash("m%2Evalues")}.mrk2")
        marks = File.read(mark_path).to_slice.dup
        mark_size = CrystalClick::WidePart::MARK_SIZE
        # Mark 1 contains two outer rows but no Map entries. The value stream
        # must still retain those row coordinates even though its byte offset
        # equals the following empty mark's offset.
        w76_reader_u64(marks, mark_size + 16).should eq(2_u64)
        w76_reader_u64(marks, mark_size * 2 + 16).should eq(2_u64)
        w76_reader_write_u64(marks, mark_size + 16, 1_u64)
        # Preserve the stream-wide row total so open succeeds; the selected
        # empty middle mark alone now disagrees with size0.
        w76_reader_write_u64(marks, mark_size * 2 + 16, 3_u64)
        File.open(mark_path, "wb") { |io| io.write(marks) }

        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(corrupted, "m")
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "preflights exact numeric byte extents on the selected empty middle mark" do
    with_w76_reader_u8_fixture do |path, _rows|
      parent = File.tempname("crystal-click-w76-reader-byte-corrupt")
      Dir.mkdir(parent)
      corrupted = File.join(parent, "bad-u8-map-width")
      FileUtils.cp_r(path, corrupted)
      begin
        mark_path = File.join(corrupted, "#{CrystalClick::StreamName.hash("m%2Evalues")}.mrk2")
        marks = File.read(mark_path).to_slice.dup
        mark_size = CrystalClick::WidePart::MARK_SIZE
        end_of_empty_middle_mark = mark_size * 2 + 8
        original_offset = w76_reader_u64(marks, end_of_empty_middle_mark)
        w76_reader_u64(marks, mark_size + 8).should eq(original_offset)
        w76_reader_write_u64(marks, end_of_empty_middle_mark, original_offset + 1_u64)
        File.open(mark_path, "wb") { |io| io.write(marks) }

        bad_reader = CrystalClick::WidePart.open_typed(corrupted, "m")
        expect_raises(CrystalClick::CorruptPartError) do
          bad_reader.map_uint64_numeric_mark_range_materialization_preflight("m", 1, 1, UInt8)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
