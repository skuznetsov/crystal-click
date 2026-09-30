require "./spec_helper"
require "file_utils"

private def w102c_u64(value : UInt64) : String
  output = IO::Memory.new
  8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

private def w102c_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w102c_signed(value : Int128, width : Int32) : String
  bits = value.unsafe_as(UInt128)
  output = IO::Memory.new
  width.times { |index| output.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
  output.to_s
end

private def w102c_raw(value : Int32) : String
  w102c_signed(value.to_i128, 4)
end

private def w102c_raw(value : Int64) : String
  w102c_signed(value.to_i128, 8)
end

private def w102c_raw(value : Int128) : String
  w102c_signed(value, 16)
end

private def w102c_raw(value : CrystalClick::Decimal256Value) : String
  bits = IO::Memory.new
  16.times { |index| bits.write_byte(((value.low >> (index * 8)) & 0xff_u128).to_u8) }
  16.times { |index| bits.write_byte(((value.high >> (index * 8)) & 0xff_u128).to_u8) }
  bits.to_s
end

private def w102c_nullable(raw : String?) : String
  if value = raw
    "\0" + value
  else
    "\1"
  end
end

private def w102c_array(values : Array(String)) : String
  output = IO::Memory.new
  w102c_varuint(output, values.size.to_u64)
  values.each { |value| output << value }
  output.to_s
end

private def w102c_nested(values : Array(Array(String))) : String
  output = IO::Memory.new
  w102c_varuint(output, values.size.to_u64)
  values.each { |inner| output << w102c_array(inner) }
  output.to_s
end

private def w102c_expected(keys : Array(UInt64), payloads : Array(String), indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    output << w102c_u64(keys[index])
    output << payloads[index]
  end
  output.to_s
end

private def w102c_append(io : IO, value : Int32) : Nil
  io << w102c_raw(value)
end

private def w102c_append(io : IO, value : Int64) : Nil
  io << w102c_raw(value)
end

private def w102c_append(io : IO, value : Int128) : Nil
  io << w102c_raw(value)
end

private def w102c_append(io : IO, value : CrystalClick::Decimal256Value) : Nil
  io << w102c_raw(value)
end

private def w102c_append_nullable(io : IO, value : T?) : Nil forall T
  if item = value
    io.write_byte(0_u8)
    w102c_append(io, item)
  else
    io.write_byte(1_u8)
  end
end

private def w102c_append(io : IO, values : Array(T)) : Nil forall T
  w102c_varuint(io, values.size.to_u64)
  values.each { |value| w102c_append(io, value) }
end

private def w102c_append_schema(io : IO, value : Int32, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102c_append(io, value)
end

private def w102c_append_schema(io : IO, value : Int64, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102c_append(io, value)
end

private def w102c_append_schema(io : IO, value : Int128, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102c_append(io, value)
end

private def w102c_append_schema(io : IO, value : CrystalClick::Decimal256Value, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102c_append(io, value)
end

private def w102c_append_schema(io : IO, value : Nil, nullable : Bool) : Nil
  raise "Nil leaf is not admitted by the declared Decimal schema" unless nullable
  io.write_byte(1_u8)
end

private def w102c_append_schema(io : IO, value : Int64?, nullable : Bool) : Nil
  if item = value
    w102c_append_schema(io, item, nullable)
  else
    w102c_append_schema(io, nil.as(Nil), nullable)
  end
end

private def w102c_append_schema(io : IO, value : CrystalClick::Decimal256Value?, nullable : Bool) : Nil
  if item = value
    w102c_append_schema(io, item, nullable)
  else
    w102c_append_schema(io, nil.as(Nil), nullable)
  end
end

private def w102c_append_schema(io : IO, values : Array(T), nullable : Bool) : Nil forall T
  w102c_varuint(io, values.size.to_u64)
  values.each { |value| w102c_append_schema(io, value, nullable) }
end

private def w102c_append_nullable_array(io : IO, values : Array(T?)) : Nil forall T
  w102c_varuint(io, values.size.to_u64)
  values.each { |value| w102c_append_nullable(io, value) }
end

private def w102c_append_nested_nullable_array(io : IO, values : Array(Array(T?))) : Nil forall T
  w102c_varuint(io, values.size.to_u64)
  values.each { |inner| w102c_append_nullable_array(io, inner) }
end

private def w102c_append_typed(io : IO, value : T, width : Int32, shape : Int32) : Nil forall T
  nullable = case {width, shape}
             when {4, 0}, {16, 2}, {4, 4} then false
             when {8, 1}, {32, 3}, {8, 5} then true
             else                              raise "unsupported W102 typed consumer profile #{width}/#{shape}"
             end
  w102c_append_schema(io, value, nullable)
end

private def w102c_append_keyed(io : IO, keys : Slice(UInt64), values : Slice(T), width : Int32, shape : Int32) : Nil forall T
  raise "W102 consumer key/value length differs" unless keys.size == values.size
  keys.each_with_index do |key, index|
    io << w102c_u64(key)
    w102c_append_typed(io, values[index], width, shape)
  end
end

private def w102c_append_batch(io : IO, batch : CrystalClick::WidePartTableBatch, width : Int32, shape : Int32) : Nil
  keys = batch.values_for("pk")
  case {width, shape}
  when {4, 0}  then w102c_append_keyed(io, keys, batch.decimal32_raw_for("payload"), width, shape)
  when {8, 1}  then w102c_append_keyed(io, keys, batch.nullable_decimal64_raw_for("payload"), width, shape)
  when {16, 2} then w102c_append_keyed(io, keys, batch.array_decimal128_raw_for("payload"), width, shape)
  when {32, 3} then w102c_append_keyed(io, keys, batch.array_nullable_decimal256_raw_for("payload"), width, shape)
  when {4, 4}  then w102c_append_keyed(io, keys, batch.array_array_decimal32_raw_for("payload"), width, shape)
  when {8, 5}  then w102c_append_keyed(io, keys, batch.array_array_nullable_decimal64_raw_for("payload"), width, shape)
  else              raise "unsupported W102 consumer profile #{width}/#{shape}"
  end
  nil
end

private def w102c_append_catalog(io : IO, value : CrystalClick::OfflineColumnValue, width : Int32, shape : Int32) : Nil
  case {width, shape}
  when {4, 0}  then w102c_append(io, value.as(Int32))
  when {8, 1}  then w102c_append_nullable(io, value.as(Int64?))
  when {16, 2} then w102c_append(io, value.as(Array(Int128)))
  when {32, 3} then w102c_append_nullable_array(io, value.as(Array(CrystalClick::Decimal256Value?)))
  when {4, 4}  then w102c_append(io, value.as(Array(Array(Int32))))
  when {8, 5}  then w102c_append_nested_nullable_array(io, value.as(Array(Array(Int64?))))
  else              raise "unsupported W102 catalog profile #{width}/#{shape}"
  end
  nil
end

private def w102c_catalog_root(root : String, part : String, declared_type : String) : String
  database_uuid = "102c0000-0000-4000-8000-000000000001"
  table_uuid = "102c0000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{declared_type}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  copied = File.join(table, "all_1_1_0")
  FileUtils.cp_r(part, copied)
  copied
end

private def w102c_assert_consumers(
  parent : String,
  label : String,
  part : String,
  type_name : String,
  catalog_type : String,
  width : Int32,
  shape : Int32,
  payloads : Array(String),
  keys : Array(UInt64),
) : Nil
  descriptor = CrystalClick::DecimalColumnType.parse(type_name).not_nil!
  descriptor.type_name.should eq(type_name)
  descriptor.storage_width.should eq(width)
  CrystalClick::DecimalColumnType.catalog_type(catalog_type).should eq(type_name)

  reader = CrystalClick::WidePart.open_typed(part, "payload")
  reader.column_type.should eq(type_name)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  table.total_row_count.should eq(keys.size.to_u64)
  full = IO::Memory.new
  table.scan_typed(batch_rows: 2) { |batch| w102c_append_batch(full, batch, width, shape) }
  full.to_s.should eq(w102c_expected(keys, payloads, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]))

  window = IO::Memory.new
  table.scan_typed_window(1_u64, 3) { |batch| w102c_append_batch(window, batch, width, shape) }
  window.to_s.should eq(w102c_expected(keys, payloads, [1_i32, 2_i32, 3_i32]))

  selected = IO::Memory.new
  table.scan_typed_candidate_marks([[1_i32, 2_i32]]) { |batch| w102c_append_batch(selected, batch, width, shape) }
  selected.to_s.should eq(w102c_expected(keys, payloads, [2_i32, 3_i32, 4_i32]))

  catalog_root = File.join(parent, "catalog_#{label}")
  copied = w102c_catalog_root(catalog_root, part, catalog_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  resolved = offline.resolved_scan_parts
  resolved.size.should eq(1)
  File.realpath(resolved[0].path).should eq(File.realpath(copied))

  catalog_full = IO::Memory.new
  offline.scan_typed(["pk", "payload"], batch_rows: 2) { |batch| w102c_append_batch(catalog_full, batch, width, shape) }
  catalog_full.to_s.should eq(w102c_expected(keys, payloads, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]))

  catalog_window = IO::Memory.new
  offline.scan_typed_window(["pk", "payload"], 1_u64, 3) { |batch| w102c_append_batch(catalog_window, batch, width, shape) }
  catalog_window.to_s.should eq(w102c_expected(keys, payloads, [1_i32, 2_i32, 3_i32]))

  values = offline["payload"].values(max_tuple_cells: 100_u64)
  values.size.should eq(keys.size)
  materialized = IO::Memory.new
  values.each { |value| w102c_append_catalog(materialized, value, width, shape) }
  payloads.join.should eq(materialized.to_s)

  candidate_keys = [] of UInt64
  offline.scan_uint64_pk_candidates(["pk"], 3_u64, 5_u64) do |batch|
    candidate_keys.concat(batch.values_for("pk"))
    nil
  end
  candidate_keys.should eq(keys)
  candidate_keys.select { |key| key >= 3_u64 && key <= 5_u64 }.should eq([3_u64, 4_u64, 5_u64])
  nil
end

describe "Decimal(P, S) table and catalog consumers" do
  it "preserves exact declarations and values across all six shapes and four carriers" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    key_slice = keys.to_unsafe.to_slice(keys.size)
    parent = File.tempname("crystal-click-w102-decimal-consumers")
    Dir.mkdir(parent)
    begin
      # Scalar P=9 is deliberately catalog-declared with its max-P alias.
      scalar32 = [-123_456_789_i32, -1_i32, 0_i32, 1_i32, 123_456_789_i32]
      part = File.join(parent, "scalar32", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(part, "pk", key_slice, "payload", scalar32.to_unsafe.to_slice(5), 3, 2, precision: 9)
      scalar_payloads = scalar32.map { |value| w102c_raw(value) }
      w102c_assert_consumers(parent, "scalar32", part, "Decimal(9, 3)", "Decimal32(3)", 4, 0, scalar_payloads, keys)

      nullable64 = [nil.as(Int64?), -12_i64.as(Int64?), 0_i64.as(Int64?), 345_i64.as(Int64?), nil.as(Int64?)]
      part = File.join(parent, "nullable64", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(part, "pk", key_slice, "payload", nullable64.to_unsafe.to_slice(5), 7, 2, precision: 15)
      nullable_payloads = nullable64.map { |value| w102c_nullable(value.try { |item| w102c_raw(item) }) }
      w102c_assert_consumers(parent, "nullable64", part, "Nullable(Decimal(15, 7))", "Nullable(Decimal(15, 7))", 8, 1, nullable_payloads, keys)

      array128 = [[] of Int128, [-2_i128, 0_i128], [1_i128], [7_i128, -10_i128], [] of Int128]
      part = File.join(parent, "array128", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(part, "pk", key_slice, "payload", array128.to_unsafe.to_slice(5), 0, 2, precision: 25)
      array_payloads = array128.map { |row| w102c_array(row.map { |value| w102c_raw(value) }) }
      w102c_assert_consumers(parent, "array128", part, "Array(Decimal(25, 0))", "Array(Decimal(25))", 16, 2, array_payloads, keys)

      make256 = ->(value : Int128) { CrystalClick::Decimal256Value.from_int128(value) }
      array_nullable256 = [
        [nil.as(CrystalClick::Decimal256Value?)], [] of CrystalClick::Decimal256Value?,
        [make256.call(-3_i128).as(CrystalClick::Decimal256Value?), nil.as(CrystalClick::Decimal256Value?)],
        [make256.call(5_i128).as(CrystalClick::Decimal256Value?), make256.call(0_i128).as(CrystalClick::Decimal256Value?)],
        [nil.as(CrystalClick::Decimal256Value?)],
      ]
      part = File.join(parent, "array_nullable256", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(part, "pk", key_slice, "payload", array_nullable256.to_unsafe.to_slice(5), 25, 2, precision: 50)
      array_nullable_payloads = array_nullable256.map do |row|
        w102c_array(row.map { |value| w102c_nullable(value.try { |item| w102c_raw(item) }) })
      end
      w102c_assert_consumers(parent, "array_nullable256", part, "Array(Nullable(Decimal(50, 25)))", "Array(Nullable(Decimal(50, 25)))", 32, 3, array_nullable_payloads, keys)

      array_array32 = [
        [] of Array(Int32), [[] of Int32], [[-9_i32], [0_i32, 9_i32]], [[1_i32]], [] of Array(Int32),
      ]
      part = File.join(parent, "array_array32", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", key_slice, "payload", array_array32.to_unsafe.to_slice(5), 1, 2, precision: 1)
      nested_payloads = array_array32.map { |row| w102c_nested(row.map { |inner| inner.map { |value| w102c_raw(value) } }) }
      w102c_assert_consumers(parent, "array_array32", part, "Array(Array(Decimal(1, 1)))", "Array(Array(Decimal(1, 1)))", 4, 4, nested_payloads, keys)

      nested_nullable64 = [
        [] of Array(Int64?), [[] of Int64?], [[nil.as(Int64?), 0_i64.as(Int64?)], [-1_i64.as(Int64?)]],
        [[10_i64.as(Int64?)], [] of Int64?],
        [[] of Int64?, [nil.as(Int64?)]],
      ]
      part = File.join(parent, "nested_nullable64", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(part))
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(part, "pk", key_slice, "payload", nested_nullable64.to_unsafe.to_slice(5), 5, 2, precision: 10)
      nested_nullable_payloads = nested_nullable64.map do |row|
        w102c_nested(row.map { |inner| inner.map { |value| w102c_nullable(value.try { |item| w102c_raw(item) }) } })
      end
      w102c_assert_consumers(parent, "nested_nullable64", part, "Array(Array(Nullable(Decimal(10, 5))))", "Array(Array(Nullable(Decimal(10, 5))))", 8, 5, nested_nullable_payloads, keys)
    ensure
      FileUtils.rm_rf(parent) if Dir.exists?(parent)
    end
  end

  it "distinguishes same-carrier precision identity without collapsing legal schemas" do
    source = CrystalClick::DecimalColumnType.parse("Array(Decimal(15, 7))").not_nil!
    same_width = CrystalClick::DecimalColumnType.parse("Array(Decimal(18, 7))").not_nil!
    source.storage_width.should eq(same_width.storage_width)
    source.should_not eq(same_width)
    CrystalClick::DecimalColumnType.parse("Array(Decimal(18, 7))").not_nil!.type_name.should eq("Array(Decimal(18, 7))")
    CrystalClick::DecimalColumnType.parse("Array(Decimal(15, 7) trailing)").should be_nil
  end
end
