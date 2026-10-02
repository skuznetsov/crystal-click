require "./spec_helper"

private def w128_owner_plan : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure),
    {"value" => CrystalClick::BinaryDataType.primitive("UInt64")})
end

private def w128_owner_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"value" => CrystalClick::BinaryDataType.primitive("UInt64")},
    max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w128_owner_rows : Array(Array(CrystalClick::ObjectDocument))
  [[
    CrystalClick::ObjectDocument.new({"value" => CrystalClick::BinaryValue.uint64(11_u64)}),
    CrystalClick::ObjectDocument.new({"value" => CrystalClick::BinaryValue.uint64(12_u64)}),
  ]]
end

private def with_w128_owner_directory(&)
  parent = File.tempname("crystal-click-w128-owner-spec-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W128 Object part writer through its public facade" do
  it "publishes an independently readable normalized Object part from caller-owned rows" do
    with_w128_owner_directory do |parent|
      destination = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        destination, "pk", Slice[2_u64, 7_u64], "payload",
        w128_owner_schema, w128_owner_plan, w128_owner_rows,
        rows_per_mark: 2, frame_bytes: 16)

      File.read(File.join(destination, "count.txt")).should eq("2")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")
      File.read(File.join(destination, "primary.idx")).to_slice.should eq(Bytes[
        2, 0, 0, 0, 0, 0, 0, 0,
        7, 0, 0, 0, 0, 0, 0, 0,
      ])
      rows = CrystalClick::ObjectDocumentFileReader.read(
        destination, "payload", w128_owner_schema.typed_paths, hashed: true)
      rows.size.should eq(1)
      rows[0].size.should eq(2)
      rows[0][0].value_for("value").as_uint64.should eq(11_u64)
      rows[0][1].value_for("value").as_uint64.should eq(12_u64)
      Dir.children(parent).should eq(["part"])
    end
  end

  it "rejects invalid key order and row binding before creating a staging directory" do
    with_w128_owner_directory do |parent|
      destination = File.join(parent, "part")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          destination, "pk", Slice[7_u64, 2_u64], "payload",
          w128_owner_schema, w128_owner_plan, w128_owner_rows,
          rows_per_mark: 2)
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          destination, "pk", Slice[2_u64], "payload",
          w128_owner_schema, w128_owner_plan, w128_owner_rows,
          rows_per_mark: 2)
      end
      Dir.children(parent).should be_empty
    end
  end
end
