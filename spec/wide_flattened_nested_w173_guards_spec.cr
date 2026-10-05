require "./spec_helper"
require "file_utils"

# W173's deliberately small flattened-Nested fixture is produced by the new
# writer. Mutated metadata below is compared against these exact source bytes;
# checksums are never rewritten to bless a malformed part.
W173G_TYPE          = "Nested(a UInt64, b String)"
W173G_COLUMNS       = "columns format version: 1\n3 columns:\n`pk` UInt64\n`n.a` Array(UInt64)\n`n.b` Array(String)\n"
W173G_SUBSTREAMS    = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n3 substreams for column `n.b`:\n\tn.size0\n\tn%2Eb.size\n\tn%2Eb\n"
W173G_SERIALIZATION = %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":5,"exact_num_defaults":true}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})

# Test-only staged-readback corruption. The production reader remains the
# source of the observation; only this W173-scoped switch changes its result.
# previous_def preserves W171's independent staging hook when specs are loaded
# into the same Crystal process.
class CrystalClick::WidePart
  class_property w173_nested_readback_defect = ""
  class_property w173_nested_readback_calls = [] of Tuple(String, Int32, Int32, String)

  def read_nested_mark_range(
    column : String,
    first_mark : Int,
    mark_count : Int,
    max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
  ) : WideArrayTupleColumnData
    observed = previous_def
    defect = CrystalClick::WidePart.w173_nested_readback_defect
    return observed if defect.empty?

    CrystalClick::WidePart.w173_nested_readback_calls << {
      column, first_mark.to_i32, mark_count.to_i32, observed.type_name,
    }
    case defect
    when "nominal"
      opposite = WideArrayTupleTypePlan.for_type("Array(Tuple(a UInt64, b String))").not_nil!
      WideArrayTupleColumnData.new(opposite, observed.row_sizes, observed.tuple_data)
    when "value"
      columns = observed.tuple_data.columns
      values = columns[0].physical_values.as(Array(UInt64))
      values[0] = values[0] ^ 1_u64
      columns[0] = WideTupleLeafColumn.new("a", values)
      tuple_data = WideTupleColumnData.new(observed.plan.tuple_plan, columns)
      WideArrayTupleColumnData.new(observed.plan, observed.row_sizes, tuple_data)
    else
      raise "unknown W173 test defect"
    end
  end
end

private def w173g_new_container(parent : String, label : String) : String
  path = File.join(parent, label)
  Dir.mkdir(path)
  path
end

private def w173g_columns : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("a", [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64]),
    CrystalClick::WideTupleLeafColumn.new("b", ["oak", "fir", "pine", "redwood", "x", "cedar", "ash", "maple"] of String),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w173g_write(
  container : String,
  key_name : String = "pk",
  group_name : String = "n",
  type_name : String = W173G_TYPE,
  row_sizes : Array(UInt64) = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64],
  columns : Array(CrystalClick::WideTupleLeafColumn) = w173g_columns,
) : String
  keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
  destination = File.join(container, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_flattened_nested_part(
    destination,
    key_name,
    keys.to_unsafe.to_slice(keys.size),
    group_name,
    type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size),
    columns,
    2,
  )
end

private def w173g_fixture(parent : String, label : String = "part") : String
  w173g_write(w173g_new_container(parent, label))
end

private def w173g_assert_baseline(part : String) : Nil
  File.read(File.join(part, "columns.txt")).should eq(W173G_COLUMNS)
  File.read(File.join(part, "columns_substreams.txt")).should eq(W173G_SUBSTREAMS)
  File.read(File.join(part, "serialization.json")).should eq(W173G_SERIALIZATION)
end

private def w173g_mutate_metadata(part : String, columns : String, substreams : String) : Nil
  File.read(File.join(part, "columns.txt")).should eq(W173G_COLUMNS)
  File.read(File.join(part, "columns_substreams.txt")).should eq(W173G_SUBSTREAMS)
  File.write(File.join(part, "columns.txt"), columns)
  File.write(File.join(part, "columns_substreams.txt"), substreams)
end

private def w173g_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w173g_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  nil
end

