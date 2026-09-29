require "./wide_part_reader_w73_helpers"

private def w78_table_rows_u64(samples : Array(T)) : Array(Array(Tuple(UInt64, Array(T)))) forall T
  [
    [] of Tuple(UInt64, Array(T)),
    [{7_u64, [] of T}, {7_u64, [samples[0], samples[1]]}] of Tuple(UInt64, Array(T)),
    [] of Tuple(UInt64, Array(T)),
    [] of Tuple(UInt64, Array(T)),
    [{UInt64::MAX, [samples[2]]}] of Tuple(UInt64, Array(T)),
    [{0_u64, [] of T}] of Tuple(UInt64, Array(T)),
    [{42_u64, [samples[1], samples[0]]}] of Tuple(UInt64, Array(T)),
  ] of Array(Tuple(UInt64, Array(T)))
end

private def w78_table_rows_string(samples : Array(T)) : Array(Array(Tuple(String, Array(T)))) forall T
  [
    [] of Tuple(String, Array(T)),
    [{"dup", [] of T}, {"dup", [samples[0], samples[1]]}] of Tuple(String, Array(T)),
    [] of Tuple(String, Array(T)),
    [] of Tuple(String, Array(T)),
    [{"", [samples[2]]}] of Tuple(String, Array(T)),
    [{"later", [] of T}] of Tuple(String, Array(T)),
    [{"tail", [samples[1], samples[0]]}] of Tuple(String, Array(T)),
  ] of Array(Tuple(String, Array(T)))
end

private def w78_table_same_leaf?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w78_table_assert_rows(expected : Array(Array(Tuple(K, Array(T)))), actual : Array(Array(Tuple(K, Array(T))))) : Nil forall K, T
  actual.size.should eq(expected.size)
  expected.each_with_index do |row, row_index|
    actual[row_index].size.should eq(row.size)
    row.each_with_index do |(key, leaves), entry_index|
      actual_entry = actual[row_index][entry_index]
      actual_entry[0].should eq(key)
      actual_entry[1].size.should eq(leaves.size)
      leaves.each_with_index do |leaf, leaf_index|
        w78_table_same_leaf?(leaf, actual_entry[1][leaf_index]).should be_true
      end
    end
  end
  nil
end

private def w78_table_check_type(samples : Array(T), leaf_name : String) : Nil forall T
  keys = [10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64, 16_u64]
  u64_rows = w78_table_rows_u64(samples)
  string_rows = w78_table_rows_string(samples)
  parent = File.tempname("crystal-click-w78-table")
  Dir.mkdir(parent)
  begin
    u64_path = File.join(parent, "all_1_1_0")
    string_path = File.join(parent, "all_2_2_0")
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
      u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      u64_rows.to_unsafe.to_slice(u64_rows.size), rows_per_mark: 2
    )
    CrystalClick::WidePartWriter.write_uint64_map_string_array_numeric_pair(
      string_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      string_rows.to_unsafe.to_slice(string_rows.size), rows_per_mark: 2
    )

    u64_table = CrystalClick::WidePartTable.open_selected_typed([u64_path], ["pk", "payload"])
    string_table = CrystalClick::WidePartTable.open_selected_typed([string_path], ["pk", "payload"])
    u64_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(UInt64, Array(#{leaf_name}))"}])
    string_table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Map(String, Array(#{leaf_name}))"}])

    actual_keys = [] of UInt64
    actual_u64 = [] of Array(Tuple(UInt64, Array(T)))
    actual_string = [] of Array(Tuple(String, Array(T)))
    u64_table.scan_typed(batch_rows: 1) do |batch|
      actual_keys.concat(batch.values_for("pk", UInt64).to_a)
      actual_u64.concat(batch.map_uint64_array_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed(batch_rows: 1) do |batch|
      actual_string.concat(batch.map_string_array_numeric_values_for("payload", T).to_a)
    end
    actual_keys.should eq(keys)
    w78_table_assert_rows(u64_rows, actual_u64)
    w78_table_assert_rows(string_rows, actual_string)

    # The middle selected mark has no Map entries, and the later one does.
    empty_u64 = [] of Array(Tuple(UInt64, Array(T)))
    empty_string = [] of Array(Tuple(String, Array(T)))
    u64_table.scan_typed_window(2_u64, 2) do |batch|
      empty_u64.concat(batch.map_uint64_array_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed_window(2_u64, 2) do |batch|
      empty_string.concat(batch.map_string_array_numeric_values_for("payload", T).to_a)
    end
    w78_table_assert_rows(u64_rows[2, 2], empty_u64)
    w78_table_assert_rows(string_rows[2, 2], empty_string)

    selected_u64 = [] of Array(Tuple(UInt64, Array(T)))
    selected_string = [] of Array(Tuple(String, Array(T)))
    u64_table.scan_typed_window(4_u64, 2) do |batch|
      selected_u64.concat(batch.map_uint64_array_numeric_values_for("payload", T).to_a)
    end
    string_table.scan_typed_window(4_u64, 2) do |batch|
      selected_string.concat(batch.map_string_array_numeric_values_for("payload", T).to_a)
    end
    w78_table_assert_rows(u64_rows[4, 2], selected_u64)
    w78_table_assert_rows(string_rows[4, 2], selected_string)

    u64_table.scan_typed(batch_rows: 1) do |batch|
      {% if T == UInt8 %}
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_uint64_array_numeric_values_for("payload", Int16)
        end
      {% else %}
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_uint64_array_numeric_values_for("payload", UInt8)
        end
      {% end %}
      expect_raises(CrystalClick::UnsupportedFormatError) do
        batch.map_string_array_numeric_values_for("payload", T)
      end
      break
    end
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W78 typed table Map array batches" do
  it "materializes every admitted primitive numeric leaf for both key shapes" do
    w78_table_check_type([0_u8, UInt8::MAX, 7_u8], "UInt8")
    w78_table_check_type([0_u16, UInt16::MAX, 7_u16], "UInt16")
    w78_table_check_type([0_u32, UInt32::MAX, 7_u32], "UInt32")
    w78_table_check_type([0_u64, UInt64::MAX, 7_u64], "UInt64")
    w78_table_check_type([Int8::MIN, Int8::MAX, -1_i8], "Int8")
    w78_table_check_type([Int16::MIN, Int16::MAX, -1_i16], "Int16")
    w78_table_check_type([Int32::MIN, Int32::MAX, -1_i32], "Int32")
    w78_table_check_type([Int64::MIN, Int64::MAX, -1_i64], "Int64")
    w78_table_check_type([
      0x80000000_u32.unsafe_as(Float32),
      0x7fc00001_u32.unsafe_as(Float32),
      0x00000001_u32.unsafe_as(Float32),
    ], "Float32")
    w78_table_check_type([
      0x8000000000000000_u64.unsafe_as(Float64),
      0x7ff8000000000001_u64.unsafe_as(Float64),
      0x0000000000000001_u64.unsafe_as(Float64),
    ], "Float64")
  end

  it "does not expose a later mark with a shifted numeric leaf offset" do
    keys = [10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64, 16_u64]
    values = w78_table_rows_u64([0_i8, -1_i8, 2_i8])
    parent = File.tempname("crystal-click-w78-table-corrupt")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )
      w71_shift_mark(part, "payload%2Evalues", 2)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      delivered = [] of UInt64
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |batch|
          delivered.concat(batch.values_for("pk", UInt64).to_a)
          batch.map_uint64_array_numeric_values_for("payload", Int8)
        end
      end
      # A batch may preflight later marks before yielding all preceding rows.
      delivered.size.should be <= 4
      delivered.should eq(keys[0, delivered.size])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
