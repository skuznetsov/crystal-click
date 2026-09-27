require "./spec_helper"

OFFLINE_W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_array_nullable_uint64/part", __DIR__)
OFFLINE_W29_DATABASE_UUID                       = "570fb63a-88a3-4f45-aa2e-6ef04cef0273"
OFFLINE_W29_TABLE_UUID                          = "9d4aa4e5-8c65-42d3-b0f7-87011b38573a"

private def offline_w29_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_offline_w29_nested_nullable_array_table(& : String ->)
  root = File.tempname("crystal-click-offline-w29-array-array-null-u64")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{OFFLINE_W29_DATABASE_UUID}'\nENGINE = Atomic\n"
    )

    database_path = offline_w29_store_path(root, OFFLINE_W29_DATABASE_UUID)
    FileUtils.mkdir_p(database_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_W29_TABLE_UUID}'\n" +
      "(\n    `pk` UInt64,\n    `payload` Array(Array(Nullable(UInt64)))\n)\n" +
      "ENGINE = MergeTree\nORDER BY pk\n"
    )

    table_path = offline_w29_store_path(root, OFFLINE_W29_TABLE_UUID)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(OFFLINE_W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE, File.join(table_path, "all_1_1_0"))

    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes nested nullable UInt64 arrays as caller-owned values" do
    expected = [
      [] of Array(UInt64?),
      [[] of UInt64?, [nil, 0_u64, UInt64::MAX] of UInt64?, [] of UInt64?],
      [[42_u64, nil] of UInt64?, [] of UInt64?],
      [] of Array(UInt64?),
      [[nil] of UInt64?, [] of UInt64?],
      [[1_u64, 2_u64, 3_u64] of UInt64?],
      [] of Array(UInt64?),
    ] of Array(Array(UInt64?))

    with_offline_w29_nested_nullable_array_table do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Array(Nullable(UInt64)))"},
      ])

      scanned = [] of Array(Array(UInt64?))
      table.scan_typed(["payload"], batch_rows: 3) do |batch|
        scanned.concat(batch.array_array_nullable_uint64s_for("payload"))
      end
      scanned.should eq(expected)

      values = table["payload"].values
      values.map(&.as(Array(Array(UInt64?)))).should eq(expected)
      owned = values[1].as(Array(Array(UInt64?)))
      owned[1][0] = 99_u64
      owned[1] << 77_u64
      owned << [88_u64] of UInt64?
      owned.should eq([[] of UInt64?, [99_u64, 0_u64, UInt64::MAX, 77_u64] of UInt64?, [] of UInt64?, [88_u64] of UInt64?] of Array(UInt64?))

      # A fresh materialization is isolated from mutations at every nested level.
      table["payload"].values.map(&.as(Array(Array(UInt64?)))).should eq(expected)
    end
  end
end
