require "./spec_helper"

private def w77_table_numeric_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w77_table_assert_rows(expected : Array(Array(Tuple(K, T?))), actual : Array(Array(Tuple(K, T?)))) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |row, row_index|
    actual[row_index].size.should eq(row.size)
    row.each_with_index do |entry, entry_index|
      observed = actual[row_index][entry_index]
      observed[0].should eq(entry[0])
      if entry[1].nil?
        observed[1].should be_nil
      else
        observed[1].nil?.should be_false
        w77_table_numeric_equal?(entry[1].not_nil!, observed[1].not_nil!).should be_true
      end
    end
  end
  nil
end

private def w77_table_assert_leaf(samples : Array(T), type_name : String) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  uint64_rows = [
    [] of Tuple(UInt64, T?),
    [{7_u64, nil}, {7_u64, samples[0]}] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [] of Tuple(UInt64, T?),
    [{UInt64::MAX, samples[1]}, {0_u64, nil}] of Tuple(UInt64, T?),
    [{42_u64, samples[2]}] of Tuple(UInt64, T?),
  ] of Array(Tuple(UInt64, T?))
  string_rows = [
    [] of Tuple(String, T?),
    [{"dup", nil}, {"dup", samples[0]}] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [] of Tuple(String, T?),
    [{"", samples[1]}, {"binary\u0000key", nil}] of Tuple(String, T?),
    [{"tail", samples[2]}] of Tuple(String, T?),
  ] of Array(Tuple(String, T?))

  parent = File.tempname("crystal-click-w77-table")
  Dir.mkdir(parent)
  uint64_path = File.join(parent, "all_1_1_0")
  string_path = File.join(parent, "all_2_2_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
      uint64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      uint64_rows.to_unsafe.to_slice(uint64_rows.size), rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
      string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
    )
    uint64_table = CrystalClick::WidePartTable.open_selected_typed([uint64_path], ["pk", "payload"])
    string_table = CrystalClick::WidePartTable.open_selected_typed([string_path], ["pk", "payload"])
    uint64_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(UInt64, Nullable(#{type_name}))"}])
    string_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(String, Nullable(#{type_name}))"}])

    actual_uint64 = [] of Array(Tuple(UInt64, T?))
    actual_string = [] of Array(Tuple(String, T?))
    uint64_table.scan_typed(batch_rows: 1) do |batch|
      actual_uint64.concat(batch.map_uint64_nullable_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed(batch_rows: 1) do |batch|
      actual_string.concat(batch.map_string_nullable_numeric_values_for("payload", T).to_a)
    end
    w77_table_assert_rows(uint64_rows, actual_uint64)
    w77_table_assert_rows(string_rows, actual_string)

    empty_uint64 = [] of Array(Tuple(UInt64, T?))
    empty_string = [] of Array(Tuple(String, T?))
    uint64_table.scan_typed_window(2_u64, 2) do |batch|
      empty_uint64.concat(batch.map_uint64_nullable_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed_window(2_u64, 2) do |batch|
      empty_string.concat(batch.map_string_nullable_numeric_values_for("payload", T).to_a)
    end
    w77_table_assert_rows(uint64_rows[2, 2], empty_uint64)
    w77_table_assert_rows(string_rows[2, 2], empty_string)

    later_uint64 = [] of Array(Tuple(UInt64, T?))
    later_string = [] of Array(Tuple(String, T?))
    uint64_table.scan_typed_window(4_u64, 2) do |batch|
      later_uint64.concat(batch.map_uint64_nullable_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed_window(4_u64, 2) do |batch|
      later_string.concat(batch.map_string_nullable_numeric_values_for("payload", T).to_a)
    end
    w77_table_assert_rows(uint64_rows[4, 2], later_uint64)
    w77_table_assert_rows(string_rows[4, 2], later_string)

    uint64_table.scan_typed(batch_rows: 1) do |batch|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        batch.map_string_nullable_numeric_values_for("payload", T)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        batch.map_uint64_numeric_values_for("payload", T)
      end
    end
    string_table.scan_typed(batch_rows: 1) do |batch|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        batch.map_uint64_nullable_numeric_values_for("payload", T)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        batch.map_string_numeric_values_for("payload", T)
      end
    end
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W77 nullable numeric Map typed table batches" do
  it "charges retained rows even when both nullable Map rows contain no entries" do
    keys = [1_u64, 2_u64]
    uint64_rows = [
      [] of Tuple(UInt64, UInt8?),
      [] of Tuple(UInt64, UInt8?),
    ]
    string_rows = [
      [] of Tuple(String, UInt8?),
      [] of Tuple(String, UInt8?),
    ]
    parent = File.tempname("crystal-click-w77-empty-map-charge")
    Dir.mkdir(parent)
    begin
      uint64_path = File.join(parent, "all_1_1_0")
      string_path = File.join(parent, "all_2_2_0")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
        uint64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint64_rows.to_unsafe.to_slice(uint64_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
        string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(uint64_path, "payload")
        .map_uint64_nullable_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt8)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePart.open_typed(string_path, "payload")
        .map_string_nullable_numeric_mark_range_materialization_preflight("payload", 0, 1, UInt8)
        .should eq({0_u64, 128_u64})
      CrystalClick::WidePartTable.open_selected_typed([uint64_path], ["payload"])
        .scan_typed { |batch| batch.map_uint64_nullable_numeric_values_for("payload", UInt8).size.should eq(2) }
      CrystalClick::WidePartTable.open_selected_typed([string_path], ["payload"])
        .scan_typed { |batch| batch.map_string_nullable_numeric_values_for("payload", UInt8).size.should eq(2) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "scans a final all-empty Map mark after nonempty child payload for both key shapes" do
    keys = [0_u64, 1_u64, 2_u64, 3_u64]
    uint64_rows = [
      [{10_u64, 7_u8}] of Tuple(UInt64, UInt8?),
      [{11_u64, nil}] of Tuple(UInt64, UInt8?),
      [] of Tuple(UInt64, UInt8?),
      [] of Tuple(UInt64, UInt8?),
    ]
    string_rows = [
      [{"before", 7_u8}] of Tuple(String, UInt8?),
      [{"middle", nil}] of Tuple(String, UInt8?),
      [] of Tuple(String, UInt8?),
      [] of Tuple(String, UInt8?),
    ]
    parent = File.tempname("crystal-click-w77-table-empty-eof")
    Dir.mkdir(parent)
    begin
      uint64_path = File.join(parent, "all_1_1_0")
      string_path = File.join(parent, "all_2_2_0")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
        uint64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint64_rows.to_unsafe.to_slice(uint64_rows.size), rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
        string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
      )

      uint64_table = CrystalClick::WidePartTable.open_selected_typed([uint64_path], ["payload"])
      string_table = CrystalClick::WidePartTable.open_selected_typed([string_path], ["payload"])
      actual_uint64 = [] of Array(Tuple(UInt64, UInt8?))
      actual_string = [] of Array(Tuple(String, UInt8?))
      uint64_table.scan_typed_window(2_u64, 2) do |batch|
        actual_uint64.concat(batch.map_uint64_nullable_numeric_values_for("payload", UInt8).to_a)
      end
      string_table.scan_typed_window(2_u64, 2) do |batch|
        actual_string.concat(batch.map_string_nullable_numeric_values_for("payload", UInt8).to_a)
      end
      w77_table_assert_rows(uint64_rows[2, 2], actual_uint64)
      w77_table_assert_rows(string_rows[2, 2], actual_string)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes all ten primitive leaves for both key shapes, preserving NULLs and later marks" do
    w77_table_assert_leaf([0_u8, UInt8::MAX, 17_u8], "UInt8")
    w77_table_assert_leaf([0_u16, UInt16::MAX, 17_u16], "UInt16")
    w77_table_assert_leaf([0_u32, UInt32::MAX, 17_u32], "UInt32")
    w77_table_assert_leaf([0_u64, UInt64::MAX, 17_u64], "UInt64")
    w77_table_assert_leaf([0_i8, Int8::MIN, Int8::MAX], "Int8")
    w77_table_assert_leaf([0_i16, Int16::MIN, Int16::MAX], "Int16")
    w77_table_assert_leaf([0_i32, Int32::MIN, Int32::MAX], "Int32")
    w77_table_assert_leaf([0_i64, Int64::MIN, Int64::MAX], "Int64")
    w77_table_assert_leaf([0x80000000_u32.unsafe_as(Float32), 0x7fc00001_u32.unsafe_as(Float32), 1.5_f32], "Float32")
    w77_table_assert_leaf([0x8000000000000000_u64.unsafe_as(Float64), 0x7ff8000000000001_u64.unsafe_as(Float64), 1.5_f64], "Float64")
  end
end
