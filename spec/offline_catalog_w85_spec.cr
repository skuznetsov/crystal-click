require "./spec_helper"
require "file_utils"

private def w85_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w85_catalog_create_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  type : String,
) : String
  File.write(
    File.join(database_path, "#{name}.sql"),
    "ATTACH TABLE _ UUID '#{uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
  )
  table_path = w85_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  File.join(table_path, "all_1_1_0")
end

private def w85_catalog_write_numeric(
  destination : String,
  keys : Slice(UInt64),
  rows : Slice(Array(Array(Tuple(K, Array(T))))),
) : Nil forall K, T
  {% if K == UInt64 %}
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_numeric_pair(
      destination, "pk", keys, "payload", rows, rows_per_mark: 2
    )
  {% elsif K == String %}
    CrystalClick::WidePartWriter.write_uint64_array_map_string_array_numeric_pair(
      destination, "pk", keys, "payload", rows, rows_per_mark: 2
    )
  {% end %}
  nil
end

private def w85_catalog_add_numeric(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  type : String,
  keys : Slice(UInt64),
  rows : Slice(Array(Array(Tuple(K, Array(T))))),
) : Nil forall K, T
  part = w85_catalog_create_table(root, database_path, name, uuid, type)
  w85_catalog_write_numeric(part, keys, rows)
end

private def w85_catalog_rows(key_a : K, key_b : K, low : T, high : T) : Array(Array(Array(Tuple(K, Array(T))))) forall K, T
  empty_map = [] of Tuple(K, Array(T))
  entries = [{key_a, [] of T}, {key_a, [low, high]}, {key_b, [] of T}] of Tuple(K, Array(T))
  [
    [] of Array(Tuple(K, Array(T))),
    [empty_map] of Array(Tuple(K, Array(T))),
    [entries] of Array(Tuple(K, Array(T))),
  ] of Array(Array(Tuple(K, Array(T))))
end

private def w85_catalog_assert_numeric(
  catalog : CrystalClick::OfflineCatalog,
  table : String,
  expected : Array(Array(Array(Tuple(K, Array(T))))),
) : Nil forall K, T
  catalog["lab"][table]["payload"].values.map do |value|
    value.as(Array(Array(Tuple(K, Array(T)))))
  end.should eq(expected)
end

