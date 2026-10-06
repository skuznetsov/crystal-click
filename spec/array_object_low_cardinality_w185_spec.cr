require "./spec_helper"

private def w185_array_lc_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w185_array_lc_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String"),
  )
end

private def w185_array_lc_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"label" => w185_array_lc_type},
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w185_array_lc_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(w185_array_lc_empty_structures, schema.typed_paths)
end

private def w185_array_lc_document(value : String) : CrystalClick::ObjectDocument
  type = w185_array_lc_type
  CrystalClick::ObjectDocument.new({
    "label" => CrystalClick::BinaryValue.low_cardinality(
      type,
      CrystalClick::BinaryValue.string(value),
    ),
  } of String => CrystalClick::BinaryValue)
end

private def w185_array_lc_granules : Array(Array(Array(CrystalClick::ObjectDocument)))
  [
    [
      [w185_array_lc_document("oak"), w185_array_lc_document("birch")] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument),
    [
      [] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument),
    [
      [] of CrystalClick::ObjectDocument,
      [w185_array_lc_document("birch"), w185_array_lc_document("cedar")] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument),
  ] of Array(Array(CrystalClick::ObjectDocument))
end

private def w185_array_lc_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def with_w185_array_lc_directory(&)
  parent = File.tempname("crystal-click-w185-array-lc-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W185 Array(JSON) LowCardinality middle-window replay" do
  it "replays the earlier global dictionary across an empty child mark before selected later values" do
    with_w185_array_lc_directory do |parent|
      part = File.join(parent, "all_4_4_0")
      schema = w185_array_lc_schema
      plan = w185_array_lc_plan(schema)
      granules = w185_array_lc_granules
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
      files = CrystalClick::ArrayObjectColumnWriter.encode(
        "a", plan, granules, mode: 0_u64, hashed: true, frame_bytes: 64)
      files.stream_names.should contain("a.size0")

      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        part, "pk", keys, "a", schema, plan, granules,
        rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
      ).should eq(part)

      typed_names = files.physical.typed("label").stream_names
      dictionary_name = typed_names["root.dictionary"]
      indexes_name = typed_names["root.indexes"]
      size_file = "#{CrystalClick::StreamName.hash("a.size0")}.bin"
      dictionary_file = "#{CrystalClick::StreamName.hash(dictionary_name)}.bin"
      indexes_file = "#{CrystalClick::StreamName.hash(indexes_name)}.bin"
      files.file_names.should contain(size_file)
      files.file_names.should contain(dictionary_file)
      files.file_names.should contain(indexes_file)

      # The wrapper schedule has C=[2, 0, 2]. The middle mark is physically
      # present but contributes no LC index record.
      size0 = CrystalClick::CompressedBlock.decode_all(
        files.file_bytes(size_file),
      )
      size0.size.should eq(6 * 8)
      Array.new(size0.size // 8) { |index| w185_array_lc_read_u64(size0, index * 8) }.should eq([
        2_u64, 0_u64,
        0_u64, 0_u64,
        0_u64, 2_u64,
      ])

      dictionary = CrystalClick::CompressedBlock.decode_all(
        files.file_bytes(dictionary_file),
      )
      dictionary.size.should eq(33)
      w185_array_lc_read_u64(dictionary, 0).should eq(1_u64)
      w185_array_lc_read_u64(dictionary, 8).should eq(4_u64)

      # This is a discriminating state test, not merely a selected value
      # round-trip: mark 0 installs one global dictionary, mark 1 has zero
      # bytes, and mark 2 names that same global dictionary without UPDATE.
      indexes = CrystalClick::CompressedBlock.decode_all(
        files.file_bytes(indexes_file),
      )
      indexes.size.should eq(36)
      first_flags = w185_array_lc_read_u64(indexes, 0)
      later_flags = w185_array_lc_read_u64(indexes, 18)
      (first_flags & CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT).should eq(
        CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT,
      )
      (first_flags & CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT).should eq(
        CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT,
      )
      (later_flags & CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT).should eq(
        CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT,
      )
      (later_flags & CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT).should eq(0_u64)

      # Public file payloads are the exact pairs published into the part.
      File.read(File.join(part, size_file)).to_slice.should eq(files.file_bytes(size_file))
      File.read(File.join(part, dictionary_file)).to_slice.should eq(files.file_bytes(dictionary_file))
      File.read(File.join(part, indexes_file)).to_slice.should eq(files.file_bytes(indexes_file))

      reader = CrystalClick::ArrayObjectColumnReader.open(part, "a", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.child_occurrence_row_counts(0, 3).should eq([2_u64, 0_u64, 2_u64])
      selected = reader.read_marks(2, 1)
      selected.size.should eq(1)
      selected[0].size.should eq(2)
      selected[0][0].should be_empty
      selected[0][1].map do |document|
        document.value_for("label").child_at(0).as_string
      end.should eq(["birch", "cedar"])
    end
  end
end
