require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"

private def w280a_uint8_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive("UInt8")
end

private def w280a_json_type(path : String = "id", value_type : CrystalClick::BinaryDataType = CrystalClick::BinaryDataType.primitive("UInt64")) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {path => value_type} of String => CrystalClick::BinaryDataType,
  )
end

private def w280a_schema(json_type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnSchema
  declaration = "Tuple(" \
                "Array(Tuple(Array(#{json_type.name}), #{json_type.name})), " \
                "Array(Tuple(UInt8, Array(UInt8))), " \
                "Array(Tuple(Array(#{json_type.name}), #{json_type.name})), " \
                "#{json_type.name})"
  CrystalClick::StorageColumnSchema.parse(declaration)
end

private def w280a_object_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 4_u64,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    statistics: CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    Hash(String, CrystalClick::DynamicStructure).new,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, json_type.json_type.not_nil!.typed_paths)
end

private def w280a_object_value(
  json_type : CrystalClick::BinaryDataType,
  value : UInt64,
  typed_path : String = "id",
) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.object_document(
    CrystalClick::ObjectDocument.new(
      {typed_path => CrystalClick::BinaryValue.uint64(value)} of String => CrystalClick::BinaryValue,
    ),
  )
end

private def w280a_json_array(json_type : CrystalClick::BinaryDataType, values : Array(UInt64)) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.array(values.map { |value| w280a_object_value(json_type, value) }.to_a)
end

private def w280a_bulk_item(value : UInt8, nested : Array(UInt8)) : CrystalClick::BinaryValue
  uint8 = w280a_uint8_type
  array_type = CrystalClick::BinaryDataType.array(uint8)
  tuple_type = CrystalClick::BinaryDataType.tuple([uint8, array_type] of CrystalClick::BinaryDataType)
  nested_values = nested.map { |item| CrystalClick::BinaryValue.fixed(uint8, Bytes[item]) }.to_a
  CrystalClick::BinaryValue.tuple(
    tuple_type,
    [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[value]),
      CrystalClick::BinaryValue.array(array_type, nested_values),
    ] of CrystalClick::BinaryValue,
  )
end

private def w280a_bulk_value(items : Array(Tuple(UInt8, Array(UInt8)))) : CrystalClick::StorageColumnValue
  uint8 = w280a_uint8_type
  nested_type = CrystalClick::BinaryDataType.array(uint8)
  tuple_type = CrystalClick::BinaryDataType.tuple([uint8, nested_type] of CrystalClick::BinaryDataType)
  type = CrystalClick::BinaryDataType.array(tuple_type)
  values = items.map { |item| w280a_bulk_item(item[0], item[1]) }.to_a
  CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.array(type, values))
end

private def w280a_bulk_type : CrystalClick::BinaryDataType
  uint8 = w280a_uint8_type
  CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.tuple(
      [uint8, CrystalClick::BinaryDataType.array(uint8)] of CrystalClick::BinaryDataType,
    ),
  )
end

private def w280a_row(
  json_type : CrystalClick::BinaryDataType,
  left : Array(Tuple(Array(UInt64), UInt64)),
  bulk : Array(Tuple(UInt8, Array(UInt8))),
  right : Array(Tuple(Array(UInt64), UInt64)),
  root_id : UInt64,
) : CrystalClick::StorageColumnValue
  tuple_values = ->(entries : Array(Tuple(Array(UInt64), UInt64))) do
    entries.map do |entry|
      CrystalClick::StorageColumnValue.tuple(
        [
          w280a_json_array(json_type, entry[0]),
          w280a_object_value(json_type, entry[1]),
        ] of CrystalClick::StorageColumnValue,
      )
    end.to_a
  end
  CrystalClick::StorageColumnValue.tuple(
    [
      CrystalClick::StorageColumnValue.array(tuple_values.call(left)),
      w280a_bulk_value(bulk),
      CrystalClick::StorageColumnValue.array(tuple_values.call(right)),
      w280a_object_value(json_type, root_id),
    ] of CrystalClick::StorageColumnValue,
  )
end

