require "./spec_helper"
require "file_utils"

private def w96_consumer_columns : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("i8", [Int8::MIN, -1_i8, 0_i8, 1_i8, Int8::MAX]),
    CrystalClick::WideTupleLeafColumn.new("i16", [Int16::MIN, -1_i16, 0_i16, 1_i16, Int16::MAX]),
    CrystalClick::WideTupleLeafColumn.new("i32", [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX]),
    CrystalClick::WideTupleLeafColumn.new("i64", [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]),
    CrystalClick::WideTupleLeafColumn.new("i128", [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX]),
    CrystalClick::WideTupleLeafColumn.new("i256", [
      CrystalClick::Int256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX),
      CrystalClick::Int256Value.new(0_u128, 0_u128),
      CrystalClick::Int256Value.new(1_u128, 0_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
    ] of CrystalClick::Int256Value),
    CrystalClick::WideTupleLeafColumn.new("u8", [0_u8, 1_u8, 0x80_u8, 0xfe_u8, UInt8::MAX]),
    CrystalClick::WideTupleLeafColumn.new("u16", [0_u16, 1_u16, 0x8000_u16, 0xfffe_u16, UInt16::MAX]),
    CrystalClick::WideTupleLeafColumn.new("u32", [0_u32, 1_u32, 0x8000_0000_u32, 0xffff_fffe_u32, UInt32::MAX]),
    CrystalClick::WideTupleLeafColumn.new("u64", [0_u64, 1_u64, 0x8000_0000_0000_0000_u64, UInt64::MAX - 1_u64, UInt64::MAX]),
    CrystalClick::WideTupleLeafColumn.new("u128", [0_u128, 1_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128, UInt128::MAX - 1_u128, UInt128::MAX]),
    CrystalClick::WideTupleLeafColumn.new("u256", [
      CrystalClick::UInt256Value.new(0_u128, 0_u128),
      CrystalClick::UInt256Value.new(1_u128, 0_u128),
      CrystalClick::UInt256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
      CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX - 1_u128),
      CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
    ] of CrystalClick::UInt256Value),
    CrystalClick::WideTupleLeafColumn.new("f32", [
      0x0000_0000_u32.unsafe_as(Float32),
      0x8000_0000_u32.unsafe_as(Float32),
      0x3fa0_0000_u32.unsafe_as(Float32),
      0x7f80_0000_u32.unsafe_as(Float32),
      0x7fc1_2345_u32.unsafe_as(Float32),
    ] of Float32),
    CrystalClick::WideTupleLeafColumn.new("f64", [
      0x0000_0000_0000_0000_u64.unsafe_as(Float64),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64),
      0x3ff4_0000_0000_0000_u64.unsafe_as(Float64),
      0x7ff0_0000_0000_0000_u64.unsafe_as(Float64),
      0x7ff8_0000_0001_2345_u64.unsafe_as(Float64),
    ] of Float64),
    CrystalClick::WideTupleLeafColumn.new("bf", [
      CrystalClick::BFloat16Value.new(0x0000_u16),
      CrystalClick::BFloat16Value.new(0x8000_u16),
      CrystalClick::BFloat16Value.new(0x3fa0_u16),
      CrystalClick::BFloat16Value.new(0x7f80_u16),
      CrystalClick::BFloat16Value.new(0x7fc1_u16),
    ] of CrystalClick::BFloat16Value),
    CrystalClick::WideTupleLeafColumn.new("text", [
      "",
      String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]),
      "é",
      String.new(Bytes[0xff_u8, 0x00_u8]),
      "tail",
    ] of String),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w96_consumer_type_name(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w96_consumer_part(parent : String, keys : Array(UInt64), columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  destination = File.join(parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w96_consumer_type_name(columns),
    columns,
    rows_per_mark: 2
  )
end

private def w96_consumer_catalog(root : String, keys : Array(UInt64), columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  metadata_path = File.join(root, "metadata")
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(File.join(root, "store"))

  database_uuid = "96000000-0000-4000-8000-000000000001"
  table_uuid = "96000000-0000-4000-8000-000000000002"
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{w96_consumer_type_name(columns)}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  part = File.join(table_path, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    w96_consumer_type_name(columns),
    columns,
    rows_per_mark: 2
  )
  part
end

private def w96_consumer_assert_row(row : CrystalClick::WideTupleRow, index : Int) : Nil
  row.value_as("i8", Int8).should eq([Int8::MIN, -1_i8, 0_i8, 1_i8, Int8::MAX][index])
  row.value_as("i16", Int16).should eq([Int16::MIN, -1_i16, 0_i16, 1_i16, Int16::MAX][index])
  row.value_as("i32", Int32).should eq([Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX][index])
  row.value_as("i64", Int64).should eq([Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX][index])
  row.value_as("i128", Int128).should eq([Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX][index])

  signed256 = row.value_as("i256", CrystalClick::Int256Value)
  expected_signed256 = [
    CrystalClick::Int256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
    CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX),
    CrystalClick::Int256Value.new(0_u128, 0_u128),
    CrystalClick::Int256Value.new(1_u128, 0_u128),
    CrystalClick::Int256Value.new(UInt128::MAX, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
  ][index]
  {signed256.low, signed256.high}.should eq({expected_signed256.low, expected_signed256.high})

  row.value_as("u8", UInt8).should eq([0_u8, 1_u8, 0x80_u8, 0xfe_u8, UInt8::MAX][index])
  row.value_as("u16", UInt16).should eq([0_u16, 1_u16, 0x8000_u16, 0xfffe_u16, UInt16::MAX][index])
  row.value_as("u32", UInt32).should eq([0_u32, 1_u32, 0x8000_0000_u32, 0xffff_fffe_u32, UInt32::MAX][index])
  row.value_as("u64", UInt64).should eq([0_u64, 1_u64, 0x8000_0000_0000_0000_u64, UInt64::MAX - 1_u64, UInt64::MAX][index])
  row.value_as("u128", UInt128).should eq([0_u128, 1_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128, UInt128::MAX - 1_u128, UInt128::MAX][index])

  unsigned256 = row.value_as("u256", CrystalClick::UInt256Value)
  expected_unsigned256 = [
    CrystalClick::UInt256Value.new(0_u128, 0_u128),
    CrystalClick::UInt256Value.new(1_u128, 0_u128),
    CrystalClick::UInt256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
    CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX - 1_u128),
    CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
  ][index]
  {unsigned256.low, unsigned256.high}.should eq({expected_unsigned256.low, expected_unsigned256.high})

  row.value_as("f32", Float32).unsafe_as(UInt32).should eq([0x0000_0000_u32, 0x8000_0000_u32, 0x3fa0_0000_u32, 0x7f80_0000_u32, 0x7fc1_2345_u32][index])
  row.value_as("f64", Float64).unsafe_as(UInt64).should eq([0x0000_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64, 0x3ff4_0000_0000_0000_u64, 0x7ff0_0000_0000_0000_u64, 0x7ff8_0000_0001_2345_u64][index])
  row.value_as("bf", CrystalClick::BFloat16Value).bits.should eq([0x0000_u16, 0x8000_u16, 0x3fa0_u16, 0x7f80_u16, 0x7fc1_u16][index])
  row.value_as("text", String).should eq(["", String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]), "é", String.new(Bytes[0xff_u8, 0x00_u8]), "tail"][index])
  nil
