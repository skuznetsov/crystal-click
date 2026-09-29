require "./w69_helpers"
require "file_utils"

W79_U64_ROWS = [
  [] of Tuple(UInt64, Array(Int8?)),
  [
    {7_u64, [nil, -5_i8] of Int8?},
    {7_u64, [] of Int8?},
  ] of Tuple(UInt64, Array(Int8?)),
  [{42_u64, [9_i8, nil] of Int8?}] of Tuple(UInt64, Array(Int8?)),
  [{UInt64::MAX, [] of Int8?}] of Tuple(UInt64, Array(Int8?)),
] of Array(Tuple(UInt64, Array(Int8?)))

W79_STRING_KEY = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
W79_NAN_BITS   = 0x7ff8_0000_0000_0042_u64

W79_STRING_ROWS = [
  [] of Tuple(String, Array(Float64?)),
  [
    {W79_STRING_KEY, [nil, 0x8000_0000_0000_0000_u64.unsafe_as(Float64)] of Float64?},
    {"", [] of Float64?},
  ] of Tuple(String, Array(Float64?)),
  [{"dup", [W79_NAN_BITS.unsafe_as(Float64), nil] of Float64?}] of Tuple(String, Array(Float64?)),
  [{"雪", [] of Float64?}] of Tuple(String, Array(Float64?)),
] of Array(Tuple(String, Array(Float64?)))

def with_w79_parts(& : String, String, String -> Nil) : Nil
  parent = File.tempname("crystal-click-w79-reader")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "all_1_1_0")
  string_path = File.join(parent, "all_2_2_0")
  keys = [0_u64, 1_u64, 2_u64, 3_u64]
  key_slice = keys.to_unsafe.to_slice(keys.size)
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_numeric_pair(
      u64_path,
      "pk",
      key_slice,
      "payload",
      W79_U64_ROWS.to_unsafe.to_slice(W79_U64_ROWS.size),
      rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_numeric_pair(
      string_path,
      "pk",
      key_slice,
      "payload",
      W79_STRING_ROWS.to_unsafe.to_slice(W79_STRING_ROWS.size),
      rows_per_mark: 2
    )
    yield parent, u64_path, string_path
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w79_catalog_table_for_part(root : String, part : String, map_type : String) : CrystalClick::OfflineTable
  database_uuid = "791d4a82-1cab-4a6f-a016-32cc0979b397"
  table_uuid = "4d33d43f-fc5d-456f-9309-e20fc8cafb79"
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
