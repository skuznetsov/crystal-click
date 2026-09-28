require "./spec_helper"

private def w76_writer_value_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w76_writer_u64_maps(samples : Array(T)) : Array(Array(Tuple(UInt64, T))) forall T
  raise "W76 test needs at least three values" if samples.size < 3
  [
    [] of Tuple(UInt64, T),
    [{7_u64, samples[0]}, {7_u64, samples[1]}] of Tuple(UInt64, T),
    [] of Tuple(UInt64, T),
    [] of Tuple(UInt64, T),
    [{UInt64::MAX, samples[2]}] of Tuple(UInt64, T),
    [{0_u64, samples[1]}] of Tuple(UInt64, T),
    [{42_u64, samples[0]}] of Tuple(UInt64, T),
  ] of Array(Tuple(UInt64, T))
end

private def w76_writer_string_maps(samples : Array(T)) : Array(Array(Tuple(String, T))) forall T
  raise "W76 test needs at least three values" if samples.size < 3
  [
    [] of Tuple(String, T),
    [{"dup", samples[0]}, {"dup", samples[1]}] of Tuple(String, T),
    [] of Tuple(String, T),
    [] of Tuple(String, T),
    [{"", samples[2]}] of Tuple(String, T),
    [{"later", samples[1]}] of Tuple(String, T),
    [{"tail", samples[0]}] of Tuple(String, T),
  ] of Array(Tuple(String, T))
end

private def w76_writer_assert_u64_maps(expected : Array(Array(Tuple(UInt64, T))), actual : Array(Array(Tuple(UInt64, T)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      w76_writer_value_equal?(expected_entry[1], actual[row][entry][1]).should be_true
    end
  end
  nil
end

private def w76_writer_assert_string_maps(expected : Array(Array(Tuple(String, T))), actual : Array(Array(Tuple(String, T)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      w76_writer_value_equal?(expected_entry[1], actual[row][entry][1]).should be_true
    end
  end
  nil
end

private def w76_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W76 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
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

private def w76_writer_assert_map_child_offsets(path : String, string_keys : Bool) : Nil
  streams = if string_keys
              ["m%2Ekeys.size", "m%2Ekeys", "m%2Evalues"]
            else
              ["m%2Ekeys", "m%2Evalues"]
            end
  streams.each do |stream|
    marks = w76_writer_marks(path, stream)
    marks.map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
    marks[1][0].should be > 0_u64
    marks[2][0].should eq(marks[1][0])
    marks[3][0].should be > marks[2][0]
    marks[4][0].should be > marks[3][0]
    marks.each { |mark| mark[1].should eq(0_u64) }
  end
  nil
end

private def w76_writer_assert_checksum_inventory(path : String, streams : Array(String)) : Nil
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

private def w76_writer_assert_typed_maps(samples : Array(T), type_name : String) : Nil forall T
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  u64_maps = w76_writer_u64_maps(samples)
  string_maps = w76_writer_string_maps(samples)
  parent = File.tempname("crystal-click-w76-writer")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "u64-map")
  string_path = File.join(parent, "string-map")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
      u64_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "m",
      u64_maps.to_unsafe.to_slice(u64_maps.size),
      rows_per_mark: 2
    ).should eq(u64_path)
    CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
      string_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "m",
      string_maps.to_unsafe.to_slice(string_maps.size),
      rows_per_mark: 2
    ).should eq(string_path)

    u64_reader = CrystalClick::WidePart.open_typed(u64_path, "m")
    string_reader = CrystalClick::WidePart.open_typed(string_path, "m")
    u64_reader.column_type.should eq("Map(UInt64, #{type_name})")
    string_reader.column_type.should eq("Map(String, #{type_name})")
    w76_writer_assert_u64_maps(
      u64_maps,
      u64_reader.read_map_uint64_numeric_mark_range("m", 0, 4, T)
    )
    w76_writer_assert_string_maps(
      string_maps,
      string_reader.read_map_string_numeric_mark_range("m", 0, 4, T)
    )

    File.read(File.join(u64_path, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
      "3 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys\n\tm%2Evalues\n"
    )
    File.read(File.join(string_path, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
      "4 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys.size\n\tm%2Ekeys\n\tm%2Evalues\n"
    )
    w76_writer_assert_map_child_offsets(u64_path, string_keys: false)
    w76_writer_assert_map_child_offsets(string_path, string_keys: true)
    w76_writer_assert_checksum_inventory(u64_path, ["pk", "m.size0", "m%2Ekeys", "m%2Evalues"])
    w76_writer_assert_checksum_inventory(string_path, ["pk", "m.size0", "m%2Ekeys.size", "m%2Ekeys", "m%2Evalues"])
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe CrystalClick::WidePartWriter do
  it "writes the ten exact non-null primitive numeric Map leaves for both key shapes" do
    w76_writer_assert_typed_maps([0_u8, UInt8::MAX, 7_u8], "UInt8")
    w76_writer_assert_typed_maps([0_u16, UInt16::MAX, 7_u16], "UInt16")
    w76_writer_assert_typed_maps([0_u32, UInt32::MAX, 7_u32], "UInt32")
    w76_writer_assert_typed_maps([0_u64, UInt64::MAX, 7_u64], "UInt64")
    w76_writer_assert_typed_maps([Int8::MIN, Int8::MAX, -1_i8], "Int8")
    w76_writer_assert_typed_maps([Int16::MIN, Int16::MAX, -1_i16], "Int16")
    w76_writer_assert_typed_maps([Int32::MIN, Int32::MAX, -1_i32], "Int32")
    w76_writer_assert_typed_maps([Int64::MIN, Int64::MAX, -1_i64], "Int64")
  end

  it "preserves Float32 and Float64 signed-zero and NaN payload bits" do
    w76_writer_assert_typed_maps([
      0x80000000_u32.unsafe_as(Float32),
      0x7fc00001_u32.unsafe_as(Float32),
      0x00000001_u32.unsafe_as(Float32),
    ], "Float32")
    w76_writer_assert_typed_maps([
      0x8000000000000000_u64.unsafe_as(Float64),
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x0000000000000001_u64.unsafe_as(Float64),
    ], "Float64")
  end

  it "rejects a same-width but unsupported Bool Map value before staging" do
    parent = File.tempname("crystal-click-w76-writer-reject")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    maps = [[{1_u64, true}]] of Array(Tuple(UInt64, Bool))
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          maps.to_unsafe.to_slice(maps.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "leaves a pre-existing destination untouched on publication collision" do
    parent = File.tempname("crystal-click-w76-writer-collision")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    Dir.mkdir(destination)
    File.write(File.join(destination, "sentinel"), "keep")
    maps = [[{"k", 1_u16}]] of Array(Tuple(String, UInt16))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          maps.to_unsafe.to_slice(maps.size),
          rows_per_mark: 1
        )
      end
      File.read(File.join(destination, "sentinel")).should eq("keep")
      Dir.children(parent).should eq(["part"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes its temporary stage when exclusive publication fails" do
    parent = File.tempname("crystal-click-w76-writer-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    maps = [[{1_u64, UInt16::MAX}]] of Array(Tuple(UInt64, UInt16))
    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
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
