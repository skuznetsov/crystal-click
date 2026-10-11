require "./spec_helper"

# This coordinate context resolves only the writer's callback relocations into
# one detached logical test tape. It preserves the existing recursive-capture
# fixture model; it is not evidence for Compact's physical mrk3/mrk4 mapping.
private class W263PreparationTapeCoordinateContext < CrystalClick::ObjectSharedInlineCoordinateContext
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

private def w263prep_write_u64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w263prep_stream_with_logical_relocations(
  data : Bytes,
  events : Array(CrystalClick::ObjectSharedPathSubstreamEvent),
  relocations : Array(CrystalClick::ObjectSharedInlineCallbackRelocation),
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectSharedPathStreams
  starts = Hash(String, UInt64).new(initial_capacity: events.size)
  events.each do |event|
    starts[event.name] = event.relative_offset
  end

  # Resolve only this in-memory writer's unresolved coordinate sidecar into
  # the detached logical tape; no physical Compact coordinate claim is made.
  relocations.each do |relocation|
    source_start = starts[relocation.source_callback]? ||
                   raise("test relocation source is absent from the callback tape")
    target_start = starts[relocation.target_callback]? ||
                   raise("test relocation target is absent from the callback tape")
    source_offset = (source_start + relocation.source_offset).to_i
    target_offset = target_start + relocation.target_offset
    w263prep_write_u64_le(data, source_offset, 0_u64)
    w263prep_write_u64_le(data, source_offset + 8, target_offset)
  end

  coordinate_context = W263PreparationTapeCoordinateContext.new(data)
  CrystalClick::ObjectSharedPathStreams.new(
    data,
    events,
    coordinate_context,
    [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
    budget,
  )
end

private def w263prep_stream_from_callbacks(
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
  w263prep_stream_with_logical_relocations(data, events, relocations, budget)
end

private def w263prep_empty_advanced_plan(version : UInt64) : CrystalClick::ObjectDocumentPlan
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

private def w263prep_static_foreign_owner_fixture(version : UInt64)
  profile = CrystalClick::BinaryBulkProfile.single_stream
  # Independently authored Complete statistics, two shared buckets, and no
  # Dynamic paths. This keeps the fixture keyless and free of a schedule key.
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

private def w263_inline_preparation_fixture(
  version : UInt64,
  corrupt_copy_type_tag : Bool = false,
  first_value : String = "first",
)
  profile = CrystalClick::BinaryBulkProfile.single_stream
  first_path = "a"
  second_path = "preparation"
  candidate = 0
  while CrystalClick::ObjectSharedBucketLayout.bucket_for(second_path, 2) ==
          CrystalClick::ObjectSharedBucketLayout.bucket_for(first_path, 2)
    if candidate >= 128
      raise "could not find a second path in the other shared bucket"
    end
    second_path = "preparation_#{candidate}"
    candidate += 1
  end

  documents = [
    CrystalClick::ObjectDocument.new(
      {first_path => CrystalClick::BinaryValue.string(first_value)} of String => CrystalClick::BinaryValue,
    ),
    CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue),
    CrystalClick::ObjectDocument.new(
      {second_path => CrystalClick::BinaryValue.string("second")} of String => CrystalClick::BinaryValue,
    ),
  ] of CrystalClick::ObjectDocument
  plan = w263prep_empty_advanced_plan(version)
  write_budget = CrystalClick::BinaryCodecBudget.new(
    CrystalClick::BinaryCodecLimits.default,
    true,
  )
  grid = CrystalClick::StorageOccurrenceGrid.new(
    [1_u64] of UInt64,
    [documents.size.to_u64] of UInt64,
    write_budget,
  )
  nested_write_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
    version,
    2,
    profile,
  )
  streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_nested_context_and_budget(
    plan,
    [documents] of Array(CrystalClick::ObjectDocument),
    grid,
    write_budget,
    nested_write_context,
  )
  physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    ".child",
    plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    write_budget.limits,
    initial_array_level: 0_u64,
    typed_descriptor_root_depth: 2,
    root_dynamic_json_budget: write_budget,
  )
  layout = CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
    physical_plan,
    plan,
    streams,
    grid,
    write_budget,
    nested_write_context,
    nil,
    ".child",
  )

  expected_spans = Array(Array(Tuple(Int32, Int32))).new(2)
  2.times do |bucket_index|
    root = ".child.object_shared_data.#{bucket_index}"
    structure_prefix_callback = layout.body_callbacks.find do |callback|
      callback[0] == "#{root}.structure_prefix"
    end || raise "inline writer omitted a bucket StructurePrefix callback"
    structure_suffix_callback = layout.body_callbacks.find do |callback|
      callback[0] == "#{root}.structure_suffix"
    end || raise "inline writer omitted a bucket StructureSuffix callback"
    structure_prefix = structure_prefix_callback[1]
    structure_suffix = structure_suffix_callback[1]
    span_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    spans = CrystalClick::ObjectSharedChunkStructureCodec.read_split_record_spans(
      structure_prefix,
      structure_suffix,
      span_budget,
    )
    expected_spans << spans.map { |span| {span.prefix_start, span.prefix_end} }
  end

  body_callbacks = layout.body_callbacks
  if corrupt_copy_type_tag
    values_callback = body_callbacks.index { |callback| callback[0] == ".child.object_shared_data.copy.values" } ||
                      raise "inline writer omitted the shared Copy values callback"
    name, source = body_callbacks[values_callback]
    unless source.size >= 2 && source[0] == 7_u8 && source[1] == CrystalClick::BinaryDataType::TAG_STRING
      raise "first shared Copy value is not the expected one-byte-sized String envelope"
    end
    corrupted = Bytes.new(source.size) { |index| source[index] }
    # Keep the length-delimited framing intact; only replace the actual type
    # tag within the first shared value envelope.
    corrupted[1] = 0xff_u8
    body_callbacks[values_callback] = {name, corrupted}
  end

  read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  path = w263prep_stream_from_callbacks(
    layout.prefix_callbacks,
    body_callbacks,
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
  {
    prefix:         prefix,
    physical_plan:  CrystalClick::ObjectSharedPathJsonTapeCodec.physical_plan_for_prefix(prefix, read_budget),
    grid:           grid,
    read_budget:    read_budget,
    expected_spans: expected_spans,
    first_path:     first_path,
    second_path:    second_path,
  }
end

describe "Object shared advanced inline preparation (W263)" do
  # Negative compilation witness, not an ordinary executable example. With
  # -D w263_raw_state_mint_attack this reproduces the formerly accepted
  # cross-source artifact substitution. The constructor variant selected with
  # -D w263_raw_state_constructor_attack must also fail: making only the seal
  # private would not be sufficient if the raw constructor remained public.
  {% if flag?(:w263_raw_state_mint_attack) || flag?(:w263_raw_state_constructor_attack) %}
    it "rejects a raw-state factory that substitutes another valid source's artifacts" do
      {2_u64, 3_u64}.each do |version|
        fixture = w263_inline_preparation_fixture(version)
        budget = fixture[:read_budget]
        prepared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
          fixture[:prefix], fixture[:physical_plan], fixture[:grid], budget,
        )
        foreign_fixture = w263_inline_preparation_fixture(version, false, "worst")
        foreign = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
          foreign_fixture[:prefix], foreign_fixture[:physical_plan],
          foreign_fixture[:grid], foreign_fixture[:read_budget],
        )
        parents = Array(Array(CrystalClick::ObjectSharedPhysicalParentMark)).new(2) do |bucket|
          [foreign.parent_for_decode(bucket)]
        end
        spans = Array(Array(CrystalClick::ObjectSharedChunkStructureReadSpan)).new(2) do |bucket|
          foreign.chunk_structure_spans_at(bucket)
        end
        copies = Array(CrystalClick::ObjectSharedCopyStreams).new(prepared.chunk_count) do |chunk|
          foreign.copy_for_decode(chunk)
        end
        expect_raises(CrystalClick::CorruptPartError) do
          {% if flag?(:w263_raw_state_constructor_attack) %}
            forged = CrystalClick::ObjectSharedAdvancedInlinePrepared.new(
              fixture[:prefix], fixture[:physical_plan], prepared.nested_context_for_decode,
              budget, prepared.logical_row_count, parents, spans, copies,
            )
          {% else %}
            forged = CrystalClick::ObjectSharedAdvancedInlinePrepared.seal(
              fixture[:prefix], fixture[:physical_plan], prepared.nested_context_for_decode,
              budget, prepared.logical_row_count, parents, spans, copies,
            )
          {% end %}
          decoded = CrystalClick::ObjectSharedAdvancedInlineDecoder.decode_prepared(forged, budget)
          decoded[0][0].entry_at(0).value.as_string.should eq("worst")
        end
      end
    end
  {% end %}

  it "retains parsed chunk spans and raw Copy lanes until prepared decoding for v2 and v3" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_inline_preparation_fixture(version)
      prepared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
        fixture[:prefix],
        fixture[:physical_plan],
        fixture[:grid],
        fixture[:read_budget],
      )

      prepared.logical_row_count.should eq(3_u64)
      prepared.bucket_count.should eq(2)
      expected_chunk_count = version == 2_u64 ? 1 : 2
      prepared.chunk_count.should eq(expected_chunk_count)
      2.times do |bucket_index|
        observed = prepared.chunk_structure_spans_at(bucket_index)
        observed.map { |span| {span.prefix_start, span.prefix_end} }.should eq(
          fixture[:expected_spans][bucket_index],
        )
        observed.size.should eq(expected_chunk_count)
      end

      rows = CrystalClick::ObjectSharedAdvancedInlineDecoder.decode_prepared(
        prepared,
        fixture[:read_budget],
      )
      rows.size.should eq(1)
      rows[0].size.should eq(3)
      rows[0][0].entry_count.should eq(1)
      rows[0][1].entry_count.should eq(0)
      rows[0][2].entry_count.should eq(1)
      String.new(rows[0][0].entry_at(0).path).should eq(fixture[:first_path])
      rows[0][0].entry_at(0).value.as_string.should eq("first")
      String.new(rows[0][2].entry_at(0).path).should eq(fixture[:second_path])
      rows[0][2].entry_at(0).value.as_string.should eq("second")
    end
  end

  it "defers a well-framed invalid Copy value tag until prepared decoding" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_inline_preparation_fixture(version, true)
      prepared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
        fixture[:prefix],
        fixture[:physical_plan],
        fixture[:grid],
        fixture[:read_budget],
      )

      prepared.logical_row_count.should eq(3_u64)
      prepared.bucket_count.should eq(2)
      prepared.chunk_count.should eq(version == 2_u64 ? 1 : 2)
      expect_raises(CrystalClick::CorruptPartError, /unknown or reserved ClickHouse binary DataType tag/) do
        CrystalClick::ObjectSharedAdvancedInlineDecoder.decode_prepared(
          prepared,
          fixture[:read_budget],
        )
      end
    end
  end

  it "rejects a foreign physical owner during preparation before consulting absent body schedules" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263prep_static_foreign_owner_fixture(version)
      expect_raises(CrystalClick::CorruptPartError, "Object callback prefix belongs to a different physical owner") do
        CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
          fixture[:prefix],
          fixture[:physical_b],
          fixture[:grid],
          fixture[:budget],
        )
      end
    end
  end

  it "rejects a fresh decode budget instead of resetting the prepared operation ceiling" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_inline_preparation_fixture(version)
      prepared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
        fixture[:prefix],
        fixture[:physical_plan],
        fixture[:grid],
        fixture[:read_budget],
      )
      fresh_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      decoded = false
      expect_raises(ArgumentError, /same.*budget|budget.*operation/i) do
        CrystalClick::ObjectSharedAdvancedInlineDecoder.decode_prepared(prepared, fresh_budget)
        decoded = true
      end
      decoded.should be_false
    end
  end

  it "owns raw Copy bytes independently of the captured input after preparation" do
    {2_u64, 3_u64}.each do |version|
      fixture = w263_inline_preparation_fixture(version)
      prefix = fixture[:prefix]
      prepared = CrystalClick::ObjectSharedAdvancedInlineDecoder.prepare_inline(
        prefix,
        fixture[:physical_plan],
        fixture[:grid],
        fixture[:read_budget],
      )
      copy_slice = nil.as(CrystalClick::ObjectSharedInlineCallbackReadSlice?)
      prefix.body_callback_slice_count.times do |index|
        slice = prefix.body_callback_slice_at(index)
        copy_slice = slice if slice.callback_name == ".child.object_shared_data.copy.values"
      end
      source = (copy_slice || raise "captured shared Copy values callback is absent").bytes
      source[1].should eq(CrystalClick::BinaryDataType::TAG_STRING)
      # This mutation is after preparation: unlike the semantic-delay control,
      # it tests ownership of the prepared snapshot, not framing acceptance.
      source[1] = 0xff_u8

      rows = CrystalClick::ObjectSharedAdvancedInlineDecoder.decode_prepared(
        prepared,
        fixture[:read_budget],
      )
      rows[0][0].entry_at(0).value.as_string.should eq("first")
      rows[0][2].entry_at(0).value.as_string.should eq("second")
    end
  end
end
