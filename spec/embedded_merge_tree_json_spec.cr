require "./spec_helper"

def with_embedded_json_table_parent(&)
  parent = File.tempname("crystal-click-embedded-json-spec")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

def embedded_json_rows(table : CrystalClick::EmbeddedMergeTreeTable) : Array({UInt64, String, UInt64, Int64, UInt8})
  rows = [] of {UInt64, String, UInt64, Int64, UInt8}
  table.scan_typed(["pk", "record.kind", "record.size", "record.signed", "record.present"], batch_rows: 1) do |batch|
    keys = batch.values_for("pk", UInt64)
    kinds = batch.strings_for("record.kind")
    sizes = batch.values_for("record.size", UInt64)
    signed = batch.values_for("record.signed", Int64)
    present = batch.values_for("record.present", UInt8)
    keys.size.should eq(kinds.size)
    keys.size.should eq(sizes.size)
    keys.size.should eq(signed.size)
    keys.size.should eq(present.size)
    keys.size.times { |index| rows << {keys[index], kinds[index], sizes[index], signed[index], present[index]} }
  end
  rows
end

describe CrystalClick::EmbeddedMergeTreeTable do
  it "creates a declared JSON schema and emits native JSON typed-path columns" do
    with_embedded_json_table_parent do |parent|
      root = File.join(parent, "table")
      paths = [
        {"kind", "String"},
        {"size", "UInt64"},
      ]
      table = CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", "record", paths)

      table.json_paths.should eq(paths)
      table.value_type.should eq("JSON(kind String, size UInt64)")
      File.read(File.join(root, "manifest.json")).should contain("\"format_version\":2")

      columns = [
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["alpha", "beta"]),
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [10_u64, 20_u64]),
      ]
      table.insert_json([1_u64, 2_u64].to_unsafe.to_slice(2), columns, rows_per_mark: 1)

      part = File.join(root, "parts", "all_1_1_0")
      File.read(File.join(part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`record` JSON(kind String, size UInt64)\n"
      )
    end
  end

  it "merges equal keys stably and preserves declared typed paths after reopen and reclaim" do
    with_embedded_json_table_parent do |parent|
      root = File.join(parent, "table")
      paths = [{"kind", "String"}, {"present", "UInt8"}, {"signed", "Int64"}, {"size", "UInt64"}]
      table = CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", "record", paths)
      table.insert_json(
        [1_u64, 2_u64, 2_u64].to_unsafe.to_slice(3),
        [
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["left-one", "left-two-a", "left-two-b"]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("present", "UInt8", [1_u8, 3_u8, 5_u8]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("signed", "Int64", [-10_i64, -20_i64, -21_i64]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [10_u64, 20_u64, 21_u64]),
        ],
        rows_per_mark: 1
      ).should eq("all_1_1_0")
      table.insert_json(
        [2_u64, 2_u64, 3_u64].to_unsafe.to_slice(3),
        [
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["right-two-a", "right-two-b", "right-three"]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("present", "UInt8", [7_u8, 9_u8, 11_u8]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("signed", "Int64", [22_i64, 23_i64, 30_i64]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [22_u64, 23_u64, 30_u64]),
        ],
        rows_per_mark: 2
      ).should eq("all_2_2_0")

      table.merge_adjacent("all_1_1_0", "all_2_2_0", rows_per_mark: 2).should eq("all_1_2_1")
      expected = [
        {1_u64, "left-one", 10_u64, -10_i64, 1_u8},
        {2_u64, "left-two-a", 20_u64, -20_i64, 3_u8},
        {2_u64, "left-two-b", 21_u64, -21_i64, 5_u8},
        {2_u64, "right-two-a", 22_u64, 22_i64, 7_u8},
        {2_u64, "right-two-b", 23_u64, 23_i64, 9_u8},
        {3_u64, "right-three", 30_u64, 30_i64, 11_u8},
      ]
      embedded_json_rows(table).should eq(expected)

      reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened.value_type.should eq("JSON(kind String, present UInt8, signed Int64, size UInt64)")
      reopened.json_paths.should eq(paths)
      embedded_json_rows(reopened).should eq(expected)
      reopened.reclaim_obsolete!
      reopened.part_paths.map(&.split('/').last).should eq(["all_1_2_1"])
      embedded_json_rows(reopened).should eq(expected)
    end
  end

  it "rejects invalid or mismatched JSON schema before publishing a part" do
    with_embedded_json_table_parent do |parent|
      root = File.join(parent, "table")
      expect_raises(ArgumentError) do
        CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", "record", [{"same", "String"}, {"same", "UInt64"}])
      end
      File.exists?(root).should be_false
      Dir.children(parent).should be_empty

      table = CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", "record", [{"kind", "String"}, {"size", "UInt64"}])
      wrong_paths = [CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["value"])]
      expect_raises(ArgumentError) do
        table.insert_json([1_u64].to_unsafe.to_slice(1), wrong_paths, rows_per_mark: 1)
      end
      wrong_value_type = [
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["value"]),
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [10_i64]),
      ]
      expect_raises(ArgumentError) do
        table.insert_json([1_u64].to_unsafe.to_slice(1), wrong_value_type, rows_per_mark: 1)
      end
      wrong_row_count = [
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["one", "two"]),
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [10_u64]),
      ]
      expect_raises(ArgumentError) do
        table.insert_json([1_u64, 2_u64].to_unsafe.to_slice(2), wrong_row_count, rows_per_mark: 1)
      end
      expect_raises(ArgumentError) do
        table.insert([1_u64].to_unsafe.to_slice(1), ["wrong-schema"].to_unsafe.to_slice(1), rows_per_mark: 1)
      end
      Dir.children(File.join(root, "parts")).should be_empty
      Dir.children(File.join(root, "committed")).should be_empty

      manifest_path = File.join(root, "manifest.json")
      File.write(manifest_path, "{\"format_version\":2,\"key_name\":\"pk\",\"key_type\":\"UInt64\",\"partition\":\"all\",\"value_name\":\"record\",\"value_type\":\"JSON(kind String)\"}\n")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::EmbeddedMergeTreeTable.open(root)
      end
    end
  end

  it "rejects a committed part whose physical JSON declaration differs from the table manifest" do
    with_embedded_json_table_parent do |parent|
      root = File.join(parent, "table")
      table = CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", "record", [{"kind", "String"}, {"size", "UInt64"}])
      table.insert_json(
        [1_u64].to_unsafe.to_slice(1),
        [
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("kind", "String", ["present"]),
          CrystalClick::WidePartWriter::JSONTypedPathColumn.new("size", "UInt64", [1_u64]),
        ],
        rows_per_mark: 1
      )
      columns_path = File.join(root, "parts", "all_1_1_0", "columns.txt")
      File.write(columns_path, "columns format version: 1\n2 columns:\n`pk` UInt64\n`record` JSON(kind String)\n")

      expect_raises(CrystalClick::UnsupportedFormatError) { table.part_paths }
    end
  end

  it "bounds complete metadata and reopens a schema near the accepted substream limit" do
    with_embedded_json_table_parent do |parent|
      value_name = "v" * 128
      overlong_paths = Array(Tuple(String, String)).new(10) do |index|
        {"p#{index.to_s.rjust(2, '0')}_#{"x" * 97}", "String"}
      end
      rejected_root = File.join(parent, "rejected")
      expect_raises(ArgumentError, /substream metadata/) do
        CrystalClick::EmbeddedMergeTreeTable.create_json(rejected_root, "pk", value_name, overlong_paths)
      end
      File.exists?(rejected_root).should be_false

      near_limit_paths = Array(Tuple(String, String)).new(8) do |index|
        {"p#{index.to_s.rjust(2, '0')}_#{"x" * 62}", "String"}
      end
      root = File.join(parent, "near-limit")
      table = CrystalClick::EmbeddedMergeTreeTable.create_json(root, "pk", value_name, near_limit_paths)
      columns = near_limit_paths.map do |name, _type|
        CrystalClick::WidePartWriter::JSONTypedPathColumn.new(name, "String", [name])
      end
      table.insert_json([1_u64].to_unsafe.to_slice(1), columns, rows_per_mark: 1)

      reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
      reopened.part_paths.size.should eq(1)
      reopened.json_paths.should eq(near_limit_paths.sort_by(&.[0]))
      substreams_bytes = File.size(File.join(root, "parts", "all_1_1_0", "columns_substreams.txt"))
      substreams_bytes.should be > 3_900
      substreams_bytes.should be <= CrystalClick::EmbeddedMergeTreeTable::MAX_METADATA_BYTES
    end
  end
end
