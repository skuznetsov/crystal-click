require "./spec_helper"

private def w77_catalog_table_for_part(root : String, part : String, map_type : String) : CrystalClick::OfflineTable
  database_uuid = "91b46ce8-8e74-44d0-8c08-416a25ff1eac"
  table_uuid = "c28ab49a-e626-4cec-a5db-0d5cf2145ad0"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` #{map_type})\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
end

private def w77_catalog_equal_value?(expected : T?, actual : T?) : Bool forall T
  return actual.nil? if expected.nil?
  return false if actual.nil?
  {% if T == Float32 %}
    expected.not_nil!.unsafe_as(UInt32) == actual.not_nil!.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.not_nil!.unsafe_as(UInt64) == actual.not_nil!.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w77_catalog_assert_leaf(samples : Array(T), type_name : String) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  uint64_rows = [
    [] of Tuple(UInt64, T?),
    [{7_u64, nil}, {7_u64, samples[0]}] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [{UInt64::MAX, samples[1]}, {0_u64, nil}] of Tuple(UInt64, T?),
    [{42_u64, samples[2]}] of Tuple(UInt64, T?),
  ] of Array(Tuple(UInt64, T?))
  string_rows = [
    [] of Tuple(String, T?),
    [{"dup", nil}, {"dup", samples[0]}] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [{String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8]), samples[1]}, {"", nil}] of Tuple(String, T?),
    [{"tail", samples[2]}] of Tuple(String, T?),
  ] of Array(Tuple(String, T?))

  parent = File.tempname("crystal-click-w77-catalog")
  Dir.mkdir(parent)
  uint64_part = File.join(parent, "all_1_1_0")
  string_part = File.join(parent, "all_2_2_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
      uint64_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      uint64_rows.to_unsafe.to_slice(uint64_rows.size), rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
      string_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
    )

    uint64_column = w77_catalog_table_for_part(
      File.join(parent, "uint64_catalog"), uint64_part, "Map(UInt64, Nullable(#{type_name}))"
    )["payload"]
    string_column = w77_catalog_table_for_part(
      File.join(parent, "string_catalog"), string_part, "Map(String, Nullable(#{type_name}))"
    )["payload"]
    actual_uint64 = uint64_column.values.map do |value|
      value.as?(Array(Tuple(UInt64, T?))) || raise("wrong UInt64-key nullable numeric Map shape")
    end
    actual_string = string_column.values.map do |value|
      value.as?(Array(Tuple(String, T?))) || raise("wrong String-key nullable numeric Map shape")
    end
    actual_uint64.size.should eq(uint64_rows.size)
    actual_string.size.should eq(string_rows.size)
    uint64_rows.each_with_index do |row, index|
      actual_uint64[index].size.should eq(row.size)
      row.each_with_index do |entry, entry_index|
        actual_uint64[index][entry_index][0].should eq(entry[0])
        w77_catalog_equal_value?(entry[1], actual_uint64[index][entry_index][1]).should be_true
      end
    end
    string_rows.each_with_index do |row, index|
      actual_string[index].size.should eq(row.size)
      row.each_with_index do |entry, entry_index|
        actual_string[index][entry_index][0].should eq(entry[0])
        w77_catalog_equal_value?(entry[1], actual_string[index][entry_index][1]).should be_true
      end
    end

    # The catalog must return independent values, including nested String keys.
    actual_string[1][0] = {"changed", actual_string[1][0][1]}
    string_column.values[1].as(Array(Tuple(String, T?)))[0][0].should eq("dup")
    string_key_bytes = 0_u64
    string_rows.each { |row| row.each { |key, _value| string_key_bytes += key.bytesize.to_u64 } }
    string_column.values(max_string_bytes: string_key_bytes).size.should eq(string_rows.size)
    expect_raises(CrystalClick::BoundsError) do
      string_column.values(max_string_bytes: string_key_bytes - 1_u64)
    end
    expect_raises(CrystalClick::BoundsError) { uint64_column.values(max_rows: 5_u64) }
    expect_raises(CrystalClick::BoundsError) { string_column.values(max_rows: 5_u64) }
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe CrystalClick::OfflineCatalog do
  it "materializes all W77 nullable primitive-numeric Map leaves and controls" do
    w77_catalog_assert_leaf([0_u8, UInt8::MAX, 17_u8], "UInt8")
    w77_catalog_assert_leaf([0_u16, UInt16::MAX, 17_u16], "UInt16")
    w77_catalog_assert_leaf([0_u32, UInt32::MAX, 17_u32], "UInt32")
    w77_catalog_assert_leaf([0_u64, UInt64::MAX, 17_u64], "UInt64")
    w77_catalog_assert_leaf([0_i8, Int8::MIN, Int8::MAX], "Int8")
    w77_catalog_assert_leaf([0_i16, Int16::MIN, Int16::MAX], "Int16")
    w77_catalog_assert_leaf([0_i32, Int32::MIN, Int32::MAX], "Int32")
    w77_catalog_assert_leaf([0_i64, Int64::MIN, Int64::MAX], "Int64")
    w77_catalog_assert_leaf([0x80000000_u32.unsafe_as(Float32), 0x7fc00001_u32.unsafe_as(Float32), 1.5_f32], "Float32")
    w77_catalog_assert_leaf([0x8000000000000000_u64.unsafe_as(Float64), 0x7ff8000000000001_u64.unsafe_as(Float64), 1.5_f64], "Float64")
  end
end
