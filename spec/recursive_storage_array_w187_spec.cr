require "./spec_helper"

private def w187_array_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w187_array_plans(schema : CrystalClick::ObjectDocumentSchema) : Hash(String, CrystalClick::ObjectDocumentPlan)
  plan = w187_array_object_plan(schema)
  {
    "root/array[0]/array[0]/tuple[0]" => plan,
    "root/array[0]/array[0]/tuple[1]" => plan,
  }
end

private def with_w187_recursive_array_part_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w187-recursive-array-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w187_array_document(value : UInt8) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value]
    ),
  })
end

private def w187_array_tuple(
  left : CrystalClick::ObjectDocument,
  right : CrystalClick::ObjectDocument,
  sequence : CrystalClick::BinaryValue,
) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(left),
    CrystalClick::StorageColumnValue.object_document(right),
    CrystalClick::StorageColumnValue.bulk(sequence),
  ] of CrystalClick::StorageColumnValue)
end

private def w187_array_valid_tuple(left : UInt8, right : UInt8, sequence : UInt64) : CrystalClick::StorageColumnValue
  w187_array_tuple(
    w187_array_document(left),
    w187_array_document(right),
    CrystalClick::BinaryValue.uint64(sequence),
  )
end

private def w187_array_mixed_granules : Array(Array(CrystalClick::StorageColumnValue))
  first_inner = CrystalClick::StorageColumnValue.array([
    w187_array_valid_tuple(3_u8, 103_u8, 1_003_u64),
  ] of CrystalClick::StorageColumnValue)
  first_root = CrystalClick::StorageColumnValue.array([
    first_inner,
  ] of CrystalClick::StorageColumnValue)

  second_inner = CrystalClick::StorageColumnValue.array([
    w187_array_valid_tuple(7_u8, 107_u8, 1_007_u64),
    w187_array_valid_tuple(8_u8, 108_u8, 1_008_u64),
  ] of CrystalClick::StorageColumnValue)
  second_root = CrystalClick::StorageColumnValue.array([
    CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    second_inner,
  ] of CrystalClick::StorageColumnValue)

  third_root = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
  [
    [first_root] of CrystalClick::StorageColumnValue,
    [second_root] of CrystalClick::StorageColumnValue,
    [third_root] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
end

private def w187_assert_array_tuple(
  value : CrystalClick::StorageColumnValue,
  left : UInt8,
  right : UInt8,
  sequence : UInt64,
) : Nil
  value.tuple?.should be_true
  value.child_count.should eq(3)
  value.child_at(0).object_document.value_for("t").bytes.should eq(Bytes[left])
  value.child_at(1).object_document.value_for("t").bytes.should eq(Bytes[right])
  value.child_at(2).bulk_value.as_uint64.should eq(sequence)
  nil
end

describe "W187 recursive Array/Tuple publication" do
  it "publishes repeated Array(Tuple(JSON, JSON, UInt64)) with independent levels, empty marks, and full/middle reads" do
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Array(Array(Tuple(l #{object_schema.declaration}, r #{object_schema.declaration}, n UInt64)))"
    )
    plans = w187_array_plans(object_schema)
    granules = w187_array_mixed_granules
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, plans, mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    )

    plan.array_site_count.should eq(2)
    outer_site = plan.array_site_at(0)
    inner_site = plan.array_site_at(1)
    {outer_site.key, outer_site.array_level, outer_site.size_name}.should eq({"root", 0_u64, "payload.size0"})
    {inner_site.key, inner_site.array_level, inner_site.size_name}.should eq({"root/array[0]", 1_u64, "payload.size1"})
    plan.object_site_count.should eq(2)
    left_site = plan.object_site_at(0)
    right_site = plan.object_site_at(1)
    {left_site.key, left_site.prefix, left_site.array_level}.should eq({"root/array[0]/array[0]/tuple[0]", "payload%2El", 2_u64})
    {right_site.key, right_site.prefix, right_site.array_level}.should eq({"root/array[0]/array[0]/tuple[1]", "payload%2Er", 2_u64})

    with_w187_recursive_array_part_parent("mixed") do |parent|
      destination = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        destination,
        "pk",
        Slice[10_u64, 20_u64, 30_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      ).should eq(destination)

      reader = CrystalClick::RecursiveStorageColumnReader.open(destination, "payload", schema)
      reader.schema_declaration.should eq(schema.declaration)
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      physical_names = reader.physical_stream_names
      physical_names.should contain("payload.size0")
      physical_names.should contain("payload.size1")
      physical_names.should contain("payload%2El.t")
      physical_names.should contain("payload%2Er.t")
      physical_names.should eq(plan.physical_stream_names)

      full = reader.read_marks(0, 3)
      full.size.should eq(3)
      full.each { |mark| mark.size.should eq(1) }
      root = full[0][0]
      root.array?.should be_true
      root.child_count.should eq(1)
      first_inner = root.child_at(0)
      first_inner.array?.should be_true
      first_inner.child_count.should eq(1)
      w187_assert_array_tuple(first_inner.child_at(0), 3_u8, 103_u8, 1_003_u64)

      root = full[1][0]
      root.child_count.should eq(2)
      root.child_at(0).array?.should be_true
      root.child_at(0).child_count.should eq(0)
      second_inner = root.child_at(1)
      second_inner.child_count.should eq(2)
      w187_assert_array_tuple(second_inner.child_at(0), 7_u8, 107_u8, 1_007_u64)
      w187_assert_array_tuple(second_inner.child_at(1), 8_u8, 108_u8, 1_008_u64)

      full[2][0].array?.should be_true
      full[2][0].child_count.should eq(0)

      middle = reader.read_marks(1, 1)
      middle.size.should eq(1)
      middle[0].size.should eq(1)
      middle_root = middle[0][0]
      middle_root.child_count.should eq(2)
      middle_root.child_at(0).child_count.should eq(0)
      w187_assert_array_tuple(middle_root.child_at(1).child_at(0), 7_u8, 107_u8, 1_007_u64)
      w187_assert_array_tuple(middle_root.child_at(1).child_at(1), 8_u8, 108_u8, 1_008_u64)
    end
  end

  it "retains both Array size levels and typed lanes when every nested child is empty" do
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Array(Array(Tuple(l #{object_schema.declaration}, r #{object_schema.declaration}, n UInt64)))"
    )
    plans = w187_array_plans(object_schema)
    empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
    granules = [
      [empty] of CrystalClick::StorageColumnValue,
      [empty] of CrystalClick::StorageColumnValue,
    ] of Array(CrystalClick::StorageColumnValue)

    with_w187_recursive_array_part_parent("all-empty") do |parent|
      destination = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        destination,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        schema,
        plans,
        granules,
        rows_per_mark: 1,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      )

      reader = CrystalClick::RecursiveStorageColumnReader.open(destination, "payload", schema)
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      names = reader.physical_stream_names
      names.should contain("payload.size0")
      names.should contain("payload.size1")
      names.should contain("payload%2El.t")
      names.should contain("payload%2Er.t")
      rows = reader.read_marks(0, 2)
      rows.size.should eq(2)
      rows.each do |mark|
        mark.size.should eq(1)
        mark[0].array?.should be_true
        mark[0].child_count.should eq(0)
      end
    end
  end

  it "rejects malformed shapes, leaf types, and colliding names before creating a stage" do
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Array(Array(Tuple(l #{object_schema.declaration}, r #{object_schema.declaration}, n UInt64)))"
    )
    plans = w187_array_plans(object_schema)
    good_root = w187_array_mixed_granules[0][0]
    one_mark = [[good_root]] of Array(CrystalClick::StorageColumnValue)
    keys = Slice[1_u64]

    malformed_root = CrystalClick::StorageColumnValue.tuple([] of CrystalClick::StorageColumnValue)
    wrong_bulk_tuple = w187_array_tuple(
      w187_array_document(1_u8),
      w187_array_document(2_u8),
      CrystalClick::BinaryValue.string("not UInt64"),
    )
    wrong_bulk_root = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.array([wrong_bulk_tuple] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue)
    missing_typed_tuple = w187_array_tuple(
      CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue),
      w187_array_document(2_u8),
      CrystalClick::BinaryValue.uint64(2_u64),
    )
    missing_typed_root = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.array([missing_typed_tuple] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue)

    colliding_schema = CrystalClick::StorageColumnSchema.parse(
      "Array(Tuple(`a.b` JSON(t UInt8), a Tuple(b JSON(t UInt8))))"
    )
    colliding_plans = {
      "root/array[0]/tuple[0]"          => w187_array_object_plan(object_schema),
      "root/array[0]/tuple[1]/tuple[0]" => w187_array_object_plan(object_schema),
    }
    empty_root = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
    empty_granules = [[empty_root]] of Array(CrystalClick::StorageColumnValue)

    with_w187_recursive_array_part_parent("fail-before-stage") do |parent|
      malformed_target = File.join(parent, "malformed")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          malformed_target, "pk", keys, "payload", schema, plans,
          [[malformed_root]] of Array(CrystalClick::StorageColumnValue),
          rows_per_mark: 1,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        )
      end
      Dir.children(parent).should be_empty

      wrong_bulk_target = File.join(parent, "wrong-bulk")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          wrong_bulk_target, "pk", keys, "payload", schema, plans,
          [[wrong_bulk_root]] of Array(CrystalClick::StorageColumnValue),
          rows_per_mark: 1,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        )
      end
      Dir.children(parent).should be_empty

      missing_typed_target = File.join(parent, "missing-typed")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          missing_typed_target, "pk", keys, "payload", schema, plans,
          [[missing_typed_root]] of Array(CrystalClick::StorageColumnValue),
          rows_per_mark: 1,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        )
      end
      Dir.children(parent).should be_empty

      collision_target = File.join(parent, "collision")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          collision_target, "pk", keys, "payload", colliding_schema, colliding_plans,
          empty_granules,
          rows_per_mark: 1,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        )
      end
      Dir.children(parent).should be_empty
    end
  end

  it "shares one transport file-byte budget across size and Object lanes before staging" do
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Array(Array(Tuple(l #{object_schema.declaration}, r #{object_schema.declaration}, n UInt64)))"
    )
    plans = w187_array_plans(object_schema)
    granules = w187_array_mixed_granules
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, plans, mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    )
    detached = CrystalClick::RecursiveStorageColumnWriter.encode(plan, granules)

    total_lane_bytes = 0_i64
    largest_lane_bytes = 0_i64
    detached.stream_names.each do |name|
      pair = detached.pair_for(name)
      lane_bytes = pair.data.size.to_i64 + pair.marks.size.to_i64
      total_lane_bytes += lane_bytes
      largest_lane_bytes = {largest_lane_bytes, lane_bytes}.max
    end
    total_lane_bytes.should be > largest_lane_bytes

    with_w187_recursive_array_part_parent("aggregate-transport-cap") do |parent|
      target = File.join(parent, "part")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          target,
          "pk",
          Slice[10_u64, 20_u64, 30_u64],
          "payload",
          schema,
          plans,
          granules,
          rows_per_mark: 1,
          mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_file_bytes: largest_lane_bytes),
        )
      end
      Dir.children(parent).should be_empty
    end
  end
end
