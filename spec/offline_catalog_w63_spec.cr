require "./spec_helper"

private def w63_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "39fb5af3-33d7-4270-97c6-7a05027c9aa7"
  table_uuid = "acf5fcb3-6448-49b0-91c6-c647bce9ce04"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` Map(String, Array(UInt64)))\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe CrystalClick::OfflineCatalog do
  it "materializes ordered Map(String, Array(UInt64)) entries with deep ownership" do
    parent = File.tempname("crystal-click-w63-catalog")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_3_0")
    keys = [1_u64, 2_u64, 3_u64]
    rows = [
      [{"k", [1_u64, 2_u64]}, {"k", [] of UInt64}],
      [] of Tuple(String, Array(UInt64)),
      [{"z", [3_u64]}],
    ] of Array(Tuple(String, Array(UInt64)))

    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
      catalog = w63_catalog_table(File.join(parent, "catalog"), part)
      first = catalog["payload"].values.map { |value| value.as(Array(Tuple(String, Array(UInt64)))) }
      first.should eq(rows)
      first[0][0][1][0] = 99_u64
      first[0] << {"new", [7_u64]}
      catalog["payload"].values.map { |value| value.as(Array(Tuple(String, Array(UInt64)))) }.should eq(rows)

      expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_string_bytes: 1_u64)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
