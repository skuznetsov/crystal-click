require "./spec_helper"

private def w188_recursive_json_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  )
end

private def w188_recursive_object_plan(
  schema : CrystalClick::ObjectDocumentSchema,
  dynamic_type : String,
) : CrystalClick::ObjectDocumentPlan
  dynamic = CrystalClick::DynamicStructure.new([
    CrystalClick::BinaryDataType.primitive(dynamic_type),
  ] of CrystalClick::BinaryDataType)
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => dynamic},
    ),
    schema.typed_paths,
  )
end

private def w188_recursive_plans(
  schema : CrystalClick::ObjectDocumentSchema,
  repeated : Bool,
) : Hash(String, CrystalClick::ObjectDocumentPlan)
  prefix = repeated ? "root/array[0]/array[0]/tuple[" : "root/array[0]/tuple["
  {
    "#{prefix}0]" => w188_recursive_object_plan(schema, "Int64"),
    "#{prefix}1]" => w188_recursive_object_plan(schema, "String"),
  }
end

private def w188_recursive_schema(
  schema : CrystalClick::ObjectDocumentSchema,
  repeated : Bool,
) : CrystalClick::StorageColumnSchema
  inner = "Tuple(l #{schema.declaration}, r #{schema.declaration}, n UInt64)"
  declaration = repeated ? "Array(Array(#{inner}))" : "Array(#{inner})"
  CrystalClick::StorageColumnSchema.parse(declaration)
end

private def w188_recursive_document(
  byte : UInt8,
  dynamic : CrystalClick::BinaryValue,
) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[byte]
    ),
    "d" => dynamic,
  } of String => CrystalClick::BinaryValue)
end

private def w188_recursive_item(
  byte : UInt8,
  left_value : CrystalClick::BinaryValue,
  right_value : CrystalClick::BinaryValue,
) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w188_recursive_document(byte, left_value)),
    CrystalClick::StorageColumnValue.object_document(w188_recursive_document(byte, right_value)),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(byte.to_u64 * 10_u64)),
  ] of CrystalClick::StorageColumnValue)
end

private def w188_recursive_fixtures(repeated : Bool) : Array(Array(CrystalClick::StorageColumnValue))
  empty = [] of CrystalClick::StorageColumnValue
  item_11 = w188_recursive_item(11_u8, CrystalClick::BinaryValue.int64(1_101_i64), CrystalClick::BinaryValue.string("r11"))
  item_21 = w188_recursive_item(21_u8, CrystalClick::BinaryValue.int64(2_101_i64), CrystalClick::BinaryValue.string("r21"))
  item_22 = w188_recursive_item(22_u8, CrystalClick::BinaryValue.null, CrystalClick::BinaryValue.null)
  item_23 = w188_recursive_item(23_u8, CrystalClick::BinaryValue.int64(2_103_i64), CrystalClick::BinaryValue.string("r23"))

  parent = ->(groups : Array(Array(CrystalClick::StorageColumnValue))) {
    if repeated
      inner = groups.map { |items| CrystalClick::StorageColumnValue.array(items) }
      CrystalClick::StorageColumnValue.array(inner)
    else
      items = [] of CrystalClick::StorageColumnValue
      groups.each { |group| items.concat(group) }
      CrystalClick::StorageColumnValue.array(items)
    end
  }

  [
    [parent.call([empty, empty]), parent.call([empty, empty])] of CrystalClick::StorageColumnValue,
    [parent.call([empty, [item_11] of CrystalClick::StorageColumnValue]), parent.call([empty, empty])] of CrystalClick::StorageColumnValue,
    [
      parent.call([[item_21] of CrystalClick::StorageColumnValue, [item_22] of CrystalClick::StorageColumnValue]),
      parent.call([[item_23] of CrystalClick::StorageColumnValue]),
    ] of CrystalClick::StorageColumnValue,
    [parent.call([empty, empty]), parent.call([empty, empty])] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
end

private def w188_recursive_assert_item(
  value : CrystalClick::StorageColumnValue,
  byte : UInt8,
  left_value : Int64?,
  right_value : String?,
) : Nil
  value.tuple?.should be_true
  value.child_count.should eq(3)
  left = value.child_at(0).object_document
  right = value.child_at(1).object_document
  left.value_for("t").byte_at(0).should eq(byte)
  right.value_for("t").byte_at(0).should eq(byte)
  if expected = left_value
    left.value_for("d").as_int64.should eq(expected)
  else
    left.has_path?("d").should be_false
  end
  if expected = right_value
    right.value_for("d").as_string.should eq(expected)
  else
    right.has_path?("d").should be_false
  end
  value.child_at(2).bulk_value.as_uint64.should eq(byte.to_u64 * 10_u64)
  nil
end

private def w188_recursive_part(repeated : Bool, label : String, & : String ->)
  parent = File.tempname("crystal-click-w188-recursive-#{label}-")
  Dir.mkdir(parent)
  schema = w188_recursive_json_schema
  column_schema = w188_recursive_schema(schema, repeated)
  plans = w188_recursive_plans(schema, repeated)
  destination = File.join(parent, "part")

  # Deliberately omit `mode`: the public recursive writer's persisted default
  # is COMPACT, including when Dynamic leaves are below one or more Arrays.
  CrystalClick::WidePartWriter.write_uint64_recursive_pair(
    destination,
    "pk",
    Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64],
    "payload",
    column_schema,
    plans,
    w188_recursive_fixtures(repeated),
    rows_per_mark: 2,
  ).should eq(destination)

  yield destination
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w188_recursive_read_item(
  root : CrystalClick::StorageColumnValue,
  repeated : Bool,
  item_index : Int,
  group_index : Int = 0,
) : CrystalClick::StorageColumnValue
  if repeated
    root.child_at(group_index).child_at(item_index)
  else
    root.child_at(item_index)
  end
