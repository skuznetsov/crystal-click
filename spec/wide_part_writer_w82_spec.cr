require "./spec_helper"

private alias W82UInt64MapString = Array(Tuple(UInt64, String))
private alias W82StringMapString = Array(Tuple(String, String))
private alias W82UInt64MapNullableString = Array(Tuple(UInt64, String?))
private alias W82StringMapNullableString = Array(Tuple(String, String?))

private def w82_u64_bytes(values : Enumerable(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w82_size_bytes(values : Enumerable(UInt64)) : Array(UInt8)
  w82_u64_bytes(values)
end

private def w82_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w82_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W82 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
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

private def w82_assert_writer_case(
  destination : String,
  keys : Array(UInt64),
  values : Array(Array(Array(Tuple(K, V)))),
  key_type : String,
  nullable : Bool,
) : Nil forall K, V
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  key_name = "pk"
  value_name = "payload"

  {% if K == UInt64 %}
    {% if V == String %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
        destination, key_name, key_slice, value_name, value_slice, rows_per_mark: 2
      ).should eq(destination)
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_string_pair(
        destination, key_name, key_slice, value_name, value_slice, rows_per_mark: 2
      ).should eq(destination)
    {% end %}
  {% else %}
    {% if V == String %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_string_pair(
        destination, key_name, key_slice, value_name, value_slice, rows_per_mark: 2
      ).should eq(destination)
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_string_pair(
        destination, key_name, key_slice, value_name, value_slice, rows_per_mark: 2
      ).should eq(destination)
    {% end %}
  {% end %}

  size0 = [] of UInt64
  size1 = [] of UInt64
  keys_raw = [] of UInt8
  key_sizes = [] of UInt64
  key_bytes_raw = [] of UInt8
  nulls = [] of UInt8
  value_sizes = [] of UInt64
  value_bytes_raw = [] of UInt8
  values.each do |row|
    size0 << row.size.to_u64
    row.each do |map|
      size1 << map.size.to_u64
      map.each do |entry|
        {% if K == UInt64 %}
          keys_raw.concat(w82_u64_bytes([entry[0]]))
        {% else %}
          key_sizes << entry[0].bytesize.to_u64
          key_bytes_raw.concat(entry[0].to_slice.to_a)
        {% end %}
        {% if V == String %}
          value_sizes << entry[1].bytesize.to_u64
          value_bytes_raw.concat(entry[1].to_slice.to_a)
        {% else %}
          if value = entry[1]
            nulls << 0_u8
            value_sizes << value.bytesize.to_u64
            value_bytes_raw.concat(value.to_slice.to_a)
          else
            nulls << 1_u8
            value_sizes << 0_u64
          end
        {% end %}
      end
    end
  end

  streams = ["#{value_name}.size0", "#{value_name}.size1"]
  expected_raw = [w82_size_bytes(size0), w82_size_bytes(size1)]
  {% if K == UInt64 %}
    streams << "#{value_name}%2Ekeys"
    expected_raw << keys_raw
  {% else %}
    streams << "#{value_name}%2Ekeys.size" << "#{value_name}%2Ekeys"
    expected_raw << w82_size_bytes(key_sizes) << key_bytes_raw
  {% end %}
  {% if V != String %}
    streams << "#{value_name}%2Evalues.null"
    expected_raw << nulls
  {% end %}
  streams << "#{value_name}%2Evalues.size" << "#{value_name}%2Evalues"
  expected_raw << w82_size_bytes(value_sizes) << value_bytes_raw

  streams.each_with_index do |stream, index|
    w82_raw_stream(destination, stream).should eq(expected_raw[index])
  end

  expected_files = ["count.txt", "primary.idx", "serialization.json"]
  ([key_name] + streams).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  checksums = CrystalClick::PartChecksums.open(destination)
  checksums.entries.keys.sort.should eq(expected_files.sort)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }
  File.read(File.join(destination, "columns.txt")).should contain("Array(Map(#{key_type}, #{nullable ? "Nullable(String)" : "String"}))")
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
                        "#{streams.size} substreams for column `#{value_name}`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  File.read(File.join(destination, "columns_substreams.txt")).should eq(expected_substreams)

  expected_rows = [2_u64, 2_u64, 1_u64, 0_u64]
  ([key_name] + streams).each do |stream|
    mark_records = w82_marks(destination, stream)
    mark_records.size.should eq(4)
    mark_records.map(&.[2]).should eq(expected_rows)
    mark_records.each { |mark| mark[1].should eq(0_u64) }
    mark_records.last[0].should eq(File.size(File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64)
  end

  part = CrystalClick::WidePart.open_typed(destination, value_name)
  part.column_type.should eq("Array(Map(#{key_type}, #{nullable ? "Nullable(String)" : "String"}))")
  {% if K == UInt64 %}
    {% if V == String %}
      part.read_array_map_uint64_string_mark_range(value_name, 0, part.mark_count).should eq(values)
      part.read_array_map_uint64_string_mark_range(value_name, 2, 1).should eq(values[4, 1])
    {% else %}
      part.read_array_map_uint64_nullable_string_mark_range(value_name, 0, part.mark_count).should eq(values)
      part.read_array_map_uint64_nullable_string_mark_range(value_name, 2, 1).should eq(values[4, 1])
    {% end %}
  {% else %}
    {% if V == String %}
      part.read_array_map_string_string_mark_range(value_name, 0, part.mark_count).should eq(values)
      part.read_array_map_string_string_mark_range(value_name, 2, 1).should eq(values[4, 1])
    {% else %}
      part.read_array_map_string_nullable_string_mark_range(value_name, 0, part.mark_count).should eq(values)
      part.read_array_map_string_nullable_string_mark_range(value_name, 2, 1).should eq(values[4, 1])
    {% end %}
  {% end %}
  nil
end

describe "W82 Array(Map(... String)) writer" do
  it "writes the four exact String-leaf shapes with stock stream order, marks, checksums, and readback" do
    parent = File.tempname("crystal-click-w82-array-map-writer")
    Dir.mkdir(parent)
    keys = [0_u64, 1_u64, 1_u64, 4_u64, UInt64::MAX]
    binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
    binary_value = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    u64_values = [
      [] of W82UInt64MapString,
      [([] of Tuple(UInt64, String)), [{7_u64, ""}, {7_u64, binary_value}] of Tuple(UInt64, String)],
      [[{9_u64, binary_value}] of Tuple(UInt64, String), [] of Tuple(UInt64, String)],
      [] of W82UInt64MapString,
      [[{UInt64::MAX, ""}] of Tuple(UInt64, String)],
    ] of Array(W82UInt64MapString)
    string_values = [
      [] of W82StringMapString,
      [([] of Tuple(String, String)), [{"dup", ""}, {"dup", binary_value}] of Tuple(String, String)],
      [[{binary_key, binary_value}] of Tuple(String, String), [] of Tuple(String, String)],
      [] of W82StringMapString,
      [[{"", ""}] of Tuple(String, String)],
    ] of Array(W82StringMapString)
    nullable_u64_values = [
      [] of W82UInt64MapNullableString,
      [([] of Tuple(UInt64, String?)), [{7_u64, ""}, {7_u64, binary_value}] of Tuple(UInt64, String?)],
      [[{9_u64, binary_value}] of Tuple(UInt64, String?), [] of Tuple(UInt64, String?)],
      [] of W82UInt64MapNullableString,
      [[{UInt64::MAX, nil}, {0_u64, ""}] of Tuple(UInt64, String?)],
    ] of Array(W82UInt64MapNullableString)
    nullable_string_values = [
      [] of W82StringMapNullableString,
      [([] of Tuple(String, String?)), [{"dup", ""}, {"dup", binary_value}] of Tuple(String, String?)],
      [[{binary_key, binary_value}] of Tuple(String, String?), [] of Tuple(String, String?)],
      [] of W82StringMapNullableString,
      [[{"", nil}, {"tail", ""}] of Tuple(String, String?)],
    ] of Array(W82StringMapNullableString)

    begin
      w82_assert_writer_case(File.join(parent, "u64"), keys, u64_values, "UInt64", false)
      w82_assert_writer_case(File.join(parent, "string"), keys, string_values, "String", false)
      w82_assert_writer_case(File.join(parent, "nullable-u64"), keys, nullable_u64_values, "UInt64", true)
      w82_assert_writer_case(File.join(parent, "nullable-string"), keys, nullable_string_values, "String", true)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid inputs before staging and preserves existing destinations" do
    parent = File.tempname("crystal-click-w82-array-map-invalid")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [2_u64, 1_u64]
    values = [[] of W82UInt64MapString, [] of W82UInt64MapString] of Array(W82UInt64MapString)

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(2), "payload", values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      sorted_keys = [1_u64, 2_u64]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
          destination, "pk", sorted_keys.to_unsafe.to_slice(2), "payload", values.to_unsafe.to_slice(1), rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
          destination, "pk", sorted_keys.to_unsafe.to_slice(2), "../payload", values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      File.write(destination, "preserve")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
          destination, "pk", sorted_keys.to_unsafe.to_slice(2), "payload", values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      File.read(destination).should eq("preserve")
      Dir.children(parent).should eq(["part"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a per-mark nested cardinality overflow before creating a stage" do
    parent = File.tempname("crystal-click-w82-array-map-bound")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    maps = Array(W82UInt64MapString).new(CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i + 1) do
      [] of Tuple(UInt64, String)
    end
    values = [maps] of Array(W82UInt64MapString)

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(1), "payload", values.to_unsafe.to_slice(1), rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
