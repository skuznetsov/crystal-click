require "./spec_helper"

private def w128_root_plan : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]),
      {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])}),
    {"t" => CrystalClick::BinaryDataType.primitive("UInt64")})
end

private def w128_root_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt64")},
    max_dynamic_paths: 1, max_dynamic_types: 1)
end

private def w128_root_documents : Array(Array(CrystalClick::ObjectDocument))
  [
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(4_u64), "d" => CrystalClick::BinaryValue.string("a\0b")}),
     CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(5_u64), "x.dot" => CrystalClick::BinaryValue.bool(true)})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(6_u64), "d" => CrystalClick::BinaryValue.int64(-7_i64)})],
  ]
end

private def with_w128_root(&)
  parent = File.tempname("crystal-click-w128-root-spec-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w128_root_write(destination : String, keys : Slice(UInt64) = Slice[1_u64, 1_u64, 9_u64], documents = w128_root_documents) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    destination, "pk", keys, "payload", w128_root_schema, w128_root_plan,
    documents, rows_per_mark: 2, frame_bytes: 16)
end

private def w128_root_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  actual.type.should eq(expected.type)
  actual.is_null?.should eq(expected.is_null?)
  actual.byte_size.should eq(expected.byte_size)
  expected.byte_size.times { |index| actual.byte_at(index).should eq(expected.byte_at(index)) }
  actual.element_count.should eq(expected.element_count)
  expected.element_count.times { |index| w128_root_assert_value(actual.element_at(index), expected.element_at(index)) }
end

private def w128_root_assert_documents(actual : Array(Array(CrystalClick::ObjectDocument)), expected : Array(Array(CrystalClick::ObjectDocument))) : Nil
  actual.size.should eq(expected.size)
  expected.each_with_index do |rows, mark|
    actual[mark].size.should eq(rows.size)
    rows.each_with_index do |document, row|
      found = actual[mark][row]
      paths = document.paths.reject do |path|
        value = document.value_for(path)
        value.type.tag == CrystalClick::BinaryDataType::TAG_NOTHING && value.is_null?
      end
      found.paths.should eq(paths)
      paths.each { |path| w128_root_assert_value(found.value_for(path), document.value_for(path)) }
    end
  end
end