end

private def w188_assert_recursive_compact_round_trip(repeated : Bool) : Nil
  schema = w188_recursive_json_schema
  column_schema = w188_recursive_schema(schema, repeated)
  plans = w188_recursive_plans(schema, repeated)
  plan = CrystalClick::RecursiveStorageColumnPlan.for_column("payload", column_schema, plans)
  plan.mode.should eq(CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE)
  plan.object_site_count.should eq(2)

  if repeated
    plan.array_site_count.should eq(2)
    plan.array_site_at(0).size_name.should eq("payload.size0")
    plan.array_site_at(1).size_name.should eq("payload.size1")
    plan.object_site_at(0).array_level.should eq(2_u64)
  else
    plan.array_site_count.should eq(1)
    plan.array_site_at(0).size_name.should eq("payload.size0")
    plan.object_site_at(0).array_level.should eq(1_u64)
  end

  w188_recursive_part(repeated, "compact-#{repeated}") do |part|
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", column_schema)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    names = reader.physical_stream_names
    names.should contain("payload%2El.t")
    names.should contain("payload%2Er.t")
    names.should contain("payload.size0")
    left_site = plan.object_site_at(0)
    right_site = plan.object_site_at(1)
    names.should contain(left_site.physical.dynamic_structure_stream("d"))
    names.should contain(right_site.physical.dynamic_structure_stream("d"))
    names.should contain(left_site.physical.discriminator_stream("d"))
    names.should contain(right_site.physical.discriminator_stream("d"))
    left_shared_names = left_site.physical.shared.stream_names.values
    right_shared_names = right_site.physical.shared.stream_names.values
    left_shared_names.any?(&.ends_with?("size#{left_site.array_level}")).should be_true
    right_shared_names.any?(&.ends_with?("size#{right_site.array_level}")).should be_true
    names.should contain("payload.size1") if repeated

    full = reader.read_marks(0, 4)
    full.map(&.size).should eq([2, 2, 2, 2])
    if repeated
      full.map { |mark| mark.map(&.child_count) }.should eq([
        [2, 2], [2, 2], [2, 1], [2, 2],
      ])
    else
      full.map { |mark| mark.map(&.child_count) }.should eq([
        [0, 0], [1, 0], [2, 1], [0, 0],
      ])
    end
    item_11 = w188_recursive_read_item(full[1][0], repeated, 0, 1)
    w188_recursive_assert_item(item_11, 11_u8, 1_101_i64, "r11")
    item_21 = w188_recursive_read_item(full[2][0], repeated, 0, 0)
    item_22 = if repeated
                w188_recursive_read_item(full[2][0], true, 0, 1)
              else
                w188_recursive_read_item(full[2][0], false, 1)
              end
    item_23 = w188_recursive_read_item(full[2][1], repeated, 0, 0)
    w188_recursive_assert_item(item_21, 21_u8, 2_101_i64, "r21")
    w188_recursive_assert_item(item_22, 22_u8, nil, nil)
    w188_recursive_assert_item(item_23, 23_u8, 2_103_i64, "r23")

    if repeated
      full[2][0].child_count.should eq(2)
      full[2][0].child_at(0).child_count.should eq(1)
      full[2][0].child_at(1).child_count.should eq(1)
      full[2][1].child_at(0).child_count.should eq(1)
    end

    middle = reader.read_marks(1, 2)
    if repeated
      middle.map { |mark| mark.map(&.child_count) }.should eq([[2, 2], [2, 1]])
    else
      middle.map { |mark| mark.map(&.child_count) }.should eq([[1, 0], [2, 1]])
    end
    middle_item_22 = if repeated
                      w188_recursive_read_item(middle[1][0], true, 0, 1)
                    else
                      w188_recursive_read_item(middle[1][0], false, 1)
                    end
    w188_recursive_assert_item(middle_item_22, 22_u8, nil, nil)
    reader.read_marks(4, 0).should be_empty
  end
  nil
end

describe "W188 recursive Array COMPACT discriminator composition" do
  it "round trips the default COMPACT mode under one Array with C=[0,1,3,0]" do
    w188_assert_recursive_compact_round_trip(false)
  end

  it "round trips the default COMPACT mode under repeated Arrays with C=[0,1,3,0]" do
    w188_assert_recursive_compact_round_trip(true)
  end
end
