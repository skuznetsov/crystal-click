require "./spec_helper"

private def w104c_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w104c_batch_type_inventory(batch : CrystalClick::WidePartTableBatch) : Array(Tuple(String, String))
  batch.column_names.map { |name| {name, batch.column_type_for(name)} }
end

private def w104c_catalog_root(root : String, part : String, ddl_type : String) : Nil
  database_uuid = "10400000-0000-4000-8000-000000000011"
  table_uuid = "10400000-0000-4000-8000-000000000012"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{ddl_type}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  nil
end

private def w104c_assert_nullable_temporal_consumers(
  parent : String,
  label : String,
  exact_type : String,
  values : Array(T?),
  write_part : Proc(String, String),
  read_values : Proc(CrystalClick::WidePartTableBatch, Slice(T?)),
) forall T
  profile_root = File.join(parent, label)
  Dir.mkdir(profile_root)
  part = File.join(profile_root, "all_1_1_0")
  write_part.call(part).should eq(part)
  File.read(File.join(part, "columns.txt")).should contain(exact_type)
  CrystalClick::WidePart.open_typed(part, "payload").column_type.should eq(exact_type)

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  table.column_types.should eq([{"pk", "UInt64"}, {"payload", exact_type}])
  full = [] of T?
  table.scan_typed do |batch|
    w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
    read_values.call(batch).each { |value| full << value }
    nil
  end
  full.should eq(values)

  window = [] of T?
  table.scan_typed_window(1_u64, 3) do |batch|
    w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
    read_values.call(batch).each { |value| window << value }
    nil
  end
  window.should eq(values[1, 3])

  catalog_root = File.join(profile_root, "catalog")
  w104c_catalog_root(catalog_root, part, exact_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "payload" }.not_nil!.type.should eq(exact_type)
  offline["payload"].values.map { |value| value.as(T?) }.should eq(values)
  catalog_full = [] of T?
  offline.scan_typed(["pk", "payload"]) do |batch|
    w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
    read_values.call(batch).each { |value| catalog_full << value }
    nil
  end
  catalog_full.should eq(values)

  catalog_window = [] of T?
  offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
    read_values.call(batch).each { |value| catalog_window << value }
    nil
  end
  catalog_window.should eq(values[1, 3])
end

