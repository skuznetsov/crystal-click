require "./spec_helper"

# This spec-level resolver models the already-relocated logical positions in a
# detached callback tape. It exercises recursive capture/materialization only;
# it is not evidence for Compact's physical mrk3/mrk4 coordinate mapping.
private class W263TapeCoordinateContext < CrystalClick::ObjectSharedInlineCoordinateContext
  @data : Bytes

  def initialize(@data : Bytes)
  end

  def path_data_size : Int64
    @data.size.to_i64
  end

  def validate_path_bytes!(relative_start : UInt64, bytes : Bytes, budget : CrystalClick::BinaryCodecBudget) : Nil
    if relative_start > @data.size.to_u64 || bytes.size.to_u64 > @data.size.to_u64 - relative_start
      raise CrystalClick::CorruptPartError.new("test callback bytes exceed their logical tape")
    end
    budget.ensure_wire_bytes(bytes.size.to_u64)
    budget.charge_wire_bytes(bytes.size.to_u64) if bytes.size > 0
    bytes.each_with_index do |byte, index|
      unless @data[(relative_start + index.to_u64).to_i] == byte
        raise CrystalClick::CorruptPartError.new("test callback bytes differ from their logical tape")
      end
    end
    nil
  end

  def callback_position(
    pair : Tuple(UInt64, UInt64),
    relative_start : UInt64,
    relative_end : UInt64,
    allow_terminal : Bool,
  ) : Int64?
    return nil unless pair[0] == 0_u64
    absolute = pair[1]
    return nil if absolute < relative_start
    return nil if allow_terminal ? absolute > relative_end : absolute >= relative_end
    (absolute - relative_start).to_i64
  end

  def same_path?(other : CrystalClick::ObjectSharedInlineCoordinateContext) : Bool
    other.same?(self)
  end
end

private def w263_write_u64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w263_stream_with_logical_relocations(
  data : Bytes,
  events : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
  relocations : Array(CrystalClick::ObjectSharedInlineCallbackRelocation),
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectSharedPathStreams
  starts = Hash(String, UInt64).new(initial_capacity: events.size)
  events.each do |event|
    starts[event.name] = event.relative_offset
  end

  # The in-memory writer intentionally returns unresolved coordinate fields.
  # Resolve its sidecar into this test tape's single logical coordinate domain
  # so the ordinary reader/materializer can be exercised without claiming an
  # on-disk Compact mark representation.
  relocations.each do |relocation|
    source_start = starts[relocation.source_callback]? ||
                   raise("test relocation source is absent from the callback tape")
    target_start = starts[relocation.target_callback]? ||
                   raise("test relocation target is absent from the callback tape")
    source_offset = (source_start + relocation.source_offset).to_i
    target_offset = target_start + relocation.target_offset
    w263_write_u64_le(data, source_offset, 0_u64)
    w263_write_u64_le(data, source_offset + 8, target_offset)
  end

  coordinate_context = W263TapeCoordinateContext.new(data)
  CrystalClick::ObjectSharedPathStreams.new(
    data,
    events,
    coordinate_context,
    [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
    budget,
  )
end

private def w263_stream_from_callbacks(
  prefixes : Array(Tuple(String, Bytes)),
  bodies : Array(Tuple(String, Bytes)),
  relocations : Array(CrystalClick::ObjectSharedInlineCallbackRelocation),
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectSharedPathStreams
  callbacks = prefixes.dup
  callbacks.concat(bodies)
  byte_count = 0
  callbacks.each { |callback| byte_count += callback[1].size }
  data = Bytes.new(byte_count)
  events = Array(CrystalClick::ObjectSharedPathSubstreamEvent).new(callbacks.size)
  offset = 0
  callbacks.each do |name, bytes|
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(name, offset.to_u64)
    bytes.each do |byte|
      data[offset] = byte
      offset += 1
    end
  end
  w263_stream_with_logical_relocations(data, events, relocations, budget)
end

private def w263_json_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"typed" => string} of String => CrystalClick::BinaryDataType,
  )
end

private def w263_child_plan(
  json_type : CrystalClick::BinaryDataType,
  version : UInt64,
) : CrystalClick::ObjectDocumentPlan
  string = CrystalClick::BinaryDataType.primitive("String")
  object = CrystalClick::ObjectStructure.new(
    ["runtime"] of String,
    shared_data_version: version,
    bucket_count: 2_u64,
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

private def w263_json_value(
  type : CrystalClick::BinaryDataType,
  typed : String,
  runtime : String? = nil,
  shared : String? = nil,
) : CrystalClick::BinaryValue
  fields = [{"typed", CrystalClick::BinaryValue.string(typed)}] of Tuple(String, CrystalClick::BinaryValue)
  if value = runtime
    fields << {"runtime", CrystalClick::BinaryValue.string(value)}
  end
  if value = shared
    fields << {"shared", CrystalClick::BinaryValue.string(value)}
  end
  CrystalClick::BinaryValue.json(type, CrystalClick::BinaryJsonRow.new(type, fields))
end

private def w263_json_leaf_bindings(
  json_type : CrystalClick::BinaryDataType,
  dynamic_structure : CrystalClick::DynamicStructure,
  child_plan : CrystalClick::ObjectDocumentPlan,
) : Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))
  array_json = CrystalClick::BinaryDataType.array(json_type)
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    dynamic_structure.canonical_index_for(array_json),
    [0_i32] of Int32,
  )
  [{key, child_plan}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
end

private def w263_empty_advanced_plan(version : UInt64) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version,
      bucket_count: 2_u64,
    ),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
