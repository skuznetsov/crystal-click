require "./spec_helper"

private def w240ai_bucket_paths : Array(String)
  paths = [] of String
  buckets = Set(Int32).new
  candidate_index = 0
  while buckets.size < 2
    candidate = "late_#{candidate_index}"
    bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(candidate, 2)
    unless buckets.includes?(bucket)
      paths << candidate
      buckets.add(bucket)
    end
    candidate_index += 1
    if candidate_index > 256
      raise "fixture could not find paths in both buckets"
    end
  end
  paths.sort!
  paths
end

private def w240ai_plan(shared_version : UInt64) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_version,
    bucket_count: 2_u64,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {} of String => CrystalClick::BinaryDataType,
  )
end

private def w240ai_documents(paths : Array(String)) : Array(CrystalClick::ObjectDocument)
  empty = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
  late_fields = Hash(String, CrystalClick::BinaryValue).new
  paths.each_with_index do |path, index|
    late_fields[path] = CrystalClick::BinaryValue.string("late-#{index}")
  end
  late = CrystalClick::ObjectDocument.new(late_fields)
  [empty, empty, late] of CrystalClick::ObjectDocument
end

private def w240ai_nested_streams(
  plan : CrystalClick::ObjectDocumentPlan,
  shared_version : UInt64,
  target_chunk_rows : Int32,
  profile : CrystalClick::BinaryBulkProfile,
  budget : CrystalClick::BinaryCodecBudget,
) : Tuple(
  CrystalClick::ObjectDocumentStreams,
  CrystalClick::StorageOccurrenceGrid,
  CrystalClick::ObjectDocumentPhysicalPlan,
)
  grid = CrystalClick::StorageOccurrenceGrid.new(
    [1_u64] of UInt64,
    [3_u64] of UInt64,
    budget,
  )
  nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
    shared_version,
    target_chunk_rows,
    profile,
  )
  streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_nested_context_and_budget(
    plan,
    [w240ai_documents(w240ai_bucket_paths)] of Array(CrystalClick::ObjectDocument),
    grid,
    budget,
    nested_context,
  )
  physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    ".child",
    plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    budget.limits,
    1_u64,
    nil,
    2,
    1,
    budget,
  )
  {streams, grid, physical}
end

private def w240ai_bucket_inputs(
  directory : String,
  bucket_index : Int32,
  files : CrystalClick::ObjectSharedPhysicalBucketFiles,
) : CrystalClick::ObjectSharedPhysicalBucketLaneInputs
  lanes = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane_name|
    files_for_lane = files.lane(lane_name)
    data_path = File.join(directory, "bucket-#{bucket_index}-#{lane_name}.bin")
    marks_path = File.join(directory, "bucket-#{bucket_index}-#{lane_name}.mrk2")
    data = files_for_lane.data
    marks = files_for_lane.marks
    File.write(data_path, data)
    File.write(marks_path, marks)
    lanes[lane_name] = CrystalClick::ObjectSharedPhysicalLaneInput.new(
      data_path,
      marks_path,
      data.size.to_i64,
      marks.size.to_i64,
    )
  end
  CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lanes)
end

private def w240ai_chunk_schedule(
  streams : CrystalClick::ObjectDocumentStreams,
  shared_version : UInt64,
  target_chunk_rows : Int32,
  profile : CrystalClick::BinaryBulkProfile,
  budget : CrystalClick::BinaryCodecBudget,
) : Array(Array(UInt64))
  rows = streams.advanced_shared_rows(budget)
  files = CrystalClick::ObjectSharedAdvancedDocumentCodec.encode(
    rows,
    [1_u64] of UInt64,
    shared_version.to_i,
    2,
    budget,
    CrystalClick::CompressedStreamBudget.write_default,
    profile: profile,
    shared_target_chunk_rows: target_chunk_rows,
  )
  files.bucket_count.should eq(2)

  directory = File.tempname("crystal-click-w240-inline-advanced-")
  Dir.mkdir(directory)
  begin
    schedules = Array(Array(UInt64)).new(files.bucket_count)
    files.bucket_count.times do |bucket_index|
      inputs = w240ai_bucket_inputs(directory, bucket_index, files.bucket_at(bucket_index))
      decoded = CrystalClick::ObjectSharedPhysicalBucketCodec.decode(
        shared_version.to_i,
        inputs,
        [1_u64] of UInt64,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::CompressedStreamBudget.read_default,
        profile,
      )
      schedules << decoded[0].chunks.map(&.row_count)
    end
    schedules
  ensure
    FileUtils.rm_rf(directory) if Dir.exists?(directory)
  end
end