describe "W128 root complete Object part contract" do
  it "owns its schema keys and declaration rather than exposing mutable aliases" do
    path = String.new("t".to_slice)
    fields = {path => CrystalClick::BinaryDataType.primitive("UInt64")}
    schema = CrystalClick::ObjectDocumentSchema.new(fields, max_dynamic_paths: 1, max_dynamic_types: 1)
    fields.clear
    # Strings expose read-only slices; use the unsafe escape hatch only to
    # challenge the ownership boundary, never as a supported mutation API.
    path.to_unsafe[0] = 'x'.ord.to_u8
    schema.typed_paths.keys.should eq(["t"])
    exposed = schema.typed_paths.keys.first
    exposed.to_unsafe[0] = 'y'.ord.to_u8
    declaration = schema.declaration
    declaration.to_unsafe[0] = 'X'.ord.to_u8
    schema.typed_paths.keys.should eq(["t"])
    schema.declaration.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt64)")
  end

  it "creates all part metadata and round-trips the short final granule without any source part" do
    with_w128_root do |parent|
      part = File.join(parent, "all_1_1_0")
      w128_root_write(part).should eq(part)
      File.read(File.join(part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt64)\n")
      File.read(File.join(part, "count.txt")).should eq("3")
      File.read(File.join(part, "metadata_version.txt")).should eq("0")
      File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n9 substreams for column `payload`:\n" +
        "\tpayload.d.SharedVariant\n\tpayload.d.String\n\tpayload.d.dynamic_structure\n\tpayload.d.variant_discr\n" +
        "\tpayload.object_shared_data%2Epaths\n\tpayload.object_shared_data%2Evalues\n\tpayload.object_shared_data.size0\n\tpayload.object_structure\n\tpayload.t\n")
      writable_file_bytes(File.join(part, "primary.idx")).should eq(Bytes[
        1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0])
      info = JSON.parse(File.read(File.join(part, "serialization.json")))
      info["version"].as_i.should eq(1)
      info["types_serialization_versions"]["string"].as_i.should eq(0)
      info["columns"].as_a.size.should eq(1)
      key = info["columns"][0]
      key["name"].as_s.should eq("pk")
      key["kind"].as_s.should eq("Default")
      key["num_rows"].as_i.should eq(3)
      key["num_defaults"].as_i.should eq(0)
      key["exact_num_defaults"].as_bool.should be_true
      actual = CrystalClick::ObjectDocumentFileReader.read(part, "payload", w128_root_schema.typed_paths, hashed: true)
      w128_root_assert_documents(actual, w128_root_documents)
      w128_root_assert_documents(CrystalClick::ObjectDocumentFileReader.read(part, "payload", w128_root_schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true), [w128_root_documents[1]])
      CrystalClick::ObjectDocumentFileReader.read(part, "payload", w128_root_schema.typed_paths, first_mark: 2, mark_count: 0, hashed: true).should be_empty
      files = Dir.children(part)
      files.select { |name| name.ends_with?(".txt") || name.ends_with?(".json") || name == "primary.idx" }.sort.should eq([
        "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json",
      ])
      files.any? { |name| name.starts_with?("statistics") }.should be_false
      files.size.should eq(28) # Nine JSON lanes, key pair and eight sidecars.
      Dir.children(parent).should eq(["all_1_1_0"])
    end
  end

  it "counts default key values independently from row count" do
    with_w128_root do |parent|
      part = File.join(parent, "all_1_1_0")
      w128_root_write(part, Slice[0_u64, 0_u64, 9_u64])
      key = JSON.parse(File.read(File.join(part, "serialization.json")))["columns"][0]
      key["num_defaults"].as_i.should eq(2)
      key["num_rows"].as_i.should eq(3)
    end
  end

  it "compares shared containers semantically and normalizes the untyped NULL sentinel" do
    with_w128_root do |parent|
      array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
      documents = [[CrystalClick::ObjectDocument.new({
        "t"       => CrystalClick::BinaryValue.uint64(4_u64),
        "x.array" => CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.uint64(0_u64), CrystalClick::BinaryValue.uint64(UInt64::MAX)]),
        "x.null"  => CrystalClick::BinaryValue.null,
      })]]
      part = File.join(parent, "all_1_1_0")
      w128_root_write(part, Slice[1_u64], documents)
      actual = CrystalClick::ObjectDocumentFileReader.read(part, "payload", w128_root_schema.typed_paths, hashed: true)
      w128_root_assert_documents(actual, documents)
      actual[0][0].has_path?("x.null").should be_false
    end
  end

  it "rejects order and outer-row binding errors before staging" do
    with_w128_root do |parent|
      target = File.join(parent, "part")
      expect_raises(ArgumentError) { w128_root_write(target, Slice[2_u64, 1_u64, 9_u64]) }
      expect_raises(ArgumentError) { w128_root_write(target, Slice[1_u64, 9_u64]) }
      docs = w128_root_documents
      expect_raises(ArgumentError) { w128_root_write(target, documents: [[docs[0][0]], [docs[0][1], docs[1][0]]]) }
      Dir.children(parent).should be_empty
    end
  end

  it "preserves an existing target and dangling symlink" do
    with_w128_root do |parent|
      target = File.join(parent, "part")
      File.write(target, "keep")
      expect_raises(ArgumentError) { w128_root_write(target) }
      File.read(target).should eq("keep")
      dangling = File.join(parent, "dangling")
      File.symlink(File.join(parent, "missing"), dangling)
      expect_raises(ArgumentError) { w128_root_write(dangling) }
      File.symlink?(dangling).should be_true
      Dir.children(parent).sort.should eq(["dangling", "part"])
    end
  end

  it "rejects schema/capacity and transport failures without publishing or leaving a stage" do
    with_w128_root do |parent|
      target = File.join(parent, "part")
      wrong = CrystalClick::ObjectDocumentSchema.new({"t" => CrystalClick::BinaryDataType.primitive("String")}, max_dynamic_paths: 1, max_dynamic_types: 1)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(target, "pk", Slice[1_u64, 1_u64, 9_u64], "payload", wrong, w128_root_plan, w128_root_documents, rows_per_mark: 2)
      end
      small = CrystalClick::ObjectDocumentSchema.new({"t" => CrystalClick::BinaryDataType.primitive("UInt64")}, max_dynamic_paths: 0, max_dynamic_types: 1)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(target, "pk", Slice[1_u64, 1_u64, 9_u64], "payload", small, w128_root_plan, w128_root_documents, rows_per_mark: 2)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(target, "pk", Slice[1_u64, 1_u64, 9_u64], "payload", w128_root_schema, w128_root_plan, w128_root_documents, rows_per_mark: 2, transport_limits: CrystalClick::CompressedStreamLimits.new(max_result_bytes: 0))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(target, "pk", Slice[1_u64, 1_u64, 9_u64], "payload", w128_root_schema, w128_root_plan, w128_root_documents, rows_per_mark: 2, shared_profile: CrystalClick::BinaryBulkProfile.with_size_stream)
      end
      Dir.children(parent).should be_empty
    end
  end
end
