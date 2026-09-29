require "./spec_helper"
require "file_utils"

W80_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])

W80_ROWS = [
  [
    [{"dup", 0_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64),
    [] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [] of Array(Tuple(String, UInt64)),
  [
    [{W80_BINARY_KEY, 7_u64}] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [
    [] of Tuple(String, UInt64),
    [{"", 9_u64}] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [] of Array(Tuple(String, UInt64)),
] of Array(Array(Tuple(String, UInt64)))

def with_w80_part(& : String, String -> Nil) : Nil
  parent = File.tempname("crystal-click-w80")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      W80_ROWS.to_unsafe.to_slice(W80_ROWS.size),
      rows_per_mark: 2
    )
    yield parent, part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w80_catalog_table_for_part(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "801d4a82-1cab-4a6f-a016-32cc0979b397"
  table_uuid = "4d33d43f-fc5d-456f-9309-e20fc8cafb80"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Array(Map(String, UInt64)))\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end
