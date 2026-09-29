require "./spec_helper"
require "file_utils"

private alias W84CatalogU64U64 = Array(Tuple(UInt64, Array(UInt64)))
private alias W84CatalogU64String = Array(Tuple(UInt64, Array(String)))
private alias W84CatalogStringU64 = Array(Tuple(String, Array(UInt64)))
private alias W84CatalogStringString = Array(Tuple(String, Array(String)))

private def w84_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w84_catalog_create_database(root : String) : String
  uuid = "a84d87f2-9c63-4e15-863a-1c7610ae4d28"
  store_path = w84_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(store_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{uuid}'\nENGINE = Atomic\n")
  store_path
end

private def w84_catalog_create_table(
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
  table_path = w84_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  File.join(table_path, "all_1_1_0")
end

describe CrystalClick::OfflineCatalog do
  it "materializes all four exact W84 types through catalog column selections" do
    root = File.tempname("crystal-click-offline-catalog-w84")
    Dir.mkdir(root)
    FileUtils.mkdir_p(File.join(root, "store"))
    keys = [0_u64, 1_u64, 2_u64]
    binary_key = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    binary_value = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
    u64_u64 = [
      [] of W84CatalogU64U64,
      [[] of Tuple(UInt64, Array(UInt64))] of W84CatalogU64U64,
      [[{7_u64, [] of UInt64}, {7_u64, [11_u64, 12_u64]}] of Tuple(UInt64, Array(UInt64))] of W84CatalogU64U64,
    ] of Array(W84CatalogU64U64)
    u64_string = [
      [] of W84CatalogU64String,
      [[] of Tuple(UInt64, Array(String))] of W84CatalogU64String,
      [[{8_u64, ["", binary_value]}] of Tuple(UInt64, Array(String))] of W84CatalogU64String,
    ] of Array(W84CatalogU64String)
    string_u64 = [
      [] of W84CatalogStringU64,
      [[] of Tuple(String, Array(UInt64))] of W84CatalogStringU64,
      [[{binary_key, [13_u64]}] of Tuple(String, Array(UInt64))] of W84CatalogStringU64,
    ] of Array(W84CatalogStringU64)
    string_string = [
      [] of W84CatalogStringString,
      [[] of Tuple(String, Array(String))] of W84CatalogStringString,
      [[{"dup", [] of String}, {"dup", [binary_value]}] of Tuple(String, Array(String))] of W84CatalogStringString,
    ] of Array(W84CatalogStringString)
    begin
      database_path = w84_catalog_create_database(root)
      part_uu = w84_catalog_create_table(root, database_path, "u64_u64", "b84d87f2-9c63-4e15-863a-1c7610ae4d21", "Array(Map(UInt64, Array(UInt64)))")
      part_us = w84_catalog_create_table(root, database_path, "u64_string", "b84d87f2-9c63-4e15-863a-1c7610ae4d22", "Array(Map(UInt64, Array(String)))")
      part_su = w84_catalog_create_table(root, database_path, "string_u64", "b84d87f2-9c63-4e15-863a-1c7610ae4d23", "Array(Map(String, Array(UInt64)))")
      part_ss = w84_catalog_create_table(root, database_path, "string_string", "b84d87f2-9c63-4e15-863a-1c7610ae4d24", "Array(Map(String, Array(String)))")

      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        part_uu, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_u64.to_unsafe.to_slice(u64_u64.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_string_pair(
        part_us, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_string.to_unsafe.to_slice(u64_string.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
        part_su, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_u64.to_unsafe.to_slice(string_u64.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_string_pair(
        part_ss, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_string.to_unsafe.to_slice(string_string.size), rows_per_mark: 2
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog["lab"]["u64_u64"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(UInt64, Array(UInt64)))))
      end.should eq(u64_u64)
      catalog["lab"]["u64_string"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(UInt64, Array(String)))))
      end.should eq(u64_string)
      catalog["lab"]["string_u64"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(String, Array(UInt64)))))
      end.should eq(string_u64)
      catalog["lab"]["string_string"]["payload"].values.map do |value|
        value.as(Array(Array(Tuple(String, Array(String)))))
      end.should eq(string_string)
      error = expect_raises(CrystalClick::BoundsError) do
        catalog["lab"]["string_string"]["payload"].values(max_string_bytes: 2_u64)
      end
      error.message.not_nil!.should eq("selected column materialization exceeds String payload limit")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
