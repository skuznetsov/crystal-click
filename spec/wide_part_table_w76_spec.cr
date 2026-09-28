require "./spec_helper"

private def w76_table_value_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w76_table_u64_rows(samples : Array(T)) : Array(Array(Tuple(UInt64, T))) forall T
  [
    [] of Tuple(UInt64, T),
    [{7_u64, samples[0]}, {7_u64, samples[1]}] of Tuple(UInt64, T),
    [] of Tuple(UInt64, T),
    [] of Tuple(UInt64, T),
    [{UInt64::MAX, samples[2]}] of Tuple(UInt64, T),
    [{0_u64, samples[1]}] of Tuple(UInt64, T),
    [{42_u64, samples[0]}] of Tuple(UInt64, T),
  ] of Array(Tuple(UInt64, T))
end

private def w76_table_string_rows(samples : Array(T)) : Array(Array(Tuple(String, T))) forall T
  [
    [] of Tuple(String, T),
    [{"dup", samples[0]}, {"dup", samples[1]}] of Tuple(String, T),
    [] of Tuple(String, T),
    [] of Tuple(String, T),
    [{"", samples[2]}] of Tuple(String, T),
    [{"later", samples[1]}] of Tuple(String, T),
    [{"tail", samples[0]}] of Tuple(String, T),
  ] of Array(Tuple(String, T))
end

