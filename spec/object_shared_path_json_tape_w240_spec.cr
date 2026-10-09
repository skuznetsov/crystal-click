require "./spec_helper"

private alias W240SJsonLeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w240s_json_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"typed" => string} of String => CrystalClick::BinaryDataType,
  )
end

private def w240s_child_plan(
  json_type : CrystalClick::BinaryDataType,
  shared_data_version : UInt64,
  bucket_count : UInt64,
) : CrystalClick::ObjectDocumentPlan
  string = CrystalClick::BinaryDataType.primitive("String")
  object = CrystalClick::ObjectStructure.new(
    ["runtime"] of String,
    shared_data_version: shared_data_version,
    bucket_count: bucket_count,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {"runtime" => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    json_type.json_type.not_nil!.typed_paths,
  )
end

private def w240s_json_value(
  type : CrystalClick::BinaryDataType,
  typed : String,
  runtime : String? = nil,
  spill : String? = nil,
) : CrystalClick::BinaryValue
  values = [{"typed", CrystalClick::BinaryValue.string(typed)}] of Tuple(String, CrystalClick::BinaryValue)
  if value = runtime
    values << {"runtime", CrystalClick::BinaryValue.string(value)}
  end
  if value = spill
    values << {"spill", CrystalClick::BinaryValue.string(value)}
  end
  row = CrystalClick::BinaryJsonRow.new(type, values)
  CrystalClick::BinaryValue.json(type, row)
end

private def w240s_values(
  json_type : CrystalClick::BinaryDataType,
  dynamic_type : CrystalClick::BinaryDataType,
) : Array(CrystalClick::BinaryValue)
  array_json = CrystalClick::BinaryDataType.array(json_type)
  [
    CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string("early")),
    CrystalClick::BinaryValue.dynamic(dynamic_type),
    CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue),
    ),
    CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(
        array_json,
        [w240s_json_value(json_type, "late-typed-only")] of CrystalClick::BinaryValue,
      ),
    ),
    CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(
        array_json,
        [
          w240s_json_value(json_type, "no-object-path"),
          w240s_json_value(json_type, "late-runtime", "root-value", "shared-value"),
        ] of CrystalClick::BinaryValue,
      ),
    ),
  ] of CrystalClick::BinaryValue
end

private def w240s_leaf_bindings(
  json_type : CrystalClick::BinaryDataType,
  dynamic_structure : CrystalClick::DynamicStructure,
  child_plan : CrystalClick::ObjectDocumentPlan,
) : Array(W240SJsonLeafPlan)
  array_json = CrystalClick::BinaryDataType.array(json_type)
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    dynamic_structure.canonical_index_for(array_json),
    [0_i32] of Int32,
  )
  [{key, child_plan}] of W240SJsonLeafPlan
end

private def w240s_object_structure_prefix : Bytes
  structure = CrystalClick::ObjectStructure.new([] of String)
  context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, nil, true)
  statistics_offset = CrystalClick::ObjectStructureCodec.write_with_statistics_offset(structure, context)
  complete = context.finish_bytes
  Bytes.new(statistics_offset) { |index| complete[index] }
end

