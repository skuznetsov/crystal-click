require "./spec_helper"
require "file_utils"

private alias W83CatalogUInt64BoolMap = Array(Tuple(UInt64, Bool))
private alias W83CatalogStringBoolMap = Array(Tuple(String, Bool))
private alias W83CatalogUInt64NullableBoolMap = Array(Tuple(UInt64, Bool?))
private alias W83CatalogStringNullableBoolMap = Array(Tuple(String, Bool?))

private def w83_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w83_catalog_create_database(root : String) : String
  uuid = "a83d87f2-9c63-4e15-863a-1c7610ae4d28"
  store_path = w83_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(store_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{uuid}'\nENGINE = Atomic\n")
  store_path
end

private def w83_catalog_create_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  type : String,
) : String
  File.write(
    File.join(database_path, "#{name}.sql"),
    "ATTACH TABLE _ UUID '#{uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w83_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  File.join(table_path, "all_1_1_0")
end

describe CrystalClick::OfflineCatalog do
  it "materializes the four exact W83 Bool leaf shapes through catalog selections" do
    root = File.tempname("crystal-click-offline-catalog-w83")
    Dir.mkdir(root)
    FileUtils.mkdir_p(File.join(root, "store"))
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
    binary_key = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    u64_bools = [
      [] of W83CatalogUInt64BoolMap,
      [([] of Tuple(UInt64, Bool)), [{7_u64, false}, {7_u64, true}] of Tuple(UInt64, Bool)],
      [[{9_u64, true}] of Tuple(UInt64, Bool), [] of Tuple(UInt64, Bool)],
      [] of W83CatalogUInt64BoolMap,
      [[{UInt64::MAX, false}] of Tuple(UInt64, Bool), [] of Tuple(UInt64, Bool)],
    ] of Array(W83CatalogUInt64BoolMap)
    string_bools = [
      [] of W83CatalogStringBoolMap,
      [([] of Tuple(String, Bool)), [{"", false}, {binary_key, true}] of Tuple(String, Bool)],
      [[{binary_key, false}] of Tuple(String, Bool), [] of Tuple(String, Bool)],
      [] of W83CatalogStringBoolMap,
      [[{"dup", true}, {"dup", false}] of Tuple(String, Bool), [] of Tuple(String, Bool)],
    ] of Array(W83CatalogStringBoolMap)
    u64_nullable_bools = [
      [] of W83CatalogUInt64NullableBoolMap,
      [([] of Tuple(UInt64, Bool?)), [{7_u64, nil}, {7_u64, false}, {7_u64, true}] of Tuple(UInt64, Bool?)],
      [[{9_u64, nil}] of Tuple(UInt64, Bool?), [] of Tuple(UInt64, Bool?)],
      [] of W83CatalogUInt64NullableBoolMap,
      [[{UInt64::MAX, nil}, {0_u64, false}] of Tuple(UInt64, Bool?), [] of Tuple(UInt64, Bool?)],
    ] of Array(W83CatalogUInt64NullableBoolMap)
    string_nullable_bools = [
      [] of W83CatalogStringNullableBoolMap,
      [([] of Tuple(String, Bool?)), [{"", nil}, {binary_key, false}, {binary_key, true}] of Tuple(String, Bool?)],
      [[{binary_key, nil}] of Tuple(String, Bool?), [] of Tuple(String, Bool?)],
      [] of W83CatalogStringNullableBoolMap,
      [[{"dup", nil}, {"dup", false}] of Tuple(String, Bool?), [] of Tuple(String, Bool?)],
    ] of Array(W83CatalogStringNullableBoolMap)
    begin
      database_path = w83_catalog_create_database(root)
      part_u64 = w83_catalog_create_table(root, database_path, "u64_bool", "b83d87f2-9c63-4e15-863a-1c7610ae4d21", "Array(Map(UInt64, Bool))")
      part_string = w83_catalog_create_table(root, database_path, "string_bool", "b83d87f2-9c63-4e15-863a-1c7610ae4d22", "Array(Map(String, Bool))")
      part_nullable_u64 = w83_catalog_create_table(root, database_path, "u64_nullable_bool", "b83d87f2-9c63-4e15-863a-1c7610ae4d23", "Array(Map(UInt64, Nullable(Bool)))")
      part_nullable_string = w83_catalog_create_table(root, database_path, "string_nullable_bool", "b83d87f2-9c63-4e15-863a-1c7610ae4d24", "Array(Map(String, Nullable(Bool)))")

      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
        part_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_bools.to_unsafe.to_slice(u64_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
        part_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_bools.to_unsafe.to_slice(string_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        part_nullable_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_nullable_bools.to_unsafe.to_slice(u64_nullable_bools.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(
        part_nullable_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_nullable_bools.to_unsafe.to_slice(string_nullable_bools.size), rows_per_mark: 2
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog["lab"]["u64_bool"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(UInt64, Bool))))
      end.should eq(u64_bools)
      catalog["lab"]["string_bool"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(String, Bool))))
      end.should eq(string_bools)
      catalog["lab"]["u64_nullable_bool"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(UInt64, Bool?))))
      end.should eq(u64_nullable_bools)
      catalog["lab"]["string_nullable_bool"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(String, Bool?))))
      end.should eq(string_nullable_bools)

      expect_raises(CrystalClick::BoundsError, "selected column materialization exceeds String payload limit") do
        catalog["lab"]["string_bool"]["payload"].values(max_string_bytes: 2_u64)
      end
      catalog["lab"]["u64_bool"]["payload"].values(max_string_bytes: 0_u64).size.should eq(keys.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