private def w76_table_assert_u64_rows(expected : Array(Array(Tuple(UInt64, T))), actual : Array(Array(Tuple(UInt64, T)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      w76_table_value_equal?(expected_entry[1], actual[row][entry][1]).should be_true
    end
  end
  nil
end

private def w76_table_assert_string_rows(expected : Array(Array(Tuple(String, T))), actual : Array(Array(Tuple(String, T)))) : Nil forall T
  actual.size.should eq(expected.size)
  expected.each_with_index do |expected_row, row|
    actual[row].size.should eq(expected_row.size)
    expected_row.each_with_index do |expected_entry, entry|
      actual[row][entry][0].should eq(expected_entry[0])
      w76_table_value_equal?(expected_entry[1], actual[row][entry][1]).should be_true
    end
  end
  nil
end

private def w76_table_assert_typed_maps(samples : Array(T), type_name : String) : Nil forall T
  keys = [10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64, 16_u64]
  u64_rows = w76_table_u64_rows(samples)
  string_rows = w76_table_string_rows(samples)
  parent = File.tempname("crystal-click-w76-table")
  Dir.mkdir(parent)
  u64_path = File.join(parent, "all_1_1_0")
  string_path = File.join(parent, "all_2_2_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
      u64_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      u64_rows.to_unsafe.to_slice(u64_rows.size),
      rows_per_mark: 2
    ).should eq(u64_path)
    CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
      string_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      string_rows.to_unsafe.to_slice(string_rows.size),
      rows_per_mark: 2
    ).should eq(string_path)

    u64_table = CrystalClick::WidePartTable.open_selected_typed([u64_path], ["pk", "payload"])
    string_table = CrystalClick::WidePartTable.open_selected_typed([string_path], ["pk", "payload"])
    u64_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(UInt64, #{type_name})"}])
    string_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(String, #{type_name})"}])

    observed_u64 = [] of Array(Tuple(UInt64, T))
    observed_string = [] of Array(Tuple(String, T))
    observed_keys = [] of UInt64
    u64_table.scan_typed(batch_rows: 1) do |batch|
      observed_keys.concat(batch.values_for("pk", UInt64).to_a)
      observed_u64.concat(batch.map_uint64_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed(batch_rows: 1) do |batch|
      observed_string.concat(batch.map_string_numeric_values_for("payload", T).to_a)
    end
    observed_keys.should eq(keys)
    w76_table_assert_u64_rows(u64_rows, observed_u64)
    w76_table_assert_string_rows(string_rows, observed_string)

    # This window selects a later physical mark whose Map rows are empty.
    # The rows still need aligned, materialized empty maps, not omitted data.
    empty_u64 = [] of Array(Tuple(UInt64, T))
    empty_u64_marks = [] of Int32
    u64_table.scan_typed_window(2_u64, 2) do |batch|
      empty_u64_marks << batch.mark_index
      empty_u64.concat(batch.map_uint64_numeric_values_for("payload", T).to_a)
    end
    empty_u64_marks.should eq([1])
    w76_table_assert_u64_rows(u64_rows[2, 2], empty_u64)

    empty_string = [] of Array(Tuple(String, T))
    empty_string_marks = [] of Int32
    string_table.scan_typed_window(2_u64, 2) do |batch|
      empty_string_marks << batch.mark_index
      empty_string.concat(batch.map_string_numeric_values_for("payload", T).to_a)
    end
    empty_string_marks.should eq([1])
    w76_table_assert_string_rows(string_rows[2, 2], empty_string)

    selected_u64 = [] of Array(Tuple(UInt64, T))
    u64_table.scan_typed_window(4_u64, 2) do |batch|
      selected_u64.concat(batch.map_uint64_numeric_values_for("payload", T).to_a)
    end
    w76_table_assert_u64_rows(u64_rows[4, 2], selected_u64)

    selected_string = [] of Array(Tuple(String, T))
    string_table.scan_typed_window(4_u64, 2) do |batch|
      selected_string.concat(batch.map_string_numeric_values_for("payload", T).to_a)
    end
    w76_table_assert_string_rows(string_rows[4, 2], selected_string)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w76_table_unmaterialized_batch : CrystalClick::WidePartTableBatch
  CrystalClick::WidePartTableBatch.new(
    0,
    "part",
    "",
    0,
    0_u64,
    0_u64,
    0_u64,
    ["payload"],
    ["Map(UInt64, UInt8)"],
    Hash(String, CrystalClick::WidePartNumericSlice).new,
    Hash(String, Slice(String)).new,
    Hash(String, CrystalClick::WidePartNullableSlice).new,
    Hash(String, CrystalClick::WidePartNullableStringSlice).new
  )
end

describe "W76 typed Map table batches" do
  it "charges retained row arrays even when a selected numeric Map mark has no entries" do
    keys = [1_u64, 2_u64]
    uint64_rows = [
      [] of Tuple(UInt64, UInt8),
      [] of Tuple(UInt64, UInt8),
    ]
    string_rows = [
      [] of Tuple(String, UInt8),
      [] of Tuple(String, UInt8),
    ]
    uint64_control_rows = [
      [] of Tuple(UInt64, UInt64),
      [] of Tuple(UInt64, UInt64),
    ]
    string_control_rows = [
      [] of Tuple(String, UInt64),
      [] of Tuple(String, UInt64),
    ]
    parent = File.tempname("crystal-click-w76-empty-map-charge")
    Dir.mkdir(parent)
    begin
      uint64_path = File.join(parent, "all_1_1_0")
      string_path = File.join(parent, "all_2_2_0")
      uint64_control_path = File.join(parent, "all_3_3_0")
      string_control_path = File.join(parent, "all_4_4_0")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
        uint64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint64_rows.to_unsafe.to_slice(uint64_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
        string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
        uint64_control_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint64_control_rows.to_unsafe.to_slice(uint64_control_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
        string_control_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_control_rows.to_unsafe.to_slice(string_control_rows.size), rows_per_mark: 2
      )

      CrystalClick::WidePart.open_typed(uint64_path, "payload")
        .map_uint64_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt8)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePart.open_typed(string_path, "payload")
        .map_string_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt8)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePart.open_typed(uint64_control_path, "payload")
        .map_uint64_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt64)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePart.open_typed(string_control_path, "payload")
        .map_string_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt64)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePartTable.open_selected_typed([uint64_control_path], ["payload"])
        .scan_typed do |batch|
          batch.map_uint64_numeric_values_for("payload", UInt64).size.should eq(2)
        end
      CrystalClick::WidePartTable.open_selected_typed([string_control_path], ["payload"])
        .scan_typed do |batch|
          batch.map_string_numeric_values_for("payload", UInt64).size.should eq(2)
        end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes all ten primitive numeric Map leaves for both key shapes" do
    w76_table_assert_typed_maps([0_u8, UInt8::MAX, 7_u8], "UInt8")
    w76_table_assert_typed_maps([0_u16, UInt16::MAX, 7_u16], "UInt16")
    w76_table_assert_typed_maps([0_u32, UInt32::MAX, 7_u32], "UInt32")
    w76_table_assert_typed_maps([0_u64, UInt64::MAX, 7_u64], "UInt64")
    w76_table_assert_typed_maps([Int8::MIN, Int8::MAX, -1_i8], "Int8")
    w76_table_assert_typed_maps([Int16::MIN, Int16::MAX, -1_i16], "Int16")
    w76_table_assert_typed_maps([Int32::MIN, Int32::MAX, -1_i32], "Int32")
    w76_table_assert_typed_maps([Int64::MIN, Int64::MAX, -1_i64], "Int64")
    w76_table_assert_typed_maps([
      0x80000000_u32.unsafe_as(Float32),
      0x7fc00001_u32.unsafe_as(Float32),
      0x00000001_u32.unsafe_as(Float32),
    ], "Float32")
    w76_table_assert_typed_maps([
      0x8000000000000000_u64.unsafe_as(Float64),
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x0000000000000001_u64.unsafe_as(Float64),
    ], "Float64")
  end

  it "fails closed for an unmaterialized exact Map and for mismatched key/value types" do
    batch = w76_table_unmaterialized_batch
    expect_raises(CrystalClick::UnsupportedFormatError) do
      batch.map_uint64_numeric_values_for("payload", UInt8)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      batch.map_uint64_numeric_values_for("payload", Float32)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      batch.map_string_numeric_values_for("payload", UInt8)
    end
  end
end
