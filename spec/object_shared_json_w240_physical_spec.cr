require "./spec_helper"

private def w240ph_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w240ph_json_value(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w240ph_empty_json_value(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[0_u8])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w240ph_assert_value_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

private def w240ph_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {} of String => CrystalClick::BinaryDataType,
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w240ph_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  bucket_count : UInt64 = 2_u64,
  shared_data_version : UInt64 = 3_u64,
) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_data_version,
    bucket_count: bucket_count,
  )
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w240ph_map_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  shared_data_version : UInt64,
) : CrystalClick::ObjectDocumentPlan
  bucket_count = shared_data_version == 0_u64 ? 1_u64 : 2_u64
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_data_version,
    bucket_count: bucket_count,
  )
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(object, {} of String => CrystalClick::DynamicStructure),
    schema.typed_paths,
  )
end

private def w240ph_policy(
  json_type : CrystalClick::BinaryDataType,
  shared_data_version : UInt64,
  bucket_count : UInt64,
) : CrystalClick::ObjectSharedAdvancedJsonWritePolicy
  array_json = CrystalClick::BinaryDataType.array(json_type)
  child_object = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: shared_data_version,
      bucket_count: bucket_count,
    ),
    {} of String => CrystalClick::DynamicStructure,
  )
  child_plan = CrystalClick::ObjectDocumentPlan.new(child_object, json_type.json_type.not_nil!.typed_paths)
  actual = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
    array_json,
    [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
  )
  CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
    [actual] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
  )
end

private def w240ph_document(value : CrystalClick::BinaryValue? = nil) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields["x"] = value if value
  CrystalClick::ObjectDocument.new(fields)
end

private def w240ph_with_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w240-physical-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent) if Dir.exists?(parent)
  end
end

private def w240ph_lane_input(
  root : String,
  name : String,
  files : CrystalClick::CompressedMarkFiles,
) : CrystalClick::ObjectSharedPhysicalLaneInput
  data_path = File.join(root, "#{name}.bin")
  marks_path = File.join(root, "#{name}.mrk2")
  data = files.data
  marks = files.marks
  File.write(data_path, data)
  File.write(marks_path, marks)
  CrystalClick::ObjectSharedPhysicalLaneInput.new(
    data_path,
    marks_path,
    data.size.to_i64,
    marks.size.to_i64,
  )
end

private def w240ph_bucket_inputs(
  root : String,
  ordinal : Int32,
  files : CrystalClick::ObjectSharedPhysicalBucketFiles,
) : CrystalClick::ObjectSharedPhysicalBucketLaneInputs
  inputs = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
    inputs[lane] = w240ph_lane_input(root, "bucket-#{ordinal}-#{lane}", files.lane(lane))
  end
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(inputs)
end

private def w240ph_chunk_rows(rows : Array(CrystalClick::ObjectSharedMapRow), target : Int32) : Array(UInt64)
  w240ph_chunk_rows(rows, target, rows.size.to_u64)
end

private def w240ph_chunk_rows(
  rows : Array(CrystalClick::ObjectSharedMapRow),
  target : Int32,
  physical_parent_rows : UInt64,
) : Array(UInt64)
  w240ph_with_parent("chunk-schedule") do |parent|
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    files = CrystalClick::ObjectSharedAdvancedDocumentCodec.encode(
      [rows] of Array(CrystalClick::ObjectSharedMapRow),
      [physical_parent_rows] of UInt64,
      3,
      1,
      write_budget,
      CrystalClick::CompressedStreamBudget.write_default,
      shared_target_chunk_rows: target,
    )
    inputs = [w240ph_bucket_inputs(parent, 0, files.bucket_at(0))] of CrystalClick::ObjectSharedPhysicalBucketLaneInputs
    decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
      3,
      inputs[0],
      [physical_parent_rows] of UInt64,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::CompressedStreamBudget.read_default,
    )
    decoded[0].chunks.map(&.row_count)
  end
end

