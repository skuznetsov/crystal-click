require "./spec_helper"

private def w81_catalog_table_for_part(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "e91d4a82-1cab-4a6f-a016-32cc0979b397"
  table_uuid = "d133d43f-fc5d-456f-9309-e20fc8cafb80"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Array(Map(String, Nullable(Int16))))\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe "W81 offline catalog Array(Map) materialization" do
  it "returns owned nullable values and binary String keys" do
    parent = File.tempname("crystal-click-w81-catalog")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
    expected = [
      [
        [{binary_key, nil}, {"zero", 0_i16}] of Tuple(String, Int16?),
        [] of Tuple(String, Int16?),
      ] of Array(Tuple(String, Int16?)),
      [] of Array(Tuple(String, Int16?)),
    ] of Array(Array(Tuple(String, Int16?)))
    keys = [0_u64, 1_u64]
    catalog_root = File.join(parent, "catalog")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        expected.to_unsafe.to_slice(expected.size),
        rows_per_mark: 1
      )
      table = w81_catalog_table_for_part(catalog_root, part)
      actual = table["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, Int16?)))) || raise("catalog returned the wrong W81 value type")
      end
      actual.should eq(expected)
      actual[0][0][0][0].to_slice.should eq(binary_key.to_slice)
      actual[0][0][0][1].should be_nil
      actual[0][0][1].should eq({"zero", 0_i16})

      actual[0][0].clear
      fresh = table["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, Int16?)))) || raise("catalog returned the wrong W81 value type")
      end
      fresh.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