end

private def w263_static_foreign_owner_fixture(version : UInt64)
  profile = CrystalClick::BinaryBulkProfile.single_stream
  # Independently authored Complete statistics, two shared buckets, and no
  # Dynamic paths. This keeps the fixture keyless and free of an inline
  # schedule registry.
  data = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, version.to_u8, 2, 0]
  events = [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.object_structure", 0_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  tape = CrystalClick::ObjectSharedPathTapeReader.new(data, events, budget)
  json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
  nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(version, profile)
  prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
    tape,
    json_type,
    1_i32,
    ".child",
    ".child",
    0_u64,
    nested_context,
    budget,
  )
  tape.finish!

  prefix.should_not be_a(CrystalClick::ObjectDocumentInlinePrefix)
  prefix.statistics_context.should eq(CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::Complete)
  prefix.structures.object.shared_data_version.should eq(version)
  prefix.structures.object.bucket_count.should eq(2_u64)
  expect_raises(ArgumentError, "Object callback body role schedule is not bound") do
    prefix.body_role_bindings
  end
  expect_raises(ArgumentError, "Object callback body role identities are not bound") do
    prefix.body_callback_pairs
  end
  expect_raises(ArgumentError, "Object body callbacks are not completely captured") do
    prefix.body_callback_count
  end

  physical_a = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix.physical_prefix,
    prefix.plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    budget.limits,
    prefix.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
  physical_b = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix.physical_prefix,
    prefix.plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    budget.limits,
    prefix.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
  physical_a.same?(physical_b).should be_false
  prefix.bind_physical_plan!(physical_a)
  grid = CrystalClick::StorageOccurrenceGrid.new(
    [1_u64] of UInt64,
    [0_u64] of UInt64,
    budget,
  )

  {
    prefix:     prefix,
    physical_b: physical_b,
    grid:       grid,
    budget:     budget,
  }
end

