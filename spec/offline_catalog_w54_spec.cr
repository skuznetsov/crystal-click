require "./spec_helper"

W54_CATALOG_FIXTURE           = File.expand_path("../test/fixtures/public/wide_map_nullable_string_w54/part", __DIR__)
W54_CATALOG_BINARY_KEY        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W54_CATALOG_MAP_UINT64_VALUES = [
  [] of Tuple(UInt64, String?),
  [{7_u64, nil}, {7_u64, ""}] of Tuple(UInt64, String?),
  [{UInt64::MAX, ""}, {0_u64, nil}] of Tuple(UInt64, String?),
  [{1_u64, "x\0y"}] of Tuple(UInt64, String?),
  [] of Tuple(UInt64, String?),
  [{5_u64, nil}, {5_u64, "雪"}] of Tuple(UInt64, String?),
  [{9_u64, "end"}] of Tuple(UInt64, String?),
] of Array(Tuple(UInt64, String?))
W54_CATALOG_MAP_STRING_VALUES = [
  [] of Tuple(String, String?),
  [{"dup", nil}, {"dup", ""}] of Tuple(String, String?),
  [{W54_CATALOG_BINARY_KEY, ""}, {"雪", nil}] of Tuple(String, String?),
  [{"empty", ""}] of Tuple(String, String?),
  [] of Tuple(String, String?),
  [{"tail", nil}, {"", "🐈"}] of Tuple(String, String?),
  [{"end", "last"}] of Tuple(String, String?),
] of Array(Tuple(String, String?))

private def w54_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

describe CrystalClick::OfflineCatalog do
  it "materializes both nullable String Map types with bounded ordered values" do
    root = File.tempname("crystal-click-w54-map-catalog")
    Dir.mkdir(root)
    database_uuid = "7b15de9e-f760-4f05-b58d-42ec01627129"
    table_uuid = "cc2ec1b8-49d9-40d1-aed2-b8f05f18a751"
    database_store = w54_catalog_store_path(root, database_uuid)
    table_store = w54_catalog_store_path(root, table_uuid)
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
        "    `map_u64` Map(UInt64, Nullable(String)),\n" \
        "    `map_string` Map(String, Nullable(String))\n" \
        ")\nENGINE = MergeTree\nORDER BY pk\n"
      )
      File.write(File.join(table_store, "format_version.txt"), "1\n")
      Dir.mkdir(File.join(table_store, "detached"))
      FileUtils.cp_r(W54_CATALOG_FIXTURE, File.join(table_store, "all_1_1_0"))

      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      u64_selection = table["map_u64"]
      string_selection = table["map_string"]
      u64_values = u64_selection.values(7_u64, 9_u64).map { |value| value.as(Array(Tuple(UInt64, String?))) }
      string_values = string_selection.values(7_u64, 33_u64).map { |value| value.as(Array(Tuple(String, String?))) }
      u64_values.should eq(W54_CATALOG_MAP_UINT64_VALUES)
      string_values.should eq(W54_CATALOG_MAP_STRING_VALUES)

      expect_raises(CrystalClick::BoundsError) { u64_selection.values(7_u64, 8_u64) }
      expect_raises(CrystalClick::BoundsError) { string_selection.values(7_u64, 32_u64) }
      expect_raises(CrystalClick::BoundsError) { u64_selection.values(6_u64, 9_u64) }
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
