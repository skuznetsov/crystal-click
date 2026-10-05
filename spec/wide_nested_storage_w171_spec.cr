require "./spec_helper"
require "file_utils"

private def w171v_nullable_int32_column(
  name : String,
  values : Array(Int32),
  nulls : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(Int32)").not_nil!
  null_map = CrystalClick::ScalarNullMap.new(nulls.to_unsafe.to_slice(nulls.size), values.size.to_u64)
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, null_map)
end

private def w171v_columns(
  a_values : Array(UInt64),
  b_values : Array(String),
  c_values : Array(Int32),
  c_nulls : Array(UInt8),
) : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("a", a_values),
    CrystalClick::WideTupleLeafColumn.new("b", b_values),
    w171v_nullable_int32_column("c", c_values, c_nulls),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w171v_write_part(
  parent : String,
  label : String,
  type_name : String,
  nested : Bool,
  keys : Array(UInt64),
  row_sizes : Array(UInt64),
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32,
) : String
  container = File.join(parent, label)
  Dir.mkdir(container)
  destination = File.join(container, "all_1_1_0")
  if nested
    CrystalClick::WidePartWriter.write_uint64_nested_part(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
      row_sizes.to_unsafe.to_slice(row_sizes.size), columns, rows_per_mark
    )
  else
    CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
      destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
      row_sizes.to_unsafe.to_slice(row_sizes.size), columns, rows_per_mark
    )
  end
end

private def w171v_offline_root(parent : String, part : String, type_name : String) : String
  root = File.join(parent, "catalog")
  database_uuid = "17110000-0000-4000-8000-000000000001"
  table_uuid = "17110000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

private def w171v_main_fixture(parent : String) : {String, String, Array(UInt64)}
  type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
  row_sizes = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
  columns = w171v_columns(
    [101_u64, 103_u64, 211_u64, 307_u64, 311_u64, 317_u64, 409_u64, 419_u64],
    ["oak", "fir", "pine", "redwood", "x", "cedar", "ash", "maple"] of String,
    [1001, 1003, 2011, 3007, 3011, 3017, 4009, 4019] of Int32,
    [0_u8, 1_u8, 0_u8, 1_u8, 0_u8, 0_u8, 1_u8, 0_u8],
  )
  part = w171v_write_part(
    parent, "nested", type_name, true,
    [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], row_sizes, columns, 2
  )
  {part, type_name, row_sizes}
end

private def w171v_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w171v_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w171v_shift_later_string_boundary(part : String, type_name : String, mark_index : Int32) : Nil
  plan = CrystalClick::WideArrayTupleTypePlan.for_storage_type(type_name) || raise "invalid W171 storage type"
  field = plan.tuple_plan.fields.find { |candidate| candidate.name == "b" } || raise "missing W171 String leaf"
  stream = plan.leaf_stream_name("payload", field)
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index.to_i * CrystalClick::WidePart::MARK_SIZE + 8
  w171v_write_u64(marks, offset, w171v_read_u64(marks, offset) + 1_u64)
  File.write(mark_path, marks)
  nil
end

