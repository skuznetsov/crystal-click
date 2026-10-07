require "./spec_helper"
require "file_utils"

private def w204a_json_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)", limits)
end

private def w204a_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w204a_schema(
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Array(Tuple(doc JSON(t UInt8), d Dynamic(max_types=1)))", limits
  )
end

private def w204a_dynamic_plan(
  actual_types : Array(CrystalClick::BinaryDataType) = [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : CrystalClick::BinaryDynamicBulkPlan
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  CrystalClick::BinaryDynamicBulkPlan.new(
    dynamic,
    {"root" => CrystalClick::DynamicStructure.new(actual_types)},
    limits: limits,
  )
end

private def w204a_dynamic_plans(
  plan : CrystalClick::BinaryDynamicBulkPlan,
) : Hash(String, CrystalClick::BinaryDynamicBulkPlan)
  {"root/array[0]/tuple[1]" => plan}
end

private def w204a_document(value : UInt8 = 1_u8) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value]
    ),
  } of String => CrystalClick::BinaryValue)
end

private def w204a_empty_granules : Array(Array(CrystalClick::StorageColumnValue))
  empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
  Array(Array(CrystalClick::StorageColumnValue)).new(4) do
    [empty, empty] of CrystalClick::StorageColumnValue
  end
end

private def w204a_with_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w204a-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w204a_write_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

private def w204a_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  hash.each do |word|
    8.times { |byte| io.write_byte(((word >> (byte * 8)) & 0xff_u64).to_u8) }
  end
end

