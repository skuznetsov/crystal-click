require "./spec_helper"

OFFLINE_W27_ARRAY_NULLABLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_nullable_uint64/part", __DIR__)
OFFLINE_W27_DATABASE_UUID          = "4cb996d1-cfa4-4f6e-87c4-2bb8ed5a3a12"
OFFLINE_W27_TABLE_UUID             = "ab52e9fb-0fab-48f0-9b56-dda5e65d37ef"

private def offline_w27_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_offline_w27_nullable_array_table(& : String ->)
  root = File.tempname("crystal-click-offline-w27-array-null-u64")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{OFFLINE_W27_DATABASE_UUID}'\nENGINE = Atomic\n"
    )

    database_path = offline_w27_store_path(root, OFFLINE_W27_DATABASE_UUID)
    FileUtils.mkdir_p(database_path)
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_W27_TABLE_UUID}'\n" +
      "(\n    `pk` UInt64,\n    `payload` Array(Nullable(UInt64))\n)\n" +
      "ENGINE = MergeTree\nORDER BY pk\n"
    )

    table_path = offline_w27_store_path(root, OFFLINE_W27_TABLE_UUID)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(OFFLINE_W27_ARRAY_NULLABLE_FIXTURE, File.join(table_path, "all_1_1_0"))

    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes nullable UInt64 arrays as caller-owned catalog values" do
    expected = [
      [] of UInt64?,
      [nil, 0_u64, UInt64::MAX] of UInt64?,
      [42_u64, nil] of UInt64?,
      [] of UInt64?,
      [nil] of UInt64?,
      [1_u64, 2_u64] of UInt64?,
      [] of UInt64?,
    ] of Array(UInt64?)

    with_offline_w27_nullable_array_table do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Nullable(UInt64))"},
      ])

      scanned = [] of Array(UInt64?)
      table.scan_typed(["payload"], batch_rows: 3) do |batch|
        scanned.concat(batch.array_nullable_uint64s_for("payload").map(&.dup))
      end
      scanned.should eq(expected)

      values = table["payload"].values
      values.map(&.as(Array(UInt64?))).should eq(expected)
      owned = values[1].as(Array(UInt64?))
      owned[0] = 99_u64
      values[1].as(Array(UInt64?)).should eq([99_u64, 0_u64, UInt64::MAX] of UInt64?)

      # A separately materialized result is isolated from mutations to the
      # earlier caller-owned nested Array.
      table["payload"].values.map(&.as(Array(UInt64?))).should eq(expected)
    end
  end
end
