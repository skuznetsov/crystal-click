require "./spec_helper"
require "file_utils"

private alias W212LeafPlans = Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))

private def w212_physical_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"id" => CrystalClick::BinaryDataType.primitive("UInt8")} of String => CrystalClick::BinaryDataType,
  )
end

private def w212_physical_object_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["counter"] of String),
    {"counter" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w212_physical_json_value(
  type : CrystalClick::BinaryDataType,
  id : UInt8,
  counter : UInt64? = nil,
  counter_path : String = "counter",
) : CrystalClick::BinaryValue
  values = [{
    "id",
    CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[id]),
  }] of Tuple(String, CrystalClick::BinaryValue)
  if value = counter
    values << {counter_path, CrystalClick::BinaryValue.uint64(value)}
  end
  row = CrystalClick::BinaryJsonRow.new(type, values)
  CrystalClick::BinaryValue.json(type, row)
end

private def w212_physical_dynamic_value(
  dynamic_type : CrystalClick::BinaryDataType,
  actual : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
end

private def w212_physical_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  granules : Array(Array(CrystalClick::BinaryValue)),
  leaf_plans : W212LeafPlans,
) : Nil
  keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    destination,
    "pk",
    keys,
    "payload",
    type,
    structures,
    granules,
    rows_per_mark: 2,
    json_object_leaf_plans: leaf_plans,
  ).should eq(destination)
end