private def w204a_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w204a_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w204a_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w204a_write_varuint(payload, bytes.size.to_u64)
    w204a_write_hash(payload, CrystalClick::CityHashV1.file_hash(bytes))
    payload.write_byte(entry.compressed ? 1_u8 : 0_u8)
    if entry.compressed
      raw = bytes.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(bytes)
      w204a_write_varuint(payload, raw.size.to_u64)
      w204a_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(CrystalClick::CompressedMarkWriter.encode_all(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w204a_write_zero_site_part(part : String) : CrystalClick::RecursiveStorageColumnPlan
  schema = w204a_schema
  json_schema = w204a_json_schema
  dynamic_plan = w204a_dynamic_plan
  object_plans = {"root/array[0]/tuple[0]" => w204a_object_plan(json_schema)}
  dynamic_plans = w204a_dynamic_plans(dynamic_plan)
  plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
    "payload", schema, object_plans, hashed: true, dynamic_plans: dynamic_plans
  )
  keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
  CrystalClick::WidePartWriter.write_uint64_recursive_pair(
    part, "pk", keys, "payload", schema, object_plans, w204a_empty_granules,
    rows_per_mark: 2,
    dynamic_plans: dynamic_plans,
  )
  plan
end

private def w204a_replace_pair(part : String, logical_name : String, files : CrystalClick::CompressedMarkFiles) : Nil
  hashed = CrystalClick::StreamName.hash(logical_name)
  File.write(File.join(part, "#{hashed}.bin"), files.data)
  File.write(File.join(part, "#{hashed}.mrk2"), files.marks)
  w204a_refresh_checksums(part)
end

describe "W204 recursive JSON/Dynamic adversaries" do
  it "requires an exact Dynamic site-to-plan roster and exact subtree type" do
    schema = w204a_schema
    object_schema = w204a_json_schema
    object_plans = {"root/array[0]/tuple[0]" => w204a_object_plan(object_schema)}
    dynamic_plan = w204a_dynamic_plan
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)

    missing = expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column("payload", schema, object_plans)
    end
    missing.message.should eq("Dynamic plan keys must exactly match recursive Dynamic site keys")
    extra = expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, object_plans,
        dynamic_plans: {
          "root/array[0]/tuple[1]" => dynamic_plan,
          "root/array[9]/tuple[1]" => dynamic_plan,
        },
      )
    end
    extra.message.should eq("Dynamic plan keys must exactly match recursive Dynamic site keys")
    wrong_type = CrystalClick::BinaryDynamicBulkPlan.new(
      CrystalClick::BinaryDataType.dynamic(max_types: 0),
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
    )
    type_mismatch = expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, object_plans,
        dynamic_plans: {"root/array[0]/tuple[1]" => wrong_type},
      )
    end
    type_mismatch.message.should eq("recursive Dynamic prepared plan differs from its declared type or profile")
    wrong_profile = CrystalClick::BinaryDynamicBulkPlan.new(
      CrystalClick::BinaryDataType.dynamic(max_types: 1),
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    profile_mismatch = expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, object_plans,
        dynamic_plans: {"root/array[0]/tuple[1]" => wrong_profile},
      )
    end
    profile_mismatch.message.should eq("recursive Dynamic prepared plan differs from its declared type or profile")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic,
        {"root.not-a-site" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      )
    end
  end

  it "does not publish when a Dynamic site is unbound or recursive input shape is malformed" do
    schema = w204a_schema
    object_schema = w204a_json_schema
    object_plans = {"root/array[0]/tuple[0]" => w204a_object_plan(object_schema)}
    dynamic_plan = w204a_dynamic_plan
    dynamic_plans = w204a_dynamic_plans(dynamic_plan)
    keys = Slice[1_u64, 2_u64]
    granules = [w204a_empty_granules[0]]

    w204a_with_parent("writer-no-publication") do |parent|
      missing = File.join(parent, "missing")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          missing, "pk", keys, "payload", schema, object_plans, granules,
          rows_per_mark: 2,
        )
      end
      Dir.children(parent).should be_empty

      malformed = File.join(parent, "malformed")
      bad_tuple = CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.object_document(w204a_document),
      ] of CrystalClick::StorageColumnValue)
      bad_root = CrystalClick::StorageColumnValue.array([bad_tuple] of CrystalClick::StorageColumnValue)
      bad_granules = [[bad_root, bad_root] of CrystalClick::StorageColumnValue]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_recursive_pair(
          malformed, "pk", keys, "payload", schema, object_plans, bad_granules,
          rows_per_mark: 2,
          dynamic_plans: dynamic_plans,
        )
      end
      Dir.children(parent).should be_empty
    end
  end

  it "rejects corrupted child marks and Dynamic structure metadata before any table callback" do
    schema = w204a_schema
    w204a_with_parent("bad-child-marks") do |parent|
      part = File.join(parent, "all_1_1_0")
      plan = w204a_write_zero_site_part(part)
      array_site = plan.array_site_at(0)
      dynamic_site = plan.dynamic_site_at(0)
      mismatched_limits = CrystalClick::BinaryCodecLimits.new(63, 4_096, 1_000_000, 64 * 1024 * 1024)
      expect_raises(ArgumentError) do
        CrystalClick::DynamicBulkSiteReader.open(
          CrystalClick::PartStreamSource.new(part),
          dynamic_site.type,
          dynamic_site.prefix,
          dynamic_site.array_level,
          plan.profile,
          plan.limits,
          plan.transport_limits,
          CrystalClick::BinaryCodecBudget.new(mismatched_limits),
          CrystalClick::CompressedStreamBudget.new,
          initial_descriptor_depth: dynamic_site.descriptor_depth,
        )
      end
      raw = CrystalClick::PartStreamSource.new(part).read_all(
        "#{CrystalClick::StreamName.hash(array_site.size_name)}.bin"
      )
      raw.size.should eq(8 * 8)
      # Eight parent rows still have one zero-length entry each; only the
      # size-lane P marks were changed from the parent grid [2,2,2,2].
      marks = CrystalClick::CompressedMarkWriter.encode(
        raw, [0_u64, 16_u64, 24_u64, 48_u64, 64_u64], [2_u64, 1_u64, 3_u64, 2_u64]
      )
      w204a_replace_pair(part, array_site.size_name, marks)

      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
        reader.read_marks(0, 0)
      end
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    w204a_with_parent("bad-dynamic-metadata") do |parent|
      part = File.join(parent, "all_1_1_0")
      plan = w204a_write_zero_site_part(part)
      site = plan.dynamic_site_at(0)
      logical_name = site.physical.structure_name_for("root")
      pair = plan.file_roster[logical_name]
      raw = CrystalClick::PartStreamSource.new(part).read_all(pair[0]).dup
      statistics_offset = site.plan.statistics_offset_for("root")
      raw[statistics_offset] = 2_u8
      malformed = CrystalClick::CompressedMarkWriter.encode_metadata(
        raw, statistics_offset, [2_u64, 2_u64, 2_u64, 2_u64]
      )
      File.write(File.join(part, pair[0]), malformed.data)
      File.write(File.join(part, pair[1]), malformed.marks)
      w204a_refresh_checksums(part)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "pins public Dynamic site read budgets to the limits admitted at open" do
    w204a_with_parent("read-budget-pinning") do |parent|
      part = File.join(parent, "all_1_1_0")
      plan = w204a_write_zero_site_part(part)
      site = plan.dynamic_site_at(0)
      physical_rows = [2_u64, 2_u64, 2_u64, 2_u64]
      logical_rows = [0_u64, 0_u64, 0_u64, 0_u64]
      site_grid = CrystalClick::StorageOccurrenceGrid.new(
        physical_rows, logical_rows, CrystalClick::BinaryCodecBudget.new(plan.limits)
      )
      reader = CrystalClick::DynamicBulkSiteReader.open(
        CrystalClick::PartStreamSource.new(part),
        site.type,
        site.prefix,
        site.array_level,
        plan.profile,
        plan.limits,
        plan.transport_limits,
        CrystalClick::BinaryCodecBudget.new(plan.limits),
        CrystalClick::CompressedStreamBudget.new(plan.transport_limits),
        physical_rows,
        site_grid,
        8_u64,
        initial_descriptor_depth: site.descriptor_depth,
        site_key: site.key,
      )

      matching_transport = CrystalClick::CompressedStreamBudget.new(plan.transport_limits)
      matching = reader.read_marks(
        0, 0, CrystalClick::BinaryCodecBudget.new(plan.limits), matching_transport
      )
      matching.should eq([] of Array(CrystalClick::BinaryValue))
      matching_transport.file_byte_count.should be > 0

      owner_limits = plan.transport_limits
      wider_limits = CrystalClick::CompressedStreamLimits.new(
        max_file_bytes: owner_limits.max_file_bytes + 1,
        max_mark_bytes: owner_limits.max_mark_bytes,
        max_frame_compressed_bytes: owner_limits.max_frame_compressed_bytes,
        max_frame_decompressed_bytes: owner_limits.max_frame_decompressed_bytes,
        max_records: owner_limits.max_records,
        max_decoded_bytes: owner_limits.max_decoded_bytes,
        max_result_bytes: owner_limits.max_result_bytes,
      )
      wider_transport = CrystalClick::CompressedStreamBudget.new(wider_limits)
      limit_error = expect_raises(ArgumentError) do
        reader.read_marks(
          0, 0, CrystalClick::BinaryCodecBudget.new(plan.limits), wider_transport
        )
      end
      limit_error.message.should eq("Dynamic site reader transport budget differs from its limits")
      wider_transport.file_byte_count.should eq(0_i64)
      wider_transport.record_count.should eq(0_i64)

      wrong_direction = CrystalClick::CompressedStreamBudget.new(owner_limits, true)
      direction_error = expect_raises(ArgumentError) do
        reader.read_marks(
          0, 0, CrystalClick::BinaryCodecBudget.new(plan.limits), wrong_direction
        )
      end
      direction_error.message.should eq("Dynamic site reader transport budget differs from its limits")
      wrong_direction.file_byte_count.should eq(0_i64)
      wrong_direction.record_count.should eq(0_i64)
    end
  end

  it "rebinds a site-discovered plan at its same inherited depth and rejects a deeper unused actual arm" do
    limits = CrystalClick::BinaryCodecLimits.new(6, 100_000, 100_000, 1_048_576)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    actual_tuple = CrystalClick::BinaryDataType.tuple([uint64] of CrystalClick::BinaryDataType)
    actual_array = CrystalClick::BinaryDataType.array(actual_tuple)
    structure = CrystalClick::DynamicStructure.new([actual_array] of CrystalClick::BinaryDataType)
    bytes = CrystalClick::DynamicStructureCodec.encode(structure, limits)
    loader = ->(_path : String, _structures : Hash(String, CrystalClick::DynamicStructure), _budget : CrystalClick::BinaryCodecBudget) { bytes }
    discovered = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams_with_loader(
      dynamic, CrystalClick::BinaryCodecBudget.new(limits), loader,
      initial_depth: 3_i32,
    )
    schema = w204a_schema(limits)
    object_schema = w204a_json_schema(limits)
    object_plans = {"root/array[0]/tuple[0]" => w204a_object_plan(object_schema)}
    dynamic_plans = w204a_dynamic_plans(discovered)
    write_plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, object_plans, limits: limits, dynamic_plans: dynamic_plans
    )
    write_plan.dynamic_site_at(0).descriptor_depth.should eq(3)

    actual_value = CrystalClick::BinaryValue.array(actual_array, [
      CrystalClick::BinaryValue.tuple(actual_tuple, [CrystalClick::BinaryValue.uint64(9_u64)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, actual_value)
    item = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(w204a_document),
      CrystalClick::StorageColumnValue.bulk(dynamic_value),
    ] of CrystalClick::StorageColumnValue)
    populated = CrystalClick::StorageColumnValue.array([item] of CrystalClick::StorageColumnValue)
    empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)

    w204a_with_parent("depth-exact-rebind") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", Slice[1_u64, 2_u64], "payload", schema, object_plans,
        [[populated, empty] of CrystalClick::StorageColumnValue],
        rows_per_mark: 2,
        limits: limits,
        dynamic_plans: dynamic_plans,
      )
      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      readback = reader.read_marks(0, 1).flatten
      readback.size.should eq(2)
      selected_actual = readback[0].array_values[0].child_at(1).bulk_value
      selected_actual.child_count.should eq(1)
      nested_array = selected_actual.child_at(0)
      nested_array.child_count.should eq(1)
      nested_tuple = nested_array.child_at(0)
      nested_tuple.child_count.should eq(1)
      nested_tuple.child_at(0).as_uint64.should eq(9_u64)
    end

    # The actual arm is valid under its standalone/local max_depth=5 budget,
    # but the root Array + Tuple + Dynamic site inherits depth three, pushing
    # the unused roster's UInt64 descriptor to depth six.
    narrow = CrystalClick::BinaryCodecLimits.new(5, 100_000, 100_000, 1_048_576)
    narrow_plan = w204a_dynamic_plan([actual_array] of CrystalClick::BinaryDataType, narrow)
    narrow_schema = w204a_schema(narrow)
    narrow_json = w204a_json_schema(narrow)
    narrow_objects = {"root/array[0]/tuple[0]" => w204a_object_plan(narrow_json)}
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", narrow_schema, narrow_objects,
        limits: narrow,
        dynamic_plans: w204a_dynamic_plans(narrow_plan),
      )
    end

    broad_schema = w204a_schema
    broad_json = w204a_json_schema
    broad_objects = {"root/array[0]/tuple[0]" => w204a_object_plan(broad_json)}
    broad_dynamic = w204a_dynamic_plan([actual_array] of CrystalClick::BinaryDataType)
    w204a_with_parent("depth-zero-q-reader") do |parent|
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
        "payload", broad_schema, {"root/array[0]/tuple[0]" => w204a_object_plan(broad_json)},
        w204a_empty_granules,
        rows_per_mark: 2,
        dynamic_plans: w204a_dynamic_plans(broad_dynamic),
      )
      empty_storage = CrystalClick::BinaryCodecLimits.new(5, 100_000, 100_000, 1_048_576)
      persisted_schema = w204a_schema(empty_storage)
      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", persisted_schema)
        reader.read_marks(0, 0)
      end
    end
  end
end