private def w280a_mixed_rows(json_type : CrystalClick::BinaryDataType) : Array(CrystalClick::StorageColumnValue)
  [
    w280a_row(
      json_type,
      [{[] of UInt64, 100_u64}, {[101_u64, 102_u64], 103_u64}] of Tuple(Array(UInt64), UInt64),
      [{11_u8, [21_u8]}, {12_u8, [] of UInt8}] of Tuple(UInt8, Array(UInt8)),
      [] of Tuple(Array(UInt64), UInt64),
      200_u64,
    ),
    w280a_row(
      json_type,
      [] of Tuple(Array(UInt64), UInt64),
      [] of Tuple(UInt8, Array(UInt8)),
      [{[104_u64], 105_u64}, {[] of UInt64, 106_u64}] of Tuple(Array(UInt64), UInt64),
      201_u64,
    ),
    w280a_row(
      json_type,
      [{[107_u64], 108_u64}] of Tuple(Array(UInt64), UInt64),
      [{13_u8, [] of UInt8}] of Tuple(UInt8, Array(UInt8)),
      [{[] of UInt64, 109_u64}] of Tuple(Array(UInt64), UInt64),
      202_u64,
    ),
    w280a_row(
      json_type,
      [] of Tuple(Array(UInt64), UInt64),
      [{14_u8, [22_u8, 23_u8]}] of Tuple(UInt8, Array(UInt8)),
      [] of Tuple(Array(UInt64), UInt64),
      203_u64,
    ),
  ] of CrystalClick::StorageColumnValue
end

private def w280a_empty_domain_rows(json_type : CrystalClick::BinaryDataType) : Array(CrystalClick::StorageColumnValue)
  [
    w280a_row(
      json_type,
      [] of Tuple(Array(UInt64), UInt64),
      [] of Tuple(UInt8, Array(UInt8)),
      [] of Tuple(Array(UInt64), UInt64),
      210_u64,
    ),
    w280a_row(
      json_type,
      [] of Tuple(Array(UInt64), UInt64),
      [] of Tuple(UInt8, Array(UInt8)),
      [] of Tuple(Array(UInt64), UInt64),
      211_u64,
    ),
  ] of CrystalClick::StorageColumnValue
end

private def w280a_column(
  schema : CrystalClick::StorageColumnSchema,
  json_type : CrystalClick::BinaryDataType,
  rows : Array(CrystalClick::StorageColumnValue),
  rows_per_mark : Int32,
) : CrystalClick::CompactPartColumn
  sites = [
    "root/tuple[0]/array[0]/tuple[0]/array[0]",
    "root/tuple[0]/array[0]/tuple[1]",
    "root/tuple[2]/array[0]/tuple[0]/array[0]",
    "root/tuple[2]/array[0]/tuple[1]",
    "root/tuple[3]",
  ] of String
  plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
  object_plan = w280a_object_plan(json_type)
  sites.each { |site| plans[site] = object_plan }
  granules = rows.each_slice(rows_per_mark).map(&.to_a).to_a
  CrystalClick::CompactPartColumn.json(
    "w280_adversary",
    schema,
    granules,
    CrystalClick::CompactJsonWriteContext.new(plans),
  )
end

private def w280a_signature(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue) : String
  if schema.object?
    "J#{value.object_document.value_for("id").as_uint64}"
  elsif schema.bulk?
    w280a_binary_signature(value.bulk_value)
  elsif schema.array?
    "A[#{value.array_values.map { |child| w280a_signature(schema.child_at(0), child) }.join(",")}]"
  elsif schema.tuple?
    children = schema.child_count.times.map do |index|
      w280a_signature(schema.child_at(index), value.child_at(index))
    end
    "T(#{children.join(",")})"
  else
    raise CrystalClick::UnsupportedFormatError.new("W280 adversary signature encountered an unsupported schema node")
  end
end

private def w280a_binary_signature(value : CrystalClick::BinaryValue) : String
  type = value.type
  if type.tag == CrystalClick::BinaryDataType::TAG_UINT8
    "U#{value.bytes[0]}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_ARRAY
    "A[#{value.elements.map { |child| w280a_binary_signature(child) }.join(",")}]"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE || type.tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    "T(#{value.elements.map { |child| w280a_binary_signature(child) }.join(",")})"
  else
    raise CrystalClick::UnsupportedFormatError.new("W280 adversary Bulk signature encountered an unsupported type")
  end
end

private def w280a_expected_signatures : Array(String)
  [
    "T(A[T(A[],J100),T(A[J101,J102],J103)],A[T(U11,A[U21]),T(U12,A[])],A[],J200)",
    "T(A[],A[],A[T(A[J104],J105),T(A[],J106)],J201)",
    "T(A[T(A[J107],J108)],A[T(U13,A[])],A[T(A[],J109)],J202)",
    "T(A[],A[T(U14,A[U22,U23])],A[],J203)",
  ] of String
end