describe "W104 timezone-qualified temporal consumers" do
  it "keeps an exact alias through normalized DDL, full scans, and row windows" do
    parent = File.tempname("crystal-click-timezone-consumer-alias")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    ticks = [Int64::MIN, -1_i64, 0_i64, 1_615_705_200_001_i64, Int64::MAX]
    exact_type = "DateTime64(3, 'US/Eastern')"

    begin
      CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
        part, "pk", w104c_slice(keys), "payload", w104c_slice(ticks), 3,
        rows_per_mark: 2, time_zone: "US/Eastern"
      ).should eq(part)
      File.read(File.join(part, "columns.txt")).should contain(exact_type)
      CrystalClick::WidePart.open_typed(part, "payload").column_type.should eq(exact_type)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table.column_types.should eq([{"pk", "UInt64"}, {"payload", exact_type}])
      full = [] of Int64
      table.scan_typed do |batch|
        w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
        batch.datetime64_ticks_for("payload").each { |value| full << value }
        nil
      end
      full.should eq(ticks)

      window = [] of Int64
      table.scan_typed_window(1_u64, 2) do |batch|
        w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
        batch.datetime64_ticks_for("payload").each { |value| window << value }
        nil
      end
      window.should eq([-1_i64, 0_i64])

      catalog_root = File.join(parent, "catalog")
      w104c_catalog_root(catalog_root, part, "DateTime64( 3 , 'US/Eastern' )")
      offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      catalog_full = [] of Int64
      offline.scan_typed(["pk", "payload"]) do |batch|
        w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
        batch.datetime64_ticks_for("payload").each { |value| catalog_full << value }
        nil
      end
      catalog_full.should eq(ticks)

      catalog_window = [] of Int64
      offline.scan_typed_window(["pk", "payload"], 1_u64, 2) do |batch|
        w104c_batch_type_inventory(batch).should eq([{"pk", "UInt64"}, {"payload", exact_type}])
        batch.datetime64_ticks_for("payload").each { |value| catalog_window << value }
        nil
      end
      catalog_window.should eq([-1_i64, 0_i64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads timezone-qualified Nullable DateTime values through table and catalog full/window scans" do
    parent = File.tempname("crystal-click-timezone-consumer-nullable")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]

    begin
      datetime_type = "Nullable(DateTime('America/New_York'))"
      datetime_values = [nil, 0_u32.as(UInt32?), 1_615_705_200_u32.as(UInt32?), nil, UInt32::MAX.as(UInt32?)]
      w104c_assert_nullable_temporal_consumers(
        parent,
        "nullable-datetime",
        datetime_type,
        datetime_values,
        ->(destination : String) {
          CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
            destination, "pk", w104c_slice(keys), "payload", w104c_slice(datetime_values),
            rows_per_mark: 2, time_zone: "America/New_York"
          )
        },
        ->(batch : CrystalClick::WidePartTableBatch) { batch.nullable_datetime_seconds_for("payload") }
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads timezone-qualified Nullable DateTime64 values through table and catalog full/window scans" do
    parent = File.tempname("crystal-click-timezone-consumer-nullable64")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    datetime64_type = "Nullable(DateTime64(3, 'America/New_York'))"
    datetime64_values = [nil, 0_i64.as(Int64?), -1_i64.as(Int64?), nil, Int64::MAX.as(Int64?)]

    begin
      w104c_assert_nullable_temporal_consumers(
        parent,
        "nullable-datetime64",
        datetime64_type,
        datetime64_values,
        ->(destination : String) {
          CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
            destination, "pk", w104c_slice(keys), "payload", w104c_slice(datetime64_values), 3,
            rows_per_mark: 2, time_zone: "America/New_York"
          )
        },
        ->(batch : CrystalClick::WidePartTableBatch) { batch.nullable_datetime64_ticks_for("payload") }
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-raw UTC and Etc/UTC schema mismatch before any callback" do
    parent = File.tempname("crystal-click-timezone-consumer-mismatch")
    Dir.mkdir(parent)
    utc_root = File.join(parent, "utc")
    etc_root = File.join(parent, "etc")
    Dir.mkdir(utc_root)
    Dir.mkdir(etc_root)
    part = File.join(utc_root, "all_1_1_0")
    etc_part = File.join(etc_root, "all_2_2_0")
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 1_615_705_200_u32, UInt32::MAX]

    begin
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(
        part, "pk", w104c_slice(keys), "payload", w104c_slice(seconds),
        rows_per_mark: 2, time_zone: "UTC"
      ).should eq(part)
      utc_type = "DateTime('UTC')"
      etc_type = "DateTime('Etc/UTC')"
      File.read(File.join(part, "columns.txt")).should contain(utc_type)
      w104c_catalog_root(File.join(parent, "catalog"), part, etc_type)
      offline = CrystalClick::OfflineCatalog.open(File.join(parent, "catalog")).table("lab", "events")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        offline.scan_typed(["pk", "payload"]) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)

      etc_keys = [4_u64, 5_u64, 6_u64]
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(
        etc_part, "pk", w104c_slice(etc_keys), "payload", w104c_slice(seconds),
        rows_per_mark: 2, time_zone: "Etc/UTC"
      ).should eq(etc_part)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part, etc_part], ["pk", "payload"])
        table.scan_typed do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains exact zoned temporal metadata in copied and empty Tuple leaves" do
    exact_type = "DateTime64(3, 'US/Eastern')"
    tuple_type = "Tuple(at #{exact_type}, tag UInt8)"
    plan = CrystalClick::WideTupleTypePlan.for_type(tuple_type).not_nil!
    empty_temporal = CrystalClick::WideTupleLeafColumn.new("at", exact_type, [] of CrystalClick::DateTime64Value)
    empty_tag = CrystalClick::WideTupleLeafColumn.new("tag", [] of UInt8)
    data = CrystalClick::WideTupleColumnData.new(plan, [empty_temporal, empty_tag])

    data.type_name.should eq(tuple_type)
    data.row_count.should eq(0)
    fields = data.fields
    fields.first.type_name.should eq(exact_type)
    copies = data.columns
    copies[0].type_name.should eq(exact_type)
    copies[0].owned_copy.type_name.should eq(exact_type)
    copies[0].size.should eq(0)

    populated_temporal = CrystalClick::WideTupleLeafColumn.new(
      "at", exact_type,
      [CrystalClick::DateTime64Value.new(Int64::MIN, 3), CrystalClick::DateTime64Value.new(1_615_705_200_001_i64, 3)]
    )
    populated_tag = CrystalClick::WideTupleLeafColumn.new("tag", [1_u8, 2_u8])
    populated = CrystalClick::WideTupleColumnData.new(plan, [populated_temporal, populated_tag])
    populated.type_name.should eq(tuple_type)
    populated.columns[0].type_name.should eq(exact_type)
    populated.columns[0].owned_copy.type_name.should eq(exact_type)
  end
end
