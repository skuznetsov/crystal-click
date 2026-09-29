require "./spec_helper"
require "file_utils"

private def w82_catalog_table_for_part(root : String, part : String, payload_type : String) : CrystalClick::OfflineTable
  database_uuid = "281f4a2b-7a5c-4a6a-988d-d15a2fe64701"
  table_uuid = "84b304b2-4f7c-4f82-b17d-35c82338e8f2"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` #{payload_type})\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe "W82 offline catalog Array(Map) String-leaf materialization" do
  it "exposes all four exact declarations with owned binary, empty, and NULL values" do
    parent = File.tempname("crystal-click-w82-catalog")
    Dir.mkdir(parent)
    binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
    binary_value = String.new(Bytes[0_u8, 0xfe_u8, 0x81_u8])
    keys = [0_u64, 1_u64]
    u64_values = [
      [[{7_u64, binary_value}, {8_u64, ""}] of Tuple(UInt64, String)],
      [] of Array(Tuple(UInt64, String)),
    ] of Array(Array(Tuple(UInt64, String)))
    string_values = [
      [[{binary_key, binary_value}, {"", ""}] of Tuple(String, String)],
      [] of Array(Tuple(String, String)),
    ] of Array(Array(Tuple(String, String)))
    u64_nullable_values = [
      [[{7_u64, nil}, {8_u64, ""}] of Tuple(UInt64, String?)],
      [] of Array(Tuple(UInt64, String?)),
    ] of Array(Array(Tuple(UInt64, String?)))
    string_nullable_values = [
      [[{binary_key, nil}, {"", binary_value}] of Tuple(String, String?)],
      [] of Array(Tuple(String, String?)),
    ] of Array(Array(Tuple(String, String?)))

    begin
      ["u64", "string", "nullable-u64", "nullable-string"].each do |directory|
        FileUtils.mkdir_p(File.join(parent, directory))
      end
      part_u64 = File.join(parent, "u64", "all_1_1_0")
      part_string = File.join(parent, "string", "all_1_1_0")
      part_nullable_u64 = File.join(parent, "nullable-u64", "all_1_1_0")
      part_nullable_string = File.join(parent, "nullable-string", "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
        part_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 1
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_string_pair(
        part_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_string_pair(
        part_nullable_u64, "pk", keys.to_unsafe.to_slice(keys.size), "payload", u64_nullable_values.to_unsafe.to_slice(u64_nullable_values.size), rows_per_mark: 1
      )
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_string_pair(
        part_nullable_string, "pk", keys.to_unsafe.to_slice(keys.size), "payload", string_nullable_values.to_unsafe.to_slice(string_nullable_values.size), rows_per_mark: 1
      )

      catalog_u64 = w82_catalog_table_for_part(File.join(parent, "catalog-u64"), part_u64, "Array(Map(UInt64, String))")
      actual_u64 = catalog_u64["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(UInt64, String)))) || raise("catalog returned the wrong W82 UInt64/String value type")
      end
      actual_u64.should eq(u64_values)
      actual_u64[0][0][0][1].to_slice.should eq(binary_value.to_slice)

      catalog_string = w82_catalog_table_for_part(File.join(parent, "catalog-string"), part_string, "Array(Map(String, String))")
      actual_string = catalog_string["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, String)))) || raise("catalog returned the wrong W82 String/String value type")
      end
      actual_string.should eq(string_values)
      actual_string[0][0][0][0].to_slice.should eq(binary_key.to_slice)

      catalog_nullable_u64 = w82_catalog_table_for_part(
        File.join(parent, "catalog-nullable-u64"), part_nullable_u64, "Array(Map(UInt64, Nullable(String)))"
      )
      actual_nullable_u64 = catalog_nullable_u64["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(UInt64, String?)))) || raise("catalog returned the wrong W82 UInt64/Nullable(String) value type")
      end
      actual_nullable_u64.should eq(u64_nullable_values)
      actual_nullable_u64[0][0][0][1].should be_nil
      actual_nullable_u64[0][0][1][1].should eq("")

      catalog_nullable_string = w82_catalog_table_for_part(
        File.join(parent, "catalog-nullable-string"), part_nullable_string, "Array(Map(String, Nullable(String)))"
      )
      actual_nullable_string = catalog_nullable_string["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, String?)))) || raise("catalog returned the wrong W82 String/Nullable(String) value type")
      end
      actual_nullable_string.should eq(string_nullable_values)
      actual_nullable_string[0][0][0][0].to_slice.should eq(binary_key.to_slice)
      actual_nullable_string[0][0][0][1].should be_nil
      actual_nullable_string[0][0][1][1].not_nil!.to_slice.should eq(binary_value.to_slice)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
