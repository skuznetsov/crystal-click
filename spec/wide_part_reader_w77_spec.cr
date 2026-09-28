require "./spec_helper"

W77_W53_CONTROL_FIXTURE = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)

private def w77_reader_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w77_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w77_reader_float64_equal?(expected : Float64?, actual : Float64?) : Bool
  if expected.nil?
    actual.nil?
  elsif actual.nil?
    false
  else
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  end
end

private def w77_reader_assert_string_maps(
  expected : Array(Array(Tuple(String, Float64?))),
  actual : Array(Array(Tuple(String, Float64?))),
) : Nil
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row_index|
    actual[row_index].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry_index|
      actual_entry = actual[row_index][entry_index]
      actual_entry[0].should eq(expected_entry[0])
      w77_reader_float64_equal?(expected_entry[1], actual_entry[1]).should be_true
    end
  end
  nil
end

private def with_w77_reader_maps(&)
  parent = File.tempname("crystal-click-w77-reader")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "u64-map")
  string_path = File.join(parent, "string-map")
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  u64_maps = [
    [] of Tuple(UInt64, UInt8?),
    [{7_u64, nil}, {7_u64, 0_u8}] of Tuple(UInt64, UInt8?),
    [] of Tuple(UInt64, UInt8?),
    [] of Tuple(UInt64, UInt8?),
    [{UInt64::MAX, UInt8::MAX}, {0_u64, nil}] of Tuple(UInt64, UInt8?),
    [{42_u64, 0_u8}] of Tuple(UInt64, UInt8?),
    [{9_u64, 7_u8}] of Tuple(UInt64, UInt8?),
  ] of Array(Tuple(UInt64, UInt8?))
  nan = 0x7ff8000000000001_u64.unsafe_as(Float64)
  string_maps = [
    [] of Tuple(String, Float64?),
    [{"dup", nil}, {"dup", 0.0_f64}] of Tuple(String, Float64?),
    [] of Tuple(String, Float64?),
    [] of Tuple(String, Float64?),
    [{"", nan}, {"雪", nil}] of Tuple(String, Float64?),
    [{"nan", nan}] of Tuple(String, Float64?),
    [{"tail", 1.25_f64}] of Tuple(String, Float64?),
  ] of Array(Tuple(String, Float64?))
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
      u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
      u64_maps.to_unsafe.to_slice(u64_maps.size), rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
      string_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
      string_maps.to_unsafe.to_slice(string_maps.size), rows_per_mark: 2
    )
    yield u64_path, string_path, u64_maps, string_maps
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W77 nullable primitive-numeric Map reader" do
  it "admits the exact nullable numeric family for both key shapes only" do
    leaves = ["UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"]
    leaves.each do |leaf|
      uint64_type = "Map(UInt64, Nullable(#{leaf}))"
      string_type = "Map(String, Nullable(#{leaf}))"
      CrystalClick::WidePart.map_uint64_nullable_numeric_value_type(uint64_type).should eq(leaf)
      CrystalClick::WidePart.map_string_nullable_numeric_value_type(string_type).should eq(leaf)
      CrystalClick::WidePart.supports_typed_type?(uint64_type).should be_true
      CrystalClick::WidePart.supports_typed_type?(string_type).should be_true
    end

    [
      "Map(UInt64, Nullable(UInt128))",
      "Map(String, Nullable(Decimal32(2)))",
      "Map(UInt32, Nullable(UInt8))",
      "Map(UInt64, Nullable(Nullable(UInt8)))",
      "Map(String,Nullable(UInt8))",
      "Map(String, Nullable(UInt8)) trailing",
      "Nullable(Map(UInt64, Nullable(UInt8)))",
      "Map(UInt64, Map(String, Nullable(UInt8)))",
    ].each do |type|
      CrystalClick::WidePart.map_uint64_nullable_numeric_value_type(type).should be_nil
      CrystalClick::WidePart.map_string_nullable_numeric_value_type(type).should be_nil
      CrystalClick::WidePart.supports_nullable_numeric_map_type?(type).should be_false
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
    CrystalClick::WidePart.supports_numeric_map_type?("Map(UInt64, Nullable(UInt8))").should be_false
  end

  it "decodes UInt8 and Float64 rows across empty, later, and tail marks" do
    with_w77_reader_maps do |u64_path, string_path, u64_maps, string_maps|
      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "m")
      string_reader = CrystalClick::WidePart.open_typed(string_path, "m")
      u64_reader.column_type.should eq("Map(UInt64, Nullable(UInt8))")
      string_reader.column_type.should eq("Map(String, Nullable(Float64))")
      u64_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      string_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])

      u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 0, u64_reader.mark_count, UInt8).should eq(u64_maps)
      w77_reader_assert_string_maps(
        string_maps,
        string_reader.read_map_string_nullable_numeric_mark_range("m", 0, string_reader.mark_count, Float64)
      )
      u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 1, 1, UInt8).should eq(u64_maps[2, 2])
      w77_reader_assert_string_maps(
        string_maps[2, 2],
        string_reader.read_map_string_nullable_numeric_mark_range("m", 1, 1, Float64)
      )
      u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 2, 1, UInt8).should eq(u64_maps[4, 2])
      w77_reader_assert_string_maps(
        string_maps[4, 2],
        string_reader.read_map_string_nullable_numeric_mark_range("m", 2, 1, Float64)
      )
      u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 3, 1, UInt8).should eq(u64_maps[6, 1])
      w77_reader_assert_string_maps(
        string_maps[6, 1],
        string_reader.read_map_string_nullable_numeric_mark_range("m", 3, 1, Float64)
      )

      u64_reader.map_uint64_nullable_numeric_mark_range_materialization_preflight("m", 1, 1, UInt8)
        .should eq({0_u64, 128_u64})
      string_reader.map_string_nullable_numeric_mark_range_materialization_preflight("m", 1, 1, Float64)
        .should eq({0_u64, 128_u64})
      u64_reader.map_uint64_nullable_numeric_mark_range_materialization_preflight("m", 2, 1, UInt8)
        .should eq({30_u64, 206_u64})
      string_reader.map_string_nullable_numeric_mark_range_materialization_preflight("m", 2, 1, Float64)
        .should eq({33_u64, 209_u64})

      expect_raises(CrystalClick::UnsupportedFormatError) do
        u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 0, 1, UInt64)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        string_reader.read_map_string_nullable_numeric_mark_range("m", 0, 1, Float32)
      end
    end
  end

  it "reads a final all-empty Map mark at nonzero child-stream EOF" do
    parent = File.tempname("crystal-click-w77-reader-empty-eof")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "u64-map")
    string_path = File.join(parent, "string-map")
    keys = [0_u64, 1_u64, 2_u64, 3_u64]
    u64_maps = [
      [{10_u64, 7_u8}] of Tuple(UInt64, UInt8?),
      [{11_u64, nil}] of Tuple(UInt64, UInt8?),
      [] of Tuple(UInt64, UInt8?),
      [] of Tuple(UInt64, UInt8?),
    ]
    string_maps = [
      [{"before", 7_u8}] of Tuple(String, UInt8?),
      [{"middle", nil}] of Tuple(String, UInt8?),
      [] of Tuple(String, UInt8?),
      [] of Tuple(String, UInt8?),
    ]
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
        u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
        u64_maps.to_unsafe.to_slice(u64_maps.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
        string_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
        string_maps.to_unsafe.to_slice(string_maps.size), rows_per_mark: 2
      )

      [
        {u64_path, ["m%2Ekeys", "m%2Evalues.null", "m%2Evalues"]},
        {string_path, ["m%2Ekeys.size", "m%2Ekeys", "m%2Evalues.null", "m%2Evalues"]},
      ].each do |part, streams|
        streams.each do |stream|
          base = CrystalClick::StreamName.hash(stream)
          data_path = File.join(part, "#{base}.bin")
          marks_path = File.join(part, "#{base}.mrk2")
          mark_offset = w77_reader_u64(File.read(marks_path).to_slice, CrystalClick::WidePart::MARK_SIZE)
          mark_offset.should be > 0_u64
          mark_offset.should eq(File.size(data_path).to_u64)
        end
      end

      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "m")
      string_reader = CrystalClick::WidePart.open_typed(string_path, "m")
      u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 1, 1, UInt8)
        .should eq(u64_maps[2, 2])
      string_reader.read_map_string_nullable_numeric_mark_range("m", 1, 1, UInt8)
        .should eq(string_maps[2, 2])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps the W53 UInt64 nullable-Map controls readable through the generic UInt64 path" do
    u64_reader = CrystalClick::WidePart.open_typed(W77_W53_CONTROL_FIXTURE, "map_u64")
    string_reader = CrystalClick::WidePart.open_typed(W77_W53_CONTROL_FIXTURE, "map_string")
    u64_reader.read_map_uint64_nullable_numeric_mark_range("map_u64", 0, u64_reader.mark_count, UInt64)
      .should eq(u64_reader.read_map_uint64_nullable_uint64_mark_range("map_u64", 0, u64_reader.mark_count))
    string_reader.read_map_string_nullable_numeric_mark_range("map_string", 0, string_reader.mark_count, UInt64)
      .should eq(string_reader.read_map_string_nullable_uint64_mark_range("map_string", 0, string_reader.mark_count))
    u64_reader.map_uint64_nullable_numeric_mark_range_materialization_preflight("map_u64", 1, 1, UInt64)
      .should eq({51_u64, 227_u64})
    string_reader.map_string_nullable_numeric_mark_range_materialization_preflight("map_string", 1, 1, UInt64)
      .should eq({53_u64, 245_u64})
  end

  it "rejects misaligned `.values.null` mark rows even when the stream-wide row total is preserved" do
    with_w77_reader_maps do |u64_path, _string_path, _u64_maps, _string_maps|
      parent = File.tempname("crystal-click-w77-reader-bad-null-mark")
      Dir.mkdir(parent)
      corrupted = File.join(parent, "bad-u64-map")
      FileUtils.cp_r(u64_path, corrupted)
      begin
        mark_path = File.join(corrupted, "#{CrystalClick::StreamName.hash("m%2Evalues.null")}.mrk2")
        marks = File.read(mark_path).to_slice.dup
        mark_size = CrystalClick::WidePart::MARK_SIZE
        w77_reader_u64(marks, mark_size + 16).should eq(2_u64)
        w77_reader_u64(marks, mark_size * 2 + 16).should eq(2_u64)
        w77_reader_write_u64(marks, mark_size + 16, 1_u64)
        w77_reader_write_u64(marks, mark_size * 2 + 16, 3_u64)
        File.open(mark_path, "wb") { |io| io.write(marks) }

        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(corrupted, "m")
        end
        (error.message || "").should contain("selected substreams have different mark row counts")
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects a non-boolean value in the nullable bitmap" do
    parent = File.tempname("crystal-click-w77-reader-bad-null-flag")
    Dir.mkdir(parent)
    part = File.join(parent, "u64-map")
    keys = [0_u64]
    maps = [[{1_u64, nil}] of Tuple(UInt64, UInt8?)]
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "m", maps.to_unsafe.to_slice(maps.size), rows_per_mark: 1
      )
      stream_path = File.join(part, "#{CrystalClick::StreamName.hash("m%2Evalues.null")}.bin")
      encoded = File.read(stream_path).to_slice.dup
      CrystalClick::CompressedBlock.decode_all(encoded).to_a.should eq([1_u8])
      encoded[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + 1] = 2_u8
      CrystalClick::CompressedBlock.decode_all(encoded).to_a.should eq([2_u8])
      File.open(stream_path, "wb") { |io| io.write(encoded) }

      reader = CrystalClick::WidePart.open_typed(part, "m")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_nullable_numeric_mark_range("m", 0, 1, UInt8)
      end
      (error.message || "").should contain("null-map byte is not boolean")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
