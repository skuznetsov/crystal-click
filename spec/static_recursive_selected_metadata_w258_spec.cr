require "./spec_helper"
require "file_utils"
require "../scripts/support/static_recursive_selected_metadata_w258_fixture"

W258_EXPECTED_KEYS   = [1001_u64, 1002_u64, 1003_u64, 1004_u64, 1005_u64, 1006_u64, 1007_u64, 1008_u64]
W258_EXPECTED_U      = [2001_u64, 2002_u64, 2003_u64, 2004_u64, 2005_u64, 2006_u64, 2007_u64, 2008_u64]
W258_EXPECTED_SIDE   = ["side-0", "side-1", "side-2", "side-3", "side-4", "side-5", "side-6", "side-7"]
W258_EXPECTED_ARRAYS = [
  [] of UInt64?,
  [] of UInt64?,
  [nil, 17_u64] of UInt64?,
  [23_u64] of UInt64?,
  [0_u64, nil] of UInt64?,
  [] of UInt64?,
  [7_u64, 8_u64, nil] of UInt64?,
  [nil, 9_u64] of UInt64?,
] of Array(UInt64?)
W258_EXPECTED_TUPLES = [
  {3001_u64, "tuple-0"},
  {3002_u64, "tuple-1"},
  {3003_u64, "tuple-2"},
  {3004_u64, "tuple-3"},
  {3005_u64, "tuple-4"},
  {3006_u64, "tuple-5"},
  {3007_u64, "tuple-6"},
  {3008_u64, "tuple-7"},
] of Tuple(UInt64, String)
W258_EXPECTED_LOW_CARDINALITY = ["dup", "red", "dup", "", "blue", "dup", "blue", "tail"]
W258_EXPECTED_VARIANTS        = [
  "variant-0",
  4002_u64,
  nil,
  "variant-3",
  4005_u64,
  "variant-5",
  4007_u64,
  nil,
] of CrystalClick::VariantStringUInt64Value

private def w258_with_part(& : String ->)
  parent = File.tempname("crystal-click-w258-selected-metadata-")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    StaticRecursiveSelectedMetadataW258Fixture.write_part(part).should eq(part)
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w258_offline_table(path : String) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, 8_u64)
  columns = [
    CrystalClick::OfflineColumn.new("pk", "UInt64"),
    CrystalClick::OfflineColumn.new("u", "UInt64"),
    CrystalClick::OfflineColumn.new("side", "String"),
    CrystalClick::OfflineColumn.new("arr", "Array(Nullable(UInt64))"),
    CrystalClick::OfflineColumn.new("tup", "Tuple(n UInt64, s String)"),
    CrystalClick::OfflineColumn.new("lc", "LowCardinality(String)"),
    CrystalClick::OfflineColumn.new("v", "Variant(String, UInt64)"),
  ] of CrystalClick::OfflineColumn
  CrystalClick::OfflineTable.new(
    "events",
    "w258-static-recursive-metadata",
    "MergeTree",
    columns,
    [candidate] of CrystalClick::OfflinePartCandidate,
    "pk",
  )
end

private def w258_assert_controls(
  observed_keys : Array(UInt64),
  observed_u : Array(UInt64),
  observed_side : Array(String),
  expected_keys : Array(UInt64),
  expected_u : Array(UInt64),
  expected_side : Array(String),
) : Nil
  observed_keys.should eq(expected_keys)
  observed_u.should eq(expected_u)
  observed_side.should eq(expected_side)
  nil
end

