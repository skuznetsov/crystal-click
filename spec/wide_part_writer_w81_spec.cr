require "./spec_helper"

private alias W81UInt64MapInt8 = Array(Tuple(UInt64, Int8))
private alias W81UInt64ArrayMapInt8 = Array(W81UInt64MapInt8)

private def w81_writer_u64_rows(samples : Array(T)) : Array(Array(Array(Tuple(UInt64, T)))) forall T
  empty_map = [] of Tuple(UInt64, T)
  duplicate_map = [{7_u64, samples[0]}, {7_u64, samples[1]}] of Tuple(UInt64, T)
  later_map = [{UInt64::MAX, samples[2]}] of Tuple(UInt64, T)
  [
    [] of Array(Tuple(UInt64, T)),
    [empty_map, duplicate_map],
    [] of Array(Tuple(UInt64, T)),
    [] of Array(Tuple(UInt64, T)),
    [later_map, empty_map],
    [] of Array(Tuple(UInt64, T)),
    [] of Array(Tuple(UInt64, T)),
  ] of Array(Array(Tuple(UInt64, T)))
end

private def w81_writer_string_rows(samples : Array(T)) : Array(Array(Array(Tuple(String, T)))) forall T
  empty_map = [] of Tuple(String, T)
  duplicate_map = [{"dup", samples[0]}, {"dup", samples[1]}] of Tuple(String, T)
  binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
  later_map = [{binary_key, samples[2]}] of Tuple(String, T)
  [
    [] of Array(Tuple(String, T)),
    [empty_map, duplicate_map],
    [] of Array(Tuple(String, T)),
    [] of Array(Tuple(String, T)),
    [later_map, empty_map],
    [] of Array(Tuple(String, T)),
    [] of Array(Tuple(String, T)),
  ] of Array(Array(Tuple(String, T)))
end

private def w81_writer_u64_nullable_rows(samples : Array(T)) : Array(Array(Array(Tuple(UInt64, T?)))) forall T
  empty_map = [] of Tuple(UInt64, T?)
  duplicate_map = [{7_u64, nil}, {7_u64, samples[0]}] of Tuple(UInt64, T?)
  later_map = [{UInt64::MAX, samples[2]}, {0_u64, nil}] of Tuple(UInt64, T?)
  [
    [] of Array(Tuple(UInt64, T?)),
    [empty_map, duplicate_map],
    [] of Array(Tuple(UInt64, T?)),
    [] of Array(Tuple(UInt64, T?)),
    [later_map, empty_map],
    [] of Array(Tuple(UInt64, T?)),
    [] of Array(Tuple(UInt64, T?)),
  ] of Array(Array(Tuple(UInt64, T?)))
end

private def w81_writer_string_nullable_rows(samples : Array(T)) : Array(Array(Array(Tuple(String, T?)))) forall T
  empty_map = [] of Tuple(String, T?)
  duplicate_map = [{"dup", nil}, {"dup", samples[0]}] of Tuple(String, T?)
  binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
  later_map = [{binary_key, samples[2]}, {"", nil}] of Tuple(String, T?)
  [
    [] of Array(Tuple(String, T?)),
    [empty_map, duplicate_map],
    [] of Array(Tuple(String, T?)),
    [] of Array(Tuple(String, T?)),
    [later_map, empty_map],
    [] of Array(Tuple(String, T?)),
    [] of Array(Tuple(String, T?)),
  ] of Array(Array(Tuple(String, T?)))
end

private def w81_writer_numeric_bytes(values : Array(T)) : Array(UInt8) forall T
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
      raise "unsupported W81 test numeric type"
    {% end %}
  end
  bytes
end

private def w81_writer_assert_array_map(expected : Array(Array(Array(Tuple(K, T)))), actual : Array(Array(Array(Tuple(K, T))))) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row_index|
    actual_row = actual[row_index]
    actual_row.size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_map, map_index|
      actual_map = actual_row[map_index]
      actual_map.size.should eq(expected_map.size)
      expected_map.each_with_index do |expected_entry, entry_index|
        actual_entry = actual_map[entry_index]
        actual_entry[0].should eq(expected_entry[0])
        {% if T == Float32 %}
          actual_entry[1].unsafe_as(UInt32).should eq(expected_entry[1].unsafe_as(UInt32))
        {% elsif T == Float64 %}
          actual_entry[1].unsafe_as(UInt64).should eq(expected_entry[1].unsafe_as(UInt64))
        {% else %}
          actual_entry[1].should eq(expected_entry[1])
        {% end %}
      end
    end
  end
  nil