private def w280a_le64(values : Array(UInt64)) : Bytes
  Bytes.new(values.size * 8) do |index|
    value = values[index // 8]
    shift = (index % 8) * 8
    ((value >> shift) & 0xff_u64).to_u8
  end
end

private def w280a_callback_bytes(
  encoded : CrystalClick::CompactJsonEncodedColumn,
  plan : CrystalClick::CompactJsonCallbackPlan,
  callback_name : String,
  mark_index : Int32,
) : Bytes
  event = plan.callback_events.find { |candidate| candidate.name == callback_name } ||
          raise(CrystalClick::UnsupportedFormatError.new("W280 adversary callback was not planned"))
  encoded.callback_bytes(event, mark_index)
end

private def w280a_assert_repeated_json_and_opaque_bulk_order_and_bytes : Nil
  json_type = w280a_json_type
  schema = w280a_schema(json_type)
  rows = w280a_mixed_rows(json_type)
  column = w280a_column(schema, json_type, rows, 2)
  input = column.json_input
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  plan = CrystalClick::CompactJsonCallbackPlan.new(input, limits, budget)

  json_keys = [
    "root/tuple[0]/array[0]/tuple[0]/array[0]",
    "root/tuple[0]/array[0]/tuple[1]",
    "root/tuple[2]/array[0]/tuple[0]/array[0]",
    "root/tuple[2]/array[0]/tuple[1]",
    "root/tuple[3]",
  ] of String
  plan.json_sites.map(&.key).should eq(json_keys)
  plan.array_sites.map(&.key).should eq([
    "root/tuple[0]",
    "root/tuple[0]/array[0]/tuple[0]",
    "root/tuple[2]",
    "root/tuple[2]/array[0]/tuple[0]",
  ] of String)
  schema.child_at(1).bulk?.should be_true
  schema.child_at(1).bulk_type.should eq(w280a_bulk_type)
  plan.bulk_site_count.should eq(1)
  plan.uint8_site_count.should eq(0)

  bulk_site = plan.schema_plan.bulk_site("root/tuple[1]")
  roles = [] of String
  bulk_site.each_role { |role| roles << role.name }
  roles.should eq([
    "root.sizes",
    "root.elements.field.0.data",
    "root.elements.field.1.sizes",
    "root.elements.field.1.elements.data",
  ] of String)
  bulk_site.size_lane_count.should eq(2)

  # Prefixes remain one root-column phase. Bodies are then the literal schema
  # DFS: Array(size) immediately followed by that Array's descendants, while
  # the opaque JSON-free Bulk site contributes its serializer's DFS roles.
  expected = [] of String
  json_keys.each do |key|
    plan.site_binding(key).prefix_pairs.each { |pair| expected << pair[1] }
  end
  body_tokens = [
    {:array, "root/tuple[0]"},
    {:array, "root/tuple[0]/array[0]/tuple[0]"},
    {:json, json_keys[0]},
    {:json, json_keys[1]},
    {:bulk, "root/tuple[1]"},
    {:array, "root/tuple[2]"},
    {:array, "root/tuple[2]/array[0]/tuple[0]"},
    {:json, json_keys[2]},
    {:json, json_keys[3]},
    {:json, json_keys[4]},
  ] of Tuple(Symbol, String)
  body_tokens.each do |token|
    case token[0]
    when :array
      expected << plan.schema_plan.array_site(token[1]).callback_name
    when :json
      plan.site_binding(token[1]).body_pairs.each { |pair| expected << pair[1] }
    when :bulk
      plan.schema_plan.bulk_site(token[1]).each_role do |role|
        expected << plan.schema_plan.bulk_site(token[1]).callback_name_for(role.name)
      end
    else
      raise CrystalClick::UnsupportedFormatError.new("unknown W280 adversary body token")
    end
  end
  plan.callback_names.should eq(expected)
  plan.callback_names.uniq.size.should eq(plan.callback_event_count)

  encoded = CrystalClick::CompactJsonEncodedColumn.encode(plan, budget)
  array_expectations = [
    {"root/tuple[0]", [[2_u64, 0_u64], [1_u64, 0_u64]]},
    {"root/tuple[0]/array[0]/tuple[0]", [[0_u64, 2_u64], [1_u64]]},
    {"root/tuple[2]", [[0_u64, 2_u64], [1_u64, 0_u64]]},
    {"root/tuple[2]/array[0]/tuple[0]", [[1_u64, 0_u64], [0_u64]]},
  ] of Tuple(String, Array(Array(UInt64)))
  array_expectations.each do |entry|
    callback = plan.schema_plan.array_site(entry[0]).callback_name
    2.times do |mark|
      w280a_callback_bytes(encoded, plan, callback, mark).should eq(w280a_le64(entry[1][mark]))
    end
  end

  expected_bulk_sizes = [
    {"root.sizes", [[2_u64, 0_u64], [1_u64, 1_u64]]},
    {"root.elements.field.1.sizes", [[1_u64, 0_u64], [0_u64, 2_u64]]},
  ] of Tuple(String, Array(Array(UInt64)))
  expected_bulk_sizes.each do |entry|
    callback = bulk_site.callback_name_for(entry[0])
    2.times do |mark|
      w280a_callback_bytes(encoded, plan, callback, mark).should eq(w280a_le64(entry[1][mark]))
    end
  end
  w280a_callback_bytes(encoded, plan, bulk_site.callback_name_for("root.elements.field.0.data"), 0).should eq(Bytes[11_u8, 12_u8])
  w280a_callback_bytes(encoded, plan, bulk_site.callback_name_for("root.elements.field.0.data"), 1).should eq(Bytes[13_u8, 14_u8])
  w280a_callback_bytes(
    encoded,
    plan,
    bulk_site.callback_name_for("root.elements.field.1.elements.data"),
    0,
  ).should eq(Bytes[21_u8])
  w280a_callback_bytes(
    encoded,
    plan,
    bulk_site.callback_name_for("root.elements.field.1.elements.data"),
    1,
  ).should eq(Bytes[22_u8, 23_u8])

  array_sizes = {
    "root/tuple[0]"                   => [2_u64, 0_u64],
    "root/tuple[0]/array[0]/tuple[0]" => [0_u64, 2_u64],
    "root/tuple[2]"                   => [0_u64, 2_u64],
    "root/tuple[2]/array[0]/tuple[0]" => [1_u64, 0_u64],
  } of String => Array(UInt64)
  rows_at_sites = plan.schema_plan.mark_site_rows(2_u64, array_sizes)
  rows_at_sites["root/tuple[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[0]/array[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[0]/array[0]/tuple[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[0]/array[0]/tuple[0]/array[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[0]/array[0]/tuple[1]"].should eq(2_u64)
  rows_at_sites["root/tuple[2]"].should eq(2_u64)
  rows_at_sites["root/tuple[2]/array[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[2]/array[0]/tuple[0]"].should eq(2_u64)
  rows_at_sites["root/tuple[2]/array[0]/tuple[0]/array[0]"].should eq(1_u64)
  rows_at_sites["root/tuple[2]/array[0]/tuple[1]"].should eq(2_u64)
  rows_at_sites["root/tuple[3]"].should eq(2_u64)

  missing_lane = array_sizes.dup
  missing_lane.delete("root/tuple[2]/array[0]/tuple[0]")
  expect_raises(CrystalClick::CorruptPartError) do
    plan.schema_plan.mark_site_rows(2_u64, missing_lane)
  end
  wrong_inherited_lane_extent = array_sizes.dup
  wrong_inherited_lane_extent["root/tuple[0]/array[0]/tuple[0]"] = [2_u64]
  expect_raises(CrystalClick::CorruptPartError) do
    plan.schema_plan.mark_site_rows(2_u64, wrong_inherited_lane_extent)
  end
  nil
end

private def w280a_assert_empty_domains : Nil
  json_type = w280a_json_type
  schema = w280a_schema(json_type)
  rows = w280a_empty_domain_rows(json_type)
  column = w280a_column(schema, json_type, rows, 2)
  column.json_input.granules[0].each do |row|
    row.child_at(1).bulk?.should be_true
    row.child_at(1).bulk_value.type.should eq(schema.child_at(1).bulk_type)
    row.child_at(1).bulk_value.element_count.should eq(0)
  end
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  plan = CrystalClick::CompactJsonCallbackPlan.new(column.json_input, limits, budget)
  sizes = {
    "root/tuple[0]"                   => [0_u64, 0_u64],
    "root/tuple[0]/array[0]/tuple[0]" => [] of UInt64,
    "root/tuple[2]"                   => [0_u64, 0_u64],
    "root/tuple[2]/array[0]/tuple[0]" => [] of UInt64,
  } of String => Array(UInt64)
  rows_at_sites = plan.schema_plan.mark_site_rows(2_u64, sizes)
  rows_at_sites["root/tuple[0]/array[0]"].should eq(0_u64)
  rows_at_sites["root/tuple[0]/array[0]/tuple[0]/array[0]"].should eq(0_u64)
  rows_at_sites["root/tuple[2]/array[0]"].should eq(0_u64)
  rows_at_sites["root/tuple[2]/array[0]/tuple[0]/array[0]"].should eq(0_u64)

  encoded = CrystalClick::CompactJsonEncodedColumn.encode(plan, budget)
  empty_domain_array_sizes = {
    "root/tuple[0]"                   => [0_u64, 0_u64],
    "root/tuple[0]/array[0]/tuple[0]" => [] of UInt64,
    "root/tuple[2]"                   => [0_u64, 0_u64],
    "root/tuple[2]/array[0]/tuple[0]" => [] of UInt64,
  } of String => Array(UInt64)
  plan.array_sites.each do |site|
    w280a_callback_bytes(encoded, plan, site.callback_name, 0).should eq(w280a_le64(empty_domain_array_sizes[site.key]))
  end
  bulk = plan.schema_plan.bulk_site("root/tuple[1]")
  bulk.each_role do |role|
    expected = if role.name == "root.sizes"
                 w280a_le64([0_u64, 0_u64])
               else
                 Bytes.empty
               end
    w280a_callback_bytes(encoded, plan, bulk.callback_name_for(role.name), 0).should eq(expected)
  end
  nil
end

private def w280a_assert_round_trip(
  rows : Array(CrystalClick::StorageColumnValue),
  schema : CrystalClick::StorageColumnSchema,
  json_type : CrystalClick::BinaryDataType,
  expected : Array(String),
  format : CrystalClick::CompactMarkFormat,
) : Nil
  parent = File.tempname("crystal-click-w280-adversary-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    column = w280a_column(schema, json_type, rows, 2)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      "pk",
      Slice(UInt64).new(rows.size) { |index| index.to_u64 + 1_u64 },
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      frame_bytes: 4096,
      mark_format: format,
    ).should eq(part_path)
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, "w280_adversary", schema)
    physical_names = [] of String
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(
      column.json_input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    callback_plan.each_physical_callback_name { |name| physical_names << name }
    if format.mrk4?
      reader.physical_stream_names.should eq(physical_names)
    else
      reader.physical_stream_names.should be_empty
    end
    decoded_marks = reader.read_marks(0, reader.mark_count)
    decoded_marks.flatten.each do |value|
      value.child_at(1).bulk?.should be_true
      value.child_at(1).bulk_value.type.should eq(schema.child_at(1).bulk_type)
    end
    actual = decoded_marks.flatten.map { |value| w280a_signature(schema, value) }
    actual.should eq(expected)
    reader.read_marks(reader.mark_count, 0).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w280a_assert_shape_budget_boundaries : Nil
  schema = w280a_schema(w280a_json_type)
  shape = CrystalClick::CompactRecursiveJsonSchemaPlan.measure_shape(schema)
  probe = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
  CrystalClick::CompactRecursiveJsonSchemaPlan.preflight_shape!(schema, "w280_adversary", shape, probe)

  required_nodes = probe.node_count + shape.bulk_role_count.to_i64 + shape.bulk_count.to_i64
  required_elements = probe.element_count + (shape.bulk_role_count * 2_u64).to_i64
  required_bytes = probe.wire_byte_count + shape.bulk_role_name_bytes.to_i64
  exact = CrystalClick::BinaryCodecLimits.new(
    max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
    max_nodes: required_nodes,
    max_elements: required_elements,
    max_bytes: required_bytes,
  )
  exact_budget = CrystalClick::BinaryCodecBudget.new(exact, true)
  CrystalClick::CompactRecursiveJsonSchemaPlan.preflight_shape!(schema, "w280_adversary", shape, exact_budget)
  exact_budget.node_count.should eq(probe.node_count)
  exact_budget.element_count.should eq(probe.element_count)
  exact_budget.wire_byte_count.should eq(probe.wire_byte_count)

  short_nodes = CrystalClick::BinaryCodecBudget.new(
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: required_nodes - 1,
      max_elements: required_elements,
      max_bytes: required_bytes,
    ),
    true,
  )
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::CompactRecursiveJsonSchemaPlan.preflight_shape!(schema, "w280_adversary", shape, short_nodes)
  end
  short_nodes.node_count.should eq(0_i64)
  short_elements = CrystalClick::BinaryCodecBudget.new(
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: required_nodes,
      max_elements: required_elements - 1,
      max_bytes: required_bytes,
    ),
    true,
  )
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::CompactRecursiveJsonSchemaPlan.preflight_shape!(schema, "w280_adversary", shape, short_elements)
  end
  short_elements.node_count.should eq(0_i64)
  short_elements.element_count.should eq(0_i64)
  short_elements.wire_byte_count.should eq(0_i64)
  short_bytes = CrystalClick::BinaryCodecBudget.new(
    CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: required_nodes,
      max_elements: required_elements,
      max_bytes: required_bytes - 1,
    ),
    true,
  )
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::CompactRecursiveJsonSchemaPlan.preflight_shape!(schema, "w280_adversary", shape, short_bytes)
  end
  short_bytes.node_count.should eq(0_i64)
  short_bytes.element_count.should eq(0_i64)
  short_bytes.wire_byte_count.should eq(0_i64)

  opaque_type = schema.child_at(1).bulk_type
  # The Bulk subtree starts at schema descriptor depth 2 (root Tuple is 1);
  # its nested UInt8 reaches depth 5. Preserve that inherited origin instead
  # of checking the isolated subtree from depth 1.
  exact_depth = CrystalClick::BinaryCodecLimits.new(5, 4096, 1_000_000, 4096)
  shallow_depth = CrystalClick::BinaryCodecLimits.new(4, 4096, 1_000_000, 4096)
  CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(opaque_type, 2_i32, exact_depth).should be_true
  CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(opaque_type, 2_i32, shallow_depth).should be_false
  nil