describe CrystalClick::OfflineCatalog do
  it "materializes nested arrays of every primitive numeric category through catalog selections" do
    root = File.tempname("crystal-click-offline-catalog-w85")
    Dir.mkdir(root)
    FileUtils.mkdir_p(File.join(root, "store"))
    FileUtils.mkdir_p(File.join(root, "metadata"))
    database_uuid = "a85d87f2-9c63-4e15-863a-1c7610ae4d28"
    database_path = w85_catalog_store_path(root, database_uuid)
    FileUtils.mkdir_p(database_path)
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    keys = [0_u64, 1_u64, 2_u64]
    binary_key = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])

    begin
      w85_catalog_add_numeric(root, database_path, "u64_u8", "b85d87f2-9c63-4e15-863a-1c7610ae4d01", "Array(Map(UInt64, Array(UInt8)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, 0_u8, UInt8::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_u16", "b85d87f2-9c63-4e15-863a-1c7610ae4d02", "Array(Map(UInt64, Array(UInt16)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, 0_u16, UInt16::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_u32", "b85d87f2-9c63-4e15-863a-1c7610ae4d03", "Array(Map(UInt64, Array(UInt32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, 0_u32, UInt32::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_u64", "b85d87f2-9c63-4e15-863a-1c7610ae4d04", "Array(Map(UInt64, Array(UInt64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, 0_u64, UInt64::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_i8", "b85d87f2-9c63-4e15-863a-1c7610ae4d05", "Array(Map(UInt64, Array(Int8)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, Int8::MIN, Int8::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_i16", "b85d87f2-9c63-4e15-863a-1c7610ae4d06", "Array(Map(UInt64, Array(Int16)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, Int16::MIN, Int16::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_i32", "b85d87f2-9c63-4e15-863a-1c7610ae4d07", "Array(Map(UInt64, Array(Int32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, Int32::MIN, Int32::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_i64", "b85d87f2-9c63-4e15-863a-1c7610ae4d08", "Array(Map(UInt64, Array(Int64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, Int64::MIN, Int64::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_f32", "b85d87f2-9c63-4e15-863a-1c7610ae4d09", "Array(Map(UInt64, Array(Float32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, -0.0_f32, 3.5_f32).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "u64_f64", "b85d87f2-9c63-4e15-863a-1c7610ae4d10", "Array(Map(UInt64, Array(Float64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows(1_u64, 2_u64, -1.25_f64, 3.5_f64).to_unsafe.to_slice(3))

      w85_catalog_add_numeric(root, database_path, "string_u8", "b85d87f2-9c63-4e15-863a-1c7610ae4d11", "Array(Map(String, Array(UInt8)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, 0_u8, UInt8::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_u16", "b85d87f2-9c63-4e15-863a-1c7610ae4d12", "Array(Map(String, Array(UInt16)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, 0_u16, UInt16::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_u32", "b85d87f2-9c63-4e15-863a-1c7610ae4d13", "Array(Map(String, Array(UInt32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, 0_u32, UInt32::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_u64", "b85d87f2-9c63-4e15-863a-1c7610ae4d14", "Array(Map(String, Array(UInt64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, 0_u64, UInt64::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_i8", "b85d87f2-9c63-4e15-863a-1c7610ae4d15", "Array(Map(String, Array(Int8)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, Int8::MIN, Int8::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_i16", "b85d87f2-9c63-4e15-863a-1c7610ae4d16", "Array(Map(String, Array(Int16)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, Int16::MIN, Int16::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_i32", "b85d87f2-9c63-4e15-863a-1c7610ae4d17", "Array(Map(String, Array(Int32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, Int32::MIN, Int32::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_i64", "b85d87f2-9c63-4e15-863a-1c7610ae4d18", "Array(Map(String, Array(Int64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, Int64::MIN, Int64::MAX).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_f32", "b85d87f2-9c63-4e15-863a-1c7610ae4d19", "Array(Map(String, Array(Float32)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("dup", binary_key, -1.25_f32, 3.5_f32).to_unsafe.to_slice(3))
      w85_catalog_add_numeric(root, database_path, "string_f64", "b85d87f2-9c63-4e15-863a-1c7610ae4d20", "Array(Map(String, Array(Float64)))", keys.to_unsafe.to_slice(keys.size), w85_catalog_rows("x", "y", -0.0_f64, 3.5_f64).to_unsafe.to_slice(3))

      catalog = CrystalClick::OfflineCatalog.open(root)
      w85_catalog_assert_numeric(catalog, "u64_u8", w85_catalog_rows(1_u64, 2_u64, 0_u8, UInt8::MAX))
      w85_catalog_assert_numeric(catalog, "u64_u16", w85_catalog_rows(1_u64, 2_u64, 0_u16, UInt16::MAX))
      w85_catalog_assert_numeric(catalog, "u64_u32", w85_catalog_rows(1_u64, 2_u64, 0_u32, UInt32::MAX))
      w85_catalog_assert_numeric(catalog, "u64_u64", w85_catalog_rows(1_u64, 2_u64, 0_u64, UInt64::MAX))
      w85_catalog_assert_numeric(catalog, "u64_i8", w85_catalog_rows(1_u64, 2_u64, Int8::MIN, Int8::MAX))
      w85_catalog_assert_numeric(catalog, "u64_i16", w85_catalog_rows(1_u64, 2_u64, Int16::MIN, Int16::MAX))
      w85_catalog_assert_numeric(catalog, "u64_i32", w85_catalog_rows(1_u64, 2_u64, Int32::MIN, Int32::MAX))
      w85_catalog_assert_numeric(catalog, "u64_i64", w85_catalog_rows(1_u64, 2_u64, Int64::MIN, Int64::MAX))
      w85_catalog_assert_numeric(catalog, "u64_f32", w85_catalog_rows(1_u64, 2_u64, -0.0_f32, 3.5_f32))
      w85_catalog_assert_numeric(catalog, "u64_f64", w85_catalog_rows(1_u64, 2_u64, -1.25_f64, 3.5_f64))
      w85_catalog_assert_numeric(catalog, "string_u8", w85_catalog_rows("dup", binary_key, 0_u8, UInt8::MAX))
      w85_catalog_assert_numeric(catalog, "string_u16", w85_catalog_rows("dup", binary_key, 0_u16, UInt16::MAX))
      w85_catalog_assert_numeric(catalog, "string_u32", w85_catalog_rows("dup", binary_key, 0_u32, UInt32::MAX))
      w85_catalog_assert_numeric(catalog, "string_u64", w85_catalog_rows("dup", binary_key, 0_u64, UInt64::MAX))
      w85_catalog_assert_numeric(catalog, "string_i8", w85_catalog_rows("dup", binary_key, Int8::MIN, Int8::MAX))
      w85_catalog_assert_numeric(catalog, "string_i16", w85_catalog_rows("dup", binary_key, Int16::MIN, Int16::MAX))
      w85_catalog_assert_numeric(catalog, "string_i32", w85_catalog_rows("dup", binary_key, Int32::MIN, Int32::MAX))
      w85_catalog_assert_numeric(catalog, "string_i64", w85_catalog_rows("dup", binary_key, Int64::MIN, Int64::MAX))
      w85_catalog_assert_numeric(catalog, "string_f32", w85_catalog_rows("dup", binary_key, -1.25_f32, 3.5_f32))
      w85_catalog_assert_numeric(catalog, "string_f64", w85_catalog_rows("x", "y", -0.0_f64, 3.5_f64))
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
