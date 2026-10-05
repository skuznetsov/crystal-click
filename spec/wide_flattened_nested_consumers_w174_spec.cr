require "./spec_helper"
require "file_utils"

private def w174_nullable_int32_column(
  name : String,
  values : Array(Int32),
  nulls : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(Int32)").not_nil!
  null_map = CrystalClick::ScalarNullMap.new(nulls.to_unsafe.to_slice(nulls.size), values.size.to_u64)
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, null_map)
end

private def w174_nested_columns(
  a_values : Array(UInt64),
  b_values : Array(String),
  c_values : Array(Int32),
  c_nulls : Array(UInt8),
) : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("a", a_values),
    CrystalClick::WideTupleLeafColumn.new("b", b_values),
    w174_nullable_int32_column("c", c_values, c_nulls),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w174_write_part(
  parent : String,
  directory : String,
  part_name : String,
  key_name : String,
  keys : Array(UInt64),
  type_name : String,
  row_sizes : Array(UInt64),
  columns : Array(CrystalClick::WideTupleLeafColumn),
) : String
  container = File.join(parent, directory)
  Dir.mkdir(container)
  destination = File.join(container, part_name)
  CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
    destination, key_name, keys.to_unsafe.to_slice(keys.size), "nested", type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size), columns, 2
  )
end

private def w174_main_part(parent : String, directory : String = "part-main") : String
  type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
  w174_write_part(
    parent, directory, "all_1_1_0", "pk",
    [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], type_name,
    [2_u64, 0_u64, 1_u64, 3_u64, 2_u64],
    w174_nested_columns(
      [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64],
      ["r0-A", "r0-B", "mid-x", "r3-A", "r3-B", "r3-C", "last-A", "last-B"] of String,
      [0, -17, 31, 0, 32, 0, -41, 41] of Int32,
      [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8],
    )
  )
end