end

private def w81_writer_assert_nullable_array_map(expected : Array(Array(Array(Tuple(K, T?)))), actual : Array(Array(Array(Tuple(K, T?))))) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row_index|
    actual_row = actual[row_index]
    actual_row.size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_map, map_index|
      actual_map = actual_row[map_index]
      actual_map.size.should eq(expected_map.size)
      expected_map.each_with_index do |expected_entry, entry_index|
        actual_entry = actual_map[entry_index]
        actual_entry[0].should eq(expected_entry[0])
        expected_value = expected_entry[1]
        actual_value = actual_entry[1]
        if expected_value.nil?
          actual_value.should be_nil
        else
          actual_value.should_not be_nil
          {% if T == Float32 %}
            actual_value.not_nil!.unsafe_as(UInt32).should eq(expected_value.not_nil!.unsafe_as(UInt32))
          {% elsif T == Float64 %}
            actual_value.not_nil!.unsafe_as(UInt64).should eq(expected_value.not_nil!.unsafe_as(UInt64))
          {% else %}
            actual_value.should eq(expected_value)
          {% end %}
        end
      end
    end
  end
  nil
end

private def w81_writer_assert_inventory(path : String, streams : Array(String)) : Nil
  expected_files = ["count.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  checksums = CrystalClick::PartChecksums.open(path)
  checksums.entries.keys.sort.should eq(expected_files.sort)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(path, name) }
  nil
end

private def w81_writer_nullable_numeric_bytes(values : Array(Tuple(K, T?))) : Array(UInt8) forall K, T
  bytes = [] of UInt8
  values.each do |_key, value|
    if numeric = value
      bytes.concat(w81_writer_numeric_bytes([numeric]))
    else
      width = {% if T == UInt8 || T == Int8 %}1{% elsif T == UInt16 || T == Int16 %}2{% elsif T == UInt32 || T == Int32 || T == Float32 %}4{% else %}8{% end %}
      bytes.concat(Array(UInt8).new(width, 0_u8))
    end
  end
  bytes
end

private def w81_writer_numeric_width(type_name : String) : Int32
  case type_name
  when "UInt8", "Int8"              then 1
  when "UInt16", "Int16"            then 2
  when "UInt32", "Int32", "Float32" then 4
  when "UInt64", "Int64", "Float64" then 8
  else
    raise "unsupported W81 numeric type"
  end
end

private def w81_writer_assert_physical_widths(path : String, streams : Array(String), values : Array(Array(Array(Tuple(K, T)))), type_name : String, nullable : Bool) : Nil forall K, T
  map_count = values.reduce(0) { |count, row| count + row.size }
  entries = values.reduce([] of Tuple(K, T)) do |all, row|
    row.each { |map| all.concat(map) }
    all
  end
  value_base = "payload%2Evalues"
  w81_writer_raw_stream(path, "payload.size0").size.should eq(values.size * 8)
  w81_writer_raw_stream(path, "payload.size1").size.should eq(map_count * 8)
  {% if K == String %}
    w81_writer_raw_stream(path, "payload%2Ekeys.size").size.should eq(entries.size * 8)
    w81_writer_raw_stream(path, "payload%2Ekeys").size.should eq(entries.reduce(0) { |sum, entry| sum + entry[0].bytesize })
  {% else %}
    w81_writer_raw_stream(path, "payload%2Ekeys").size.should eq(entries.size * 8)
  {% end %}
  {% if T.union_types.size == 2 && T.union_types.includes?(Nil) %}
    w81_writer_raw_stream(path, "#{value_base}.null").size.should eq(entries.size)
    w81_writer_raw_stream(path, "#{value_base}.null").should eq(entries.map { |entry| entry[1].nil? ? 1_u8 : 0_u8 })
    expected_values = w81_writer_nullable_numeric_bytes(entries)
    w81_writer_raw_stream(path, value_base).should eq(expected_values)
  {% else %}
    expected_values = entries.map { |entry| entry[1] }
    w81_writer_raw_stream(path, value_base).should eq(w81_writer_numeric_bytes(expected_values))
  {% end %}
  w81_writer_raw_stream(path, value_base).size.should eq(entries.size * w81_writer_numeric_width(type_name))
  marks = w81_writer_marks(path, streams.last)
  marks.map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  marks.last[0].should eq(File.size(File.join(path, "#{CrystalClick::StreamName.hash(streams.last)}.bin")).to_u64)
  nil