private def w212_physical_expect_marks!(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |rows, mark|
    rows.size.should eq(expected[mark].size)
    rows.each_with_index do |value, row|
      CrystalClick::BinaryValueCodec.encode(value).should eq(
        CrystalClick::BinaryValueCodec.encode(expected[mark][row])
      )
    end
  end
end

private def w212_physical_mark_rows(marks : Bytes) : Array(UInt64)
  unless marks.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
    raise "W212 mark file contains an incomplete record"
  end
  mark_count = marks.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
  Array(UInt64).new(mark_count) do |record_index|
    offset = record_index * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
    value = 0_u64
    8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w212_physical_array_element_rows_per_mark(
  sizes : CrystalClick::BinaryBulkStream,
  physical_rows_per_mark : Array(UInt64),
) : Array(UInt64)
  unless sizes.mark_count == physical_rows_per_mark.size
    raise "W212 Array size lane differs from the physical mark grid"
  end
  Array(UInt64).new(sizes.mark_count) do |mark|
    start_offset = sizes.offset_at(mark)
    end_offset = sizes.offset_at(mark + 1)
    raise "W212 Array size lane offsets are not monotone" if end_offset < start_offset
    expected_bytes = physical_rows_per_mark[mark] * 8_u64
    unless end_offset - start_offset == expected_bytes
      raise "W212 Array size lane differs from its parent row count"
    end
    total = 0_u64
    physical_rows_per_mark[mark].to_i.times do |row|
      value = 0_u64
      8.times do |byte_index|
        offset = start_offset + row.to_u64 * 8_u64 + byte_index.to_u64
        value |= sizes.byte_at(offset.to_i).to_u64 << (byte_index * 8)
      end
      if total > UInt64::MAX - value
        raise "W212 Array element count overflows UInt64"
      end
      total += value
    end
    total
  end
end

private def w212_physical_lane_values_per_mark(
  stream : CrystalClick::BinaryBulkStream,
  bytes_per_value : UInt64,
) : Array(UInt64)
  raise "W212 lane element width must be positive" if bytes_per_value == 0_u64
  Array(UInt64).new(stream.mark_count) do |mark|
    start_offset = stream.offset_at(mark)
    end_offset = stream.offset_at(mark + 1)
    raise "W212 lane offsets are not monotone" if end_offset < start_offset
    byte_count = end_offset - start_offset
    unless byte_count % bytes_per_value == 0_u64
      raise "W212 lane mark does not contain complete values"
    end
    byte_count // bytes_per_value
  end
end

describe "W212 recursive Dynamic JSON physical leaves" do
  it "writes and auto-reads root Dynamic Array(Nullable(JSON)) with P distinct from default-expanded E" do
    json = w212_physical_json_type
    nullable_json = CrystalClick::BinaryDataType.nullable(json)
    actual_type = CrystalClick::BinaryDataType.array(nullable_json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(actual_type), [0_i32, 0_i32]
    )
    plans = [{key, w212_physical_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    wrap = ->(items : Array(CrystalClick::BinaryValue)) {
      w212_physical_dynamic_value(dynamic, CrystalClick::BinaryValue.array(actual_type, items))
    }
    json_row = ->(id : UInt8, counter : UInt64?) {
      CrystalClick::BinaryValue.nullable(
        nullable_json,
        w212_physical_json_value(json, id, counter),
      )
    }
    null_json = CrystalClick::BinaryValue.null(nullable_json)
    granules = [
      [wrap.call([] of CrystalClick::BinaryValue), wrap.call([null_json] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [
        wrap.call([json_row.call(11_u8, 101_u64), null_json, json_row.call(12_u8, nil)] of CrystalClick::BinaryValue),
        wrap.call([json_row.call(13_u8, 103_u64)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [
        wrap.call([json_row.call(21_u8, 201_u64), json_row.call(22_u8, 202_u64)] of CrystalClick::BinaryValue),
        wrap.call([] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root" => structure}
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic, structures, granules, json_object_leaf_plans: plans
    )
    physical_rows = [2_u64, 2_u64, 2_u64]                                                                             # P. This root Dynamic fixture also has Q=R=P.
    selected_actual_arm_rows = [2_u64, 2_u64, 2_u64]                                                                  # R: each physical Dynamic selects this sole actual arm.
    w212_physical_lane_values_per_mark(normalized.data.stream("root.discriminators"), 1_u64).should eq(physical_rows) # Q
    w212_physical_lane_values_per_mark(
      normalized.data.stream("root.arm.#{key.canonical_arm_index}.sizes"), 8_u64,
    ).should eq(selected_actual_arm_rows)
    sizes_role = "root.arm.#{key.canonical_arm_index}.sizes"
    array_element_slots = w212_physical_array_element_rows_per_mark(
      normalized.data.stream(sizes_role), selected_actual_arm_rows,
    )
    array_element_slots.should eq([1_u64, 4_u64, 2_u64]) # S: Array slots, including Nullable NULLs.
    nonnull_json_rows = [0_u64, 3_u64, 2_u64]            # J, not R: NULL entries still serialize a default Object row.
    leaf_streams = normalized.json_object_leaf_for(key)
    leaf_streams.rows_per_mark.should eq(array_element_slots) # E includes Nullable's serialized default Object row.
    leaf_streams.rows_per_mark.should_not eq(nonnull_json_rows)
    plan.json_object_leaf_depth(key).should eq(4)

    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
    site = physical.json_object_site(key)
    site.leaf_key.should eq(key)
    site.array_level.should eq(1_u64)
    site.escaped_prefix.should eq(
      CrystalClick::PhysicalStreamName.append_escaped_component("payload", actual_type.name)
    )

    parent = File.tempname("crystal-click-w212-array-nullable-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w212_physical_write_part(part, dynamic, structures, granules, plans)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      w212_physical_expect_marks!(reader.read_marks(0, reader.mark_count), granules)

      child_name = site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
      child_marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(child_name)}.mrk2")).to_slice
      w212_physical_mark_rows(child_marks).should eq([2_u64, 2_u64, 2_u64, 0_u64]) # Physical P is not child E.

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed = Array(Array(CrystalClick::BinaryValue)).new(granules.size) { [] of CrystalClick::BinaryValue }
      table.scan_typed do |batch|
        observed[batch.mark_index] = batch.dynamic_bulk_values_for("payload").to_a
      end
      w212_physical_expect_marks!(observed, granules)

      candidate = [] of CrystalClick::BinaryValue
      table.scan_typed_candidate_marks([[1_i32]]) do |batch|
        batch.mark_index.should eq(1)
        candidate.concat(batch.dynamic_bulk_values_for("payload").to_a)
      end
      w212_physical_expect_marks!([candidate], [granules[1]])
      eof_callbacks = 0
      table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps outer P distinct from Dynamic-site Q and validates a wrapped all-empty JSON leaf E=0" do
    json = w212_physical_json_type
    actual_type = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    outer_type = CrystalClick::BinaryDataType.array(dynamic)
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(actual_type)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new("root.elements", arm, [0_i32])
    plans = [{key, w212_physical_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    empty_actual = CrystalClick::BinaryValue.array(actual_type, [] of CrystalClick::BinaryValue)
    nested_dynamic = w212_physical_dynamic_value(dynamic, empty_actual)
    outer = ->(items : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(outer_type, items)
    }
    granules = [
      [outer.call([] of CrystalClick::BinaryValue), outer.call([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
      [
        outer.call([nested_dynamic, nested_dynamic] of CrystalClick::BinaryValue),
        outer.call([nested_dynamic] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
      [outer.call([nested_dynamic] of CrystalClick::BinaryValue), outer.call([nested_dynamic] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root.elements" => structure}
    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      outer_type, structures, granules, json_object_leaf_plans: plans
    )

    physical_rows = [2_u64, 2_u64, 2_u64] # P
    site_occurrences = w212_physical_array_element_rows_per_mark(
      normalized.data.stream("root.sizes"), physical_rows,
    )
    site_occurrences.should eq([0_u64, 3_u64, 2_u64]) # Q
    w212_physical_lane_values_per_mark(
      normalized.data.stream("root.elements.discriminators"), 1_u64,
    ).should eq(site_occurrences)
    selected_arm_occurrences = w212_physical_lane_values_per_mark(
      normalized.data.stream("root.elements.arm.#{arm}.sizes"), 8_u64,
    )
    selected_arm_occurrences.should eq(site_occurrences) # R; this fixture has one selected actual arm.
    w212_physical_array_element_rows_per_mark(
      normalized.data.stream("root.elements.arm.#{arm}.sizes"), selected_arm_occurrences,
    ).should eq([0_u64, 0_u64, 0_u64])
    normalized.json_object_leaf_for(key).rows_per_mark.should eq([0_u64, 0_u64, 0_u64]) # E: no actual JSON rows.

    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      outer_type,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
    site = physical.json_object_site(key)

    parent = File.tempname("crystal-click-w212-empty-wrapped-leaf-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w212_physical_write_part(part, outer_type, structures, granules, plans)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", outer_type)
      reader.mark_row_counts.should eq(physical_rows)
      w212_physical_expect_marks!(reader.read_marks(0, reader.mark_count), granules)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      candidate = [] of CrystalClick::BinaryValue
      table.scan_typed_candidate_marks([[1_i32]]) do |batch|
        batch.mark_index.should eq(1)
        candidate.concat(batch.dynamic_bulk_values_for("payload").to_a)
      end
      w212_physical_expect_marks!([candidate], [granules[1]])
      eof_callbacks = 0
      table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)

      child_name = site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
      missing_part = File.join(parent, "missing_1_1_0")
      w212_physical_write_part(missing_part, outer_type, structures, granules, plans)
      File.delete(File.join(missing_part, "#{CrystalClick::StreamName.hash(child_name)}.bin"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(missing_part, "payload", outer_type)
      end

      corrupt_part = File.join(parent, "corrupt_1_1_0")
      w212_physical_write_part(corrupt_part, outer_type, structures, granules, plans)
      corrupt_table = CrystalClick::WidePartTable.open_selected_typed([corrupt_part], ["pk", "payload"])
      corrupt_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
      corrupt_bytes = File.read(corrupt_path).to_slice.dup
      raise "W212 E=0 child file is unexpectedly empty" if corrupt_bytes.empty?
      corrupt_bytes[0] = corrupt_bytes[0] ^ 0xff_u8
      File.write(corrupt_path, corrupt_bytes)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        corrupt_table.scan_typed_window(corrupt_table.total_row_count, 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "validates the wholly unselected wrapped Array(JSON) Dynamic arm on EOF and empty candidates" do
    json = w212_physical_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    structure = CrystalClick::DynamicStructure.new(
      [array_json, uint8] of CrystalClick::BinaryDataType
    )
    array_arm = structure.canonical_index_for(array_json)
    uint8_arm = structure.canonical_index_for(uint8)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", array_arm, [0_i32])
    plans = [{key, w212_physical_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    uint8_value = ->(value : UInt8) {
      w212_physical_dynamic_value(
        dynamic,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[value]),
      )
    }
    granules = [
      [uint8_value.call(1_u8), uint8_value.call(2_u8)] of CrystalClick::BinaryValue,
      [uint8_value.call(3_u8), uint8_value.call(4_u8)] of CrystalClick::BinaryValue,
      [uint8_value.call(5_u8), uint8_value.call(6_u8)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root" => structure}
    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic, structures, granules, json_object_leaf_plans: plans
    )

    physical_rows = [2_u64, 2_u64, 2_u64] # P remains positive although the JSON arm is never selected.
    w212_physical_lane_values_per_mark(
      normalized.data.stream("root.discriminators"), 1_u64,
    ).should eq(physical_rows)
    w212_physical_lane_values_per_mark(
      normalized.data.stream("root.arm.#{array_arm}.sizes"), 8_u64,
    ).should eq([0_u64, 0_u64, 0_u64]) # No Array(JSON) actuals.
    w212_physical_lane_values_per_mark(
      normalized.data.stream("root.arm.#{uint8_arm}.data"), 1_u64,
    ).should eq(physical_rows)
    normalized.json_object_leaf_for(key).rows_per_mark.should eq([0_u64, 0_u64, 0_u64]) # E=0, but the binding remains.

    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    site = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload").json_object_site(key)

    parent = File.tempname("crystal-click-w212-unselected-array-json-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w212_physical_write_part(part, dynamic, structures, granules, plans)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
      reader.mark_row_counts.should eq(physical_rows)
      w212_physical_expect_marks!(reader.read_marks(0, reader.mark_count), granules)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      selected = [] of CrystalClick::BinaryValue
      table.scan_typed_candidate_marks([[1_i32]]) do |batch|
        batch.mark_index.should eq(1)
        selected.concat(batch.dynamic_bulk_values_for("payload").to_a)
      end
      w212_physical_expect_marks!([selected], [granules[1]])

      child_name = site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
      metadata_part = File.join(parent, "metadata_1_1_0")
      w212_physical_write_part(metadata_part, dynamic, structures, granules, plans)
      metadata_table = CrystalClick::WidePartTable.open_selected_typed([metadata_part], ["pk", "payload"])
      metadata_path = File.join(metadata_part, "#{CrystalClick::StreamName.hash(child_name)}.mrk2")
      metadata_bytes = File.read(metadata_path).to_slice.dup
      raise "W212 E=0 child mark file is unexpectedly empty" if metadata_bytes.empty?
      metadata_bytes[0] = metadata_bytes[0] ^ 0xff_u8
      File.write(metadata_path, metadata_bytes)
      metadata_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        metadata_table.scan_typed_window(metadata_table.total_row_count, 1) do |_batch|
          metadata_callbacks += 1
        end
      end
      metadata_callbacks.should eq(0)

      body_part = File.join(parent, "body_1_1_0")
      w212_physical_write_part(body_part, dynamic, structures, granules, plans)
      body_table = CrystalClick::WidePartTable.open_selected_typed([body_part], ["pk", "payload"])
      body_path = File.join(body_part, "#{CrystalClick::StreamName.hash(child_name)}.bin")
      body_bytes = File.read(body_path).to_slice.dup
      raise "W212 E=0 child body is unexpectedly empty" if body_bytes.empty?
      body_bytes[0] = body_bytes[0] ^ 0xff_u8
      File.write(body_path, body_bytes)
      candidate_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        body_table.scan_typed_candidate_marks([[] of Int32]) { |_batch| candidate_callbacks += 1 }
      end
      candidate_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps equal Tuple(JSON, JSON) leaves separately bound and named" do
    json = w212_physical_json_type
    actual_type = CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(actual_type)
    keys = [
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [0_i32]),
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [1_i32]),
    ] of CrystalClick::BinaryDynamicJsonLeafKey
    plans = Array(Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )).new(keys.size)
    keys.each { |key| plans << {key, w212_physical_object_plan(json)} }
    row = ->(left : UInt8, right : UInt8) {
      tuple = CrystalClick::BinaryValue.tuple(
        actual_type,
        [w212_physical_json_value(json, left, left.to_u64), w212_physical_json_value(json, right, right.to_u64)] of CrystalClick::BinaryValue,
      )
      w212_physical_dynamic_value(dynamic, tuple)
    }
    granules = [
      [row.call(1_u8, 2_u8), row.call(3_u8, 4_u8)] of CrystalClick::BinaryValue,
      [row.call(5_u8, 6_u8), row.call(7_u8, 8_u8)] of CrystalClick::BinaryValue,
      [row.call(9_u8, 10_u8), row.call(11_u8, 12_u8)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root" => structure}

    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
    left_site = physical.json_object_site(keys[0])
    right_site = physical.json_object_site(keys[1])
    left_site.escaped_prefix.should_not eq(right_site.escaped_prefix)
    left_site.physical_plan.stream_names.should_not eq(right_site.physical_plan.stream_names)

    parent = File.tempname("crystal-click-w212-tuple-leaves-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w212_physical_write_part(part, dynamic, structures, granules, plans)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
      w212_physical_expect_marks!(reader.read_marks(0, reader.mark_count), granules)
      reader.physical_stream_names.each { |name| name.should be_a(String) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "resolves JSON through Map, Array, and Variant coordinates" do
    json = w212_physical_json_type
    string = CrystalClick::BinaryDataType.primitive("String")
    variant = CrystalClick::BinaryDataType.variant([json, string] of CrystalClick::BinaryDataType)
    json_arm = variant.children.index(json).not_nil!
    string_arm = variant.children.index(string).not_nil!
    array = CrystalClick::BinaryDataType.array(variant)
    actual_type = CrystalClick::BinaryDataType.map(string, array)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(actual_type), [1_i32, 0_i32, json_arm.to_i32]
    )
    plans = [{key, w212_physical_object_plan(json)}] of Tuple(
      CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
    )
    map_value = ->(id : UInt8, with_string : Bool) {
      variants = [] of CrystalClick::BinaryValue
      variants << CrystalClick::BinaryValue.variant(
        variant, json_arm, w212_physical_json_value(json, id, id.to_u64)
      )
      if with_string
        variants << CrystalClick::BinaryValue.variant(
          variant, string_arm, CrystalClick::BinaryValue.string("not-json")
        )
      end
      array_value = CrystalClick::BinaryValue.array(array, variants)
      map = CrystalClick::BinaryValue.map(
        actual_type,
        [CrystalClick::BinaryValue.string("entry"), array_value] of CrystalClick::BinaryValue,
      )
      w212_physical_dynamic_value(dynamic, map)
    }
    granules = [
      [map_value.call(1_u8, true), map_value.call(2_u8, false)] of CrystalClick::BinaryValue,
      [map_value.call(3_u8, true), map_value.call(4_u8, true)] of CrystalClick::BinaryValue,
      [map_value.call(5_u8, false), map_value.call(6_u8, true)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root" => structure}
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
    site = physical.json_object_site(key)
    site.array_level.should eq(2_u64)
    actual_prefix = CrystalClick::PhysicalStreamName.append_escaped_component("payload", actual_type.name)
    map_prefix = CrystalClick::PhysicalStreamName.append_escaped_field(actual_prefix, "values")
    variant_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(map_prefix, json.name)
    site.escaped_prefix.should eq(variant_prefix)

    parent = File.tempname("crystal-click-w212-map-variant-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      w212_physical_write_part(part, dynamic, structures, granules, plans)
      reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", dynamic)
      w212_physical_expect_marks!(reader.read_marks(0, reader.mark_count), granules)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires physical children for a hidden Nullable default JSON leaf before callbacks" do
    json = w212_physical_json_type
    nullable_json = CrystalClick::BinaryDataType.nullable(json)
    actual_type = CrystalClick::BinaryDataType.tuple(
      [json, nullable_json] of CrystalClick::BinaryDataType
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    arm = structure.canonical_index_for(actual_type)
    used_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [0_i32])
    unused_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [1_i32, 0_i32])
    plans = [
      {used_key, w212_physical_object_plan(json)},
      {unused_key, w212_physical_object_plan(json)},
    ] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    row = ->(id : UInt8) {
      tuple = CrystalClick::BinaryValue.tuple(
        actual_type,
        [
          w212_physical_json_value(json, id, id.to_u64),
          CrystalClick::BinaryValue.null(nullable_json),
        ] of CrystalClick::BinaryValue,
      )
      w212_physical_dynamic_value(dynamic, tuple)
    }
    granules = [
      [row.call(1_u8), row.call(2_u8)] of CrystalClick::BinaryValue,
      [row.call(3_u8), row.call(4_u8)] of CrystalClick::BinaryValue,
      [row.call(5_u8), row.call(6_u8)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    structures = {"root" => structure}
    normalized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic, structures, granules, json_object_leaf_plans: plans
    )
    normalized.json_object_leaf_for(unused_key).rows_per_mark.should eq([2_u64, 2_u64, 2_u64]) # E consumes NULL defaults.
    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      dynamic,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      json_object_leaf_plans: plans,
    )
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload")
    default_site = physical.json_object_site(unused_key)
    default_site.physical_plan.stream_names.should_not be_empty

    parent = File.tempname("crystal-click-w212-nullable-default-leaf-")
    Dir.mkdir(parent)
    begin
      missing_part = File.join(parent, "missing_1_1_0")
      w212_physical_write_part(missing_part, dynamic, structures, granules, plans)
      default_name = default_site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
      default_path = File.join(missing_part, "#{CrystalClick::StreamName.hash(default_name)}.bin")
      File.delete(default_path)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicBulkColumnReader.open(missing_part, "payload", dynamic)
      end

      corrupt_part = File.join(parent, "corrupt_1_1_0")
      w212_physical_write_part(corrupt_part, dynamic, structures, granules, plans)
      table = CrystalClick::WidePartTable.open_selected_typed([corrupt_part], ["pk", "payload"])
      corrupt_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash(default_name)}.bin")
      corrupt_bytes = File.read(corrupt_path).to_slice.dup
      raise "W212 Nullable-default child file is unexpectedly empty" if corrupt_bytes.empty?
      corrupt_bytes[0] = corrupt_bytes[0] ^ 0xff_u8
      File.write(corrupt_path, corrupt_bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "compares staged nested JSON content and raw paths instead of owner identity" do
    json = w212_physical_json_type
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [string, json] of CrystalClick::BinaryDataType
    )
    actual_type = CrystalClick::BinaryDataType.array(tuple_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    build = ->(counter : UInt64, counter_path : String) {
      tuple = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [
          CrystalClick::BinaryValue.string("owner"),
          w212_physical_json_value(json, 7_u8, counter, counter_path),
        ] of CrystalClick::BinaryValue,
      )
      actual = CrystalClick::BinaryValue.array(
        actual_type, [tuple] of CrystalClick::BinaryValue
      )
      w212_physical_dynamic_value(dynamic_type, actual)
    }

    left_owner = build.call(701_u64, "counter")
    equal_distinct_owner = build.call(701_u64, "counter")
    left_owner.same?(equal_distinct_owner).should be_false
    CrystalClick.w212_physical_compare_dynamic!(left_owner, equal_distinct_owner)

    changed_nested_scalar = build.call(702_u64, "counter")
    changed_raw_path = build.call(701_u64, "other_counter")
    [changed_nested_scalar, changed_raw_path].each do |changed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick.w212_physical_compare_dynamic!(left_owner, changed)
      end
    end
  end
end

module CrystalClick
  module WidePartWriter
    private class DynamicBulkPartWriter
      def self.w212_physical_compare!(actual : BinaryValue, expected : BinaryValue) : Nil
        compare_binary_value!(actual, expected)
      end
    end

    def self.w212_physical_compare_dynamic!(actual : BinaryValue, expected : BinaryValue) : Nil
      DynamicBulkPartWriter.w212_physical_compare!(actual, expected)
    end
  end

  def self.w212_physical_compare_dynamic!(actual : BinaryValue, expected : BinaryValue) : Nil
    WidePartWriter.w212_physical_compare_dynamic!(actual, expected)
  end
end
