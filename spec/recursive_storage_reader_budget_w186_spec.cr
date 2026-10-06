require "./spec_helper"

private def w186_reader_budget_declaration(depth : Int) : String
  declaration = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)").declaration
  depth.times do |index|
    declaration = "Tuple(level#{index} #{declaration})"
  end
  declaration
end

private def w186_reader_budget_value(depth : Int, byte : UInt8) : CrystalClick::StorageColumnValue
  value = CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[byte]
    ),
  }))
  depth.times do
    value = CrystalClick::StorageColumnValue.tuple([value] of CrystalClick::StorageColumnValue)
  end
  value
end

private def w186_reader_budget_object_plan(
  schema : CrystalClick::ObjectDocumentSchema,
) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def with_w186_reader_budget_part(& : String ->)
  parent = File.tempname("crystal-click-w186-reader-budget-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def write_w186_reader_budget_part(parent : String) : Tuple(String, String, CrystalClick::StorageColumnSchema)
  depth = 8
  declaration = w186_reader_budget_declaration(depth)
  schema = CrystalClick::StorageColumnSchema.parse(declaration)
  object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
  plans = {
    schema.json_site_keys[0] => w186_reader_budget_object_plan(object_schema),
  }
  rows = Array(CrystalClick::StorageColumnValue).new(32) do |index|
    w186_reader_budget_value(depth, (index + 1).to_u8)
  end
  keys = Slice(UInt64).new(rows.size) { |index| (index + 1).to_u64 }
  part = File.join(parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_recursive_pair(
    part,
    "pk",
    keys,
    "payload",
    schema,
    plans,
    [rows] of Array(CrystalClick::StorageColumnValue),
    rows_per_mark: 32,
  ).should eq(part)
  {part, declaration, schema}
end

describe "W186 recursive reader codec budget" do
  it "accounts structural Tuple owners under node limits before selected reads" do
    with_w186_reader_budget_part do |parent|
      part, declaration, _schema = write_w186_reader_budget_part(parent)

      # Eight Tuple edges plus the JSON leaf create nine StorageColumnValue
      # owners per row. The leaf codecs alone fit these caps; the structural
      # wrappers do not. Open is intentionally expected to succeed so this
      # isolates the missing selected-read accounting rather than schema parse.
      node_limits = CrystalClick::BinaryCodecLimits.new(16, 320, 4_096, 1_048_576)
      node_schema = CrystalClick::StorageColumnSchema.parse(declaration, node_limits)
      node_reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", node_schema)
      node_reader.read_marks(0, 0).should eq([] of Array(CrystalClick::StorageColumnValue))
      expect_raises(CrystalClick::CorruptPartError) { node_reader.read_marks(0, 1) }
    end
  end

  it "accounts structural Tuple edges under element limits before selected reads" do
    with_w186_reader_budget_part do |parent|
      part, declaration, _schema = write_w186_reader_budget_part(parent)
      edge_limits = CrystalClick::BinaryCodecLimits.new(16, 4_096, 200, 1_048_576)
      edge_schema = CrystalClick::StorageColumnSchema.parse(declaration, edge_limits)
      edge_reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", edge_schema)
      edge_reader.read_marks(0, 0).should eq([] of Array(CrystalClick::StorageColumnValue))
      expect_raises(CrystalClick::CorruptPartError) { edge_reader.read_marks(0, 1) }
    end
  end

  it "preserves the selected logical values when the codec limits are generous" do
    depth = 8
    with_w186_reader_budget_part do |parent|
      part, _declaration, schema = write_w186_reader_budget_part(parent)
      generous = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      decoded = generous.read_marks(0, 1)
      decoded.size.should eq(1)
      decoded[0].size.should eq(32)
      decoded[0].each_with_index do |value, index|
        depth.times { value = value.child_at(0) }
        value.object_document.value_for("t").bytes.should eq(Bytes[(index + 1).to_u8])
      end
    end
  end
end