end

private def w280a_assert_typed_path_size_collision : Nil
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  json_type = w280a_json_type("size0", uint64)
  schema = CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  site = "root/array[0]"
  rows = [
    [
      CrystalClick::StorageColumnValue.array(
        [w280a_object_value(json_type, 7_u64, "size0")] of CrystalClick::StorageColumnValue,
      ),
    ] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
  column = CrystalClick::CompactPartColumn.json(
    "w280_adversary_collision",
    schema,
    rows,
    CrystalClick::CompactJsonWriteContext.new({site => w280a_object_plan(json_type)} of String => CrystalClick::ObjectDocumentPlan),
  )
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  expect_raises(CrystalClick::UnsupportedFormatError, "Compact JSON callback schedule repeats a physical callback") do
    CrystalClick::CompactJsonCallbackPlan.new(
      column.json_input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
  end
  parent = File.tempname("crystal-click-w280-size0-collision-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    expect_raises(CrystalClick::UnsupportedFormatError, "Compact JSON callback schedule repeats a physical callback") do
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "pk",
        Slice(UInt64).new(1) { 1_u64 },
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: 1,
        frame_bytes: 4096,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )
    end
    File.exists?(part_path).should be_false
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w280a_assert_mrk4_mixed_ledger_guards : Nil
  type = w280a_bulk_type
  first_row = CrystalClick::BinaryValue.array(
    type,
    [
      w280a_bulk_item(11_u8, [21_u8]),
      w280a_bulk_item(12_u8, [] of UInt8),
    ] of CrystalClick::BinaryValue,
  )
  second_row = CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
  column = CrystalClick::CompactPartColumn.binary_bulk(
    "payload",
    type,
    [[first_row, second_row] of CrystalClick::BinaryValue],
  )
  parent = File.tempname("crystal-click-w280-ledger-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      "pk",
      Slice[1_u64, 2_u64],
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      frame_bytes: 4096,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    )
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.mrk4?.should be_true
    physical.mark_row_counts.should eq([2_u64])
    granule = physical.read_window("payload", 0, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("W280 mixed-ledger fixture has no selected parent mark"))

    physical_plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload")
    role_names = [
      "root.sizes",
      "root.elements.field.0.data",
      "root.elements.field.1.sizes",
      "root.elements.field.1.elements.data",
    ] of String
    expected_events = role_names.map { |role| physical_plan.stream_name_for(role) }
    physical_events = granule.shards.map do |shard|
      shard.stream_name || raise(CrystalClick::CorruptPartError.new("W280 mixed-ledger fixture has an unnamed MRK4 callback"))
    end
    physical_events.should eq(expected_events)

    reordered = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
      physical,
      "payload",
      granule,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
    )
    reordered.finish_prefixes!
    reordered.begin_mixed_body_schedule!(2)
    # Attempt the first UInt8 body before the Array size callback that owns its
    # inherited row domain. The physical cursor must reject this without
    # consuming the parent mark, after which the exact DFS schedule succeeds.
    expect_raises(CrystalClick::CorruptPartError, "Compact mrk4 callback order differs from the selected serializer traversal") do
      reordered.capture_bulk_body(expected_events[1], 2)
    end
    reordered.capture_mixed_array_size_lane(expected_events[0], 16)
    reordered.capture_bulk_body(expected_events[1], 2)
    reordered.capture_mixed_array_size_lane(expected_events[2], 16)
    reordered.capture_bulk_body(expected_events[3], 1)
    reordered.finish_mark!(expected_events)
    reordered.complete?.should be_true

    missing = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
      physical,
      "payload",
      granule,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
    )
    missing.finish_prefixes!
    missing.begin_mixed_body_schedule!(2)
    missing.capture_mixed_array_size_lane(expected_events[0], 16)
    missing.capture_bulk_body(expected_events[1], 2)
    missing.capture_mixed_array_size_lane(expected_events[2], 16)
    expect_raises(CrystalClick::CorruptPartError, "recursive Compact parent callback sequence differs from its frozen serializer schedule") do
      missing.finish_mark!(expected_events)
    end
    missing.complete?.should be_false
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w280a_assert_wrong_inherited_bulk_domain_rejected : Nil
  json_type = w280a_json_type
  schema = w280a_schema(json_type)
  rows = w280a_mixed_rows(json_type) + w280a_mixed_rows(json_type)
  column = w280a_column(schema, json_type, rows, 2)
  parent = File.tempname("crystal-click-w280-domain-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    frame_bytes = 1_048_576
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      "pk",
      Slice(UInt64).new(rows.size) { |index| index.to_u64 + 1_u64 },
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      frame_bytes: frame_bytes,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    )
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(
      column.json_input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bulk = callback_plan.schema_plan.bulk_site("root/tuple[1]")
    size_callback = bulk.callback_name_for("root.sizes")
    granule = physical.read_window(column.name, 0, 1).granules.first? ||
              raise(CrystalClick::CorruptPartError.new("W280 domain fixture has no first parent mark"))
    size_shard = granule.shards.find { |shard| shard.stream_name == size_callback } ||
                 raise(CrystalClick::CorruptPartError.new("W280 domain fixture has no root Bulk size callback"))
    original_size_bytes = size_shard.bytes
    original_size_bytes.should eq(w280a_le64([2_u64, 0_u64]))
    (size_shard.logical_end - size_shard.logical_start).should eq(16_i64)

    data_path = File.join(part_path, "data.bin")
    raw = CrystalClick::CompressedMarkReader.read_all(data_path, File.size(data_path).to_i64)
    mutation_start = size_shard.logical_start.to_i
    original_size_bytes.size.times { |index| raw[mutation_start + index] = 0_u8 }

    # Re-encode the same logical tape and remap every saved MRK4 slot start.
    # This preserves the physical slot roster and row grid even when the tape
    # spans multiple literal-LZ4 frames; compressed coordinates are not
    # assumed stable across a rewrite.
    slots = physical.physical_roster
    spans_before = w280a_mrk4_slot_grid(physical)
    roster_before = slots.map { |slot| {slot.index, slot.column_name, slot.stream_name} }
    slot_grid = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(physical.granule_count) do
      Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
    end
    columns = [] of String
    slots.each { |slot| columns << slot.column_name unless columns.includes?(slot.column_name) }
    columns.each do |column_name|
      window = physical.read_window(column_name, 0, physical.granule_count)
      window.granules.each_with_index do |mark, mark_index|
        mark.shards.each do |shard|
          unless shard.slot_index >= 0 && shard.slot_index < slots.size && slots[shard.slot_index].column_name == column_name
            raise "W280 reframe observed a shard outside its MRK4 slot roster"
          end
          raise "W280 reframe duplicated an MRK4 slot" if slot_grid[mark_index][shard.slot_index]
          slot_grid[mark_index][shard.slot_index] = shard
        end
      end
    end
    queries = [] of UInt64
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        shard = slot_grid[mark_index][slot_index] || raise "W280 reframe missed an MRK4 slot"
        queries << shard.logical_start.to_u64
      end
    end
    slots.size.times { queries << raw.size.to_u64 }
    positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw,
      [0_u64, raw.size.to_u64],
      [physical.row_count],
      queries,
      frame_bytes: frame_bytes,
    )
    positions = positioned.positions
    positions.size.should eq(queries.size)

    record_width = slots.size * 16 + 8
    marks = Bytes.new((physical.granule_count + 1) * record_width, 0_u8)
    physical.granule_count.times do |mark_index|
      slots.size.times do |slot_index|
        pair = positions[mark_index * slots.size + slot_index]
        w280a_write_u64_le(marks, mark_index * record_width + slot_index * 16, pair[0])
        w280a_write_u64_le(marks, mark_index * record_width + slot_index * 16 + 8, pair[1])
      end
      w280a_write_u64_le(marks, mark_index * record_width + slots.size * 16, physical.mark_row_counts[mark_index])
    end
    slots.size.times do |slot_index|
      pair = positions[physical.granule_count * slots.size + slot_index]
      w280a_write_u64_le(marks, physical.granule_count * record_width + slot_index * 16, pair[0])
      w280a_write_u64_le(marks, physical.granule_count * record_width + slot_index * 16 + 8, pair[1])
    end
    w280a_write_u64_le(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)
    File.write(data_path, positioned.files.data)
    File.write(File.join(part_path, "data.mrk4"), marks)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)

    mutated_physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    mutated_physical.physical_roster.map { |slot| {slot.index, slot.column_name, slot.stream_name} }.should eq(roster_before)
    mutated_physical.mark_row_counts.should eq(physical.mark_row_counts)
    mutated_granule = mutated_physical.read_window(column.name, 0, 1).granules.first? ||
                      raise(CrystalClick::CorruptPartError.new("W280 mutated domain fixture lost its parent mark"))
    mutated_size_shard = mutated_granule.shards.find { |shard| shard.stream_name == size_callback } ||
                         raise(CrystalClick::CorruptPartError.new("W280 mutated domain callback is absent"))
    mutated_size_shard.logical_start.should eq(size_shard.logical_start)
    mutated_size_shard.logical_end.should eq(size_shard.logical_end)
    mutated_size_shard.bytes.should eq(Bytes.new(16, 0_u8))
    w280a_mrk4_slot_grid(mutated_physical).should eq(spans_before)

    expect_raises(CrystalClick::CorruptPartError, "recursive Compact named callback has the wrong byte extent") do
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column.name, schema)
      reader.read_marks(0, 1)
    end
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w280a_mrk4_slot_grid(
  physical : CrystalClick::CompactPartPhysicalContext,
) : Array(Array(Tuple(Int32, String?, Int64, Int64)))
  slots = physical.physical_roster
  columns = [] of String
  slots.each { |slot| columns << slot.column_name unless columns.includes?(slot.column_name) }
  grid = Array(Array(Tuple(Int32, String?, Int64, Int64))).new(physical.granule_count) do
    [] of Tuple(Int32, String?, Int64, Int64)
  end
  columns.each do |column_name|
    window = physical.read_window(column_name, 0, physical.granule_count)
    window.granules.each_with_index do |granule, mark_index|
      granule.shards.each do |shard|
        grid[mark_index] << {shard.slot_index, shard.stream_name, shard.logical_start, shard.logical_end}
      end
    end
  end
  grid.each(&.sort_by!(&.[0]))
  grid
