require "./spec_helper"
require "file_utils"

private def w173_nullable_int32_column(
  name : String,
  values : Array(Int32),
  nulls : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(Int32)").not_nil!
  null_map = CrystalClick::ScalarNullMap.new(nulls.to_unsafe.to_slice(nulls.size), values.size.to_u64)
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, null_map)
end

private def w173_columns(
  a_values : Array(UInt64),
  b_values : Array(String),
  c_values : Array(Int32),
  c_nulls : Array(UInt8),
) : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("a", a_values),
    CrystalClick::WideTupleLeafColumn.new("b", b_values),
    w173_nullable_int32_column("c", c_values, c_nulls),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w173_write_part(
  parent : String,
  label : String,
  type_name : String,
  keys : Array(UInt64),
  row_sizes : Array(UInt64),
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32,
) : String
  container = File.join(parent, label)
  Dir.mkdir(container)
  destination = File.join(container, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
    destination, "pk", keys.to_unsafe.to_slice(keys.size), "nested", type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size), columns, rows_per_mark
  )
end

private def w173_main_fixture(parent : String) : {String, String, Array(UInt64)}
  type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
  row_sizes = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
  columns = w173_columns(
    [101_u64, 103_u64, 211_u64, 307_u64, 311_u64, 317_u64, 409_u64, 419_u64],
    ["oak", "fir", "pine", "redwood", "x", "cedar", "ash", "maple"] of String,
    [1001, 1003, 2011, 3007, 3011, 3017, 4009, 4019] of Int32,
    [0_u8, 1_u8, 0_u8, 1_u8, 0_u8, 0_u8, 1_u8, 0_u8],
  )
  part = w173_write_part(
    parent, "flat-nested", type_name,
    [7_u64, 13_u64, 22_u64, 31_u64, 50_u64], row_sizes, columns, 2
  )
  {part, type_name, row_sizes}
end

describe "W173 explicit flattened Nested storage" do
  it "pairs flat sibling arrays as one nominal Nested reader and validates PK-only selection" do
    parent = File.tempname("crystal-click-w173-flat-reader-")
    Dir.mkdir(parent)
    begin
      part, type_name, sizes = w173_main_fixture(parent)
      File.read(File.join(part, "columns.txt")).should eq(
        "columns format version: 1\n4 columns:\n`pk` UInt64\n`nested.a` Array(UInt64)\n`nested.b` Array(String)\n`nested.c` Array(Nullable(Int32))\n"
      )
      File.read(File.join(part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n4 columns:\n" +
        "1 substreams for column `pk`:\n\tpk\n" +
        "2 substreams for column `nested.a`:\n\tnested.size0\n\tnested%2Ea\n" +
        "3 substreams for column `nested.b`:\n\tnested.size0\n\tnested%2Eb.size\n\tnested%2Eb\n" +
        "3 substreams for column `nested.c`:\n\tnested.size0\n\tnested%2Ec.null\n\tnested%2Ec\n"
      )

      reader = CrystalClick::WidePart.open_flattened_nested(part, "nested", type_name)
      reader.column_type.should eq(type_name)
      reader.source_column_name.should eq("nested")
      reader.row_count.should eq(5_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])

      data = reader.read_nested_mark_range("nested", 0, reader.mark_count)
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
      data.row(3)[2].value_as("c", Int32).should eq(3017)
      data.row(4)[1].value_as("c", Int32).should eq(4019)

      middle = reader.read_nested_mark_range("nested", 1, 1)
      middle.row_sizes.should eq([1_u64, 3_u64])
      middle.row(0)[0].value_as("a", UInt64).should eq(211_u64)
      middle.row(1)[2].value_as("b", String).should eq("cedar")
      expect_raises(CrystalClick::BoundsError) do
        reader.read_nested_mark_range("nested", reader.mark_count, 0)
      end

      keys = CrystalClick::WidePart.open_flattened_nested(part, "nested", type_name, "pk")
      keys.column_type.should eq("UInt64")
      keys.read_uint64_mark_range("pk", 0, keys.mark_count).should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
      keys.mark_row_counts.should eq(reader.mark_row_counts)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "nested")
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "nested.a")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps nonzero outer rows when every flattened sibling has zero elements" do
    parent = File.tempname("crystal-click-w173-flat-empty-elements-")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      part = w173_write_part(
        parent, "empty-elements", type_name, [1_u64, 2_u64, 3_u64],
        [0_u64, 0_u64, 0_u64], w173_columns([] of UInt64, [] of String, [] of Int32, [] of UInt8), 2
      )
      reader = CrystalClick::WidePart.open_flattened_nested(part, "nested", type_name)
      reader.row_count.should eq(3_u64)
      reader.mark_row_counts.should eq([2_u64, 1_u64])
      data = reader.read_nested_mark_range("nested", 0, reader.mark_count)
      data.row_count.should eq(3)
      data.element_count.should eq(0)
      data.row_sizes.should eq([0_u64, 0_u64, 0_u64])
      data.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])
      data.row(0).size.should eq(0)
      data.row(1).size.should eq(0)
      data.row(2).size.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains a later nonempty mark after a wholly empty element mark" do
    parent = File.tempname("crystal-click-w173-flat-empty-first-mark-")
    Dir.mkdir(parent)
    begin
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      part = w173_write_part(
        parent, "empty-first-mark", type_name, [1_u64, 2_u64, 3_u64],
        [0_u64, 0_u64, 1_u64], w173_columns([71_u64], ["later"] of String, [91] of Int32, [0_u8]), 2
      )
      reader = CrystalClick::WidePart.open_flattened_nested(part, "nested", type_name)
      first = reader.read_nested_mark_range("nested", 0, 1)
      first.row_sizes.should eq([0_u64, 0_u64])
      first.element_count.should eq(0)
      later = reader.read_nested_mark_range("nested", 1, 1)
      later.row_sizes.should eq([1_u64])
      later.row(0)[0].value_as("a", UInt64).should eq(71_u64)
      later.row(0)[0].value_as("b", String).should eq("later")
      later.row(0)[0].value_as("c", Int32).should eq(91)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects leaf-cardinality errors before creating a destination" do
    parent = File.tempname("crystal-click-w173-flat-preflight-")
    Dir.mkdir(parent)
    begin
      container = File.join(parent, "bad")
      Dir.mkdir(container)
      destination = File.join(container, "all_1_1_0")
      type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
          destination, "pk", [1_u64, 2_u64].to_unsafe.to_slice(2), "nested", type_name,
          [1_u64, 0_u64].to_unsafe.to_slice(2),
          w173_columns([7_u64, 8_u64], ["too few"] of String, [9] of Int32, [0_u8]), 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(container).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