private def w240ai_expected_body_callbacks : Array(String)
  callbacks = [] of String
  2.times do |bucket_index|
    prefix = ".child.object_shared_data.#{bucket_index}."
    callbacks.concat([
      "#{prefix}structure_prefix",
      "#{prefix}data",
      "#{prefix}paths_marks",
      "#{prefix}substreams",
      "#{prefix}substreams_marks",
      "#{prefix}paths_substreams_metadata",
      "#{prefix}structure_suffix",
    ])
  end
  callbacks.concat([
    ".child.object_shared_data.copy.sizes",
    ".child.object_shared_data.copy.paths_indexes",
    ".child.object_shared_data.copy.values",
  ])
  callbacks
end

private def w240ai_assert_relocations(layout : CrystalClick::ObjectSharedAdvancedInlineRawLayout) : Nil
  callback_bytes = Hash(String, Bytes).new
  layout.body_callbacks.each do |callback|
    callback_bytes.has_key?(callback[0]).should be_false
    callback_bytes[callback[0]] = callback[1]
  end

  relocations = layout.relocations
  layout.relocation_count.should be > 0
  relocations.size.should eq(layout.relocation_count)
  relocations.each do |relocation|
    callback_bytes.has_key?(relocation.source_callback).should be_true
    callback_bytes.has_key?(relocation.target_callback).should be_true
    source = callback_bytes[relocation.source_callback]
    target = callback_bytes[relocation.target_callback]
    target_offset = relocation.target_offset

    (relocation.source_offset <= source.size.to_u64).should be_true
    (CrystalClick::ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES <=
      source.size.to_u64 - relocation.source_offset).should be_true
    (target_offset <= target.size.to_u64).should be_true
    source_offset = relocation.source_offset.to_i

    # These raw callback bytes deliberately retain zero coordinate fields.
    # The sidecar identifies what a containing Data assembler must relocate;
    # this test does not treat the detached placeholders as publishable marks.
    CrystalClick::ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES.to_i.times do |byte_index|
      source[source_offset + byte_index].should eq(0_u8)
    end
  end
end

private def w240ai_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(max_dynamic_paths: 2, max_dynamic_types: 1)
end