end

private def w81_writer_assert_numeric_matrix_case(samples : Array(T), type_name : String) : Nil forall T
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  u64_values = w81_writer_u64_rows(samples)
  string_values = w81_writer_string_rows(samples)
  nullable_u64_values = w81_writer_u64_nullable_rows(samples)
  nullable_string_values = w81_writer_string_nullable_rows(samples)
  parent = File.tempname("crystal-click-w81-matrix")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "u64")
  string_path = File.join(parent, "string")
  nullable_u64_path = File.join(parent, "nullable-u64")
  nullable_string_path = File.join(parent, "nullable-string")
  begin
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_numeric_pair(
      u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 2
    ).should eq(u64_path)
    CrystalClick::WidePartWriter.write_uint64_array_map_string_numeric_pair(
      string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 2
    ).should eq(string_path)
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_numeric_pair(
      nullable_u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", nullable_u64_values.to_unsafe.to_slice(nullable_u64_values.size), rows_per_mark: 2
    ).should eq(nullable_u64_path)
    CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_numeric_pair(
      nullable_string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", nullable_string_values.to_unsafe.to_slice(nullable_string_values.size), rows_per_mark: 2
    ).should eq(nullable_string_path)

    u64_streams = ["pk", "payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues"]
    string_streams = ["pk", "payload.size0", "payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues"]
    nullable_u64_streams = ["pk", "payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues"]
    nullable_string_streams = ["pk", "payload.size0", "payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues"]
    [{u64_path, u64_streams}, {string_path, string_streams}, {nullable_u64_path, nullable_u64_streams}, {nullable_string_path, nullable_string_streams}].each do |path, streams|
      w81_writer_assert_inventory(path, streams)
      File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
    end
    w81_writer_assert_physical_widths(u64_path, u64_streams, u64_values, type_name, false)
    w81_writer_assert_physical_widths(string_path, string_streams, string_values, type_name, false)
    w81_writer_assert_physical_widths(nullable_u64_path, nullable_u64_streams, nullable_u64_values, type_name, true)
    w81_writer_assert_physical_widths(nullable_string_path, nullable_string_streams, nullable_string_values, type_name, true)

    u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
    string_reader = CrystalClick::WidePart.open_typed(string_path, "payload")
    nullable_u64_reader = CrystalClick::WidePart.open_typed(nullable_u64_path, "payload")
    nullable_string_reader = CrystalClick::WidePart.open_typed(nullable_string_path, "payload")
    u64_reader.column_type.should eq("Array(Map(UInt64, #{type_name}))")
    string_reader.column_type.should eq("Array(Map(String, #{type_name}))")
    nullable_u64_reader.column_type.should eq("Array(Map(UInt64, Nullable(#{type_name})))")
    nullable_string_reader.column_type.should eq("Array(Map(String, Nullable(#{type_name})))")
    w81_writer_assert_array_map(u64_values, u64_reader.read_array_map_uint64_numeric_mark_range("payload", 0, u64_reader.mark_count, T))
    w81_writer_assert_array_map(string_values, string_reader.read_array_map_string_numeric_mark_range("payload", 0, string_reader.mark_count, T))
    w81_writer_assert_nullable_array_map(nullable_u64_values, nullable_u64_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 0, nullable_u64_reader.mark_count, T))
    w81_writer_assert_nullable_array_map(nullable_string_values, nullable_string_reader.read_array_map_string_nullable_numeric_mark_range("payload", 0, nullable_string_reader.mark_count, T))
    w81_writer_assert_array_map(u64_values[4, 2], u64_reader.read_array_map_uint64_numeric_mark_range("payload", 2, 1, T))
    w81_writer_assert_array_map(string_values[4, 2], string_reader.read_array_map_string_numeric_mark_range("payload", 2, 1, T))
    w81_writer_assert_nullable_array_map(nullable_u64_values[4, 2], nullable_u64_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 2, 1, T))
    w81_writer_assert_nullable_array_map(nullable_string_values[4, 2], nullable_string_reader.read_array_map_string_nullable_numeric_mark_range("payload", 2, 1, T))
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w81_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w81_writer_u64(values : Enumerable(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w81_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W81 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    words = Array(UInt64).new(3) do |word|
      value = 0_u64
      8.times { |byte| value |= bytes[offset + word * 8 + byte].to_u64 << (byte * 8) }
      value
    end
    {words[0], words[1], words[2]}
  end
end

describe "W81 Array(Map(K, numeric)) writer" do
  it "writes UInt64-key maps under the outer Array and nested Map offset axes" do
    parent = File.tempname("crystal-click-w81-array-map-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
    duplicate_entries = [{7_u64, -1_i8}, {7_u64, 0_i8}] of Tuple(UInt64, Int8)
    values = [
      [] of W81UInt64MapInt8,
      [([] of Tuple(UInt64, Int8)), duplicate_entries] of W81UInt64MapInt8,
      [] of W81UInt64MapInt8,
      [] of W81UInt64MapInt8,
      [[{UInt64::MAX, 42_i8}] of Tuple(UInt64, Int8)] of W81UInt64MapInt8,
      [] of W81UInt64MapInt8,
      [] of W81UInt64MapInt8,
    ] of W81UInt64ArrayMapInt8

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_numeric_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Map(UInt64, Int8))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n" +
        "\tpayload%2Ekeys\n\tpayload%2Evalues\n"
      )
      w81_writer_raw_stream(destination, "payload.size0").should eq(w81_writer_u64([0_u64, 2_u64, 0_u64, 0_u64, 1_u64, 0_u64, 0_u64]))
      w81_writer_raw_stream(destination, "payload.size1").should eq(w81_writer_u64([0_u64, 2_u64, 1_u64]))
      w81_writer_raw_stream(destination, "payload%2Ekeys").should eq(w81_writer_u64([7_u64, 7_u64, UInt64::MAX]))
      w81_writer_raw_stream(destination, "payload%2Evalues").should eq([0xff_u8, 0_u8, 42_u8])

      expected_mark_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
      ["pk", "payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues"].each do |stream|
        marks = w81_writer_marks(destination, stream)
        marks.map(&.[2]).should eq(expected_mark_rows)
        marks.last[0].should eq(File.size(File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64)
      end
      ["payload.size1", "payload%2Ekeys", "payload%2Evalues"].each do |stream|
        marks = w81_writer_marks(destination, stream)
        {marks[1][0], marks[1][1]}.should eq({marks[2][0], marks[2][1]})
        {marks[3][0], marks[3][1]}.should eq({marks[4][0], marks[4][1]})
      end

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      ["pk", "payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues"].each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin" << "#{base}.mrk2"
      end
      checksums = CrystalClick::PartChecksums.open(destination)
      checksums.entries.keys.sort.should eq(expected_files.sort)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Array(Map(UInt64, Int8))")
      reader.read_array_map_uint64_numeric_mark_range("payload", 0, reader.mark_count, Int8).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips all 40 key, leaf-width, and nullable declarations with physical widths" do
    w81_writer_assert_numeric_matrix_case([0_u8, UInt8::MAX, 17_u8], "UInt8")
    w81_writer_assert_numeric_matrix_case([0_u16, UInt16::MAX, 17_u16], "UInt16")
    w81_writer_assert_numeric_matrix_case([0_u32, UInt32::MAX, 17_u32], "UInt32")
    w81_writer_assert_numeric_matrix_case([0_u64, UInt64::MAX, 17_u64], "UInt64")
    w81_writer_assert_numeric_matrix_case([0_i8, Int8::MIN, Int8::MAX], "Int8")
    w81_writer_assert_numeric_matrix_case([0_i16, Int16::MIN, Int16::MAX], "Int16")
    w81_writer_assert_numeric_matrix_case([0_i32, Int32::MIN, Int32::MAX], "Int32")
    w81_writer_assert_numeric_matrix_case([0_i64, Int64::MIN, Int64::MAX], "Int64")
    w81_writer_assert_numeric_matrix_case([
      0.0_f32,
      0x7fc0_0042_u32.unsafe_as(Float32),
      0x8000_0000_u32.unsafe_as(Float32),
    ], "Float32")
    w81_writer_assert_numeric_matrix_case([
      0.0_f64,
      0x7ff8_0000_0000_0042_u64.unsafe_as(Float64),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64),
    ], "Float64")
  end
end
