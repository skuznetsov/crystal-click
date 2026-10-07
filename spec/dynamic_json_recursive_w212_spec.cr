require "./spec_helper"
require "file_utils"

private class W212CountingJsonLeafKey < CrystalClick::BinaryDynamicJsonLeafKey
  getter dynamic_site_reads : Int32
  getter last_returned_site : String?

  def initialize(site : String, canonical_arm_index : Int, descriptor_child_path : Array(Int32))
    super(site, canonical_arm_index, descriptor_child_path)
    @dynamic_site_reads = 0
    @last_returned_site = nil
  end

  def dynamic_site : String
    @dynamic_site_reads += 1
    returned_site = super
    @last_returned_site = returned_site
    returned_site
  end

  def reset_dynamic_site_reads : Nil
    @dynamic_site_reads = 0
    @last_returned_site = nil
  end
end

private def w212_json_type(max_dynamic_types : Int32 = 1) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: max_dynamic_types,
    typed_paths: {"id" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w212_json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w212_object_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

describe "W212 recursive JSON Dynamic actuals" do
  it "hashes the site, canonical arm, and exact child path" do
    hash = ->(key : CrystalClick::BinaryDynamicJsonLeafKey) do
      key.hash(Crystal::Hasher.new(0_u64, 0_u64)).result
    end
    baseline = CrystalClick::BinaryDynamicJsonLeafKey.new("root", 1, [0, 2] of Int32)

    hash.call(baseline).should_not eq(hash.call(CrystalClick::BinaryDynamicJsonLeafKey.new("other", 1, [0, 2] of Int32)))
    hash.call(baseline).should_not eq(hash.call(CrystalClick::BinaryDynamicJsonLeafKey.new("root", 2, [0, 2] of Int32)))
    hash.call(baseline).should_not eq(hash.call(CrystalClick::BinaryDynamicJsonLeafKey.new("root", 1, [0, 3] of Int32)))
  end

  it "keeps exact leaf keys hash-stable when input and accessor bytes mutate" do
    site = String.build { |io| io << "root" }
    path = [0] of Int32
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(site, 1, path)
    bindings = {key => "object-plan"} of CrystalClick::BinaryDynamicJsonLeafKey => String

    site.to_unsafe[0] = 'x'.ord.to_u8
    path[0] = 9
    accessor_site = key.dynamic_site
    accessor_site.to_unsafe[0] = 'y'.ord.to_u8
    key.descriptor_child_path[0] = 8

    lookup = CrystalClick::BinaryDynamicJsonLeafKey.new("root", 1, [0] of Int32)
    bindings[lookup].should eq("object-plan")
    key.dynamic_site.should eq("root")
    key.descriptor_child_path.should eq([0])
  end

  it "sorts plan JSON leaves without requesting detached site strings" do
    json = w212_json_type
    tuple_json_json = CrystalClick::BinaryDataType.tuple(
      [json, json] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([tuple_json_json] of CrystalClick::BinaryDataType)
    structures = {"root" => structure} of String => CrystalClick::DynamicStructure
    arm = structure.canonical_index_for(tuple_json_json)
    left_key = W212CountingJsonLeafKey.new("root", arm, [0_i32])
    right_key = W212CountingJsonLeafKey.new("root", arm, [1_i32])
    leaf_plans = [
      {left_key.as(CrystalClick::BinaryDynamicJsonLeafKey), w212_object_plan(json)},
      {right_key.as(CrystalClick::BinaryDynamicJsonLeafKey), w212_object_plan(json)},
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)

    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: leaf_plans,
    )

    left_key.reset_dynamic_site_reads
    right_key.reset_dynamic_site_reads
    plan.json_object_leaf_keys
    left_key.dynamic_site_reads.should eq(0)
    right_key.dynamic_site_reads.should eq(0)
  end

  it "sorts normalized JSON child streams without requesting detached site strings" do
    json = w212_json_type
    tuple_json_json = CrystalClick::BinaryDataType.tuple(
      [json, json] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([tuple_json_json] of CrystalClick::BinaryDataType)
    structures = {"root" => structure} of String => CrystalClick::DynamicStructure
    arm = structure.canonical_index_for(tuple_json_json)
    left_key = W212CountingJsonLeafKey.new("root", arm, [0_i32])
    right_key = W212CountingJsonLeafKey.new("root", arm, [1_i32])
    leaf_plans = [
      {left_key.as(CrystalClick::BinaryDynamicJsonLeafKey), w212_object_plan(json)},
      {right_key.as(CrystalClick::BinaryDynamicJsonLeafKey), w212_object_plan(json)},
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_json_json, [
      w212_json_value(json, 51_u8),
      w212_json_value(json, 52_u8),
    ] of CrystalClick::BinaryValue)
    values = [[CrystalClick::BinaryValue.dynamic(dynamic, tuple_value)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      structures,
      values,
      json_object_leaf_plans: leaf_plans,
    )

    left_key.reset_dynamic_site_reads
    right_key.reset_dynamic_site_reads
    streams.json_object_leaf_keys
    left_key.dynamic_site_reads.should eq(0)
    right_key.dynamic_site_reads.should eq(0)
  end

  it "rejects an over-budget binding site before requesting its detached string" do
    json = w212_json_type
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(json)
    key = W212CountingJsonLeafKey.new("root", arm, [] of Int32)
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
      max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
      max_bytes: 3,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicJsonObjectBinding.new(
        key,
        structure,
        w212_object_plan(json),
        budget,
      )
    end
    key.dynamic_site_reads.should eq(0)
  end

  it "retains exactly the detached site string returned for a successful binding" do
    json = w212_json_type
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(json)
    key = W212CountingJsonLeafKey.new("root", arm, [] of Int32)
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    binding = CrystalClick::DynamicJsonObjectBinding.new(
      key,
      structure,
      w212_object_plan(json),
      budget,
    )

    key.dynamic_site_reads.should eq(1)
    binding.site_key.to_unsafe.should eq(key.last_returned_site.not_nil!.to_unsafe)
  end

  it "publishes wrapped actuals through the existing complete-part API" do
    json = w212_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    parent_array = CrystalClick::BinaryDataType.array(dynamic)

    structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(array_json)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [0_i32])
    plans = [{key, w212_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    structures = {"root.elements" => structure} of String => CrystalClick::DynamicStructure
    empty_array = CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)
    one_json_array = CrystalClick::BinaryValue.array(array_json, [w212_json_value(json, 11_u8)] of CrystalClick::BinaryValue)
    wrap = ->(actual : CrystalClick::BinaryValue) { CrystalClick::BinaryValue.dynamic(dynamic, actual) }
    granules = [
      [CrystalClick::BinaryValue.array(parent_array, [wrap.call(empty_array)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.array(parent_array, [wrap.call(one_json_array)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    parent = File.tempname("crystal-click-w212-red-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64, 2_u64],
        "payload",
        parent_array,
        structures,
        granules,
        rows_per_mark: 1,
        json_object_leaf_plans: plans,
      ).should eq(part)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "publishes a Tuple(JSON, JSON) actual through the existing complete-part API" do
    json = w212_json_type
    tuple_json_json = CrystalClick::BinaryDataType.tuple(
      [json, json] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    parent_array = CrystalClick::BinaryDataType.array(dynamic)
    structure = CrystalClick::DynamicStructure.new([tuple_json_json] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(tuple_json_json)
    plans = [
      {CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [0_i32]), w212_object_plan(json)},
      {CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [1_i32]), w212_object_plan(json)},
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    structures = {"root.elements" => structure} of String => CrystalClick::DynamicStructure
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_json_json, [
      w212_json_value(json, 41_u8),
      w212_json_value(json, 42_u8),
    ] of CrystalClick::BinaryValue)
    wrapped = CrystalClick::BinaryValue.dynamic(dynamic, tuple_value)
    granules = [[
      CrystalClick::BinaryValue.array(parent_array, [wrapped] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    parent = File.tempname("crystal-click-w212-tuple-red-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[1_u64],
        "payload",
        parent_array,
        structures,
        granules,
        rows_per_mark: 1,
        json_object_leaf_plans: plans,
      ).should eq(part)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects absent, duplicate, and wrong-path wrapped JSON bindings before publication" do
    json = w212_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    parent_array = CrystalClick::BinaryDataType.array(dynamic)
    structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    structures = {"root.elements" => structure} of String => CrystalClick::DynamicStructure
    actual = CrystalClick::BinaryValue.array(array_json, [w212_json_value(json, 31_u8)] of CrystalClick::BinaryValue)
    granules = [[
      CrystalClick::BinaryValue.array(parent_array, [CrystalClick::BinaryValue.dynamic(dynamic, actual)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    arm = structure.canonical_index_for(array_json)
    exact_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [0_i32])
    object_plan = w212_object_plan(json)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        parent_array,
        structures,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        parent_array,
        structures,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_leaf_plans: [{
          CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [1_i32]), object_plan,
        }] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan),
      )
    end

    tuple_type = CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
    tuple_structure = CrystalClick::DynamicStructure.new([tuple_type] of CrystalClick::BinaryDataType)
    tuple_arm = tuple_structure.canonical_index_for(tuple_type)
    left_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", tuple_arm, [0_i32])
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        dynamic,
        {"root" => tuple_structure} of String => CrystalClick::DynamicStructure,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_leaf_plans: [
          {left_key, object_plan},
          {left_key, object_plan},
        ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan),
      )
    end

    parent = File.tempname("crystal-click-w212-unbound-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "unbound_1_1_0")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          Slice[1_u64],
          "payload",
          parent_array,
          structures,
          granules,
          rows_per_mark: 1,
        )
      end
      Dir.exists?(part).should be_false
      exact_key.descriptor_child_path.should eq([0_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "adds inherited Object depth once for a wrapped leaf and rejects one-less typed depth" do
    json = w212_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    structures = {"root" => structure} of String => CrystalClick::DynamicStructure
    arm = structure.canonical_index_for(array_json)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [0_i32])
    plans = [{key, w212_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    wrapped_array = CrystalClick::BinaryValue.array(
      array_json, [w212_json_value(json, 71_u8)] of CrystalClick::BinaryValue,
    )
    values = [[CrystalClick::BinaryValue.dynamic(dynamic, wrapped_array)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic, structures, values, json_object_leaf_plans: plans
    )

    decode_with_depth = ->(max_depth : Int32) do
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: max_depth,
        max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
        max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
        max_bytes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      # Structure plan, wrapper census, Object child, and value traversal all
      # borrow this one operation budget; no sub-owner restarts the allowance.
      budget = CrystalClick::BinaryCodecBudget.new(limits)
      plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        dynamic,
        streams.structures,
        budget,
        CrystalClick::BinaryBulkProfile.single_stream,
        nil,
        plans,
      )
      reader = CrystalClick::BinaryDynamicBulkJsonObjectReader.new(
        plan,
        streams,
        [1_u64],
        budget,
        CrystalClick::BinaryBulkProfile.single_stream,
        initial_descriptor_depth: 3,
      )
      CrystalClick::BinaryBulkDecoder.decode(
        dynamic,
        streams.data,
        [1_u64],
        budget,
        0,
        nil,
        CrystalClick::BinaryBulkProfile.single_stream,
        plan,
        reader,
      )
    end

    decoded = decode_with_depth.call(6_i32)
    decoded[0][0].child_at(0).child_at(0).json_row.value_for("id").not_nil!.byte_at(0).should eq(71_u8)
    expect_raises(CrystalClick::CorruptPartError) do
      decode_with_depth.call(5_i32)
    end
  end
end