describe "W263 recursive advanced decoder contract" do
  it "materializes recursive Array(JSON) children with typed, Dynamic and shared values for v2 and v3" do
    profile = CrystalClick::BinaryBulkProfile.single_stream

    {2_u64, 3_u64}.each do |version|
      json_type = w263_json_type
      array_json = CrystalClick::BinaryDataType.array(json_type)
      dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      dynamic_structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
      structures = {"root" => dynamic_structure} of String => CrystalClick::DynamicStructure
      rows = [
        CrystalClick::BinaryValue.dynamic(
          dynamic_type,
          CrystalClick::BinaryValue.array(
            array_json,
            [
              w263_json_value(json_type, "typed-a"),
              w263_json_value(json_type, "typed-b", "runtime-b", "shared-b"),
            ] of CrystalClick::BinaryValue,
          ),
        ),
      ] of CrystalClick::BinaryValue
      encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
        dynamic_type,
        structures,
        rows,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        w263_json_leaf_bindings(json_type, dynamic_structure, w263_child_plan(json_type, version)),
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(version, 2, profile),
        profile,
      )
      read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      path = w263_stream_with_logical_relocations(
        encoded.data,
        encoded.events,
        encoded.callback_relocations,
        read_budget,
      )

      decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
        path.data,
        path.events,
        rows.size,
        dynamic_type,
        read_budget,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(version, profile),
        profile,
        path.coordinate_context,
      )

      expected_json_type = w263_json_type
      expected_array_type = CrystalClick::BinaryDataType.array(expected_json_type)
      expected = [
        CrystalClick::BinaryValue.dynamic(
          dynamic_type,
          CrystalClick::BinaryValue.array(
            expected_array_type,
            [
              CrystalClick::BinaryValue.json(
                expected_json_type,
                CrystalClick::BinaryJsonRow.new(
                  expected_json_type,
                  [{"typed", CrystalClick::BinaryValue.string("typed-a")}] of Tuple(String, CrystalClick::BinaryValue),
                ),
              ),
              CrystalClick::BinaryValue.json(
                expected_json_type,
                CrystalClick::BinaryJsonRow.new(
                  expected_json_type,
                  [
                    {"typed", CrystalClick::BinaryValue.string("typed-b")},
                    {"runtime", CrystalClick::BinaryValue.string("runtime-b")},
                    {"shared", CrystalClick::BinaryValue.string("shared-b")},
                  ] of Tuple(String, CrystalClick::BinaryValue),
                ),
              ),
            ] of CrystalClick::BinaryValue,
          ),
        ),
      ] of CrystalClick::BinaryValue
      decoded.rows.size.should eq(expected.size)
      expected.each_with_index do |value, index|
        CrystalClick::BinaryValueCodec.encode(decoded.rows[index]).should eq(
          CrystalClick::BinaryValueCodec.encode(value),
        )
      end
    end
  end

  it "keeps the four-argument advanced decoder usable after ordinary recursive body capture" do
    profile = CrystalClick::BinaryBulkProfile.single_stream

    {2_u64, 3_u64}.each do |version|
      plan = w263_empty_advanced_plan(version)
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
      grid = CrystalClick::StorageOccurrenceGrid.new(
        [1_u64] of UInt64,
        [3_u64] of UInt64,
        budget,
      )
      documents = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
      streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_nested_context_and_budget(
        plan,
        [[documents, documents, documents] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument),
        grid,
        budget,
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(version, 2, profile),
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
        ".child",
        plan,
        profile,
        CrystalClick::BinaryBulkProfile.single_stream,
        budget.limits,
        initial_array_level: 0_u64,
        typed_descriptor_root_depth: 2,
        root_dynamic_json_budget: budget,
      )
      layout = CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
        physical,
        plan,
        streams,
        grid,
        budget,
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(version, 2, profile),
        nil,
        ".child",
      )
      read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      path = w263_stream_from_callbacks(
        layout.prefix_callbacks,
        layout.body_callbacks,
        layout.relocations,
        read_budget,
      )
      tape = CrystalClick::ObjectSharedPathTapeReader.new(
        path.data,
        path.events,
        read_budget,
        path.coordinate_context,
      )
      json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
      prefix = CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
        tape,
        json_type,
        CrystalClick::BinaryDynamicJsonLeafKey.new("root", 0, [] of Int32),
        1,
        ".child",
        ".child",
        0_u64,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(version, profile),
        read_budget,
      )
      CrystalClick::ObjectSharedPathJsonTapeCodec.capture_body!(prefix, tape, profile, read_budget)
      tape.finish!
      prefix.event_schedule_context[1].should eq(".child")
      prefix.body_callback_slice_count.should be > 0
      expect_raises(ArgumentError, "Object callback body role schedule is not bound") do
        prefix.body_role_bindings
      end
      expect_raises(ArgumentError, "Object callback body role identities are not bound") do
        prefix.body_callback_pairs
      end

      # Recursive capture retains the validated owner schedule but does not
      # bind this newer direct role roster. The original four-argument call
      # must derive it from that retained schedule, as before the split.
      decoded = CrystalClick::ObjectSharedAdvancedInlineDecoder.decode(
        prefix,
        CrystalClick::ObjectSharedPathJsonTapeCodec.physical_plan_for_prefix(prefix, read_budget),
        grid,
        read_budget,
      )
      decoded.size.should eq(1)
      decoded[0].size.should eq(3)
      decoded[0].each { |row| row.entry_count.should eq(0) }
    end
  end

  it "requires an explicit role schedule for a direct static Object V3 prefix" do
    profile = CrystalClick::BinaryBulkProfile.single_stream

    {2_u64, 3_u64}.each do |version|
      # This independently authored V3 Object structure has complete empty
      # statistics, two shared buckets, and no Dynamic paths. It deliberately
      # has no Dynamic JSON leaf key or inline event-schedule registry.
      data = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, version.to_u8, 2, 0]
      events = [
        CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.object_structure", 0_u64),
      ] of CrystalClick::ObjectSharedPathSubstreamEvent
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      tape = CrystalClick::ObjectSharedPathTapeReader.new(data, events, budget)
      json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
      nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(version, profile)
      prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
        tape,
        json_type,
        1_i32,
        ".child",
        ".child",
        0_u64,
        nested_context,
        budget,
      )
      tape.finish!

      prefix.should_not be_a(CrystalClick::ObjectDocumentInlinePrefix)
      prefix.statistics_context.should eq(CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::Complete)
      prefix.structures.object.shared_data_version.should eq(version)
      prefix.structures.object.bucket_count.should eq(2_u64)

      physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
        prefix.physical_prefix,
        prefix.plan,
        profile,
        CrystalClick::BinaryBulkProfile.single_stream,
        budget.limits,
        prefix.array_level,
        typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
        inferred_actual_root_depth: prefix.inferred_actual_root_depth,
        root_dynamic_json_budget: budget,
      )
      prefix.bind_physical_plan!(physical)
      grid = CrystalClick::StorageOccurrenceGrid.new(
        [1_u64] of UInt64,
        [0_u64] of UInt64,
        budget,
      )

      expect_raises(ArgumentError, "Object callback body role schedule is not bound") do
        CrystalClick::ObjectSharedAdvancedInlineDecoder.decode(
          prefix,
          physical,
          grid,
          budget,
        )
      end
    end
  end

  it "rejects a foreign physical owner in the static advanced decoder" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_static_foreign_owner_fixture(version)
      expect_raises(CrystalClick::CorruptPartError, /physical owner/) do
        CrystalClick::ObjectSharedAdvancedInlineDecoder.decode(
          fixture[:prefix],
          fixture[:physical_b],
          fixture[:grid],
          fixture[:budget],
        )
      end
    end
  end

  it "rejects a foreign physical owner in the static body materializer" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_static_foreign_owner_fixture(version)
      expect_raises(CrystalClick::CorruptPartError, /physical owner/) do
        CrystalClick::ObjectDocumentInlineBodyMaterializer.materialize(
          fixture[:prefix],
          fixture[:physical_b],
          fixture[:grid],
          fixture[:budget],
        )
      end
    end
  end
end
