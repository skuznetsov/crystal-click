require "./spec_helper"

private def w195p_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {
      "t"       => CrystalClick::BinaryDataType.primitive("UInt8"),
      "sibling" => CrystalClick::BinaryDataType.primitive("String"),
    },
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w195p_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  version : UInt64,
) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version,
      bucket_count: 2_u64,
    ),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
end

private def w195p_path(bucket : Int32) : String
  candidate = 0
  loop do
    path = "w195-profile-path-#{candidate}"
    return path if CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) == bucket
    candidate += 1
  end
end

private def w195p_document(
  byte : UInt8,
  path : String,
  shared : String,
  typed : String,
) : CrystalClick::ObjectDocument
  fields = {
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[byte]
    ),
    "sibling" => CrystalClick::BinaryValue.string(typed),
  } of String => CrystalClick::BinaryValue
  fields[path] = CrystalClick::BinaryValue.string(shared)
  CrystalClick::ObjectDocument.new(fields)
end

private def with_w195p_part_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w195-profile-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w195p_assert_metadata_profile_zero(part : String) : Nil
  metadata = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  metadata["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
  metadata["types_serialization_versions"].as_h["string"].as_i.should eq(0)
end

private def w195p_path_events(
  part : String,
  physical : CrystalClick::ObjectDocumentPhysicalPlan,
  version : Int,
  expected_path : String,
  limits : CrystalClick::BinaryCodecLimits,
) : Array(String)
  source = CrystalClick::PartStreamSource.new(part)
  expected_parent_rows = [1_u64]
  found_events = nil.as(Array(String)?)

  physical.shared_bucket_count.times do |bucket_index|
    lanes = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
      logical = physical.advanced_bucket_stream_name(bucket_index, lane)
      basename = CrystalClick::StreamName.hash(logical)
      data_name = CrystalClick::PhysicalStreamName.append_literal(basename, ".bin")
      marks_name = CrystalClick::PhysicalStreamName.append_literal(basename, ".mrk2")
      lanes[lane] = source.physical_lane_input(data_name, marks_name)
    end

    parents = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
      version,
      CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lanes),
      expected_parent_rows,
      CrystalClick::BinaryCodecBudget.new(limits),
      CrystalClick::CompressedStreamBudget.read_default,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
    )
    parents.each do |parent_mark|
      parent_mark.chunk_count.times do |chunk_index|
        chunk = parent_mark.chunk_at(chunk_index)
        chunk.path_count.times do |path_index|
          path = chunk.path_at(path_index)
          if path.name == expected_path
            found_events = path.streams.events.map(&.name)
          end
        end
      end
    end
  end

  found_events || raise("expected shared path was absent from decoded ADVANCED buckets")
end

private def w195p_assert_shared_string_uses_profile_zero(
  part : String,
  physical : CrystalClick::ObjectDocumentPhysicalPlan,
  version : Int,
  path : String,
  limits : CrystalClick::BinaryCodecLimits,
) : Nil
  w195p_assert_metadata_profile_zero(part)
  events = w195p_path_events(part, physical, version, path, limits)
  events.any? { |name| name == ".SharedVariant.size" }.should be_false
  events.any? { |name| name == ".SharedVariant" }.should be_true
end

describe "W195 advanced shared String profile propagation" do
  it "uses the persisted single-stream profile in root ADVANCED path data without changing typed String" do
    schema = w195p_schema
    plan = w195p_plan(schema, 2_u64)
    path = w195p_path(0)
    document = w195p_document(7_u8, path, "advanced-value", "typed-root")
    granules = [[document] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument)

    with_w195p_part_parent("root-advanced") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[7_u64],
        "payload",
        schema,
        plan,
        granules,
        rows_per_mark: 1,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part)

      physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
        "payload",
        plan,
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::BinaryBulkProfile.single_stream,
        schema.limits,
      )
      w195p_assert_shared_string_uses_profile_zero(part, physical, 2, path, schema.limits)

      rows = CrystalClick::ObjectColumnReader.open(part, "payload", schema).read_marks(0, 1)
      rows[0][0].value_for("sibling").as_string.should eq("typed-root")
      rows[0][0].value_for(path).as_string.should eq("advanced-value")
    end
  end

  it "uses profile zero for recursive Array(JSON) children while preserving ordinary typed String" do
    schema = w195p_schema
    plan = w195p_plan(schema, 3_u64)
    storage_schema = CrystalClick::StorageColumnSchema.parse("Array(#{schema.declaration})")
    path = w195p_path(1)
    document = w195p_document(9_u8, path, "chunked-array-value", "typed-array")
    array_value = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(document),
    ] of CrystalClick::StorageColumnValue)
    granules = [[array_value] of CrystalClick::StorageColumnValue] of Array(CrystalClick::StorageColumnValue)
    plans = {"root/array[0]" => plan}

    with_w195p_part_parent("array-chunked") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[9_u64],
        "payload",
        storage_schema,
        plans,
        granules,
        rows_per_mark: 1,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        limits: schema.limits,
      ).should eq(part)

      recursive = CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload",
        storage_schema,
        plans,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true,
        limits: schema.limits,
      )
      physical = recursive.object_site_at(0).physical
      w195p_assert_shared_string_uses_profile_zero(part, physical, 3, path, recursive.limits)

      rows = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", storage_schema).read_marks(0, 1)
      root = rows[0][0]
      root.array?.should be_true
      root.child_count.should eq(1)
      child = root.child_at(0).object_document
      child.value_for("sibling").as_string.should eq("typed-array")
      child.value_for(path).as_string.should eq("chunked-array-value")
    end
  end

  it "uses profile zero at a root Tuple JSON site and keeps its typed Tuple sibling intact" do
    object_schema = w195p_schema
    plan = w195p_plan(object_schema, 2_u64)
    path = w195p_path(0)
    document = w195p_document(11_u8, path, "tuple-value", "typed-json-sibling")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(doc #{object_schema.declaration}, sibling String)"
    )
    plans = {"root/tuple[0]" => plan}
    row = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("typed-tuple")),
    ] of CrystalClick::StorageColumnValue)
    granules = [[row] of CrystalClick::StorageColumnValue] of Array(CrystalClick::StorageColumnValue)

    with_w195p_part_parent("tuple-root") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        Slice[11_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part)

      recursive = CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload",
        schema,
        plans,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true,
      )
      physical = recursive.object_site_at(0).physical
      w195p_assert_shared_string_uses_profile_zero(part, physical, 2, path, recursive.limits)

      rows = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema).read_marks(0, 1)
      tuple = rows[0][0]
      tuple.child_at(0).object_document.value_for("sibling").as_string.should eq("typed-json-sibling")
      tuple.child_at(0).object_document.value_for(path).as_string.should eq("tuple-value")
      tuple.child_at(1).bulk_value.as_string.should eq("typed-tuple")
    end
  end
end
