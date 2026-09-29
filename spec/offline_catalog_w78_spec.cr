require "./spec_helper"

W78_CATALOG_KEYS       = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
W78_CATALOG_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])

private def w78_catalog_rows_u64(samples : Array(T)) : Array(Array(Tuple(UInt64, Array(T)))) forall T
  [
    [] of Tuple(UInt64, Array(T)),
    [{0_u64, [] of T}, {0_u64, [samples[0], samples[1]]}] of Tuple(UInt64, Array(T)),
    [] of Tuple(UInt64, Array(T)),
    [] of Tuple(UInt64, Array(T)),
    [{UInt64::MAX, [samples[2]]}] of Tuple(UInt64, Array(T)),
    [{42_u64, [samples[3], samples[0]]}] of Tuple(UInt64, Array(T)),
  ] of Array(Tuple(UInt64, Array(T)))
end

private def w78_catalog_rows_string(samples : Array(T)) : Array(Array(Tuple(String, Array(T)))) forall T
  [
    [] of Tuple(String, Array(T)),
    [{"dup", [] of T}, {"dup", [samples[0], samples[1]]}] of Tuple(String, Array(T)),
    [] of Tuple(String, Array(T)),
    [] of Tuple(String, Array(T)),
    [{W78_CATALOG_BINARY_KEY, [samples[2]]}] of Tuple(String, Array(T)),
    [{"尾", [samples[3], samples[0]]}] of Tuple(String, Array(T)),
  ] of Array(Tuple(String, Array(T)))
end

private def w78_catalog_same_leaf?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w78_catalog_assert_rows(expected : Array(Array(Tuple(K, Array(T)))), actual : Array(Array(Tuple(K, Array(T))))) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |row, row_index|
    actual[row_index].size.should eq(row.size)
    row.each_with_index do |(key, leaves), entry_index|
      actual_entry = actual[row_index][entry_index]
      actual_entry[0].should eq(key)
      actual_entry[1].size.should eq(leaves.size)
      leaves.each_with_index do |leaf, leaf_index|
        w78_catalog_same_leaf?(leaf, actual_entry[1][leaf_index]).should be_true
      end
    end
  end
  nil
end