describe "W173 flattened Nested nominal boundary" do
  it "reads the exact root and key while preserving the three-column physical roster" do
    parent = File.tempname("crystal-click-w173-flat-positive-")
    Dir.mkdir(parent)
    begin
      part = w173g_fixture(parent)
      w173g_assert_baseline(part)

      root = CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE)
      root.column_type.should eq(W173G_TYPE)
      data = root.read_nested_mark_range("n", 0, root.mark_count)
      data.type_name.should eq(W173G_TYPE)
      data.row_sizes.should eq([2_u64, 0_u64, 1_u64, 3_u64, 2_u64])
      data.row(0)[1].value_as("a", UInt64).should eq(103_u64)
      data.row(2)[0].value_as("b", String).should eq("pine")
      data.row(3)[2].value_as("b", String).should eq("cedar")
      data.row(4)[1].value_as("a", UInt64).should eq(419_u64)

      key = CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE, "pk")
      key.column_type.should eq("UInt64")
      key.read_uint64_mark_range("pk", 0, key.mark_count).should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not widen ordinary typed or Array(Tuple) APIs to the virtual Nested root" do
    parent = File.tempname("crystal-click-w173-flat-api-closure-")
    Dir.mkdir(parent)
    begin
      part = w173g_fixture(parent)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part, "n")
      end

      nested = CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nested.read_array_tuple_mark_range("n", 0, nested.mark_count)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE, "n.a")
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_flattened_nested(part, "wrong", W173G_TYPE)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_flattened_nested(part, "n", "Array(Tuple(a UInt64, b String))")
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_flattened_nested(part, "n.dotted", W173G_TYPE)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects missing, extra, reordered, and wrong-type flattened siblings" do
    missing_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`n.a` Array(UInt64)\n"
    missing_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n"
    extra_columns = "columns format version: 1\n4 columns:\n`pk` UInt64\n`n.a` Array(UInt64)\n`n.b` Array(String)\n`n.extra` Array(UInt64)\n"
    extra_substreams = "columns substreams version: 1\n4 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n3 substreams for column `n.b`:\n\tn.size0\n\tn%2Eb.size\n\tn%2Eb\n2 substreams for column `n.extra`:\n\tn.size0\n\tn%2Eextra\n"
    reordered_columns = "columns format version: 1\n3 columns:\n`pk` UInt64\n`n.b` Array(String)\n`n.a` Array(UInt64)\n"
    reordered_substreams = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `n.b`:\n\tn.size0\n\tn%2Eb.size\n\tn%2Eb\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n"
    wrong_type_columns = "columns format version: 1\n3 columns:\n`pk` UInt64\n`n.a` Array(UInt64)\n`n.b` Array(UInt64)\n"

    invalid = [
      {"missing sibling", missing_columns, missing_substreams},
      {"extra sibling", extra_columns, extra_substreams},
      {"reordered siblings", reordered_columns, reordered_substreams},
      {"wrong sibling type", wrong_type_columns, W173G_SUBSTREAMS},
    ]
    invalid.each do |_label, columns, substreams|
      parent = File.tempname("crystal-click-w173-flat-schema-")
      Dir.mkdir(parent)
      begin
        part = w173g_fixture(parent)
        w173g_assert_baseline(part)
        w173g_mutate_metadata(part, columns, substreams)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects missing, wrong, and arbitrary repeated shared-size substreams" do
    missing_shared = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n2 substreams for column `n.b`:\n\tn%2Eb.size\n\tn%2Eb\n"
    wrong_shared = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n3 substreams for column `n.b`:\n\tn.b.size0\n\tn%2Eb.size\n\tn%2Eb\n"
    repeated_leaf = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n3 substreams for column `n.b`:\n\tn.size0\n\tn%2Ea\n\tn%2Eb\n"
    repeated_shared_in_one_child = "columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `n.a`:\n\tn.size0\n\tn%2Ea\n4 substreams for column `n.b`:\n\tn.size0\n\tn.size0\n\tn%2Eb.size\n\tn%2Eb\n"

    {missing_shared, wrong_shared, repeated_leaf, repeated_shared_in_one_child}.each do |substreams|
      parent = File.tempname("crystal-click-w173-flat-substreams-")
      Dir.mkdir(parent)
      begin
        part = w173g_fixture(parent)
        w173g_assert_baseline(part)
        w173g_mutate_metadata(part, W173G_COLUMNS, substreams)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "validates the full group and serializer envelope even for key-only selection" do
    parent = File.tempname("crystal-click-w173-flat-key-preflight-")
    Dir.mkdir(parent)
    begin
      part = w173g_fixture(parent)
      w173g_assert_baseline(part)

      # Exact full-string replacement below keeps this fixture mutation honest.
      bad_group_substreams = W173G_SUBSTREAMS.sub("\tn.size0\n\tn%2Ea", "\tn.bogus\n\tn%2Ea")
      w173g_mutate_metadata(part, W173G_COLUMNS, bad_group_substreams)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE, "pk")
      end
    ensure
      FileUtils.rm_rf(parent)
    end

    [nil, "pk"].each do |selected|
      parent = File.tempname("crystal-click-w173-flat-serializer-")
      Dir.mkdir(parent)
      begin
        part = w173g_fixture(parent)
        w173g_assert_baseline(part)
        File.write(
          File.join(part, "serialization.json"),
          W173G_SERIALIZATION.sub("\"version\":1", "\"version\":2")
        )
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE, selected)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects key/root mark-axis disagreement before invoking a row callback" do
    parent = File.tempname("crystal-click-w173-flat-mark-axis-")
    Dir.mkdir(parent)
    begin
      part = w173g_fixture(parent)
      w173g_assert_baseline(part)
      mark_path = File.join(part, "#{CrystalClick::StreamName.hash("pk")}.mrk2")
      CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE, "pk").mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE).mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      marks = File.read(mark_path).to_slice.dup
      marks.size.should eq(4 * CrystalClick::WidePart::MARK_SIZE)
      w173g_read_u64(marks, 3 * CrystalClick::WidePart::MARK_SIZE + 16).should eq(0_u64)
      w173g_write_u64(marks, 16, 1_u64)
      w173g_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
      # The altered primary-key marks still sum to five rows; the corruption is
      # specifically an axis disagreement with Nested's shared size0 marks.
      (0...3).sum { |index| w173g_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16) }.should eq(5_u64)
      File.write(mark_path, marks)

      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePart.open_flattened_nested(part, "n", W173G_TYPE)
        reader.each_nested_mark_range("n", 0, reader.mark_count) do |_data, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps bad cardinality, child shapes, and invalid group ownership out of staging" do
    parent = File.tempname("crystal-click-w173-flat-preflight-")
    Dir.mkdir(parent)
    begin
      cardinality = w173g_new_container(parent, "cardinality")
      expect_raises(ArgumentError) do
        w173g_write(cardinality, row_sizes: [2_u64, 0_u64, 1_u64, 3_u64])
      end
      Dir.children(cardinality).should be_empty

      ["Nested(t Tuple(x UInt64))", "Nested(t Array(UInt64))"].each_with_index do |type_name, index|
        container = w173g_new_container(parent, "child-#{index}")
        values = [CrystalClick::WideTupleLeafColumn.new("t", [17_u64])]
        expect_raises(ArgumentError) do
          w173g_write(
            container,
            type_name: type_name,
            row_sizes: [1_u64],
            columns: values,
          )
        end
        Dir.children(container).should be_empty
      end

      [
        {"dotted", "n.sub", "pk"},
        {"key collision", "n", "n"},
        {"oversized simple group", "g" * (CrystalClick::WidePart::MAX_METADATA_LINE_BYTES + 1), "pk"},
      ].each do |label, group_name, key_name|
        container = w173g_new_container(parent, label.gsub(' ', '-'))
        expect_raises(ArgumentError) do
          w173g_write(container, key_name: key_name, group_name: group_name)
        end
        Dir.children(container).should be_empty
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe "W173 flattened Nested staged semantic readback" do
  ["nominal", "value"].each do |defect|
    it "rejects a same-shape #{defect} defect and does not publish" do
      parent = File.tempname("crystal-click-w173-flat-stage-#{defect}-")
      Dir.mkdir(parent)
      container = w173g_new_container(parent, "destination")
      File.write(File.join(container, "keep"), "unchanged")
      before = Dir.children(container).sort
      CrystalClick::WidePart.w173_nested_readback_calls.clear
      CrystalClick::WidePart.w173_nested_readback_defect = defect
      begin
        expect_raises(CrystalClick::CorruptPartError) { w173g_write(container) }
        CrystalClick::WidePart.w173_nested_readback_calls.should eq([
          {"n", 0_i32, 3_i32, W173G_TYPE},
        ])
        Dir.children(container).sort.should eq(before)
        File.exists?(File.join(container, "all_1_1_0")).should be_false
        File.read(File.join(container, "keep")).should eq("unchanged")
      ensure
        CrystalClick::WidePart.w173_nested_readback_defect = ""
        CrystalClick::WidePart.w173_nested_readback_calls.clear
        FileUtils.rm_rf(parent)
      end
    end
  end
end