private def w240ph_shared_row(path : String = "x") : CrystalClick::ObjectSharedMapRow
  CrystalClick::ObjectSharedMapRow.new([
    CrystalClick::ObjectSharedMapEntry.new(path.to_slice, CrystalClick::BinaryValue.string("v")),
  ] of CrystalClick::ObjectSharedMapEntry)
end

private def w240ph_write_part(part : String, shared_data_version : UInt64 = 3_u64) : {CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan, CrystalClick::BinaryDataType}
  schema = w240ph_schema
  plan = w240ph_plan(schema, shared_data_version: shared_data_version)
  json = w240ph_json_type
  array_json = CrystalClick::BinaryDataType.array(json)
  first = CrystalClick::BinaryValue.array(
    array_json,
    [w240ph_json_value(json, 7_u8), w240ph_empty_json_value(json)] of CrystalClick::BinaryValue,
  )
  second = CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)
  granules = [
    [w240ph_document(first)] of CrystalClick::ObjectDocument,
    [w240ph_document(second)] of CrystalClick::ObjectDocument,
    [w240ph_document] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "pk",
    Slice[10_u64, 20_u64, 30_u64],
    "payload",
    schema,
    plan,
    granules,
    rows_per_mark: 1,
    shared_json_policy: w240ph_policy(json, shared_data_version, 2_u64),
    shared_target_chunk_rows: 4,
  )
  {schema, plan, array_json}
end

private def w240ph_write_map_part(
  part : String,
  shared_data_version : UInt64,
) : {CrystalClick::ObjectDocumentSchema, CrystalClick::ObjectDocumentPlan, CrystalClick::BinaryDataType, CrystalClick::BinaryDataType}
  schema = w240ph_schema
  plan = w240ph_map_plan(schema, shared_data_version)
  json = w240ph_json_type
  array_json = CrystalClick::BinaryDataType.array(json)
  first = CrystalClick::BinaryValue.array(
    array_json,
    [w240ph_json_value(json, 7_u8), w240ph_empty_json_value(json)] of CrystalClick::BinaryValue,
  )
  second = CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)
  granules = [
    [w240ph_document(first)] of CrystalClick::ObjectDocument,
    [w240ph_document(second)] of CrystalClick::ObjectDocument,
    [w240ph_document] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "pk",
    Slice[10_u64, 20_u64, 30_u64],
    "payload",
    schema,
    plan,
    granules,
    rows_per_mark: 1,
  )
  {schema, plan, json, array_json}
end