private def w78_catalog_table_for_part(root : String, part : String, map_type : String) : CrystalClick::OfflineTable
  database_uuid = "781d4a82-1cab-4a6f-a016-32cc0979b397"
  table_uuid = "4d33d43f-fc5d-456f-9309-e20fc8cafb6b"
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
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def w78_catalog_check_u64(samples : Array(T), leaf_name : String) : Nil forall T
  expected = w78_catalog_rows_u64(samples)
  parent = File.tempname("crystal-click-w78-catalog-u64")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
      part, "pk", W78_CATALOG_KEYS.to_unsafe.to_slice(W78_CATALOG_KEYS.size), "payload",
      expected.to_unsafe.to_slice(expected.size), rows_per_mark: 2
    )
    table = w78_catalog_table_for_part(File.join(parent, "catalog"), part, "Map(UInt64, Array(#{leaf_name}))")
    actual = table["payload"].values.map do |row|
      row.as?(Array(Tuple(UInt64, Array(T)))) || raise("catalog returned the wrong Map(UInt64, Array(T)) shape")
    end
    w78_catalog_assert_rows(expected, actual)
    expect_raises(CrystalClick::BoundsError) do
      table["payload"].values(max_rows: 5_u64)
    end
    actual[1][1][1].clear
    fresh = table["payload"].values.map do |row|
      row.as?(Array(Tuple(UInt64, Array(T)))) || raise("catalog returned the wrong Map(UInt64, Array(T)) shape")
    end
    w78_catalog_assert_rows(expected, fresh)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w78_catalog_check_string(samples : Array(T), leaf_name : String) : Nil forall T
  expected = w78_catalog_rows_string(samples)
  parent = File.tempname("crystal-click-w78-catalog-string")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_map_string_array_numeric_pair(
      part, "pk", W78_CATALOG_KEYS.to_unsafe.to_slice(W78_CATALOG_KEYS.size), "payload",
      expected.to_unsafe.to_slice(expected.size), rows_per_mark: 2
    )
    table = w78_catalog_table_for_part(File.join(parent, "catalog"), part, "Map(String, Array(#{leaf_name}))")
    actual = table["payload"].values.map do |row|
      row.as?(Array(Tuple(String, Array(T)))) || raise("catalog returned the wrong Map(String, Array(T)) shape")
    end
    w78_catalog_assert_rows(expected, actual)

    key_bytes = 0_u64
    expected.each do |row|
      row.each { |key, _| key_bytes += key.bytesize.to_u64 }
    end
    table["payload"].values(max_string_bytes: key_bytes).size.should eq(expected.size)
    expect_raises(CrystalClick::BoundsError) do
      table["payload"].values(max_string_bytes: key_bytes - 1_u64)
    end
    expect_raises(CrystalClick::BoundsError) do
      table["payload"].values(max_rows: 5_u64)
    end
    actual[1][1][1].clear
    actual[4][0] = {"changed", actual[4][0][1]}
    fresh = table["payload"].values.map do |row|
      row.as?(Array(Tuple(String, Array(T)))) || raise("catalog returned the wrong Map(String, Array(T)) shape")
    end
    w78_catalog_assert_rows(expected, fresh)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe CrystalClick::OfflineCatalog do
  it "materializes both key shapes and all primitive Array leaves from W78 parts" do
    w78_catalog_check_u64([0_u8, UInt8::MAX, 17_u8, 44_u8], "UInt8")
    w78_catalog_check_string([0_u8, UInt8::MAX, 17_u8, 44_u8], "UInt8")
    w78_catalog_check_u64([0_u16, UInt16::MAX, 17_u16, 44_u16], "UInt16")
    w78_catalog_check_string([0_u16, UInt16::MAX, 17_u16, 44_u16], "UInt16")
    w78_catalog_check_u64([0_u32, UInt32::MAX, 17_u32, 44_u32], "UInt32")
    w78_catalog_check_string([0_u32, UInt32::MAX, 17_u32, 44_u32], "UInt32")
    w78_catalog_check_u64([0_u64, UInt64::MAX, 17_u64, 44_u64], "UInt64")
    w78_catalog_check_string([0_u64, UInt64::MAX, 17_u64, 44_u64], "UInt64")
    w78_catalog_check_u64([Int8::MIN, Int8::MAX, -1_i8, 5_i8], "Int8")
    w78_catalog_check_string([Int8::MIN, Int8::MAX, -1_i8, 5_i8], "Int8")
    w78_catalog_check_u64([Int16::MIN, Int16::MAX, -1_i16, 5_i16], "Int16")
    w78_catalog_check_string([Int16::MIN, Int16::MAX, -1_i16, 5_i16], "Int16")
    w78_catalog_check_u64([Int32::MIN, Int32::MAX, -1_i32, 5_i32], "Int32")
    w78_catalog_check_string([Int32::MIN, Int32::MAX, -1_i32, 5_i32], "Int32")
    w78_catalog_check_u64([Int64::MIN, Int64::MAX, -1_i64, 5_i64], "Int64")
    w78_catalog_check_string([Int64::MIN, Int64::MAX, -1_i64, 5_i64], "Int64")
    w78_catalog_check_u64([
      0x80000000_u32.unsafe_as(Float32),
      0x7fc00001_u32.unsafe_as(Float32),
      0x3f800000_u32.unsafe_as(Float32),
      0x40f00000_u32.unsafe_as(Float32),
    ], "Float32")
    w78_catalog_check_string([
      0x80000000_u32.unsafe_as(Float32),
      0x7fc00001_u32.unsafe_as(Float32),
      0x3f800000_u32.unsafe_as(Float32),
      0x40f00000_u32.unsafe_as(Float32),
    ], "Float32")
    w78_catalog_check_u64([
      0x8000000000000000_u64.unsafe_as(Float64),
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x3ff0000000000000_u64.unsafe_as(Float64),
      0x401e000000000000_u64.unsafe_as(Float64),
    ], "Float64")
    w78_catalog_check_string([
      0x8000000000000000_u64.unsafe_as(Float64),
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x3ff0000000000000_u64.unsafe_as(Float64),
      0x401e000000000000_u64.unsafe_as(Float64),
    ], "Float64")
  end
end
