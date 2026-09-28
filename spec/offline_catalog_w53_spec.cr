require "./spec_helper"

W53_CATALOG_FIXTURE           = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
W53_CATALOG_BINARY_KEY        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W53_CATALOG_MAP_UINT64_VALUES = [
  [] of Tuple(UInt64, UInt64?),
  [{7_u64, nil}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [{UInt64::MAX, 42_u64}, {0_u64, nil}] of Tuple(UInt64, UInt64?),
  [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [] of Tuple(UInt64, UInt64?),
  [{5_u64, nil}, {5_u64, UInt64::MAX}] of Tuple(UInt64, UInt64?),
  [{9_u64, 0_u64}] of Tuple(UInt64, UInt64?),
] of Array(Tuple(UInt64, UInt64?))
W53_CATALOG_MAP_STRING_VALUES = [
  [] of Tuple(String, UInt64?),
  [{"dup", nil}, {"dup", 0_u64}] of Tuple(String, UInt64?),
  [{W53_CATALOG_BINARY_KEY, UInt64::MAX}, {"雪", nil}] of Tuple(String, UInt64?),
  [{"empty", 0_u64}, {"empty", nil}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"tail", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [{"end", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))

private def w53_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

describe CrystalClick::OfflineCatalog do
  it "materializes both nullable Map values from a stock part and exact table DDL" do
    root = File.tempname("crystal-click-w53-map-catalog")
    Dir.mkdir(root)
    database_uuid = "7b15de9e-f760-4f05-b58d-42ec01627129"
    table_uuid = "cc2ec1b8-49d9-40d1-aed2-b8f05f18a751"
    database_store = w53_catalog_store_path(root, database_uuid)
    table_store = w53_catalog_store_path(root, table_uuid)
    begin
      FileUtils.mkdir_p(File.join(root, "metadata"))
      FileUtils.mkdir_p(database_store)
      FileUtils.mkdir_p(table_store)
      File.write(
        File.join(root, "metadata", "lab.sql"),
        "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
      )
      File.write(
        File.join(database_store, "events.sql"),
        "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" \
        "    `pk` UInt64,\n" \
        "    `map_u64` Map(UInt64, Nullable(UInt64)),\n" \
        "    `map_string` Map(String, Nullable(UInt64))\n" \
        ")\nENGINE = MergeTree\nORDER BY pk\n"
      )
      File.write(File.join(table_store, "format_version.txt"), "1\n")
      Dir.mkdir(File.join(table_store, "detached"))
      FileUtils.cp_r(W53_CATALOG_FIXTURE, File.join(table_store, "all_1_1_0"))

      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      u64_values = table["map_u64"].values.map { |value| value.as(Array(Tuple(UInt64, UInt64?))) }
      string_values = table["map_string"].values.map { |value| value.as(Array(Tuple(String, UInt64?))) }
      u64_values.should eq(W53_CATALOG_MAP_UINT64_VALUES)
      string_values.should eq(W53_CATALOG_MAP_STRING_VALUES)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
