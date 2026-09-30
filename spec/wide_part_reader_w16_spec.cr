require "./spec_helper"

private def w16_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w16_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w16_with_catalog_root(&)
  root = File.tempname("crystal-click-w16-reader-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    database_uuid = "b16e7af8-f57c-42b8-bcb0-863f3de0ca51"
    database_path = w16_catalog_store_path(root, database_uuid)
    FileUtils.mkdir_p(database_path)
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    yield root, database_uuid
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w16_create_catalog_table(
  root : String,
  database_uuid : String,
  table_name : String,
  table_uuid : String,
  column_type : String,
  part_path : String,
) : Nil
  database_path = w16_catalog_store_path(root, database_uuid)
  File.write(
    File.join(database_path, "#{table_name}.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `amount` #{column_type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w16_catalog_store_path(root, table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part_path, File.join(table_path, "all_1_1_0"))
end

describe CrystalClick::WidePart do
  it "admits only canonical Decimal128 forms at scales zero through 38" do
    [
      "Decimal(38, 0)",
      "Decimal(38, 38)",
      "Nullable(Decimal(38, 0))",
      "Nullable(Decimal(38, 38))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end
    CrystalClick::WidePart.supports_w15_semantic_type?("Decimal(38, 0)").should be_false
    CrystalClick::WidePart.supports_nullable_w15_semantic_type?("Nullable(Decimal(38, 0))").should be_false

    [
      "Decimal(0, 0)",
      "Decimal(77, 0)",
      "Decimal(38, 39)",
      "Decimal(38, 00)",
      "Nullable(Nullable(Decimal(38, 2)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "normalizes Decimal128 aliases only at the catalog boundary" do
    CrystalClick::WidePart.catalog_type("Decimal128(0)").should eq("Decimal(38, 0)")
    CrystalClick::WidePart.catalog_type("Decimal128(38)").should eq("Decimal(38, 38)")
    CrystalClick::WidePart.catalog_type("Nullable(Decimal128(2))").should eq("Nullable(Decimal(38, 2))")
    CrystalClick::WidePart.supports_typed_type?("Decimal128(2)").should be_false
  end

  it "reads signed Decimal128 across marks and keeps it isolated from primitive accessors" do
    parent = File.tempname("crystal-click-w16-reader-decimal128")
    Dir.mkdir(parent)
    keys = w16_reader_keys(5)
    values = [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX]
    part_path = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 0, 2
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "amount")
      reader.column_type.should eq("Decimal(38, 0)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      CrystalClick::WidePart.decimal128_scale(reader.column_type).should eq(0)
      reader.read_decimal128_raw_mark_range("amount", 0, 2).should eq(values[0, 4])
      reader.read_decimal128_raw_mark_range("amount", 2, 1).should eq([Int128::MAX])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("amount", 0, 1, Int128)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["amount"])
      observed = [] of Int128
      batch_sizes = [] of Int32
      table.scan_typed(batch_rows: 3) do |batch|
        selected = batch.decimal128_raw_for("amount")
        observed.concat(selected)
        batch_sizes << selected.size.to_i32
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("amount", Int128)
        end
      end
      observed.should eq(values)
      batch_sizes.should eq([2_i32, 2_i32, 1_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves Nullable Decimal128 NULL separately from zero through table and catalog scans" do
    parent = File.tempname("crystal-click-w16-reader-nullable-decimal128")
    Dir.mkdir(parent)
    keys = w16_reader_keys(5)
    values = [nil.as(Int128?), 0_i128.as(Int128?), Int128::MIN.as(Int128?), nil.as(Int128?), Int128::MAX.as(Int128?)]
    part_path = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 38, 2
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "amount")
      reader.column_type.should eq("Nullable(Decimal(38, 38))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      CrystalClick::WidePart.nullable_decimal128_scale(reader.column_type).should eq(38)
      reader.read_nullable_decimal128_raw_mark_range("amount", 0, reader.mark_count).should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nullable_numeric_mark_range("amount", 0, 1, Int128)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["amount"])
      observed = [] of Int128?
      table.scan_typed(batch_rows: 3) do |batch|
        selected = batch.nullable_decimal128_raw_for("amount")
        observed.concat(selected)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nullable_values_for("amount", Int128)
        end
      end
      observed.should eq(values)

      w16_with_catalog_root do |root, database_uuid|
        bare_part = File.join(parent, "bare-part")
        bare_values = [Int128::MIN, 0_i128, Int128::MAX]
        bare_keys = w16_reader_keys(bare_values.size)
        CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
          bare_part, "pk", bare_keys.to_unsafe.to_slice(bare_keys.size), "amount",
          bare_values.to_unsafe.to_slice(bare_values.size), 3, 2
        )
        w16_create_catalog_table(root, database_uuid, "bare", "b16e7af8-f57c-42b8-bcb0-863f3de0ca52", "Decimal128(3)", bare_part)
        w16_create_catalog_table(root, database_uuid, "nullable", "b16e7af8-f57c-42b8-bcb0-863f3de0ca53", "Nullable(Decimal128(38))", part_path)

        catalog = CrystalClick::OfflineCatalog.open(root)
        catalog.table("lab", "bare").materialize_selected_values("amount").map(&.as(Int128)).should eq(bare_values)
        catalog.table("lab", "nullable").materialize_selected_values("amount").map(&.as(Int128?)).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a truncated Decimal128 payload stream before decoding rows" do
    parent = File.tempname("crystal-click-w16-reader-truncated")
    Dir.mkdir(parent)
    keys = w16_reader_keys(1)
    values = [Int128::MAX]
    part_path = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 0, 1
      )
      data_path = File.join(part_path, "#{CrystalClick::StreamName.hash("amount")}.bin")
      data = File.read(data_path)
      File.write(data_path, data.byte_slice(0, data.bytesize - 1))
      expect_raises(CrystalClick::CorruptPartError, "mark compressed offset exceeds data") do
        CrystalClick::WidePart.open_typed(part_path, "amount").read_decimal128_raw_mark_range("amount", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
