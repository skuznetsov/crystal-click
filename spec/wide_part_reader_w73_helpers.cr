require "./w71_helpers"

W73_READER_BINARY         = String.new(Bytes[0x4b_u8, 0_u8, 0xff_u8])
W73_READER_KEYS           = [0_u64, 1_u64, 2_u64, 3_u64, UInt64::MAX]
W73_READER_U64_U64_VALUES = [
  [] of Tuple(UInt64, Array(UInt64)),
  [
    {0_u64, [] of UInt64},
    {0_u64, [0_u64, UInt64::MAX] of UInt64},
    {UInt64::MAX, [7_u64, 7_u64] of UInt64},
  ] of Tuple(UInt64, Array(UInt64)),
  [{1_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
  [{UInt64::MAX, [UInt64::MAX, 1_u64, 2_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
  [{42_u64, [5_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
] of Array(Tuple(UInt64, Array(UInt64)))

W73_READER_STRING_STRING_VALUES = [
  [] of Tuple(String, Array(String)),
  [
    {"dup", [] of String},
    {"dup", ["", "a\0b"] of String},
    {W73_READER_BINARY, ["é"] of String},
  ] of Tuple(String, Array(String)),
  [{"empty-array", [] of String}] of Tuple(String, Array(String)),
  [
    {"雪", ["x", ""] of String},
    {"", ["尾"] of String},
  ] of Tuple(String, Array(String)),
  [{"tail", ["after", ""] of String}] of Tuple(String, Array(String)),
] of Array(Tuple(String, Array(String)))

W73_READER_U64_STRING_VALUES = [
  [] of Tuple(UInt64, Array(String)),
  [
    {0_u64, [] of String},
    {0_u64, ["", "a\0b"] of String},
    {UInt64::MAX, ["é"] of String},
  ] of Tuple(UInt64, Array(String)),
  [{1_u64, [] of String}] of Tuple(UInt64, Array(String)),
  [
    {UInt64::MAX, ["x", ""] of String},
    {7_u64, ["尾"] of String},
  ] of Tuple(UInt64, Array(String)),
  [{42_u64, ["tail", ""] of String}] of Tuple(UInt64, Array(String)),
] of Array(Tuple(UInt64, Array(String)))

W73_READER_U64_U64_STREAMS = [
  "payload.size0",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues",
]

W73_READER_STRING_STRING_STREAMS = [
  "payload.size0",
  "payload%2Ekeys.size",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.size",
  "payload%2Evalues",
]

W73_READER_U64_STRING_STREAMS = [
  "payload.size0",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.size",
  "payload%2Evalues",
]

def w73_reader_encoded_stream(path : String, stream : String) : Array(UInt8)
  File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice.to_a
end

def with_w73_reader_u64_u64_part(& : String ->) : Nil
  parent = File.tempname("crystal-click-w73-reader-u64-u64")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
      part, "pk", W73_READER_KEYS.to_unsafe.to_slice(W73_READER_KEYS.size), "payload",
      W73_READER_U64_U64_VALUES.to_unsafe.to_slice(W73_READER_U64_U64_VALUES.size), rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def with_w73_reader_string_string_part(& : String ->) : Nil
  parent = File.tempname("crystal-click-w73-reader-string-string")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
      part, "pk", W73_READER_KEYS.to_unsafe.to_slice(W73_READER_KEYS.size), "payload",
      W73_READER_STRING_STRING_VALUES.to_unsafe.to_slice(W73_READER_STRING_STRING_VALUES.size), rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def with_w73_reader_u64_string_part(& : String ->) : Nil
  parent = File.tempname("crystal-click-w73-reader-u64-string")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
      part, "pk", W73_READER_KEYS.to_unsafe.to_slice(W73_READER_KEYS.size), "payload",
      W73_READER_U64_STRING_VALUES.to_unsafe.to_slice(W73_READER_U64_STRING_VALUES.size), rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

def w73_reader_catalog_table(root : String, part : String, map_type : String) : CrystalClick::OfflineTable
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
