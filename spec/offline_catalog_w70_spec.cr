require "./w70_helpers"

private def w70_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  database_uuid = "58fd019f-65d2-48fb-97a6-8b64382a57d5"
  table_uuid = "70444768-5d9c-4954-8c57-378c4f6d6273"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`id` UInt64, `m` Map(String, Array(Nullable(String))))\nENGINE = MergeTree\nORDER BY id\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe CrystalClick::OfflineCatalog do
  it "returns independently owned ordered W70 Map rows and enforces retained String limits" do
    with_w70_part do |part|
      catalog = w70_catalog_table(File.join(File.dirname(part), "catalog"), part)
      first = catalog["m"].values.map do |value|
        value.as(Array(Tuple(String, Array(String?))))
      end
      first.should eq(W70_VALUES)

      first[0][0][1][2] = "changed"
      first[0][0][1][0] = "changed"
      catalog["m"].values.map do |value|
        value.as(Array(Tuple(String, Array(String?))))
      end.should eq(W70_VALUES)

      expect_raises(CrystalClick::BoundsError) do
        catalog["m"].values(max_string_bytes: 1_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        catalog["m"].values(max_rows: 6_u64)
      end
    end
  end

  it "does not charge hidden NULL bytes against retained String limits" do
    with_w70_part do |part|
      w70_rewrite_mark_frame(part, "m%2Evalues.size", 0) do |raw, offset|
        w70_write_u64(raw, offset, 1_u64)
        w70_write_u64(raw, offset + 16, 2_u64)
      end
      catalog = w70_catalog_table(File.join(File.dirname(part), "catalog_hidden"), part)
      expected = W70_VALUES.dup
      expected[0] = expected[0].dup
      expected[0][0] = {"dup", [nil, "", "\0b", "café"] of String?}
      catalog["m"].values(max_string_bytes: 90_u64).map do |value|
        value.as(Array(Tuple(String, Array(String?))))
      end.should eq(expected)
    end
  end
end
