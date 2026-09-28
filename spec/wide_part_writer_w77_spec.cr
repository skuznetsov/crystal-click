require "./spec_helper"

private def w77_writer_value_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w77_writer_u64_maps(samples : Array(T)) : Array(Array(Tuple(UInt64, T?))) forall T
  raise "W77 test needs at least three values" if samples.size < 3
  [
    [] of Tuple(UInt64, T?),
    [{7_u64, nil}, {7_u64, samples[0]}] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [{UInt64::MAX, samples[2]}, {0_u64, nil}] of Tuple(UInt64, T?),
    [{42_u64, samples[1]}] of Tuple(UInt64, T?),
    [{9_u64, samples[samples.size - 1]}] of Tuple(UInt64, T?),
  ] of Array(Tuple(UInt64, T?))
end

private def w77_writer_string_maps(samples : Array(T)) : Array(Array(Tuple(String, T?))) forall T
  raise "W77 test needs at least three values" if samples.size < 3
  [
    [] of Tuple(String, T?),
    [{"dup", nil}, {"dup", samples[0]}] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [{"", samples[2]}, {"雪", nil}] of Tuple(String, T?),
    [{"later", samples[1]}] of Tuple(String, T?),
    [{"tail", samples[samples.size - 1]}] of Tuple(String, T?),
  ] of Array(Tuple(String, T?))
end

