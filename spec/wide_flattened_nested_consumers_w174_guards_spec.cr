require "./spec_helper"
require "file_utils"

W174G_TYPE  = String.new("Nested(a UInt64, b String, c Nullable(Int32))".to_slice)
W174G_SIZES = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
W174G_KEYS  = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]

private def w174g_columns(
  type_name : String = W174G_TYPE,
  a_values : Array(UInt64) = [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64],
  b_values : Array(String) = ["r0-A", "r0-B", "mid-x", "r3-A", "r3-B", "r3-C", "last-A", "last-B"] of String,
) : Array(CrystalClick::WideTupleLeafColumn)
  c_values = [0, -17, 31, 0, 32, 0, -41, 41] of Int32
  if type_name == "Nested(a UInt64, b String, c Nullable(Int32))"
    leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(Int32)").not_nil!
    nulls = [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8]
    null_map = CrystalClick::ScalarNullMap.new(nulls.to_unsafe.to_slice(nulls.size), c_values.size.to_u64)
    [
      CrystalClick::WideTupleLeafColumn.new("a", a_values),
      CrystalClick::WideTupleLeafColumn.new("b", b_values),
      CrystalClick::WideTupleLeafColumn.new("c", leaf_type, c_values, null_map),
    ] of CrystalClick::WideTupleLeafColumn
  else
    [
      CrystalClick::WideTupleLeafColumn.new("a", a_values),
      CrystalClick::WideTupleLeafColumn.new("b", b_values),
      CrystalClick::WideTupleLeafColumn.new("c", c_values),
    ] of CrystalClick::WideTupleLeafColumn
  end
end

private def w174g_write_part(
  parent : String,
  directory : String,
  part_name : String = "all_1_1_0",
  key_name : String = "pk",
  keys : Array(UInt64) = W174G_KEYS,
  type_name : String = W174G_TYPE,
) : String
  container = File.join(parent, directory)
  Dir.mkdir(container)
  destination = File.join(container, part_name)
  CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    "nested",
    type_name,
    W174G_SIZES.to_unsafe.to_slice(W174G_SIZES.size),
    w174g_columns(type_name),
    2
  )
end

private def w174g_catalog_root(
  parent : String,
  ddl_columns : String,
  part_paths : Array(String),
  engine : String = "MergeTree",
  order_by : String = "pk",
) : String
  root = File.join(parent, "catalog")
  database_uuid = "17400000-0000-4000-8000-000000000001"
  table_uuid = "17400000-0000-4000-8000-000000000002"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(
    File.join(metadata_path, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
  )
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{ddl_columns}\n)\n" \
    "ENGINE = #{engine}\nORDER BY #{order_by}\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  part_paths.each do |part|
    FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  end
  root
end

