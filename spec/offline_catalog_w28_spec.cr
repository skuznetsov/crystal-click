require "./spec_helper"

OFFLINE_W28_ARRAY_ARRAY_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_array_uint64/part", __DIR__)
OFFLINE_W28_DATABASE_UUID              = "b3c44b70-2f5b-4d98-a7c4-33f2db736c6b"
OFFLINE_W28_TABLE_UUID                 = "7d71f162-236e-4fd4-9ed5-95cccd169760"

private def offline_w28_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_offline_w28_nested_array_table(& : String ->)
  root = File.tempname("crystal-click-offline-w28-array-array-u64")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{OFFLINE_W28_DATABASE_UUID}'\nENGINE = Atomic\n"
    )

    database_path = offline_w28_store_path(root, OFFLINE_W28_DATABASE_UUID)
    FileUtils.mkdir_p(database_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_W28_TABLE_UUID}'\n" +
      "(\n    `pk` UInt64,\n    `payload` Array(Array(UInt64))\n)\n" +
      "ENGINE = MergeTree\nORDER BY pk\n"
    )

    table_path = offline_w28_store_path(root, OFFLINE_W28_TABLE_UUID)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(OFFLINE_W28_ARRAY_ARRAY_UINT64_FIXTURE, File.join(table_path, "all_1_1_0"))

    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes nested UInt64 arrays as caller-owned values" do
    expected = [
      [] of Array(UInt64),
      [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64],
      [[42_u64], [] of UInt64],
      [] of Array(UInt64),
      [[] of UInt64, [] of UInt64],
      [[1_u64, 2_u64, 3_u64]],
      [] of Array(UInt64),
    ] of Array(Array(UInt64))

    with_offline_w28_nested_array_table do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Array(UInt64))"},
      ])

      scanned = [] of Array(Array(UInt64))
      table.scan_typed(["payload"], batch_rows: 3) do |batch|
        scanned.concat(batch.array_array_uint64s_for("payload"))
      end
      scanned.should eq(expected)

      values = table["payload"].values
      values.map(&.as(Array(Array(UInt64)))).should eq(expected)
      owned = values[1].as(Array(Array(UInt64)))
      owned[1][0] = 99_u64
      owned << [77_u64]
      owned.should eq([[] of UInt64, [99_u64, UInt64::MAX], [] of UInt64, [77_u64]])

      # A fresh materialization is isolated from mutations to both nesting levels.
      table["payload"].values.map(&.as(Array(Array(UInt64)))).should eq(expected)
    end
  end
end