end

private def w280a_write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

describe "W280 recursive JSON adversary controls" do
  it "seals serializer DFS, >4 Object sites, opaque Bulk roles, and per-lane inherited domains" do
    w280a_assert_repeated_json_and_opaque_bulk_order_and_bytes
  end

  it "retains the whole Bulk carrier and zero-length callbacks for empty inherited domains" do
    w280a_assert_empty_domains
  end

  it "round-trips the mixed nested Bulk adversary through MRK3 and MRK4 with literal outputs" do
    json_type = w280a_json_type
    schema = w280a_schema(json_type)
    rows = w280a_mixed_rows(json_type)
    expected = w280a_expected_signatures
    [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4].each do |format|
      w280a_assert_round_trip(rows, schema, json_type, expected, format)
    end
  end

  it "round-trips completely empty nested/Bulk occurrence domains through both mark formats" do
    json_type = w280a_json_type
    schema = w280a_schema(json_type)
    rows = w280a_empty_domain_rows(json_type)
    expected = [
      "T(A[],A[],A[],J210)",
      "T(A[],A[],A[],J211)",
    ] of String
    [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4].each do |format|
      w280a_assert_round_trip(rows, schema, json_type, expected, format)
    end
  end

  it "checks the exact preflight and type-depth boundaries for the structural/Bulk plan" do
    w280a_assert_shape_budget_boundaries
  end

  it "rejects a typed JSON size0 leaf that aliases the enclosing Array size stream" do
    w280a_assert_typed_path_size_collision
  end

  it "rejects reordered and missing mixed callbacks at the MRK4 parent-ledger boundary" do
    w280a_assert_mrk4_mixed_ledger_guards
  end

  it "rejects a same-length Bulk size mutation that changes the inherited Q domain" do
    w280a_assert_wrong_inherited_bulk_domain_rejected
  end
end