private def w174g_read_u64(bytes : Slice(UInt8), offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w174g_write_u64(bytes : Slice(UInt8), offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

describe "W174 flattened Nested consumer guards" do
  it "keeps the ordinary table unchanged and routes a separate bounded offline view" do
    parent = File.tempname("crystal-click-w174-flat-offline")
    Dir.mkdir(parent)
    begin
      part = w174g_write_part(parent, "source")
      ddl_columns = "    `pk` UInt64,\n    `nested` #{W174G_TYPE}"
      root = w174g_catalog_root(parent, ddl_columns, [part])
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed(["pk", "nested"]) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)

      group_name = String.new("nested".to_slice)
      view = table.with_flattened_nested(group_name)
      group_name.to_unsafe[0] = 0x63_u8
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"nested", W174G_TYPE},
      ])
      view.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"nested", W174G_TYPE},
      ])
      view.metadata_ddl.should eq(table.metadata_ddl)

      exposed_columns = view.columns
      exposed_columns[0].name.to_unsafe[0] = 0x78_u8
      exposed_columns[0].type.to_unsafe[0] = 0x58_u8
      exposed_columns[1].name.to_unsafe[0] = 0x78_u8
      exposed_columns[1].type.to_unsafe[0] = 0x58_u8
      view.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"nested", W174G_TYPE},
      ])
      exposed_ddl = view.metadata_ddl.not_nil!
      exposed_ddl.to_unsafe[0] = 0x78_u8
      view.metadata_ddl.should eq(table.metadata_ddl)

      full_keys = [] of UInt64
      full_rows = [] of Array(Tuple(UInt64, String, Int32?))
      view.scan_typed(["pk", "nested"], batch_rows: 2) do |batch|
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
      full_keys.should eq(W174G_KEYS)
      full_rows.map(&.size).should eq([2, 0, 1, 3, 2])
      full_rows[0][0][0].should eq(11_u64)
      full_rows[0][0][2].should be_nil
      full_rows[3][2][0].should eq(311_u64)
      full_rows[3][2][2].should be_nil
      full_rows[4][1][0].should eq(419_u64)

      window_rows = [] of Array(Tuple(UInt64, String, Int32?))
      view.scan_typed_window(["pk", "nested"], 1_u64, 3) do |batch|
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
      window_rows[1][0][1].should eq("mid-x")
      window_rows[2][2][1].should eq("r3-C")

      empty_row_sizes = [] of Int32
      view.scan_typed_window(["pk", "nested"], 1_u64, 1) do |batch|
        batch.nested_rows_for("nested").each { |row| empty_row_sizes << row.size }
        nil
      end
      empty_row_sizes.should eq([0])

      end_window_callbacks = 0
      view.scan_typed_window(["pk", "nested"], W174G_KEYS.size.to_u64, 1) do |_batch|
        end_window_callbacks += 1
        nil
      end
      end_window_callbacks.should eq(0)

      materialized = view["nested"].values.map(&.as(CrystalClick::WideArrayTupleRow))
      materialized.map(&.size).should eq([2, 0, 1, 3, 2])
      materialized[0][0]["a"].should eq(11_u64)
      materialized[0][0]["c"].should be_nil
      materialized[3][2]["b"].should eq("r3-C")
      materialized[4][1]["c"].should eq(41)
      view["nested"].values(max_tuple_cells: 24_u64).map(&.as(CrystalClick::WideArrayTupleRow)).map(&.size).should eq([2, 0, 1, 3, 2])
      expect_raises(CrystalClick::BoundsError) do
        view["nested"].values(max_tuple_cells: 23_u64)
      end
      view["nested"].values(max_string_bytes: 37_u64).size.should eq(5)
      expect_raises(CrystalClick::BoundsError) do
        view["nested"].values(max_string_bytes: 36_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        view["nested"].values(max_rows: 4_u64)
      end

      exposed_key = view.primary_key_column.not_nil!
      exposed_key.to_unsafe[0] = 0x6e_u8
      view.primary_key_column.should eq("pk")

      legacy_callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_uint64(["pk"]) do |_batch|
          legacy_callbacks += 1
          nil
        end
      end
      legacy_callbacks.should eq(0)

      candidate_keys = [] of UInt64
      candidate_rows = [] of Array(Tuple(UInt64, String, Int32?))
      view.scan_uint64_pk_candidates(["pk", "nested"], 22_u64, 31_u64) do |batch|
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
      # The PK index returns whole conservative granules, not exact matches.
      candidate_keys.should eq([7_u64, 13_u64, 22_u64, 31_u64])
      candidate_rows.map(&.size).should eq([2, 0, 1, 3])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_uint64_pk_candidates(["nested"], 22_u64, 31_u64) { |_batch| nil }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_typed(["nested.a"]) { |_batch| nil }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects sibling-only and otherwise noncanonical DDL bindings" do
    parent = File.tempname("crystal-click-w174-flat-ddl-guards")
    Dir.mkdir(parent)
    begin
      sibling_only = "    `pk` UInt64,\n    `nested` Array(UInt64)"
      wrong_order = "    `nested` #{W174G_TYPE},\n    `pk` UInt64"
      wrong_key_type = "    `pk` String,\n    `nested` #{W174G_TYPE}"
      extra_column = "    `pk` UInt64,\n    `nested` #{W174G_TYPE},\n    `extra` String"
      alias_key = "    `pk` UInt64 ALIAS 1,\n    `nested` #{W174G_TYPE}"
      alias_root = "    `pk` UInt64,\n    `nested` #{W174G_TYPE} ALIAS pk"
      recursive_leaf = "    `pk` UInt64,\n    `nested` Nested(a Array(UInt64))"

      [
        {"sibling-only", sibling_only, "MergeTree"},
        {"wrong-order", wrong_order, "MergeTree"},
        {"wrong-key", wrong_key_type, "MergeTree"},
        {"extra", extra_column, "MergeTree"},
        {"alias-key", alias_key, "MergeTree"},
        {"alias-root", alias_root, "MergeTree"},
        {"recursive-leaf", recursive_leaf, "MergeTree"},
        {"engine", "    `pk` UInt64,\n    `nested` #{W174G_TYPE}", "ReplacingMergeTree"},
      ].each do |label, columns, engine|
        root = w174g_catalog_root(parent, columns, [] of String, engine)
        table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.with_flattened_nested("nested")
        end
        FileUtils.rm_rf(root)
      end

      missing_key_parent = File.join(parent, "missing-key-pk")
      Dir.mkdir(missing_key_parent)
      root = w174g_catalog_root(
        missing_key_parent,
        "    `pk` UInt64,\n    `nested` #{W174G_TYPE}",
        [] of String,
        order_by: "missing"
      )
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.with_flattened_nested("nested")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a later part with the wrong key or Nested schema before callbacks" do
    parent = File.tempname("crystal-click-w174-flat-multipart-guards")
    Dir.mkdir(parent)
    begin
      first = w174g_write_part(parent, "first", "all_1_1_0", "pk")
      wrong_key = w174g_write_part(
        parent, "wrong-key", "all_2_2_0", "other_pk",
        [57_u64, 63_u64, 72_u64, 81_u64, 100_u64]
      )
      root = w174g_catalog_root(
        parent,
        "    `pk` UInt64,\n    `nested` #{W174G_TYPE}",
        [first, wrong_key]
      )
      view = CrystalClick::OfflineCatalog.open(root)["lab"]["events"].with_flattened_nested("nested")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_typed(["nested"]) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)

      changed_type = "Nested(a UInt64, b String, c Int32)"
      wrong_roster = w174g_write_part(
        parent, "wrong-roster", "all_3_3_0", "pk",
        [107_u64, 113_u64, 122_u64, 131_u64, 150_u64], changed_type
      )
      key_only_root = w174g_catalog_root(
        File.join(parent, "roster-catalog-parent"),
        "    `pk` UInt64,\n    `nested` #{W174G_TYPE}",
        [first, wrong_roster]
      )
      key_only_view = CrystalClick::OfflineCatalog.open(key_only_root)["lab"]["events"].with_flattened_nested("nested")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        key_only_view.scan_typed(["pk"]) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects key/root mark-axis disagreement before callbacks" do
    parent = File.tempname("crystal-click-w174-flat-mark-axis")
    Dir.mkdir(parent)
    begin
      part = w174g_write_part(parent, "part")
      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("pk")}.mrk2")
      marks = File.read(mark_path).to_slice.dup
      marks.size.should eq(4 * CrystalClick::WidePart::MARK_SIZE)
      w174g_read_u64(marks, 16).should eq(2_u64)
      w174g_write_u64(marks, 16, 1_u64)
      w174g_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
      observed_rows = (0...3).sum do |index|
        w174g_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16)
      end
      observed_rows.should eq(5_u64)
      File.write(mark_path, marks)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
          [part], ["nested"], "pk", "nested", W174G_TYPE
        )
        reader.scan_typed do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "snapshots explicit reader selection and schema inputs" do
    parent = File.tempname("crystal-click-w174-flat-input-snapshots")
    Dir.mkdir(parent)
    begin
      part = w174g_write_part(parent, "part")
      path_input = String.new(part.to_slice)
      paths = [path_input]
      columns = [String.new("pk".to_slice), String.new("nested".to_slice)]
      key_name = String.new("pk".to_slice)
      group_name = String.new("nested".to_slice)
      type_name = String.new(W174G_TYPE.to_slice)
      reader = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
        paths, columns, key_name, group_name, type_name
      )

      path_input.to_unsafe[0] = 0x78_u8
      columns[0].to_unsafe[0] = 0x78_u8
      columns[1].to_unsafe[0] = 0x78_u8
      key_name.to_unsafe[0] = 0x78_u8
      group_name.to_unsafe[0] = 0x78_u8
      type_name.to_unsafe[0] = 0x58_u8
      reader.columns.should eq(["pk", "nested"])
      reader.column_types.should eq([
        {"pk", "UInt64"},
        {"nested", W174G_TYPE},
      ])

      exposed_columns = reader.columns
      exposed_columns[0].to_unsafe[0] = 0x78_u8
      exposed_columns[1].to_unsafe[0] = 0x78_u8
      reader.columns.should eq(["pk", "nested"])

      exposed_types = reader.column_types
      exposed_types[0][0].to_unsafe[0] = 0x78_u8
      exposed_types[0][1].to_unsafe[0] = 0x58_u8
      exposed_types[1][0].to_unsafe[0] = 0x78_u8
      exposed_types[1][1].to_unsafe[0] = 0x58_u8
      reader.column_types.should eq([
        {"pk", "UInt64"},
        {"nested", W174G_TYPE},
      ])

      exposed_sources = reader.column_sources
      exposed_sources[0][0].to_unsafe[0] = 0x78_u8
      exposed_sources[0][1].to_unsafe[0] = 0x78_u8
      exposed_sources[0][2].to_unsafe[0] = 0x58_u8
      exposed_sources[1][0].to_unsafe[0] = 0x78_u8
      exposed_sources[1][1].to_unsafe[0] = 0x78_u8
      exposed_sources[1][2].to_unsafe[0] = 0x58_u8
      reader.column_sources.should eq([
        {"pk", "pk", "UInt64"},
        {"nested", "nested", W174G_TYPE},
      ])

      keys = [] of UInt64
      root_sizes = [] of Int32
      reader.scan_typed do |batch|
        keys.concat(batch.values_for("pk").to_a)
        batch.nested_rows_for("nested").each { |row| root_sizes << row.size }
        nil
      end
      keys.should eq(W174G_KEYS)
      root_sizes.should eq([2, 0, 1, 3, 2])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses the legacy numeric scan on a single-field flattened Nested view" do
    parent = File.tempname("crystal-click-w174-flat-numeric-guard")
    Dir.mkdir(parent)
    begin
      container = File.join(parent, "single-field-part")
      Dir.mkdir(container)
      part = File.join(container, "all_1_1_0")
      type_name = "Nested(a UInt64)"
      CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
        part,
        "pk",
        [1_u64, 2_u64].to_unsafe.to_slice(2),
        "nested",
        type_name,
        [1_u64, 0_u64].to_unsafe.to_slice(2),
        [CrystalClick::WideTupleLeafColumn.new("a", [9_u64])] of CrystalClick::WideTupleLeafColumn,
        2
      )
      root = w174g_catalog_root(
        parent,
        "    `pk` UInt64,\n    `nested` #{type_name}",
        [part]
      )
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]

      ordinary_keys = [] of UInt64
      table.scan_numeric(["pk"]) do |batch|
        ordinary_keys.concat(batch.values_for("pk").to_a)
        nil
      end
      ordinary_keys.should eq([1_u64, 2_u64])

      view = table.with_flattened_nested("nested")
      typed_keys = [] of UInt64
      row_sizes = [] of Int32
      nested_a = [] of UInt64
      view.scan_typed(["pk", "nested"]) do |batch|
        typed_keys.concat(batch.values_for("pk").to_a)
        batch.nested_rows_for("nested").each do |row|
          row_sizes << row.size
          row.each { |element| nested_a << element.value_as("a", UInt64) }
        end
        nil
      end
      typed_keys.should eq([1_u64, 2_u64])
      row_sizes.should eq([1, 0])
      nested_a.should eq([9_u64])

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_numeric(["pk"]) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps the Array(Tuple) and nominal Nested row accessors disjoint" do
    parent = File.tempname("crystal-click-w174-flat-array-control")
    Dir.mkdir(parent)
    begin
      container = File.join(parent, "array-part")
      Dir.mkdir(container)
      part = File.join(container, "all_1_1_0")
      type_name = "Array(Tuple(a UInt64, b String, c Int32))"
      CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
        part,
        "pk",
        [1_u64, 2_u64].to_unsafe.to_slice(2),
        "payload",
        type_name,
        [1_u64, 0_u64].to_unsafe.to_slice(2),
        [
          CrystalClick::WideTupleLeafColumn.new("a", [9_u64]),
          CrystalClick::WideTupleLeafColumn.new("b", ["control"] of String),
          CrystalClick::WideTupleLeafColumn.new("c", [17] of Int32),
        ] of CrystalClick::WideTupleLeafColumn,
        2
      )
      reader = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      outer_sizes = [] of Int32
      control_values = [] of Array(Int32)
      reader.scan_typed do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.nested_rows_for("payload")
        end
        batch.array_tuple_rows_for("payload").each do |row|
          outer_sizes << row.size
          c_values = [] of Int32
          row.each { |element| c_values << element.value_as("c", Int32) }
          control_values << c_values
        end
        nil
      end
      outer_sizes.should eq([1, 0])
      control_values.should eq([[17] of Int32, [] of Int32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
