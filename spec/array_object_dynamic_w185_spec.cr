require "./spec_helper"

private def w185ad_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {} of String => CrystalClick::BinaryDataType,
    max_dynamic_paths: 2,
    max_dynamic_types: 1,
  )
end

private def w185ad_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
  actual = CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["d", "e"] of String),
    {"d" => actual, "e" => actual},
  )
  CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
end

private def w185ad_array(strings : Array(String)) : CrystalClick::BinaryValue
  array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
  elements = [] of CrystalClick::BinaryValue
  strings.each { |value| elements << CrystalClick::BinaryValue.string(value) }
  CrystalClick::BinaryValue.array(array_type, elements)
end

private def w185ad_document(
  d : Array(String)?,
  e : Array(String)?,
) : CrystalClick::ObjectDocument
  fields = {} of String => CrystalClick::BinaryValue
  fields["d"] = d ? w185ad_array(d) : CrystalClick::BinaryValue.null
  fields["e"] = e ? w185ad_array(e) : CrystalClick::BinaryValue.null
  CrystalClick::ObjectDocument.new(fields)
end

private def w185ad_array_signature(document : CrystalClick::ObjectDocument, path : String) : String
  return "NULL" unless document.has_path?(path)
  value = document.value_for(path)
  return "NULL" if value.is_null?

  "[#{value.elements.map { |element| element.as_string }.join("|")}]"
end

private def w185ad_signatures(
  marks : Array(Array(Array(CrystalClick::ObjectDocument))),
) : Array(Array(Array(String)))
  marks.map do |rows|
    rows.map do |documents|
      documents.map do |document|
        "d=#{w185ad_array_signature(document, "d")};e=#{w185ad_array_signature(document, "e")}"
      end
    end
  end
end

private def with_w185ad_directory(&)
  parent = File.tempname("crystal-click-w185-array-dynamic-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W185 persisted Array(JSON) Dynamic Array(String) sites" do
  it "keeps per-site discriminator and child state across positive/empty/positive child marks" do
    with_w185ad_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      schema = w185ad_schema
      plan = w185ad_plan(schema)

      mark0 = [
        [
          w185ad_document(["red", "blue"], nil),
          w185ad_document(nil, ["east"]),
        ] of CrystalClick::ObjectDocument,
        [w185ad_document([] of String, ["south", "west"])] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)
      mark1 = [
        [] of CrystalClick::ObjectDocument,
        [] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)
      mark2 = [
        [
          w185ad_document(["green"], nil),
          w185ad_document(nil, ["gold", "silver"]),
        ] of CrystalClick::ObjectDocument,
        [w185ad_document(["violet", "indigo"], [] of String)] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)
      granules = [mark0, mark1, mark2] of Array(Array(CrystalClick::ObjectDocument))
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]

      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        part, "pk", keys, "a", schema, plan, granules,
        rows_per_mark: 2, frame_bytes: 64,
      ).should eq(part)

      reader = CrystalClick::ArrayObjectColumnReader.open(part, "a", schema)
      reader.row_count.should eq(6_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.child_occurrence_row_counts(0, 3).should eq([3_u64, 0_u64, 3_u64])

      expected = [
        [
          ["d=[red|blue];e=NULL", "d=NULL;e=[east]"],
          ["d=[];e=[south|west]"],
        ],
        [[] of String, [] of String],
        [
          ["d=[green];e=NULL", "d=NULL;e=[gold|silver]"],
          ["d=[violet|indigo];e=[]"],
        ],
      ]
      w185ad_signatures(reader.read_marks(0, 3)).should eq(expected)
      # Begin after the earlier positive child mark. The selected window must
      # retain the all-empty middle mark and decode the later site's own data.
      w185ad_signatures(reader.read_marks(1, 2)).should eq(expected[1, 2])

      physical_names = reader.physical_stream_names
      physical_names.should contain("a.size0")
      physical_names.should contain("a.d.Array%28String%29.size1")
      physical_names.should contain("a.e.Array%28String%29.size1")
      physical_names.includes?("a.d.Array%28String%29.size0").should be_false
      physical_names.includes?("a.e.Array%28String%29.size0").should be_false
    end
  end
end