describe "W171 paired unflattened Nested storage" do
  it "reads full, middle, and empty outer rows with exact nominal type and three leaf axes" do
    parent = File.tempname("crystal-click-w171-nested-reader-")
    Dir.mkdir(parent)
    begin
      part, type_name, sizes = w171v_main_fixture(parent)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_nested_mark_range("payload", 0, reader.mark_count)

      data.type_name.should eq(type_name)
      data.row_count.should eq(5)
      data.element_count.should eq(8)
      data.row_sizes.should eq(sizes)
      data.offsets.should eq([0_u64, 2_u64, 2_u64, 3_u64, 6_u64, 8_u64])
      data.row(0)[0].value_as("a", UInt64).should eq(101_u64)
      data.row(0)[1].value_as("b", String).should eq("fir")
      data.row(0)[1]["c"].should be_nil
      data.row(1).size.should eq(0)
      data.row(2)[0].value_as("c", Int32).should eq(2011)
      data.row(3)[0].value_as("b", String).should eq("redwood")
      data.row(3)[0]["c"].should be_nil
      data.row(3)[1].value_as("a", UInt64).should eq(311_u64)
      data.row(3)[2].value_as("c", Int32).should eq(3017)
      data.row(4)[1].value_as("b", String).should eq("maple")

      middle = reader.read_nested_mark_range("payload", 1, 1)
      middle.row_sizes.should eq([1_u64, 3_u64])
      middle.row(0)[0].value_as("a", UInt64).should eq(211_u64)
      middle.row(1)[2].value_as("c", Int32).should eq(3017)
      reader.nested_mark_range_materialization_charge("payload", 0, reader.mark_count).should be > 0_u64

      mark_indexes = [] of Int32
      mark_rows = [] of Int32
      reader.each_nested_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
        mark_indexes << mark_index
        mark_rows << mark_data.row_count
        nil
      end
      mark_indexes.should eq([0_i32, 1_i32, 2_i32])
      mark_rows.should eq([2_i32, 2_i32, 1_i32])

      callbacks = [] of Int32
      expect_raises(CrystalClick::BoundsError) do
        reader.each_nested_mark_range("payload", reader.mark_count, 1) do |_mark_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_array_tuple_mark_range("payload", 0, reader.mark_count)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes owned Nested row handles through table scans, windows, and Offline values" do
    parent = File.tempname("crystal-click-w171-nested-consumers-")
    Dir.mkdir(parent)
    begin
      part, type_name, sizes = w171v_main_fixture(parent)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      full_rows = [] of CrystalClick::WideArrayTupleRow
      table.scan_typed(batch_rows: 2) do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.array_tuple_rows_for("payload")
        end
        batch.nested_rows_for("payload").each { |row| full_rows << row }
        nil
      end
      full_rows.map(&.size).should eq(sizes.map(&.to_i32))
      full_rows[0][1].value_as("a", UInt64).should eq(103_u64)
      full_rows[2][0].value_as("b", String).should eq("pine")
      full_rows[3][0]["c"].should be_nil
      full_rows[3][2].value_as("c", Int32).should eq(3017)

      callbacks = 0
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(6_u64, 2) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)

      window_rows = [] of CrystalClick::WideArrayTupleRow
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.nested_rows_for("payload").each { |row| window_rows << row }
        nil
      end
      window_rows.map(&.size).should eq([0_i32, 1_i32, 3_i32])
      window_rows[1][0].value_as("a", UInt64).should eq(211_u64)
      window_rows[2][2].value_as("b", String).should eq("cedar")

      offline = CrystalClick::OfflineCatalog.open(w171v_offline_root(parent, part, type_name))["lab"]["events"]
      values = offline["payload"].values(max_tuple_cells: 24_u64)
      rows = values.map(&.as(CrystalClick::WideArrayTupleRow))
      rows.map(&.size).should eq(sizes.map(&.to_i32))
      rows[0][0].value_as("b", String).should eq("oak")
      rows[4][0]["c"].should be_nil
      rows[4][1].value_as("c", Int32).should eq(4019)
      expect_raises(CrystalClick::BoundsError) do
        offline["payload"].values(max_tuple_cells: 23_u64)
      end

      offline_window = [] of CrystalClick::WideArrayTupleRow
      offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.nested_rows_for("payload").each { |row| offline_window << row }
        nil
      end
      offline_window.map(&.size).should eq([0_i32, 1_i32, 3_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps empty-element marks on the outer-row schedule" do
    parent = File.tempname("crystal-click-w171-nested-empty-marks-")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      sizes = [0_u64, 0_u64, 1_u64, 3_u64, 0_u64]
      part = w171v_write_part(
        parent, "empty-marks", type_name, true,
        [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], sizes,
        w171v_columns(
          [211_u64, 307_u64, 311_u64, 317_u64],
          ["pine", "redwood", "cedar", "ash"] of String,
          [2011, 3007, 3011, 3017] of Int32,
          [0_u8, 0_u8, 1_u8, 0_u8],
        ),
        2
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      observed = [] of Tuple(Int32, Array(UInt64), Int32)
      reader.each_nested_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
        observed << {mark_index, mark_data.row_sizes, mark_data.element_count}
        nil
      end
      observed.should eq([
        {0_i32, [0_u64, 0_u64], 0_i32},
        {1_i32, [1_u64, 3_u64], 4_i32},
        {2_i32, [0_u64], 0_i32},
      ])
      final_empty = reader.read_nested_mark_range("payload", 2, 1)
      final_empty.row_count.should eq(1)
      final_empty.element_count.should eq(0)
      final_empty.offsets.should eq([0_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "validates later child mark boundaries before yielding the first mark" do
    parent = File.tempname("crystal-click-w171-nested-later-boundary-")
    Dir.mkdir(parent)
    begin
      part, type_name, _sizes = w171v_main_fixture(parent)
      w171v_shift_later_string_boundary(part, type_name, 2)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader.each_nested_mark_range("payload", 0, reader.mark_count) do |_mark_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains nonzero outer rows when every flattened child is empty" do
    parent = File.tempname("crystal-click-w171-nested-all-empty-")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      sizes = [0_u64, 0_u64, 0_u64, 0_u64, 0_u64]
      part = w171v_write_part(
        parent, "all-empty", type_name, true,
        [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], sizes,
        w171v_columns(
          [] of UInt64, [] of String, [] of Int32, [] of UInt8
        ),
        2
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_nested_mark_range("payload", 0, reader.mark_count)
      data.type_name.should eq(type_name)
      data.row_count.should eq(5)
      data.element_count.should eq(0)
      data.row_sizes.should eq(sizes)
      data.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      data.row(0).each { |_element| fail "empty Nested row yielded an element" }

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      rows = [] of CrystalClick::WideArrayTupleRow
      table.scan_typed(batch_rows: 2) do |batch|
        batch.nested_rows_for("payload").each { |row| rows << row }
        nil
      end
      rows.size.should eq(5)
      rows.map(&.size).should eq([0, 0, 0, 0, 0])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a Nested outer-size schedule that disagrees with flattened child cardinality before staging" do
    parent = File.tempname("crystal-click-w171-nested-inconsistent-axis-")
    Dir.mkdir(parent)
    container = File.join(parent, "parts")
    Dir.mkdir(container)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nested_part(
          File.join(container, "all_1_1_0"), "pk", [7_u64, 13_u64].to_unsafe.to_slice(2),
          "payload", type_name, [1_u64, 0_u64].to_unsafe.to_slice(2),
          w171v_columns(
            [101_u64, 103_u64], ["oak", "fir"] of String,
            [1001, 1003] of Int32, [0_u8, 1_u8],
          ),
          1
        )
      end
      Dir.children(container).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not route an Array(Tuple) control through the nominal Nested accessor" do
    parent = File.tempname("crystal-click-w171-nested-array-control-")
    Dir.mkdir(parent)
    begin
      type_name = "Array(Tuple(a UInt64, b String, c Nullable(Int32)))"
      part = w171v_write_part(
        parent, "array-control", type_name, false,
        [7_u64, 13_u64], [1_u64, 1_u64],
        w171v_columns(
          [101_u64, 103_u64], ["oak", "fir"] of String,
          [1001, 1003] of Int32, [0_u8, 1_u8],
        ),
        1
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_nested_mark_range("payload", 0, reader.mark_count)
      end
      reader.read_array_tuple_mark_range("payload", 0, reader.mark_count).type_name.should eq(type_name)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callbacks = 0
      observed_rows = 0
      table.scan_typed(batch_rows: 2) do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.nested_rows_for("payload") }
        callbacks += 1
        observed_rows += batch.array_tuple_rows_for("payload").size
        nil
      end
      callbacks.should eq(2)
      observed_rows.should eq(2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
