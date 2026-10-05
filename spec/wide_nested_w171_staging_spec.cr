require "./spec_helper"
require "file_utils"

# Inert unless enabled by this spec. A valid physical readback is replaced by
# a same-shape result, so rejection must come from nominal/semantic comparison,
# not malformed bytes, checksum failure or an instrument exception.
class CrystalClick::WidePart
  class_property w171_nested_readback_defect = ""
  class_property w171_nested_readback_calls = [] of Tuple(Int32, Int32, String)

  def read_nested_mark_range(
    column : String,
    first_mark : Int,
    mark_count : Int,
    max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
  ) : WideArrayTupleColumnData
    observed = previous_def
    defect = CrystalClick::WidePart.w171_nested_readback_defect
    return observed if defect.empty?
    CrystalClick::WidePart.w171_nested_readback_calls << {
      first_mark.to_i32, mark_count.to_i32, observed.type_name,
    }

    case defect
    when "nominal"
      opposite = WideArrayTupleTypePlan.for_type("Array(Tuple(v UInt64))").not_nil!
      WideArrayTupleColumnData.new(opposite, observed.row_sizes, observed.tuple_data)
    when "value"
      columns = observed.tuple_data.columns
      values = columns[0].physical_values.as(Array(UInt64))
      values[0] = values[0] ^ 1_u64
      columns[0] = WideTupleLeafColumn.new("v", values)
      tuple_data = WideTupleColumnData.new(observed.plan.tuple_plan, columns)
      WideArrayTupleColumnData.new(observed.plan, observed.row_sizes, tuple_data)
    else
      raise "unknown W171 test defect"
    end
  end
end

private def w171s_write(parent : String) : String
  keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
  sizes = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
  values = [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64]
  CrystalClick::WidePartWriter.write_uint64_nested_part(
    File.join(parent, "all_1_1_0"), "pk", keys.to_unsafe.to_slice(keys.size),
    "payload", "Nested(v UInt64)", sizes.to_unsafe.to_slice(sizes.size),
    [CrystalClick::WideTupleLeafColumn.new("v", values)], 2
  )
end

private def w171s_offline_root(parent : String, part : String) : String
  root = File.join(parent, "catalog")
  database_uuid = "17100000-0000-4000-8000-000000000001"
  table_uuid = "17100000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` Nested(v UInt64)\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

describe "W171 Nested staged semantic readback" do
  it "uses the public nominal Nested readback before publication" do
    parent = File.tempname("crystal-click-w171-staged-positive-")
    Dir.mkdir(parent)
    begin
      part = w171s_write(parent)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_nested_mark_range("payload", 0, reader.mark_count)
      data.type_name.should eq("Nested(v UInt64)")
      data.row_sizes.should eq([2_u64, 0_u64, 1_u64, 3_u64, 2_u64])
      data.row(3)[2]["v"].should eq(311_u64)
      Dir.children(parent).should eq(["all_1_1_0"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  ["nominal", "value"].each do |defect|
    it "rejects a same-shape #{defect} defect and removes the stage" do
      parent = File.tempname("crystal-click-w171-staged-#{defect}-")
      Dir.mkdir(parent)
      File.write(File.join(parent, "keep"), "unchanged")
      before = Dir.children(parent).sort
      CrystalClick::WidePart.w171_nested_readback_calls.clear
      CrystalClick::WidePart.w171_nested_readback_defect = defect
      begin
        expect_raises(CrystalClick::CorruptPartError) { w171s_write(parent) }
        CrystalClick::WidePart.w171_nested_readback_calls.should eq([
          {0_i32, 3_i32, "Nested(v UInt64)"},
        ])
        Dir.children(parent).sort.should eq(before)
        File.exists?(File.join(parent, "all_1_1_0")).should be_false
        File.read(File.join(parent, "keep")).should eq("unchanged")
      ensure
        CrystalClick::WidePart.w171_nested_readback_defect = ""
        CrystalClick::WidePart.w171_nested_readback_calls.clear
        FileUtils.rm_rf(parent)
      end
    end
  end
end

describe "W171 Nested consumer nominal boundary" do
  ["Nested ( v UInt64 )", "Array ( Tuple(v UInt64) )"].each do |metadata_type|
    it "preserves legal #{metadata_type} whitespace through table materialization" do
      parent = File.tempname("crystal-click-w171-consumer-whitespace-")
      Dir.mkdir(parent)
      begin
        part = if metadata_type.starts_with?("Nested")
                 w171s_write(parent)
               else
                 keys = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
                 sizes = [2_u64, 0_u64, 1_u64, 3_u64, 2_u64]
                 values = [11_u64, 103_u64, 211_u64, 307_u64, 310_u64, 311_u64, 409_u64, 419_u64]
                 CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
                   File.join(parent, "all_1_1_0"), "pk", keys.to_unsafe.to_slice(keys.size),
                   "payload", "Array(Tuple(v UInt64))", sizes.to_unsafe.to_slice(sizes.size),
                   [CrystalClick::WideTupleLeafColumn.new("v", values)], 2
                 )
               end
        File.write(
          File.join(part, "columns.txt"),
          "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{metadata_type}\n"
        )
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        rows = [] of CrystalClick::WideArrayTupleRow
        table.scan_typed(batch_rows: 2) do |batch|
          batch_rows = if metadata_type.starts_with?("Nested")
                         batch.nested_rows_for("payload")
                       else
                         batch.array_tuple_rows_for("payload")
                       end
          batch_rows.each { |row| rows << row }
          nil
        end
        rows.map(&.size).should eq([2, 0, 1, 3, 2])
        rows[3][2]["v"].should eq(311_u64)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects a same-shape Array result before table callbacks or offline values" do
    parent = File.tempname("crystal-click-w171-consumer-nominal-")
    Dir.mkdir(parent)
    begin
      part = w171s_write(parent)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      offline = CrystalClick::OfflineCatalog.open(w171s_offline_root(parent, part))["lab"]["events"]
      callbacks = 0
      CrystalClick::WidePart.w171_nested_readback_calls.clear
      CrystalClick::WidePart.w171_nested_readback_defect = "nominal"
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 2) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
      expect_raises(CrystalClick::CorruptPartError) { offline["payload"].values }
      CrystalClick::WidePart.w171_nested_readback_calls.should eq([
        {0_i32, 1_i32, "Nested(v UInt64)"},
        {0_i32, 1_i32, "Nested(v UInt64)"},
      ])
    ensure
      CrystalClick::WidePart.w171_nested_readback_defect = ""
      CrystalClick::WidePart.w171_nested_readback_calls.clear
      FileUtils.rm_rf(parent)
    end
  end
end