private def w240ai_json_value(
  type : CrystalClick::BinaryDataType,
  fields : Hash(String, CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  entries = Array(Tuple(String, CrystalClick::BinaryValue)).new(fields.size)
  fields.each { |path, value| entries << {path, value} }
  CrystalClick::BinaryValue.json(type, CrystalClick::BinaryJsonRow.new(type, entries))
end

private def w240ai_encode_json_array_child(
  shared_version : UInt64,
  target_chunk_rows : Int32,
  profile : CrystalClick::BinaryBulkProfile,
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectSharedPathStreams
  paths = w240ai_bucket_paths
  json_type = w240ai_json_type
  array_json = CrystalClick::BinaryDataType.array(json_type)
  dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  dynamic_structure = CrystalClick::DynamicStructure.new(
    [array_json] of CrystalClick::BinaryDataType,
  )
  structures = {"root" => dynamic_structure} of String => CrystalClick::DynamicStructure

  empty = w240ai_json_value(json_type, {} of String => CrystalClick::BinaryValue)
  late_fields = Hash(String, CrystalClick::BinaryValue).new
  paths.each_with_index do |path, index|
    late_fields[path] = CrystalClick::BinaryValue.string("late-#{index}")
  end
  late = w240ai_json_value(json_type, late_fields)
  array = CrystalClick::BinaryValue.array(
    array_json,
    [empty, empty, late] of CrystalClick::BinaryValue,
  )
  row = CrystalClick::BinaryValue.dynamic(dynamic_type, array)
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    dynamic_structure.canonical_index_for(array_json),
    [0_i32] of Int32,
  )
  child_plan = w240ai_plan(shared_version)
  leaf_bindings = [{key, child_plan}] of Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  # This whole path carries the caller's single budget through Dynamic, JSON,
  # and the nested Object child. The current advanced-inline guard is the RED.
  CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
    dynamic_type,
    structures,
    [row] of CrystalClick::BinaryValue,
    budget,
    leaf_bindings,
    CrystalClick::ObjectSharedNestedSerializationContext.for_write(
      shared_version,
      target_chunk_rows,
      profile,
    ),
    profile,
  )
end

describe "W240 adversary: nested inline ADVANCED / ADVANCED_CHUNKED JSON" do
  it "pins native Compact callback roles and their source-defined bucket/Copy order" do
    # SerializationObjectSharedData.cpp:162-182 and 199-201 enumerate these
    # literal roles. ISerialization.cpp:383-405 gives the corresponding names.
    # The specialized StructurePrefix/Suffix callbacks are distinct even
    # though the normalized physical bucket codec owns one structure lane.
    expected = w240ai_expected_body_callbacks
    expected.size.should eq(17) # 2 * (7 per-bucket callbacks) + 3 global Copy callbacks
    expected.should eq([
      ".child.object_shared_data.0.structure_prefix",
      ".child.object_shared_data.0.data",
      ".child.object_shared_data.0.paths_marks",
      ".child.object_shared_data.0.substreams",
      ".child.object_shared_data.0.substreams_marks",
      ".child.object_shared_data.0.paths_substreams_metadata",
      ".child.object_shared_data.0.structure_suffix",
      ".child.object_shared_data.1.structure_prefix",
      ".child.object_shared_data.1.data",
      ".child.object_shared_data.1.paths_marks",
      ".child.object_shared_data.1.substreams",
      ".child.object_shared_data.1.substreams_marks",
      ".child.object_shared_data.1.paths_substreams_metadata",
      ".child.object_shared_data.1.structure_suffix",
      ".child.object_shared_data.copy.sizes",
      ".child.object_shared_data.copy.paths_indexes",
      ".child.object_shared_data.copy.values",
    ])
    CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.should eq([
      "structure", "data", "paths_marks", "substreams", "substreams_marks",
      "paths_substreams_metadata",
    ])
    CrystalClick::ObjectSharedAdvancedDocumentCodec::COPY_LANES.should eq([
      "sizes", "indexes", "values",
    ])
  end

  it "keeps an empty prefix and late-only path across v2's single chunk and two buckets" do
    version = 2_u64
    target = 2
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    w240ai_bucket_paths.map { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) }.uniq.size.should eq(2)
    plan = w240ai_plan(version)
    streams, grid, physical = w240ai_nested_streams(plan, version, target, profile, budget)

    grid.logical_occurrences_at(0).should eq(3_u64)
    streams.advanced_shared_row_count_at(0).should eq(3)
    streams.advanced_shared_row_at(0, 0).entry_count.should eq(0)
    streams.advanced_shared_row_at(0, 1).entry_count.should eq(0)
    streams.advanced_shared_row_at(0, 2).entry_count.should eq(2)
    w240ai_chunk_schedule(streams, version, target, profile, budget).should eq([
      [3_u64] of UInt64,
      [3_u64] of UInt64,
    ])

    nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
      version,
      target,
      profile,
    )
    layout = CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
      physical,
      plan,
      streams,
      grid,
      budget,
      nested_context,
      nil,
      ".child",
    )
    layout.prefix_callbacks.map(&.[0]).should eq([".child.object_structure"])
    layout.body_callbacks.map(&.[0]).should eq(w240ai_expected_body_callbacks)
    w240ai_assert_relocations(layout)
    budget.node_count.should be > 0
    budget.wire_byte_count.should be > 0
  end

  it "keeps the final two paths in the last of two v3 chunks and uses one callback per role" do
    version = 3_u64
    target = 2
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    w240ai_bucket_paths.map { |path| CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2) }.uniq.size.should eq(2)
    plan = w240ai_plan(version)
    streams, grid, physical = w240ai_nested_streams(plan, version, target, profile, budget)

    rows = streams.advanced_shared_row_at(0, 0).entry_count +
           streams.advanced_shared_row_at(0, 1).entry_count +
           streams.advanced_shared_row_at(0, 2).entry_count
    rows.should eq(2)
    w240ai_chunk_schedule(streams, version, target, profile, budget).should eq([
      [2_u64, 1_u64] of UInt64,
      [2_u64, 1_u64] of UInt64,
    ])

    nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
      version,
      target,
      profile,
    )
    layout = CrystalClick::ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
      physical,
      plan,
      streams,
      grid,
      budget,
      nested_context,
      nil,
      ".child",
    )
    layout.prefix_callbacks.map(&.[0]).should eq([".child.object_structure"])
    body_names = layout.body_callbacks.map(&.[0])
    body_names.should eq(w240ai_expected_body_callbacks)
    body_names.uniq.size.should eq(body_names.size)
    w240ai_assert_relocations(layout)
    budget.node_count.should be > 0
    budget.wire_byte_count.should be > 0
  end

  it "keeps the legacy Tuple callback API guarded for advanced v2 and v3" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    [2_u64, 3_u64].each do |version|
      target = 2
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
      plan = w240ai_plan(version)
      streams, grid, physical = w240ai_nested_streams(plan, version, target, profile, budget)

      expect_raises(CrystalClick::UnsupportedFormatError, /Compact coordinate relocation/) do
        CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
          physical,
          plan,
          streams,
          grid,
          budget,
          profile,
          ".child",
        )
      end
    end
  end

  it "routes real Array(JSON) child values through the nested v2 bridge and inherited budget" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    encoded = w240ai_encode_json_array_child(2_u64, 2, profile, budget)

    encoded.data.empty?.should be_false
    encoded.events.size.should be > 0
    budget.node_count.should be > 0
    budget.wire_byte_count.should be > 0
  end

  it "routes real Array(JSON) child values through the nested v3 bridge and inherited budget" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    encoded = w240ai_encode_json_array_child(3_u64, 2, profile, budget)

    encoded.data.empty?.should be_false
    encoded.events.size.should be > 0
    budget.node_count.should be > 0
    budget.wire_byte_count.should be > 0
  end
end
