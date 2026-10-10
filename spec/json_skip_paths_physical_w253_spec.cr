require "./spec_helper"

private def w253_physical_u8(value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(
    CrystalClick::BinaryDataType.primitive("UInt8"),
    Bytes[value],
  )
end

private def w253_physical_schema : CrystalClick::ObjectDocumentSchema
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::ObjectDocumentSchema.new(
    {"id" => uint8},
    max_dynamic_paths: 2,
    max_dynamic_types: 1,
    skip_paths: ["z", "secret"],
  )
end

private def w253_physical_documents : Array(Array(CrystalClick::ObjectDocument))
  (1_u8..3_u8).map do |value|
    CrystalClick::ObjectDocument.new({
      "id"        => w253_physical_u8(value),
      "secretary" => w253_physical_u8(value + 10_u8),
      "zz"        => w253_physical_u8(value + 20_u8),
    } of String => CrystalClick::BinaryValue)
  end.each_slice(2).map(&.to_a).to_a
end

private def w253_physical_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["secretary", "zz"] of String),
      {
        "secretary" => CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType),
        "zz"        => CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType),
      },
    ),
    schema.typed_paths,
  )
end

private def w253_physical_signature(document : CrystalClick::ObjectDocument) : Array(UInt8)
  ["id", "secretary", "zz"].map { |path| document.value_for(path).byte_at(0) }
end

private def with_w253_physical_root(&)
  root = File.tempname("crystal-click-w253-physical-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "W253 persisted SKIP policy handoff" do
  it "roundtrips schema policy while retaining runtime paths in direct, table, and offline reads" do
    schema = w253_physical_schema
    schema.declaration.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, SKIP secret, SKIP z)")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.declaration.should eq(schema.declaration)
    parsed.max_dynamic_paths.should eq(schema.max_dynamic_paths)
    parsed.max_dynamic_types.should eq(schema.max_dynamic_types)
    parsed.typed_paths.should eq(schema.typed_paths)
    parsed.skip_paths.should eq(["secret", "z"])

    with_w253_physical_root do |root|
      part = File.join(root, "all_1_1_0")
      result = CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64],
        "payload",
        schema,
        w253_physical_plan(schema),
        w253_physical_documents,
        rows_per_mark: 2,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      )
      result.should eq(part)

      expected = [[1_u8, 11_u8, 21_u8], [2_u8, 12_u8, 22_u8], [3_u8, 13_u8, 23_u8]]
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.schema_declaration.should eq(schema.declaration)
      direct = reader.read_marks(0, reader.mark_row_counts.size).flatten.map { |document| w253_physical_signature(document) }
      direct.should eq(expected)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      public_rows = [] of Array(UInt8)
      table.scan_typed_candidate_marks([[0, 1]]) do |batch|
        public_rows.concat(batch.object_documents_for("payload").map { |document| w253_physical_signature(document) })
      end
      public_rows.should eq(expected)

      info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
      candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 3_u64)
      offline = CrystalClick::OfflineTable.new(
        "w253_object",
        "00000000-0000-0000-0000-000000000253",
        "MergeTree",
        [
          CrystalClick::OfflineColumn.new("pk", "UInt64"),
          CrystalClick::OfflineColumn.new("payload", schema.declaration),
        ],
        [candidate],
        "pk",
      )
      offline_rows = offline["payload"].values.map do |value|
        w253_physical_signature(value.as(CrystalClick::ObjectDocument))
      end
      offline_rows.should eq(expected)

      # Omitting the persisted policy is not an equivalent binding, even
      # though the physical reader must not apply scalar RowBinary filtering.
      wrong_schema = CrystalClick::ObjectDocumentSchema.new(
        {"id" => CrystalClick::BinaryDataType.primitive("UInt8")},
        max_dynamic_paths: 2,
        max_dynamic_types: 1,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectColumnReader.open(part, "payload", wrong_schema)
      end
    end
  end
end