describe "W258 selected recursive metadata admission" do
  it "retains the ordinary sparse WITH_TYPES profile and independently reads the key/control columns" do
    w258_with_part do |part|
      File.read(File.join(part, "columns.txt")).should eq(
        "columns format version: 1\n7 columns:\n" +
        "`pk` UInt64\n`u` UInt64\n`side` String\n`arr` Array(Nullable(UInt64))\n" +
        "`tup` Tuple(n UInt64, s String)\n`lc` LowCardinality(String)\n`v` Variant(String, UInt64)\n"
      )

      serialization = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
      serialization.keys.sort.should eq([
        "columns",
        "propagate_types_serialization_versions_to_nested_types",
        "types_serialization_versions",
        "version",
      ])
      serialization["version"].as_i.should eq(1)
      serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization["types_serialization_versions"].as_h.keys.should eq(["string"])
      serialization["types_serialization_versions"].as_h["string"].as_i.should eq(1)
      serialization["columns"].as_a.should be_empty

      key_reader = CrystalClick::WidePart.open(part, "pk")
      key_reader.row_count.should eq(8_u64)
      key_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      key_reader.read_uint64.should eq(W258_EXPECTED_KEYS)

      selected = ["u", "pk", "side"]
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.column_types.should eq([
        {"u", "UInt64"},
        {"pk", "UInt64"},
        {"side", "String"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])
      table.total_row_count.should eq(8_u64)

      keys = [] of UInt64
      u_values = [] of UInt64
      side_values = [] of String
      table.scan_typed do |batch|
        keys.concat(batch.values_for("pk"))
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS, W258_EXPECTED_U, W258_EXPECTED_SIDE)

      keys.clear
      u_values.clear
      side_values.clear
      table.scan_typed_window(2_u64, 4) do |batch|
        keys.concat(batch.values_for("pk"))
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(
        keys,
        u_values,
        side_values,
        W258_EXPECTED_KEYS[2, 4],
        W258_EXPECTED_U[2, 4],
        W258_EXPECTED_SIDE[2, 4],
      )

      eof_callbacks = 0
      table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    end
  end

  it "reads Array(Nullable(UInt64)) with empty first granule, nulls, and row-aligned controls" do
    w258_with_part do |part|
      selected = ["u", "arr", "side", "pk"]
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.column_types.should eq([
        {"u", "UInt64"},
        {"arr", "Array(Nullable(UInt64))"},
        {"side", "String"},
        {"pk", "UInt64"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

      keys = [] of UInt64
      u_values = [] of UInt64
      side_values = [] of String
      values = [] of Array(UInt64?)
      table.scan_typed do |batch|
        batch_keys = batch.values_for("pk")
        batch_arrays = batch.array_nullable_uint64s_for("arr")
        batch_keys.each_with_index do |key, index|
          expected_index = (key - W258_EXPECTED_KEYS.first).to_i
          batch_arrays[index].should eq(W258_EXPECTED_ARRAYS[expected_index])
          values << batch_arrays[index].dup
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS, W258_EXPECTED_U, W258_EXPECTED_SIDE)
      values.should eq(W258_EXPECTED_ARRAYS)

      keys.clear
      u_values.clear
      side_values.clear
      values.clear
      table.scan_typed_window(2_u64, 4) do |batch|
        batch_keys = batch.values_for("pk")
        batch_arrays = batch.array_nullable_uint64s_for("arr")
        batch_keys.each_with_index do |key, index|
          expected_index = (key - W258_EXPECTED_KEYS.first).to_i
          batch_arrays[index].should eq(W258_EXPECTED_ARRAYS[expected_index])
          values << batch_arrays[index].dup
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS[2, 4], W258_EXPECTED_U[2, 4], W258_EXPECTED_SIDE[2, 4])
      values.should eq(W258_EXPECTED_ARRAYS[2, 4])

      eof_callbacks = 0
      table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    end
  end

  it "reads named Tuple rows without changing caller order or sibling alignment" do
    w258_with_part do |part|
      selected = ["side", "tup", "pk", "u"]
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.column_types.should eq([
        {"side", "String"},
        {"tup", "Tuple(n UInt64, s String)"},
        {"pk", "UInt64"},
        {"u", "UInt64"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

      keys = [] of UInt64
      u_values = [] of UInt64
      side_values = [] of String
      values = [] of Tuple(UInt64, String)
      table.scan_typed do |batch|
        batch_keys = batch.values_for("pk")
        batch.tuple_rows_for("tup").each_with_index do |row, index|
          expected_index = (batch_keys[index] - W258_EXPECTED_KEYS.first).to_i
          row.type_name.should eq("Tuple(n UInt64, s String)")
          tuple = {row.value_as("n", UInt64), row.value_as("s", String)}
          tuple.should eq(W258_EXPECTED_TUPLES[expected_index])
          values << tuple
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS, W258_EXPECTED_U, W258_EXPECTED_SIDE)
      values.should eq(W258_EXPECTED_TUPLES)

      keys.clear
      u_values.clear
      side_values.clear
      values.clear
      table.scan_typed_window(2_u64, 4) do |batch|
        batch_keys = batch.values_for("pk")
        batch.tuple_rows_for("tup").each_with_index do |row, index|
          expected_index = (batch_keys[index] - W258_EXPECTED_KEYS.first).to_i
          values << {row.value_as("n", UInt64), row.value_as("s", String)}
          values.last.should eq(W258_EXPECTED_TUPLES[expected_index])
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS[2, 4], W258_EXPECTED_U[2, 4], W258_EXPECTED_SIDE[2, 4])
      values.should eq(W258_EXPECTED_TUPLES[2, 4])

      eof_callbacks = 0
      table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    end
  end

  it "reads LowCardinality(String) through its established String accessor" do
    w258_with_part do |part|
      selected = ["lc", "u", "pk", "side"]
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.column_types.should eq([
        {"lc", "LowCardinality(String)"},
        {"u", "UInt64"},
        {"pk", "UInt64"},
        {"side", "String"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

      keys = [] of UInt64
      u_values = [] of UInt64
      side_values = [] of String
      values = [] of String
      table.scan_typed do |batch|
        batch_keys = batch.values_for("pk")
        batch_lc = batch.low_cardinality_strings_for("lc")
        batch_keys.each_with_index do |key, index|
          expected_index = (key - W258_EXPECTED_KEYS.first).to_i
          batch_lc[index].should eq(W258_EXPECTED_LOW_CARDINALITY[expected_index])
          values << String.new(batch_lc[index].to_slice)
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS, W258_EXPECTED_U, W258_EXPECTED_SIDE)
      values.should eq(W258_EXPECTED_LOW_CARDINALITY)

      keys.clear
      u_values.clear
      side_values.clear
      values.clear
      table.scan_typed_window(2_u64, 4) do |batch|
        batch_keys = batch.values_for("pk")
        batch.low_cardinality_strings_for("lc").each_with_index do |value, index|
          expected_index = (batch_keys[index] - W258_EXPECTED_KEYS.first).to_i
          values << String.new(value.to_slice)
          values.last.should eq(W258_EXPECTED_LOW_CARDINALITY[expected_index])
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS[2, 4], W258_EXPECTED_U[2, 4], W258_EXPECTED_SIDE[2, 4])
      values.should eq(W258_EXPECTED_LOW_CARDINALITY[2, 4])

      eof_callbacks = 0
      table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    end
  end

  it "reads both Variant arms and NULL through the exact public union accessor" do
    w258_with_part do |part|
      selected = ["pk", "v", "side", "u"]
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.column_types.should eq([
        {"pk", "UInt64"},
        {"v", "Variant(String, UInt64)"},
        {"side", "String"},
        {"u", "UInt64"},
      ])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

      keys = [] of UInt64
      u_values = [] of UInt64
      side_values = [] of String
      values = [] of CrystalClick::VariantStringUInt64Value
      table.scan_typed do |batch|
        batch_keys = batch.values_for("pk")
        batch.variant_string_uint64_for("v").each_with_index do |value, index|
          expected_index = (batch_keys[index] - W258_EXPECTED_KEYS.first).to_i
          value.should eq(W258_EXPECTED_VARIANTS[expected_index])
          values << (case value
          when String then String.new(value.to_slice)
          else             value
          end)
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS, W258_EXPECTED_U, W258_EXPECTED_SIDE)
      values.should eq(W258_EXPECTED_VARIANTS)

      keys.clear
      u_values.clear
      side_values.clear
      values.clear
      table.scan_typed_window(2_u64, 4) do |batch|
        batch_keys = batch.values_for("pk")
        batch.variant_string_uint64_for("v").each_with_index do |value, index|
          expected_index = (batch_keys[index] - W258_EXPECTED_KEYS.first).to_i
          values << (case value
          when String then String.new(value.to_slice)
          else             value
          end)
          values.last.should eq(W258_EXPECTED_VARIANTS[expected_index])
        end
        keys.concat(batch_keys)
        u_values.concat(batch.values_for("u"))
        side_values.concat(batch.strings_for("side").map { |value| String.new(value.to_slice) })
      end
      w258_assert_controls(keys, u_values, side_values, W258_EXPECTED_KEYS[2, 4], W258_EXPECTED_U[2, 4], W258_EXPECTED_SIDE[2, 4])
      values.should eq(W258_EXPECTED_VARIANTS[2, 4])

      eof_callbacks = 0
      table.scan_typed_window(8_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    end
  end

  it "materializes owned nullable Array values through OfflineTable.values" do
    expected = [
      [] of UInt64?,
      [] of UInt64?,
      [nil, 17_u64] of UInt64?,
      [23_u64] of UInt64?,
      [0_u64, nil] of UInt64?,
      [] of UInt64?,
      [7_u64, 8_u64, nil] of UInt64?,
      [nil, 9_u64] of UInt64?,
    ] of Array(UInt64?)
    w258_with_part do |part|
      table = w258_offline_table(part)
      table["arr"].values.map(&.as(Array(UInt64?))).should eq(expected)
    end
  end

  it "materializes owned named Tuple row handles through OfflineTable.values" do
    expected = [
      {3001_u64, "tuple-0"},
      {3002_u64, "tuple-1"},
      {3003_u64, "tuple-2"},
      {3004_u64, "tuple-3"},
      {3005_u64, "tuple-4"},
      {3006_u64, "tuple-5"},
      {3007_u64, "tuple-6"},
      {3008_u64, "tuple-7"},
    ] of Tuple(UInt64, String)
    w258_with_part do |part|
      rows = w258_offline_table(part)["tup"].values.map(&.as(CrystalClick::WideTupleRow))
      rows.size.should eq(expected.size)
      rows.each_with_index do |row, index|
        row.type_name.should eq("Tuple(n UInt64, s String)")
        {row.value_as("n", UInt64), row.value_as("s", String)}.should eq(expected[index])
      end
    end
  end

  it "materializes owned LowCardinality strings through OfflineTable.values" do
    expected = ["dup", "red", "dup", "", "blue", "dup", "blue", "tail"]
    w258_with_part do |part|
      w258_offline_table(part)["lc"].values.map(&.as(String)).should eq(expected)
    end
  end

  it "materializes owned Variant arm and null values through OfflineTable.values" do
    expected = [
      "variant-0",
      4002_u64,
      nil,
      "variant-3",
      4005_u64,
      "variant-5",
      4007_u64,
      nil,
    ] of CrystalClick::VariantStringUInt64Value
    w258_with_part do |part|
      w258_offline_table(part)["v"].values.map(&.as(CrystalClick::VariantStringUInt64Value)).should eq(expected)
    end
  end
end