describe "W240 physical Object shared JSON paths" do
  it "projects MAP0 and MAP_WITH_BUCKETS through their ordinary shared lanes" do
    [0_u64, 1_u64].each do |version|
      w240ph_with_parent("map-path-#{version}") do |parent|
        part = File.join(parent, "all_1_1_0")
        schema, _plan, json, array_json = w240ph_write_map_part(part, version)
        reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
        selected = reader.read_shared_path_marks("x", 0, 3)
        selected.size.should eq(3)

        dynamic = CrystalClick::BinaryDataType.dynamic(max_types: CrystalClick::DynamicStructure::MAX_ORDINARY_TYPES)
        expected_value = CrystalClick::BinaryValue.dynamic(
          dynamic,
          CrystalClick::BinaryValue.array(
            array_json,
            [w240ph_json_value(json, 7_u8), w240ph_empty_json_value(json)] of CrystalClick::BinaryValue,
          ),
        )
        expected_empty = CrystalClick::BinaryValue.dynamic(
          dynamic,
          CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue),
        )
        w240ph_assert_value_equal!(selected[0][0], expected_value)
        w240ph_assert_value_equal!(selected[1][0], expected_empty)
        selected[2][0].is_null?.should be_true
      end
    end
  end

  it "uses the source-exact persisted CHUNKED row schedule" do
    row_count = 10
    rows = Array(CrystalClick::ObjectSharedMapRow).new(row_count) { w240ph_shared_row }
    w240ph_chunk_rows(rows[0, 9], 4).should eq([4_u64, 5_u64])
    w240ph_chunk_rows(rows, 4).should eq([4_u64, 4_u64, 2_u64])
    w240ph_chunk_rows(rows[0, 5], 2).should eq([2_u64, 2_u64, 1_u64])
    w240ph_chunk_rows([] of CrystalClick::ObjectSharedMapRow, 4, 1_u64).should eq([0_u64])
    expect_raises(CrystalClick::UnsupportedFormatError, /physical parent rows must be positive/) do
      w240ph_chunk_rows([] of CrystalClick::ObjectSharedMapRow, 4, 0_u64)
    end
    w240ph_chunk_rows(rows[0, 1], 4).should eq([1_u64])
  end

  it "rejects a nonpositive public write target before creating a destination" do
    w240ph_with_parent("invalid-target") do |parent|
      part = File.join(parent, "invalid_1_1_0")
      schema = w240ph_schema
      plan = w240ph_plan(schema)
      granules = [[w240ph_document] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument)
      expect_raises(ArgumentError, /target chunk rows must be positive/) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          part,
          "pk",
          Slice[1_u64],
          "payload",
          schema,
          plan,
          granules,
          rows_per_mark: 1,
          shared_target_chunk_rows: 0,
        )
      end
      Dir.exists?(part).should be_false
    end
  end

  it "reads only the selected path without touching the root Copy representation" do
    json = w240ph_json_type
    [2_u64, 3_u64].each do |version|
      w240ph_with_parent("path-only-copy-#{version}") do |parent|
        part = File.join(parent, "all_1_1_0")
        schema, plan, array_json = w240ph_write_part(part, version)
        reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
        selected = reader.read_shared_path_marks("x", 0, 2)
        selected.size.should eq(2)
        selected[0].size.should eq(1)
        selected[1].size.should eq(1)
        dynamic = CrystalClick::BinaryDataType.dynamic(max_types: CrystalClick::DynamicStructure::MAX_ORDINARY_TYPES)
        expected_value = CrystalClick::BinaryValue.dynamic(
          dynamic,
          CrystalClick::BinaryValue.array(
            array_json,
            [w240ph_json_value(json, 7_u8), w240ph_empty_json_value(json)] of CrystalClick::BinaryValue,
          ),
        )
        expected_empty = CrystalClick::BinaryValue.dynamic(
          dynamic,
          CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue),
        )
        w240ph_assert_value_equal!(selected[0][0], expected_value)
        w240ph_assert_value_equal!(selected[1][0], expected_empty)
        missing = reader.read_shared_path_marks("not-present", 0, 1)
        missing[0].size.should eq(1)
        missing[0][0].is_null?.should be_true

        physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
          "payload", plan, CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.single_stream, schema.limits
        )
        copy_path = File.join(part, "#{CrystalClick::StreamName.hash(physical.advanced_copy_stream_name("values"))}.bin")
        corrupted_copy = File.read(copy_path).to_slice.dup
        corrupted_copy[0] = 0_u8
        File.write(copy_path, corrupted_copy)

        # Advanced path reads consume the six bucket lanes, not root Copy;
        # the Copy representation remains a separately validated full view.
        w240ph_assert_value_equal!(reader.read_shared_path_marks("x", 0, 1)[0][0], expected_value)
        expect_raises(CrystalClick::Error) { reader.read_marks(0, 1) }
      end
    end
  end

  it "fails closed on selected Data compressed-frame corruption in both path-only and full reads" do
    w240ph_with_parent("late-data-corruption") do |parent|
      part = File.join(parent, "all_1_1_0")
      schema, plan, _array_json = w240ph_write_part(part)
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
        "payload", plan, CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.single_stream, schema.limits
      )
      bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for("x", physical.shared_bucket_count)
      data_path = File.join(
        part,
        "#{CrystalClick::StreamName.hash(physical.advanced_bucket_stream_name(bucket, "data"))}.bin",
      )
      corrupted_data = File.read(data_path).to_slice.dup
      corrupted_data[0] = 0_u8
      File.write(data_path, corrupted_data)

      expect_raises(CrystalClick::Error) { reader.read_shared_path_marks("x", 0, 1) }
      expect_raises(CrystalClick::Error) { reader.read_marks(0, 1) }
    end
  end
end
