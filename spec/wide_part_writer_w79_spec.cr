require "./spec_helper"

private def w79_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w79_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W79 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    values = Array(UInt64).new(3) do |word|
      value = 0_u64
      8.times { |byte| value |= bytes[offset + word * 8 + byte].to_u64 << (byte * 8) }
      value
    end
    {values[0], values[1], values[2]}
  end
end

private def w79_uint64_values(first : T, second : T) : Array(Array(Tuple(UInt64, Array(T?)))) forall T
  empty = [] of Tuple(UInt64, Array(T?))
  first_row = [
    {7_u64, [nil, first] of T?},
    {7_u64, [] of T?},
  ] of Tuple(UInt64, Array(T?))
  second_row = [{UInt64::MAX, [second, nil] of T?}] of Tuple(UInt64, Array(T?))
  [empty, empty.dup, first_row, second_row]
end

private def w79_string_values(first : T, second : T) : Array(Array(Tuple(String, Array(T?)))) forall T
  empty = [] of Tuple(String, Array(T?))
  first_row = [
    {"dup", [nil, first] of T?},
    {"", [] of T?},
  ] of Tuple(String, Array(T?))
  second_row = [{"dup", [second, nil] of T?}] of Tuple(String, Array(T?))
  [empty, empty.dup, first_row, second_row]
end

private def w79_assert_map_equal(
  expected : Array(Array(Tuple(K, Array(T?)))),
  actual : Array(Array(Tuple(K, Array(T?)))),
) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual_entry = actual[row][entry]
      actual_entry[0].should eq(expected_entry[0])
      actual_entry[1].size.should eq(expected_entry[1].size)
      expected_entry[1].each_with_index do |expected_value, index|
        actual_value = actual_entry[1][index]
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

private def w79_assert_numeric_case(
  parent : String,
  part_name : String,
  type_name : String,
  width : Int32,
  values : Array(Array(Tuple(K, Array(T?)))),
) : Nil forall K, T
  destination = File.join(parent, part_name)
  keys = [0_u64, 1_u64, 2_u64, 3_u64]
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if K == String %}
    CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_numeric_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", value_slice, rows_per_mark: 2
    )
  {% else %}
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_numeric_pair(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", value_slice, rows_per_mark: 2
    )
  {% end %}

  File.read(File.join(destination, "columns.txt")).should contain(
    "`payload` Map(#{K}, Array(Nullable(#{type_name})))"
  )
  nulls = w79_raw_stream(destination, "payload%2Evalues.null")
  nulls.should eq([1_u8, 0_u8, 0_u8, 1_u8])
  leaf_bytes = w79_raw_stream(destination, "payload%2Evalues")
  leaf_bytes.size.should eq(4 * width)
  leaf_bytes[0, width].should eq(Array(UInt8).new(width, 0_u8))
  leaf_bytes[width * 3, width].should eq(Array(UInt8).new(width, 0_u8))

  leaf_marks = w79_marks(destination, "payload%2Evalues")
  leaf_marks.map(&.[2]).should eq([2_u64, 2_u64, 0_u64])
  {leaf_marks[0][0], leaf_marks[0][1]}.should eq({leaf_marks[1][0], leaf_marks[1][1]})
  null_marks = w79_marks(destination, "payload%2Evalues.null")
  {null_marks[0][0], null_marks[0][1]}.should eq({null_marks[1][0], null_marks[1][1]})

  reader = CrystalClick::WidePart.open_typed(destination, "payload")
  reader.column_type.should eq("Map(#{K}, Array(Nullable(#{type_name})))")
  {% if K == String %}
    actual = reader.read_map_string_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, T)
    w79_assert_map_equal(values, actual)
  {% else %}
    actual = reader.read_map_uint64_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, T)
    w79_assert_map_equal(values, actual)
  {% end %}
  nil
end

describe CrystalClick::WidePartWriter do
  it "writes nullable numeric leaves of every primitive width under both Map key types" do
    parent = File.tempname("crystal-click-wide-writer-w79")
    Dir.mkdir(parent)
    begin
      w79_assert_numeric_case(parent, "Int8", "Int8", 1, w79_uint64_values(-1_i8, 2_i8))
      w79_assert_numeric_case(parent, "Int16", "Int16", 2, w79_uint64_values(-2_i16, 3_i16))
      w79_assert_numeric_case(parent, "Int32", "Int32", 4, w79_uint64_values(-3_i32, 4_i32))
      w79_assert_numeric_case(parent, "Int64", "Int64", 8, w79_uint64_values(-4_i64, 5_i64))
      w79_assert_numeric_case(parent, "UInt8", "UInt8", 1, w79_uint64_values(1_u8, 2_u8))
      w79_assert_numeric_case(parent, "UInt16", "UInt16", 2, w79_uint64_values(2_u16, 3_u16))
      w79_assert_numeric_case(parent, "UInt32", "UInt32", 4, w79_uint64_values(3_u32, 4_u32))
      w79_assert_numeric_case(parent, "UInt64", "UInt64", 8, w79_uint64_values(4_u64, 5_u64))
      w79_assert_numeric_case(parent, "Float32", "Float32", 4, w79_uint64_values(0x7fc0_0042_u32.unsafe_as(Float32), -0.0_f32))
      w79_assert_numeric_case(parent, "Float64", "Float64", 8, w79_uint64_values(0x7ff8_0000_0000_0042_u64.unsafe_as(Float64), -0.0_f64))
      w79_assert_numeric_case(parent, "string-keys", "Float32", 4, w79_string_values(0x7fc0_0042_u32.unsafe_as(Float32), -0.0_f32))

      string_part = File.join(parent, "string-keys")
      w79_raw_stream(string_part, "payload%2Ekeys.size").should eq([
        3_u8, 0, 0, 0, 0, 0, 0, 0,
        0_u8, 0, 0, 0, 0, 0, 0, 0,
        3_u8, 0, 0, 0, 0, 0, 0, 0,
      ])
      w79_raw_stream(string_part, "payload%2Ekeys").should eq("dupdup".bytes)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects nullable leaf overflow before staging or publication" do
    parent = File.tempname("crystal-click-wide-writer-w79-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_leaves = Array(Int8?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, nil)
    values = [[{7_u64, too_many_leaves}] of Tuple(UInt64, Array(Int8?))] of Array(Tuple(UInt64, Array(Int8?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_numeric_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "leaves an existing destination unchanged after an exclusive-publish collision" do
    parent = File.tempname("crystal-click-wide-writer-w79-collision")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 1_u64, 2_u64, 3_u64]
    values = w79_uint64_values(41_u64, 42_u64)
    value_slice = values.to_unsafe.to_slice(values.size)
    key_slice = keys.to_unsafe.to_slice(keys.size)
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_numeric_pair(
        destination, "pk", key_slice, "payload", value_slice, rows_per_mark: 2
      )
      snapshot = ["checksums.txt", "columns.txt", "serialization.json"].map do |name|
        File.read(File.join(destination, name))
      end

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_numeric_pair(
          destination, "pk", key_slice, "payload", value_slice, rows_per_mark: 2
        )
      end

      ["checksums.txt", "columns.txt", "serialization.json"].map do |name|
        File.read(File.join(destination, name))
      end.should eq(snapshot)
      Dir.children(parent).should eq(["part"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