end

describe "W96 numeric Tuple table and catalog consumers" do
  it "keeps all 15 numeric identities across full, window, sparse, and catalog reads" do
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    columns = w96_consumer_columns
    parent = File.tempname("crystal-click-w96-consumers")
    Dir.mkdir(parent)
    begin
      part = w96_consumer_part(parent, keys, columns)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

      full_indices = [] of Int32
      table.scan_typed do |batch|
        rows = batch.tuple_rows_for("payload")
        batch_keys = batch.values_for("pk")
        rows.each_with_index do |row, offset|
          index = (batch_keys[offset] // 10_u64 - 1_u64).to_i
          w96_consumer_assert_row(row, index)
          full_indices << index.to_i32
        end
        nil
      end
      full_indices.should eq([0, 1, 2, 3, 4])

      window_indices = [] of Int32
      table.scan_typed_window(1_u64, 3) do |batch|
        batch_keys = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, offset|
          index = (batch_keys[offset] // 10_u64 - 1_u64).to_i
          w96_consumer_assert_row(row, index)
          window_indices << index.to_i32
        end
        nil
      end
      window_indices.should eq([1, 2, 3])

      sparse_indices = [] of Int32
      table.scan_typed_candidate_marks([[0_i32, 2_i32]]) do |batch|
        batch_keys = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, offset|
          index = (batch_keys[offset] // 10_u64 - 1_u64).to_i
          w96_consumer_assert_row(row, index)
          sparse_indices << index.to_i32
        end
        nil
      end
      sparse_indices.should eq([0, 1, 4])

      catalog_root = File.tempname("crystal-click-w96-catalog")
      Dir.mkdir(catalog_root)
      begin
        catalog_part = w96_consumer_catalog(catalog_root, keys, columns)
        catalog_part.should_not be_empty
        selection = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]["payload"]
        values = selection.values(max_tuple_cells: 80_u64)
        values.size.should eq(keys.size)
        values.each_with_index do |value, index|
          row = value.as(CrystalClick::WideTupleRow)
          w96_consumer_assert_row(row, index)
        end
      ensure
        FileUtils.rm_rf(catalog_root)
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.tuples_for("payload")
          nil
        end
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.tuple_rows_for("payload")[0].value_as("u8", Int8)
          nil
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
