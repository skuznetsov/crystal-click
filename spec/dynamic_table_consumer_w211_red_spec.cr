require "./spec_helper"

describe "W211 Dynamic table consumer RED" do
  it "opens and scans a writer-authored canonical root Dynamic bulk part" do
    parent = File.tempname("crystal-click-w211-dynamic-table-red-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      structures = {
        "root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
      }
      granules = [
        [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(11_u64))] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)

      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part, "pk", Slice[2_u64, 5_u64], "payload", dynamic, structures, granules,
        rows_per_mark: 1,
      ).should eq(part)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed_rows = 0
      table.scan_typed do |batch|
        observed_rows += batch.values_for("pk", UInt64).size
      end
      observed_rows.should eq(2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