private def w77_writer_assert_u64_maps(expected : Array(Array(Tuple(UInt64, T?))), actual : Array(Array(Tuple(UInt64, T?)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      actual_value = actual[row][entry][1]
      if expected_value = expected_entry[1]
        actual_value.should_not be_nil
        w77_writer_value_equal?(expected_value, actual_value.not_nil!).should be_true
      else
        actual_value.should be_nil
      end
    end
  end
  nil
end

private def w77_writer_assert_string_maps(expected : Array(Array(Tuple(String, T?))), actual : Array(Array(Tuple(String, T?)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      actual_value = actual[row][entry][1]
      if expected_value = expected_entry[1]
        actual_value.should_not be_nil
        w77_writer_value_equal?(expected_value, actual_value.not_nil!).should be_true
      else
        actual_value.should be_nil
      end
    end
  end
  nil
end

private def w77_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin"))
  CrystalClick::CompressedBlock.decode_all(encoded.to_slice).to_a
end

private def w77_writer_numeric_bytes(values : Array(T)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |value|
    {% if T == UInt8 || T == Int8 %}
      bits = value.unsafe_as(UInt8)
      bytes << bits
    {% elsif T == UInt16 || T == Int16 %}
      bits = value.unsafe_as(UInt16)
      2.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u16).to_u8 }
    {% elsif T == UInt32 || T == Int32 || T == Float32 %}
      bits = value.unsafe_as(UInt32)
      4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
    {% elsif T == UInt64 || T == Int64 || T == Float64 %}
      bits = value.unsafe_as(UInt64)
      8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
    {% else %}
      raise "unsupported W77 test numeric type"
    {% end %}
  end
  bytes
end

private def w77_writer_numeric_width(type_name : String) : Int32
  case type_name
  when "UInt8", "Int8"              then 1
  when "UInt16", "Int16"            then 2
  when "UInt32", "Int32", "Float32" then 4
  when "UInt64", "Int64", "Float64" then 8
  else
    raise "unsupported W77 test numeric type"
  end
end

private def w77_writer_nullable_numeric_bytes(values : Array(Tuple(K, T?)), width : Int32) : Array(UInt8) forall K, T
  bytes = [] of UInt8
  values.each do |_key, value|
    if numeric = value
      bytes.concat(w77_writer_numeric_bytes([numeric]))
    else
      bytes.concat(Array(UInt8).new(width, 0_u8))
    end
  end
  bytes
end

private def w77_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W77 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
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

private def w77_writer_assert_inventory(path : String, streams : Array(String)) : Nil
  expected = ["count.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected << "#{base}.bin" << "#{base}.mrk2"
  end
  checksums = CrystalClick::PartChecksums.open(path)
  checksums.entries.keys.sort.should eq(expected.sort)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(path, name) }
  nil
end

private def w77_writer_assert_typed_maps(samples : Array(T), type_name : String) : Nil forall T
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  u64_maps = w77_writer_u64_maps(samples)
  string_maps = w77_writer_string_maps(samples)
  parent = File.tempname("crystal-click-w77-writer")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "u64-map")
  string_path = File.join(parent, "string-map")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
      u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
      u64_maps.to_unsafe.to_slice(u64_maps.size), rows_per_mark: 2
    ).should eq(u64_path)
    CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
      string_path, "pk", keys.to_unsafe.to_slice(keys.size), "m",
      string_maps.to_unsafe.to_slice(string_maps.size), rows_per_mark: 2
    ).should eq(string_path)

    u64_reader = CrystalClick::WidePart.open_typed(u64_path, "m")
    string_reader = CrystalClick::WidePart.open_typed(string_path, "m")
    u64_reader.column_type.should eq("Map(UInt64, Nullable(#{type_name}))")
    string_reader.column_type.should eq("Map(String, Nullable(#{type_name}))")
    w77_writer_assert_u64_maps(u64_maps, u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 0, 4, T))
    w77_writer_assert_string_maps(string_maps, string_reader.read_map_string_nullable_numeric_mark_range("m", 0, 4, T))
    w77_writer_assert_u64_maps(u64_maps[4, 2], u64_reader.read_map_uint64_nullable_numeric_mark_range("m", 2, 1, T))
    w77_writer_assert_string_maps(string_maps[4, 2], string_reader.read_map_string_nullable_numeric_mark_range("m", 2, 1, T))

    File.read(File.join(u64_path, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
      "4 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys\n\tm%2Evalues.null\n\tm%2Evalues\n"
    )
    File.read(File.join(string_path, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
      "5 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys.size\n\tm%2Ekeys\n\tm%2Evalues.null\n\tm%2Evalues\n"
    )
    expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    File.read(File.join(u64_path, "serialization.json")).should eq(expected_serialization)
    File.read(File.join(string_path, "serialization.json")).should eq(expected_serialization)

    u64_streams = ["pk", "m.size0", "m%2Ekeys", "m%2Evalues.null", "m%2Evalues"]
    string_streams = ["pk", "m.size0", "m%2Ekeys.size", "m%2Ekeys", "m%2Evalues.null", "m%2Evalues"]
    w77_writer_assert_inventory(u64_path, u64_streams)
    w77_writer_assert_inventory(string_path, string_streams)
    (u64_streams + string_streams).each do |stream|
      path = u64_streams.includes?(stream) ? u64_path : string_path
      w77_writer_marks(path, stream).map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
    end
    [{u64_path, u64_streams}, {string_path, string_streams}].each do |path, streams|
      streams.each do |stream|
        marks = w77_writer_marks(path, stream)
        marks.each { |mark| mark[1].should eq(0_u64) }
      end
      (streams - ["pk", "m.size0"]).each do |stream|
        marks = w77_writer_marks(path, stream)
        marks[2][0].should eq(marks[1][0])
      end
    end

    u64_flat = u64_maps.flatten
    w77_writer_raw_stream(u64_path, "m%2Evalues.null").should eq(u64_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 })
    w77_writer_raw_stream(u64_path, "m%2Evalues").should eq(w77_writer_nullable_numeric_bytes(u64_flat, w77_writer_numeric_width(type_name)))
    string_flat = string_maps.flatten
    w77_writer_raw_stream(string_path, "m%2Evalues.null").should eq(string_flat.map { |_key, value| value.nil? ? 1_u8 : 0_u8 })
    w77_writer_raw_stream(string_path, "m%2Evalues").should eq(w77_writer_nullable_numeric_bytes(string_flat, w77_writer_numeric_width(type_name)))
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W77 nullable primitive-numeric Map writer" do
  it "writes all ten exact numeric value leaves for both key shapes" do
    w77_writer_assert_typed_maps([0_u8, UInt8::MAX, 7_u8], "UInt8")
    w77_writer_assert_typed_maps([0_u16, UInt16::MAX, 7_u16], "UInt16")
    w77_writer_assert_typed_maps([0_u32, UInt32::MAX, 7_u32], "UInt32")
    w77_writer_assert_typed_maps([0_u64, UInt64::MAX, 7_u64], "UInt64")
    w77_writer_assert_typed_maps([0_i8, Int8::MIN, Int8::MAX], "Int8")
    w77_writer_assert_typed_maps([0_i16, Int16::MIN, Int16::MAX], "Int16")
    w77_writer_assert_typed_maps([0_i32, Int32::MIN, Int32::MAX], "Int32")
    w77_writer_assert_typed_maps([0_i64, Int64::MIN, Int64::MAX], "Int64")
    w77_writer_assert_typed_maps([
      0.0_f32,
      0x7fc00001_u32.unsafe_as(Float32),
      0x80000000_u32.unsafe_as(Float32),
      Float32::INFINITY,
    ], "Float32")
    w77_writer_assert_typed_maps([
      0.0_f64,
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x8000000000000000_u64.unsafe_as(Float64),
      Float64::INFINITY,
    ], "Float64")
  end

  it "rejects a nullable Bool value before creating a staging directory" do
    parent = File.tempname("crystal-click-w77-writer-reject")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    maps = [[{1_u64, true}, {2_u64, nil}] of Tuple(UInt64, Bool?)]
    string_destination = File.join(parent, "string-part")
    string_maps = [[{"one", true}, {"two", nil}] of Tuple(String, Bool?)]
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          maps.to_unsafe.to_slice(maps.size),
          rows_per_mark: 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
          string_destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          string_maps.to_unsafe.to_slice(string_maps.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
      File.exists?(string_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a mismatched primary-key and value row count before staging" do
    parent = File.tempname("crystal-click-w77-writer-row-count")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    maps = [[{1_u64, 7_u8}] of Tuple(UInt64, UInt8?)]
    string_destination = File.join(parent, "string-part")
    string_maps = [[{"one", 7_u8}] of Tuple(String, UInt8?)]
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
          destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "m",
          maps.to_unsafe.to_slice(maps.size),
          rows_per_mark: 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
          string_destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "m",
          string_maps.to_unsafe.to_slice(string_maps.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
      File.exists?(string_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes the private stage when final publication fails" do
    parent = File.tempname("crystal-click-w77-writer-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    maps = [[{1_u64, 7_u8}] of Tuple(UInt64, UInt8?)]
    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          maps.to_unsafe.to_slice(maps.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