describe "W240 paired Object shared JSON callback tape" do
  it "round-trips typed and root-Dynamic lanes across MAP and MAP_WITH_BUCKETS" do
    json_type = w240s_json_type
    array_json = CrystalClick::BinaryDataType.array(json_type)
    string = CrystalClick::BinaryDataType.primitive("String")
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    dynamic_structure = CrystalClick::DynamicStructure.new(
      [array_json, string] of CrystalClick::BinaryDataType,
    )
    dynamic_structures = {"root" => dynamic_structure} of String => CrystalClick::DynamicStructure
    rows = w240s_values(json_type, dynamic_type)
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    # These values deliberately mix an early ordinary String actual, NULL,
    # an empty Array(JSON), a late pathless JSON row, and a later JSON row
    # carrying both a root-Dynamic String and a shared-MAP String.
    rows[1].is_null?.should be_true
    rows[2].child_at(0).element_count.should eq(0)
    rows[3].child_at(0).child_at(0).json_row.value_for("runtime").should be_nil
    rows[4].child_at(0).child_at(1).json_row.value_for("spill").should_not be_nil

    {0_u64, 1_u64}.each do |shared_version|
      bucket_count = shared_version == 0_u64 ? 1_u64 : 2_u64
      child_plan = w240s_child_plan(json_type, shared_version, bucket_count)
      leaf_bindings = w240s_leaf_bindings(json_type, dynamic_structure, child_plan)

      profiles.each do |profile|
        write_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
          shared_version,
          1,
          profile,
        )
        encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
          dynamic_type,
          dynamic_structures,
          rows,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
          leaf_bindings,
          write_context,
          profile,
        )

        size_callbacks = encoded.events.count { |event| event.name.ends_with?(".size") }
        # The two implicit SharedVariant String arms (outer and child root
        # Dynamic), the outer ordinary String actual, and the child's typed
        # and root-Dynamic ordinary String actuals all use the inherited
        # String profile. The spill value remains in the nested shared
        # envelope, whose source profile is single-stream.
        size_callbacks.should eq(profile.with_size_stream? ? 5 : 0)

        decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
          encoded.data,
          encoded.events,
          rows.size,
          dynamic_type,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
          CrystalClick::ObjectSharedNestedSerializationContext.for_read(shared_version, profile),
          profile,
        )
        decoded.rows.size.should eq(rows.size)
        rows.each_with_index do |expected, index|
          CrystalClick::BinaryValueCodec.encode(decoded.rows[index]).should eq(
            CrystalClick::BinaryValueCodec.encode(expected),
          )
        end
      end
    end
  end

  it "carries advanced child raw callbacks and relocations through the JSON path tape" do
    json_type = w240s_json_type
    array_json = CrystalClick::BinaryDataType.array(json_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    dynamic_structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    structures = {"root" => dynamic_structure} of String => CrystalClick::DynamicStructure
    profile = CrystalClick::BinaryBulkProfile.single_stream

    {2_u64, 3_u64}.each do |shared_version|
      child_plan = w240s_child_plan(json_type, shared_version, 2_u64)
      rows = [
        CrystalClick::BinaryValue.dynamic(
          dynamic_type,
          CrystalClick::BinaryValue.array(
            array_json,
            [w240s_json_value(json_type, "advanced-supported", "root-value", "shared-value")] of CrystalClick::BinaryValue,
          ),
        ),
      ] of CrystalClick::BinaryValue
      encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
        dynamic_type,
        structures,
        rows,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        w240s_leaf_bindings(json_type, dynamic_structure, child_plan),
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(shared_version, 1, profile),
        profile,
      )

      encoded.data_size.should be > 0
      encoded.callback_relocation_count.should be > 0
      event_names = Array(String).new(encoded.event_count)
      encoded.event_count.times do |index|
        event_names << encoded.event_at(index).name
      end
      encoded.callback_relocation_count.times do |index|
        relocation = encoded.callback_relocation_at(index)
        event_names.should contain(relocation.source_callback)
        event_names.should contain(relocation.target_callback)
      end
    end
  end

  it "rejects a further nested JSON typed field while reading an inline child prefix" do
    inner_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"nested" => inner_json} of String => CrystalClick::BinaryDataType,
    )
    physical_prefix = "inline"
    structure_prefix = w240s_object_structure_prefix
    structure_name = CrystalClick::PhysicalStreamName.append_literal(
      physical_prefix,
      ".object_structure",
    )
    tape = CrystalClick::ObjectSharedPathTapeReader.new(
      structure_prefix,
      [CrystalClick::ObjectSharedPathSubstreamEvent.new(structure_name, 0_u64)] of CrystalClick::ObjectSharedPathSubstreamEvent,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    profile = CrystalClick::BinaryBulkProfile.single_stream

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
        tape,
        outer_json,
        CrystalClick::BinaryDynamicJsonLeafKey.new("root", 0, [0_i32] of Int32),
        1,
        physical_prefix,
        physical_prefix,
        0_u64,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    error.message.to_s.should contain("nested JSON typed fields")
  end
end