describe "W174 flattened Nested table consumers" do
  it "exposes the nominal root through full, window, and candidate-mark scans" do
    parent = File.tempname("crystal-click-w174-flat-table")
    Dir.mkdir(parent)
    begin
      part = w174_main_part(parent)
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      reader = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
        [part], ["pk", "nested"], "pk", "nested", type_name
      )
      reader.columns.should eq(["pk", "nested"])
      reader.column_types.should eq([
        {"pk", "UInt64"},
        {"nested", type_name},
      ])
      reader.column_sources.should eq([
        {"pk", "pk", "UInt64"},
        {"nested", "nested", type_name},
      ])

      full_keys = [] of UInt64
      full_rows = [] of Array(Tuple(UInt64, String, Int32?))
      reader.scan_typed(batch_rows: 2) do |batch|
        full_keys.concat(batch.values_for("pk").to_a)
        batch.nested_rows_for("nested").each do |row|
          copied = [] of Tuple(UInt64, String, Int32?)
          row.each do |element|
            copied << {
              element.value_as("a", UInt64),
              element.value_as("b", String),
              element["c"].as(Int32?),
            }
          end
          full_rows << copied
        end
        nil
      end
      full_keys.should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
      full_rows.map(&.size).should eq([2, 0, 1, 3, 2])
      full_rows[0][0][0].should eq(11_u64)
      full_rows[0][0][1].should eq("r0-A")
      full_rows[0][0][2].should be_nil
      full_rows[0][1][0].should eq(103_u64)
      full_rows[0][1][1].should eq("r0-B")
      full_rows[0][1][2].should eq(-17)
      full_rows[2][0][0].should eq(211_u64)
      full_rows[2][0][1].should eq("mid-x")
      full_rows[2][0][2].should eq(31)
      full_rows[3][0][0].should eq(307_u64)
      full_rows[3][0][2].should eq(0)
      full_rows[3][2][0].should eq(311_u64)
      full_rows[3][2][2].should be_nil
      full_rows[4][1][0].should eq(419_u64)
      full_rows[4][1][1].should eq("last-B")
      full_rows[4][1][2].should eq(41)

      window_rows = [] of Array(Tuple(UInt64, String, Int32?))
      reader.scan_typed_window(1_u64, 3) do |batch|
        batch.nested_rows_for("nested").each do |row|
          copied = [] of Tuple(UInt64, String, Int32?)
          row.each do |element|
            copied << {
              element.value_as("a", UInt64),
              element.value_as("b", String),
              element["c"].as(Int32?),
            }
          end
          window_rows << copied
        end
        nil
      end
      window_rows.map(&.size).should eq([0, 1, 3])
      window_rows[1][0][0].should eq(211_u64)
      window_rows[1][0][1].should eq("mid-x")
      window_rows[1][0][2].should eq(31)
      window_rows[2][1][0].should eq(310_u64)
      window_rows[2][1][1].should eq("r3-B")
      window_rows[2][1][2].should eq(32)

      empty_row_sizes = [] of Int32
      reader.scan_typed_window(1_u64, 1) do |batch|
        batch.nested_rows_for("nested").each { |row| empty_row_sizes << row.size }
        nil
      end
      empty_row_sizes.should eq([0])

      end_window_callbacks = 0
      reader.scan_typed_window(full_keys.size.to_u64, 1) do |_batch|
        end_window_callbacks += 1
        nil
      end
      end_window_callbacks.should eq(0)

      candidate_keys = [] of UInt64
      candidate_rows = [] of Array(Tuple(UInt64, String, Int32?))
      reader.scan_typed_candidate_marks([[1]]) do |batch|
        candidate_keys.concat(batch.values_for("pk").to_a)
        batch.nested_rows_for("nested").each do |row|
          copied = [] of Tuple(UInt64, String, Int32?)
          row.each do |element|
            copied << {
              element.value_as("a", UInt64),
              element.value_as("b", String),
              element["c"].as(Int32?),
            }
          end
          candidate_rows << copied
        end
        nil
      end
      candidate_keys.should eq([22_u64, 31_u64])
      candidate_rows.map(&.size).should eq([1, 3])
      candidate_rows[1][2][0].should eq(311_u64)
      candidate_rows[1][2][1].should eq("r3-C")
      candidate_rows[1][2][2].should be_nil

      expect_raises(CrystalClick::BoundsError) do
        reader.scan_typed_candidate_marks([[3]]) { |_batch| nil }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.scan_typed do |batch|
          batch.array_tuple_rows_for("nested")
          nil
        end
      end

      key_only = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
        [part], ["pk"], "pk", "nested", type_name
      )
      key_only_values = [] of UInt64
      key_only.scan_typed do |batch|
        key_only_values.concat(batch.values_for("pk").to_a)
        nil
      end
      key_only_values.should eq(full_keys)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        key_only.scan_typed do |batch|
          batch.nested_rows_for("pk")
          nil
        end
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "nested"])
      end

      malformed_serializer_part = w174_main_part(parent, "part-malformed-serializer")
      serializer_path = File.join(malformed_serializer_part, "serialization.json")
      malformed_serializer = File.read(serializer_path).sub("\"version\":1", "\"version\":2")
      File.write(serializer_path, malformed_serializer)
      malformed_key_only_callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        malformed_key_only = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
          [malformed_serializer_part], ["pk"], "pk", "nested", type_name
        )
        malformed_key_only.scan_typed do |_batch|
          malformed_key_only_callbacks += 1
          nil
        end
      end
      malformed_key_only_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps nonzero outer rows when every Nested element list is empty" do
    parent = File.tempname("crystal-click-w174-flat-zero-elements")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      part = w174_write_part(
        parent,
        "all-empty",
        "all_1_1_0",
        "pk",
        [101_u64, 203_u64, 307_u64],
        type_name,
        [0_u64, 0_u64, 0_u64],
        w174_nested_columns(
          [] of UInt64,
          [] of String,
          [] of Int32,
          [] of UInt8,
        )
      )

      reader = CrystalClick::WidePart.open_flattened_nested(part, "nested", type_name, "nested")
      data = reader.read_nested_mark_range("nested", 0, reader.mark_count)
      data.row_count.should eq(3)
      data.element_count.should eq(0)
      data.row_sizes.should eq([0_u64, 0_u64, 0_u64])
      data.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])

      table = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
        [part], ["pk", "nested"], "pk", "nested", type_name
      )
      observed_keys = [] of UInt64
      observed_sizes = [] of Int32
      table.scan_typed do |batch|
        observed_keys.concat(batch.values_for("pk").to_a)
        batch.nested_rows_for("nested").each { |row| observed_sizes << row.size }
        nil
      end
      observed_keys.should eq([101_u64, 203_u64, 307_u64])
      observed_sizes.should eq([0, 0, 0])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "binds the expected key on every selected part before group-only callbacks" do
    parent = File.tempname("crystal-click-w174-flat-key-binding")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      sizes = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
      columns = w174_nested_columns(
        [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64],
        ["r0-A", "r0-B", "mid-x", "r3-A", "r3-B", "r3-C", "last-A", "last-B"] of String,
        [0, -17, 31, 0, 32, 0, -41, 41] of Int32,
        [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8],
      )
      first = w174_write_part(
        parent, "part-first", "all_1_1_0", "pk",
        [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], type_name, sizes, columns
      )
      second = w174_write_part(
        parent, "part-second", "all_2_2_0", "other_pk",
        [57_u64, 63_u64, 72_u64, 81_u64, 100_u64], type_name, sizes, columns
      )

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
          [first, second], ["nested"], "pk", "nested", type_name
        )
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
end
