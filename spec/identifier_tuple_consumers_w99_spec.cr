require "./spec_helper"
require "file_utils"

private def w99c_mixed_columns : Array(CrystalClick::WideTupleLeafColumn)
  ipv6 = [
    CrystalClick::IPv6Value.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64),
    CrystalClick::IPv6Value.new(0xfedcba9876543210_u64, 0x0123456789abcdef_u64),
    CrystalClick::IPv6Value.new(0_u64, 0_u64),
    CrystalClick::IPv6Value.new(UInt64::MAX, 0x0102030405060708_u64),
    CrystalClick::IPv6Value.new(0x8000000000000000_u64, 0xffff000000000001_u64),
  ]
  ipv4 = [
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
    CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
  ]
  uuid = [
    CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
    CrystalClick::UUIDValue.new(UInt64::MAX, 0_u64),
    CrystalClick::UUIDValue.new(0_u64, 0_u64),
    CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
    CrystalClick::UUIDValue.new(0x7f00ff01fe02fd03_u64, 0x04fc05fb06fa07f9_u64),
  ]
  strings = ["alpha", String.new(Bytes[0x62_u8, 0x00_u8, 0xff_u8]), "", "delta", "epsilon"]

  [
    CrystalClick::WideTupleLeafColumn.new("v6", ipv6),
    CrystalClick::WideTupleLeafColumn.new("count", [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]),
    CrystalClick::WideTupleLeafColumn.new("v4", ipv4),
    CrystalClick::WideTupleLeafColumn.new("id", uuid),
    CrystalClick::WideTupleLeafColumn.new("flag", [false, true, false, true, true]),
    CrystalClick::WideTupleLeafColumn.new("text", strings),
    CrystalClick::WideTupleLeafColumn.new("id_again", uuid),
    CrystalClick::WideTupleLeafColumn.new("v6_again", ipv6),
    CrystalClick::WideTupleLeafColumn.new("v4_again", ipv4),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w99c_identifier_only_columns : Array(CrystalClick::WideTupleLeafColumn)
  mixed = w99c_mixed_columns
  [mixed[3].owned_copy, mixed[2].owned_copy, mixed[0].owned_copy] of CrystalClick::WideTupleLeafColumn
end

private def w99c_all_default_columns : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("id", Array.new(5) { CrystalClick::UUIDValue.new(0_u64, 0_u64) }),
    CrystalClick::WideTupleLeafColumn.new("v4", Array.new(5) { CrystalClick::IPv4Value.new(0_u32) }),
    CrystalClick::WideTupleLeafColumn.new("v6", Array.new(5) { CrystalClick::IPv6Value.new(0_u64, 0_u64) }),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w99c_type_name(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w99c_keys : Array(UInt64)
  [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
end

private def w99c_write_part(parent : String, label : String, columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  container = File.join(parent, label)
  Dir.mkdir(container)
  destination = File.join(container, "all_1_1_0")
  keys = w99c_keys
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w99c_type_name(columns),
    columns,
    rows_per_mark: 2
  )
  destination
end

private def w99c_assert_data(
  data : CrystalClick::WideTupleColumnData,
  columns : Array(CrystalClick::WideTupleLeafColumn),
  source_indexes : Array(Int32),
) : Nil
  data.type_name.should eq(w99c_type_name(columns))
  data.row_count.should eq(source_indexes.size)
  data.fields.map { |field| {field.name, field.type_name} }.should eq(columns.map { |column| {column.name, column.type_name} })

  columns.each_with_index do |column, field_index|
    source_indexes.each_with_index do |source_index, local_index|
      case column.type_name
      when "UUID"
        data.value_as(column.name, local_index, CrystalClick::UUIDValue).should eq(column.value_at(source_index, CrystalClick::UUIDValue))
      when "IPv4"
        data.value_as(column.name, local_index, CrystalClick::IPv4Value).should eq(column.value_at(source_index, CrystalClick::IPv4Value))
      when "IPv6"
        data.value_as(column.name, local_index, CrystalClick::IPv6Value).should eq(column.value_at(source_index, CrystalClick::IPv6Value))
      when "UInt64"
        data.value_as(column.name, local_index, UInt64).should eq(column.value_at(source_index, UInt64))
      when "Bool"
        data.value_as(column.name, local_index, Bool).should eq(column.value_at(source_index, Bool))
      when "String"
        data.value_as(column.name, local_index, String).should eq(column.value_at(source_index, String))
      else
        raise "unexpected W99 spec leaf #{column.type_name} at #{field_index}"
      end
    end
  end
  nil
end

private def w99c_assert_row(
  row : CrystalClick::WideTupleRow,
  columns : Array(CrystalClick::WideTupleLeafColumn),
  source_index : Int32,
) : Nil
  row.type_name.should eq(w99c_type_name(columns))
  row.field_count.should eq(columns.size)
  columns.each do |column|
    case column.type_name
    when "UUID"
      row.value_as(column.name, CrystalClick::UUIDValue).should eq(column.value_at(source_index, CrystalClick::UUIDValue))
    when "IPv4"
      row.value_as(column.name, CrystalClick::IPv4Value).should eq(column.value_at(source_index, CrystalClick::IPv4Value))
    when "IPv6"
      row.value_as(column.name, CrystalClick::IPv6Value).should eq(column.value_at(source_index, CrystalClick::IPv6Value))
    when "UInt64"
      row.value_as(column.name, UInt64).should eq(column.value_at(source_index, UInt64))
    when "Bool"
      row.value_as(column.name, Bool).should eq(column.value_at(source_index, Bool))
    when "String"
      row.value_as(column.name, String).should eq(column.value_at(source_index, String))
    else
      raise "unexpected W99 spec leaf #{column.type_name}"
    end
  end
  nil
end

private def w99c_catalog(root : String, part : String, columns : Array(CrystalClick::WideTupleLeafColumn)) : Array(CrystalClick::OfflineColumnValue)
  database_uuid = "b9900000-0000-4000-8000-000000000001"
  table_uuid = "b9900000-0000-4000-8000-000000000002"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{w99c_type_name(columns)}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")["payload"].values(max_tuple_cells: 1_000_u64)
end

describe "W99 identifier Tuple table and catalog consumers" do
  it "keeps repeated identifiers nominal through full, window, sparse, range, and catalog reads" do
    columns = w99c_mixed_columns
    parent = File.tempname("crystal-click-w99-identifier-consumers")
    Dir.mkdir(parent)
    begin
      part = w99c_write_part(parent, "mixed", columns)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      full = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
      w99c_assert_data(full, columns, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
      selected = reader.read_tuple_mark_range("payload", 1, 2)
      w99c_assert_data(selected, columns, [2_i32, 3_i32, 4_i32])

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      seen = [] of Int32
      retained = [] of CrystalClick::WideTupleRow
      table.scan_typed do |batch|
        keys = batch.values_for("pk")
        rows = batch.tuple_rows_for("payload")
        rows.each_with_index do |row, offset|
          source_index = (keys[offset] - 1_u64).to_i32
          w99c_assert_row(row, columns, source_index)
          seen << source_index
          retained << row
        end
        nil
      end
      seen.should eq([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])

      window_indexes = [] of Int32
      table.scan_typed_window(1_u64, 3) do |batch|
        keys = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, offset|
          source_index = (keys[offset] - 1_u64).to_i32
          w99c_assert_row(row, columns, source_index)
          window_indexes << source_index
        end
        nil
      end
      window_indexes.should eq([1_i32, 2_i32, 3_i32])

      candidate_indexes = [] of Int32
      table.scan_typed_candidate_marks([[0_i32, 2_i32]]) do |batch|
        keys = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, offset|
          source_index = (keys[offset] - 1_u64).to_i32
          w99c_assert_row(row, columns, source_index)
          candidate_indexes << source_index
        end
        nil
      end
      candidate_indexes.should eq([0_i32, 1_i32, 4_i32])

      retained.size.should eq(5)
      retained.each_with_index { |row, index| w99c_assert_row(row, columns, index.to_i32) }

      catalog_root = File.tempname("crystal-click-w99-identifier-catalog")
      begin
        catalog_values = w99c_catalog(catalog_root, part, columns)
        catalog_values.size.should eq(5)
        catalog_values.each_with_index do |value, index|
          w99c_assert_row(value.as(CrystalClick::WideTupleRow), columns, index.to_i32)
        end
      ensure
        FileUtils.rm_rf(catalog_root)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains distinct UUID, IPv4, and IPv6 values in identifier-only and all-default profiles" do
    parent = File.tempname("crystal-click-w99-identifier-only-consumers")
    Dir.mkdir(parent)
    begin
      [
        {"identifier_only", w99c_identifier_only_columns},
        {"all_default", w99c_all_default_columns},
      ].each do |label, columns|
        part = w99c_write_part(parent, label, columns)
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
        w99c_assert_data(data, columns, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
        expect_raises(CrystalClick::UnsupportedFormatError) do
          data.value_as(columns.first.name, 0, UInt32)
        end

        catalog_root = File.tempname("crystal-click-w99-identifier-only-catalog")
        begin
          values = w99c_catalog(catalog_root, part, columns)
          values.each_with_index do |value, index|
            w99c_assert_row(value.as(CrystalClick::WideTupleRow), columns, index.to_i32)
          end
        ensure
          FileUtils.rm_rf(catalog_root)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
