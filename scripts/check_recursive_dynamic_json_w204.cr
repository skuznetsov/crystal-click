require "../src/crystal_click"
require "json"

module CheckRecursiveDynamicJSONW204
  extend self

  JSON_TYPE = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  CASE_IDS = ["root_tuple", "array_tuple", "ragged_array_tuple", "lc_bulk_tuple"]
  PROFILE_IDS = ["single_stream", "with_size_stream"]
  COLUMN = "payload"
  KEY = "pk"
  ROWS_PER_MARK = 2
  ROW_COUNT = 8_u64
  MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  FORMAT_INPUT = "recursive_dynamic_json_w204_input_v1"
  FORMAT_OUTPUT = "recursive_dynamic_json_w204_helper_v1"

  alias Fixture = NamedTuple(
    schema: CrystalClick::StorageColumnSchema,
    object_schema: CrystalClick::ObjectDocumentSchema,
    object_plans: Hash(String, CrystalClick::ObjectDocumentPlan),
    dynamic_plans: Hash(String, CrystalClick::BinaryDynamicBulkPlan),
    granules: Array(Array(CrystalClick::StorageColumnValue)),
    dynamic_site_keys: Array(String),
  )
  alias DynamicFixtureTuple = Tuple(Int32, String?)
  alias LCBulkFixtureTuple = Tuple(Int32, String, String?, String, Array(String?))

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W204 helper: #{message}") unless condition
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W204 profile is outside the fixed String profile roster")
    end
  end

  private def u8(value : Int) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value.to_u8])
  end

  private def u64(value : Int) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.uint64(value.to_u64)
  end

  private def json_document(index : Int32, label : String) : CrystalClick::StorageColumnValue
    values = {
      "t" => u8(index),
      "s" => CrystalClick::BinaryValue.string(label),
    } of String => CrystalClick::BinaryValue
    CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new(values))
  end

  private def dynamic(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue? = nil) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def dynamic_bulk_value(type : CrystalClick::BinaryDataType, index : Int32, payload : String?) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.bulk(dynamic(type, dynamic_child(payload)))
  end

  private def dynamic_child(payload : String?) : CrystalClick::BinaryValue?
    if value = payload
      value.starts_with?("#u64:") ? u64(value[5..].to_i) : CrystalClick::BinaryValue.string(value)
    else
      nil
    end
  end

  private def tuple_value(
    json_schema : CrystalClick::ObjectDocumentSchema,
    dynamic_type : CrystalClick::BinaryDataType,
    index : Int32,
    payload : String?,
  ) : CrystalClick::StorageColumnValue
    doc = json_document(index, "json-#{index}")
    dyn = dynamic_bulk_value(dynamic_type, index, payload)
    CrystalClick::StorageColumnValue.tuple([doc, dyn] of CrystalClick::StorageColumnValue)
  end

  private def array_row(values : Array(CrystalClick::StorageColumnValue)) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.array(values)
  end

  private def pair_rows(
    json_schema : CrystalClick::ObjectDocumentSchema,
    dynamic_type : CrystalClick::BinaryDataType,
    groups : Array(Array(Tuple(Int32, String?))),
  ) : Array(CrystalClick::StorageColumnValue)
    groups.map do |group|
      array_row(group.map { |item| tuple_value(json_schema, dynamic_type, item[0], item[1]) })
    end
  end

  private def plain_tuple_fixture(json_schema : CrystalClick::ObjectDocumentSchema, depth : Int32) : Array(Array(CrystalClick::StorageColumnValue))
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    result = [] of Array(CrystalClick::StorageColumnValue)
    if depth == 0
      values = [nil, nil, "#u64:7", "spill-a", "#u64:0", nil, "spill-b", "#u64:99"] of String?
      4.times do |mark|
        rows = [] of CrystalClick::StorageColumnValue
        2.times do |offset|
          index = mark * 2 + offset + 1
          rows << tuple_value(json_schema, dynamic_type, index, values[index - 1])
        end
        result << rows
      end
    elsif depth == 1
      rows = [
        [] of DynamicFixtureTuple,
        [] of DynamicFixtureTuple,
        [{3, "#u64:7"}] of DynamicFixtureTuple,
        [{4, "spill-a"}] of DynamicFixtureTuple,
        [] of DynamicFixtureTuple,
        [{6, nil}, {6, "#u64:0"}] of DynamicFixtureTuple,
        [{7, "spill-b"}] of DynamicFixtureTuple,
        [] of DynamicFixtureTuple,
      ] of Array(DynamicFixtureTuple)
      4.times do |mark|
        mark_rows = [] of CrystalClick::StorageColumnValue
        2.times do |offset|
          row_index = mark * 2 + offset
          elements = rows[row_index].map { |item| tuple_value(json_schema, dynamic_type, item[0], item[1]) }
          mark_rows << array_row(elements)
        end
        result << mark_rows
      end
    else
      rows = [
        [] of Array(DynamicFixtureTuple),
        [] of Array(DynamicFixtureTuple),
        [[] of DynamicFixtureTuple, [{3, "#u64:7"}] of DynamicFixtureTuple],
        [[{4, "spill-a"}] of DynamicFixtureTuple],
        [[] of DynamicFixtureTuple, [] of DynamicFixtureTuple],
        [[{6, nil}, {6, "#u64:0"}] of DynamicFixtureTuple],
        [[{7, "spill-b"}] of DynamicFixtureTuple],
        [] of Array(DynamicFixtureTuple),
      ] of Array(Array(DynamicFixtureTuple))
      4.times do |mark|
        mark_rows = [] of CrystalClick::StorageColumnValue
        2.times do |offset|
          row_index = mark * 2 + offset
          groups = rows[row_index].map { |group| group.map { |item| tuple_value(json_schema, dynamic_type, item[0], item[1]) } }
          mark_rows << array_row(groups.map { |group| array_row(group) })
        end
        result << mark_rows
      end
    end
    result
  end

  private def lc_bulk_tuple_fixture(json_schema : CrystalClick::ObjectDocumentSchema) : Array(Array(CrystalClick::StorageColumnValue))
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    lc_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    dynamic_array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    bulk_tuple = CrystalClick::BinaryDataType.tuple(
      [lc_type, dynamic_type, string_type, dynamic_array_type] of CrystalClick::BinaryDataType,
      ["label", "d", "text", "nested"] of String,
    )
    records = [
      [] of LCBulkFixtureTuple,
      [] of LCBulkFixtureTuple,
      [{3, "red", "#u64:7", "text-a", ["#u64:12", nil] of String?}] of LCBulkFixtureTuple,
      [{4, "blue", "spill-a", "text-b", ["#u64:13"] of String?}] of LCBulkFixtureTuple,
      [] of LCBulkFixtureTuple,
      [{6, "red", nil, "text-c", [] of String?}, {6, "green", "#u64:0", "text-d", ["#u64:14", "spill-nested-b"] of String?}] of LCBulkFixtureTuple,
      [{7, "blue", "spill-b", "text-e", ["#u64:15"] of String?}] of LCBulkFixtureTuple,
      [] of LCBulkFixtureTuple,
    ] of Array(LCBulkFixtureTuple)
    result = [] of Array(CrystalClick::StorageColumnValue)
    4.times do |mark|
      rows = [] of CrystalClick::StorageColumnValue
      2.times do |offset|
        row_index = mark * 2 + offset
        elements = records[row_index].map do |record|
          label = CrystalClick::BinaryValue.low_cardinality(lc_type, CrystalClick::BinaryValue.string(record[1]))
          child = if payload = record[2]
                    if payload.starts_with?("#u64:")
                      u64(payload[5..].to_i)
                    else
                      CrystalClick::BinaryValue.string(payload)
                    end
                  else
                    nil
                  end
          dyn = dynamic(dynamic_type, child)
          text = CrystalClick::BinaryValue.string(record[3])
          nested_values = record[4].map do |payload|
            dynamic(dynamic_type, dynamic_child(payload))
          end
          nested = CrystalClick::BinaryValue.array(dynamic_array_type, nested_values)
          inner = CrystalClick::BinaryValue.tuple(bulk_tuple, [label, dyn, text, nested] of CrystalClick::BinaryValue)
          outer = CrystalClick::StorageColumnValue.tuple([
            json_document(record[0], "json-#{record[0]}"),
            CrystalClick::StorageColumnValue.bulk(inner),
          ] of CrystalClick::StorageColumnValue)
          outer
        end
        rows << array_row(elements)
      end
      result << rows
    end
    result
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    path = "s"
    object = CrystalClick::ObjectStructure.new([path] of String)
    structures = {path => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(object, structures),
      schema.typed_paths,
    )
  end

  private def fixture(case_id : String, profile_name : String) : Fixture
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_TYPE)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic_profile = profile(profile_name)
    object_plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
    dynamic_plans = Hash(String, CrystalClick::BinaryDynamicBulkPlan).new
    bulk_type : CrystalClick::BinaryDataType
    schema_declaration : String
    array_depth : Int32

    case case_id
    when "root_tuple"
      bulk_type = dynamic_type
      schema_declaration = "Tuple(doc #{JSON_TYPE}, d #{dynamic_type.name})"
      array_depth = 0
      dynamic_plans["root/tuple[1]"] = CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic_type,
        {"root" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
        dynamic_profile,
      )
    when "array_tuple"
      bulk_type = dynamic_type
      schema_declaration = "Array(Tuple(doc #{JSON_TYPE}, d #{dynamic_type.name}))"
      array_depth = 1
      dynamic_plans["root/array[0]/tuple[1]"] = CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic_type,
        {"root" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
        dynamic_profile,
      )
    when "ragged_array_tuple"
      bulk_type = dynamic_type
      schema_declaration = "Array(Array(Tuple(doc #{JSON_TYPE}, d #{dynamic_type.name})))"
      array_depth = 2
      dynamic_plans["root/array[0]/array[0]/tuple[1]"] = CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic_type,
        {"root" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
        dynamic_profile,
      )
    when "lc_bulk_tuple"
      dynamic_array_type = CrystalClick::BinaryDataType.array(dynamic_type)
      bulk_type = CrystalClick::BinaryDataType.tuple(
        [CrystalClick::BinaryDataType.low_cardinality(string_type), dynamic_type, string_type, dynamic_array_type] of CrystalClick::BinaryDataType,
        ["label", "d", "text", "nested"] of String,
      )
      schema_declaration = "Array(Tuple(doc #{JSON_TYPE}, state #{bulk_type.name}))"
      array_depth = 1
      dynamic_plans["root/array[0]/tuple[1]"] = CrystalClick::BinaryDynamicBulkPlan.new(
        bulk_type,
        {
          "root.field.1" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType),
          "root.field.3.elements" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType),
        } of String => CrystalClick::DynamicStructure,
        dynamic_profile,
      )
    else
      raise ArgumentError.new("W204 case id is outside the fixed carrier roster")
    end

    schema = CrystalClick::StorageColumnSchema.parse(schema_declaration)
    object_sites = schema.json_site_keys.sort!
    unless object_sites.size == 1
      raise CrystalClick::UnsupportedFormatError.new("W204 fixture must have exactly one JSON site")
    end
    object_plans[object_sites[0]] = object_plan(object_schema)
    granules = if case_id == "lc_bulk_tuple"
                 lc_bulk_tuple_fixture(object_schema)
               else
                 plain_tuple_fixture(object_schema, array_depth)
               end
    dynamic_site_keys = dynamic_plans.keys.sort!
    {
      schema: schema,
      object_schema: object_schema,
      object_plans: object_plans,
      dynamic_plans: dynamic_plans,
      granules: granules,
      dynamic_site_keys: dynamic_site_keys,
    }
  end

  private def same_value?(schema : CrystalClick::StorageColumnSchema, left : CrystalClick::StorageColumnValue, right : CrystalClick::StorageColumnValue) : Bool
    return false unless schema.kind == left.kind && left.kind == right.kind
    if schema.array?
      left_values = left.array_values
      right_values = right.array_values
      return false unless left_values.size == right_values.size
      left_values.each_with_index { |value, index| return false unless same_value?(schema.child_at(0), value, right_values[index]) }
      true
    elsif schema.tuple?
      return false unless left.child_count == right.child_count && right.child_count == schema.child_count
      schema.child_count.times { |index| return false unless same_value?(schema.child_at(index), left.child_at(index), right.child_at(index)) }
      true
    elsif schema.object?
      left_doc = left.object_document
      right_doc = right.object_document
      return false unless left_doc.paths == right_doc.paths
      left_doc.paths.all? do |path|
        a = left_doc.value_for(path)
        b = right_doc.value_for(path)
        a.type == b.type && CrystalClick::BinaryValueCodec.encode(a) == CrystalClick::BinaryValueCodec.encode(b)
      end
    else
      a = left.bulk_value
      b = right.bulk_value
      a.type == b.type && CrystalClick::BinaryValueCodec.encode(a) == CrystalClick::BinaryValueCodec.encode(b)
    end
  end

  private def compare_marks!(
    schema : CrystalClick::StorageColumnSchema,
    actual : Array(Array(CrystalClick::StorageColumnValue)),
    expected : Array(Array(CrystalClick::StorageColumnValue)),
    label : String,
  ) : Nil
    require!(actual.size == expected.size, "#{label} mark count differs")
    actual.each_with_index do |rows, mark|
      wanted = expected[mark]
      require!(rows.size == wanted.size, "#{label} parent-row count differs at mark #{mark}")
      rows.each_with_index do |value, row|
        require!(same_value?(schema, value, wanted[row]), "#{label} nominal value differs at #{mark}/#{row}")
      end
    end
  end

  private def json_value(document : CrystalClick::ObjectDocument, schema : CrystalClick::ObjectDocumentSchema) : JSON::Any
    fields = {} of String => JSON::Any
    document.paths.each do |path|
      value = document.value_for(path)
      type_name = (schema.typed_paths[path]? || value.type).name
      fields[path] = case type_name
                     when "String"
                       JSON::Any.new(value.as_string)
                     when "UInt8"
                       JSON::Any.new(value.bytes[0].to_i64)
                     else
                       raise CrystalClick::CorruptPartError.new("W204 JSON fixture type is outside its literal renderer")
                     end
    end
    JSON::Any.new(fields)
  end

  private def bulk_value(value : CrystalClick::BinaryValue) : JSON::Any
    type = value.type
    if value.is_null?
      return JSON::Any.new(nil)
    end
    case type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string)
    when CrystalClick::BinaryDataType::TAG_UINT64
      JSON::Any.new(value.as_uint64.to_i64)
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      raise CrystalClick::CorruptPartError.new("W204 Dynamic actual unexpectedly disappeared") if value.element_count == 0
      actual = value.child_at(0)
      JSON::Any.new({"type" => JSON::Any.new(actual.type.name), "value" => bulk_value(actual)} of String => JSON::Any)
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
         CrystalClick::BinaryDataType::TAG_NULLABLE
      value.element_count == 0 ? JSON::Any.new(nil) : bulk_value(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = {} of String => JSON::Any
      type.child_count.times do |index|
        name = type.tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE ? type.field_name_at(index) : index.to_s
        fields[name] = bulk_value(value.child_at(index))
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |child| bulk_value(child) }.to_a)
    else
      raise CrystalClick::CorruptPartError.new("W204 BinaryBulk fixture type #{type.name} is outside its literal renderer")
    end
  end

  private def render_value(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue) : JSON::Any
    require!(schema.kind == value.kind, "recursive node/value kinds differ")
    if schema.array?
      JSON::Any.new(value.array_values.map { |child| render_value(schema.child_at(0), child) }.to_a)
    elsif schema.tuple?
      fields = {} of String => JSON::Any
      schema.child_count.times do |index|
        fields[schema.field_name_at(index)] = render_value(schema.child_at(index), value.child_at(index))
      end
      JSON::Any.new(fields)
    elsif schema.object?
      json_value(value.object_document, schema.object_schema)
    else
      bulk_value(value.bulk_value)
    end
  end

  private def row_signature(key : UInt64, schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue) : JSON::Any
    JSON::Any.new([JSON::Any.new(key.to_s), render_value(schema, value)] of JSON::Any)
  end

  private def marked_signatures(
    marks : Array(Array(CrystalClick::StorageColumnValue)),
    schema : CrystalClick::StorageColumnSchema,
    first_key : UInt64,
  ) : Array(Array(JSON::Any))
    next_key = first_key
    marks.map do |mark|
      mark.map do |value|
        signature = row_signature(next_key, schema, value)
        next_key += 1_u64
        signature
      end
    end
  end

  private def table_signatures(table : CrystalClick::WidePartTable, schema : CrystalClick::StorageColumnSchema) : Array(JSON::Any)
    rows = [] of JSON::Any
    table.scan_typed(batch_rows: ROWS_PER_MARK) do |batch|
      keys = batch.values_for(KEY)
      values = batch.recursive_values_for(COLUMN)
      unless keys.size == values.size
        raise CrystalClick::CorruptPartError.new("W204 key/value batch widths differ")
      end
      keys.size.times { |index| rows << row_signature(keys[index], schema, values[index]) }
      nil
    end
    rows
  end

  private def occurrence_count(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue, target : Symbol) : UInt64
    if target == :object && schema.object?
      return 1_u64
    end
    if target == :dynamic && schema.bulk? && schema.bulk_type.contains_dynamic?
      return bulk_dynamic_count(value.bulk_value)
    end
    if schema.array?
      value.array_values.reduce(0_u64) { |sum, child| sum + occurrence_count(schema.child_at(0), child, target) }
    elsif schema.tuple?
      schema.child_count.times.reduce(0_u64) { |sum, index| sum + occurrence_count(schema.child_at(index), value.child_at(index), target) }
    else
      0_u64
    end
  end

  private def bulk_dynamic_count(value : CrystalClick::BinaryValue) : UInt64
    type = value.type
    return 1_u64 if type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_NESTED
      value.elements.reduce(0_u64) { |sum, child| sum + bulk_dynamic_count(child) }
    when CrystalClick::BinaryDataType::TAG_NULLABLE,
         CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
         CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
      value.element_count == 0 ? 0_u64 : bulk_dynamic_count(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      type.child_count.times.reduce(0_u64) { |sum, index| sum + bulk_dynamic_count(value.child_at(index)) }
    when CrystalClick::BinaryDataType::TAG_VARIANT
      value.element_count == 0 ? 0_u64 : bulk_dynamic_count(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_MAP
      value.elements.reduce(0_u64) { |sum, child| sum + bulk_dynamic_count(child) }
    else
      0_u64
    end
  end

  private def bulk_dynamic_site_counts(value : CrystalClick::BinaryValue, path : String = "root") : Hash(String, UInt64)
    type = value.type
    if type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      return {path => 1_u64}
    end
    result = Hash(String, UInt64).new(0_u64)
    case type.tag
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_NESTED,
         CrystalClick::BinaryDataType::TAG_MAP
      value.elements.each do |child|
        bulk_dynamic_site_counts(child, "#{path}.elements").each { |name, count| result[name] += count }
      end
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      type.child_count.times do |index|
        bulk_dynamic_site_counts(value.child_at(index), "#{path}.field.#{index}").each { |name, count| result[name] += count }
      end
    when CrystalClick::BinaryDataType::TAG_NULLABLE,
         CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
         CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE,
         CrystalClick::BinaryDataType::TAG_VARIANT
      if value.element_count > 0
        bulk_dynamic_site_counts(value.child_at(0), path).each { |name, count| result[name] += count }
      end
    end
    result
  end

  private def dynamic_site_counts(schema : CrystalClick::StorageColumnSchema, value : CrystalClick::StorageColumnValue, site_key : String = "root") : Hash(String, UInt64)
    if schema.bulk? && schema.bulk_type.contains_dynamic?
      return bulk_dynamic_site_counts(value.bulk_value).each_with_object(Hash(String, UInt64).new(0_u64)) do |(internal_path, count), result|
        result["#{site_key}::#{internal_path}"] += count
      end
    end
    result = Hash(String, UInt64).new(0_u64)
    if schema.array?
      value.array_values.each do |child|
        dynamic_site_counts(schema.child_at(0), child, "#{site_key}/array[0]").each { |name, count| result[name] += count }
      end
    elsif schema.tuple?
      schema.child_count.times do |index|
        dynamic_site_counts(schema.child_at(index), value.child_at(index), "#{site_key}/tuple[#{index}]").each { |name, count| result[name] += count }
      end
    end
    result
  end

  private def reader_record(part : String, fixed : Fixture, origin : String) : Hash(String, JSON::Any)
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, COLUMN, fixed[:schema])
    full = reader.read_marks(0, reader.mark_count)
    first = reader.read_marks(0, 1)
    later = reader.read_marks(1, 1)
    middle = reader.read_marks(2, 1)
    final = reader.read_marks(3, 1)
    zero = reader.read_marks(reader.mark_count, 0)
    compare_marks!(fixed[:schema], full, fixed[:granules], "#{origin}/full")
    compare_marks!(fixed[:schema], first, fixed[:granules][0, 1], "#{origin}/first")
    compare_marks!(fixed[:schema], later, fixed[:granules][1, 1], "#{origin}/later")
    compare_marks!(fixed[:schema], middle, fixed[:granules][2, 1], "#{origin}/middle")
    compare_marks!(fixed[:schema], final, fixed[:granules][3, 1], "#{origin}/final")
    require!(zero.empty?, "#{origin} end-zero selection is not empty")
    require!(reader.schema_declaration == fixed[:schema].declaration, "#{origin} nominal declaration differs")
    require!(reader.row_count == ROW_COUNT && reader.mark_count == 4, "#{origin} parent P grid differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{origin} physical parent mark rows differ")
    occurrence_grids = full.map do |mark|
      mark.reduce({"object" => 0_u64, "dynamic" => 0_u64}) do |acc, row|
        acc["object"] += occurrence_count(fixed[:schema], row, :object)
        acc["dynamic"] += occurrence_count(fixed[:schema], row, :dynamic)
        acc
      end
    end
    declared_dynamic_site_paths = [] of String
    fixed[:dynamic_plans].each do |schema_site_key, plan|
      plan.site_paths.each { |internal_path| declared_dynamic_site_paths << "#{schema_site_key}::#{internal_path}" }
    end
    declared_dynamic_site_paths.sort!
    dynamic_site_grids = full.map do |mark|
      grid = Hash(String, UInt64).new(0_u64)
      declared_dynamic_site_paths.each { |name| grid[name] = 0_u64 }
      mark.each do |row|
        dynamic_site_counts(fixed[:schema], row).each { |name, count| grid[name] += count }
      end
      grid
    end
    {
      "schema_declaration" => JSON::Any.new(reader.schema_declaration),
      "source_declaration" => JSON::Any.new(reader.source_declaration),
      "row_count" => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts" => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "dynamic_site_keys" => JSON::Any.new(fixed[:dynamic_site_keys].map { |key| JSON::Any.new(key) }),
      "physical_stream_names" => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "occurrence_counts_by_parent_mark" => JSON::Any.new(occurrence_grids.map do |grid|
        JSON::Any.new({"object" => JSON::Any.new(grid["object"].to_i64), "dynamic" => JSON::Any.new(grid["dynamic"].to_i64)} of String => JSON::Any)
      end),
      "dynamic_site_occurrences_by_parent_mark" => JSON::Any.new(dynamic_site_grids.map do |grid|
        JSON::Any.new(grid.to_h { |name, count| {name, JSON::Any.new(count.to_i64)} })
      end),
      "windows" => JSON::Any.new({
        "full" => JSON::Any.new(marked_signatures(full, fixed[:schema], 1_u64).map { |mark| JSON::Any.new(mark) }),
        "first" => JSON::Any.new(marked_signatures(first, fixed[:schema], 1_u64).map { |mark| JSON::Any.new(mark) }),
        "later" => JSON::Any.new(marked_signatures(later, fixed[:schema], 3_u64).map { |mark| JSON::Any.new(mark) }),
        "middle" => JSON::Any.new(marked_signatures(middle, fixed[:schema], 5_u64).map { |mark| JSON::Any.new(mark) }),
        "final" => JSON::Any.new(marked_signatures(final, fixed[:schema], 7_u64).map { |mark| JSON::Any.new(mark) }),
        "end_zero" => JSON::Any.new(zero.map { |mark| JSON::Any.new(mark.map { |value| render_value(fixed[:schema], value) }) }),
      } of String => JSON::Any),
    } of String => JSON::Any
  end

  private def write_library_part(path : String, fixed : Fixture, profile_name : String) : Nil
    profile = profile(profile_name)
    result = CrystalClick::WidePartWriter.write_uint64_recursive_pair(
      path,
      KEY,
      Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
      COLUMN,
      fixed[:schema],
      fixed[:object_plans],
      fixed[:granules],
      rows_per_mark: ROWS_PER_MARK,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      profile: profile,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
      dynamic_plans: fixed[:dynamic_plans],
    )
    require!(result == path, "writer returned a different destination")
  end

  private def validate_part(path : String, root : String, must_be_absent : Bool) : String
    full = File.expand_path(path)
    root_full = File.realpath(root)
    require!(full.starts_with?(root_full + File::SEPARATOR), "part path escaped its authenticated root")
    if must_be_absent
      require!(!File.exists?(full), "generated library part already exists")
    else
      require!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full, "source part is absent or noncanonical")
    end
    full
  end

  private def process_case(input : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    case_id = input["case_id"].as_s
    profile_name = input["profile_id"].as_s
    source_part = input["source_part"].as_s
    library_part = input["library_part"].as_s
    require!(CASE_IDS.includes?(case_id) && PROFILE_IDS.includes?(profile_name), "input case/profile outside fixed roster")
    require!(input["capture_root"].as_s == capture_root, "case capture root differs")
    validate_part(source_part, capture_root, false)
    validate_part(library_part, output_root, true)
    fixed = fixture(case_id, profile_name)
    write_library_part(library_part, fixed, profile_name)
    source_reader = reader_record(source_part, fixed, "stock/#{case_id}/#{profile_name}")
    library_reader = reader_record(library_part, fixed, "library/#{case_id}/#{profile_name}")
    stock_table = CrystalClick::WidePartTable.open_selected_typed([source_part], [KEY, COLUMN])
    library_table = CrystalClick::WidePartTable.open_selected_typed([library_part], [KEY, COLUMN])
    source_rows = table_signatures(stock_table, fixed[:schema])
    library_rows = table_signatures(library_table, fixed[:schema])
    expected_rows = marked_signatures(fixed[:granules], fixed[:schema], 1_u64).flatten
    require!(source_rows == expected_rows, "stock table recursive values differ from fixture literals")
    require!(library_rows == expected_rows, "library table recursive values differ from fixture literals")
    JSON::Any.new({
      "case_id" => JSON::Any.new(case_id),
      "profile_id" => JSON::Any.new(profile_name),
      "schema_declaration" => JSON::Any.new(fixed[:schema].declaration),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "stock_reader" => JSON::Any.new(source_reader),
      "library_reader" => JSON::Any.new(library_reader),
      "stock_table_rows" => JSON::Any.new(source_rows),
      "library_table_rows" => JSON::Any.new(library_rows),
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_recursive_dynamic_json_w204.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W204 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W204 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    expected = CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile_id| "#{case_id}/#{profile_id}" } }
    actual = cases.map { |item| "#{item["case_id"].as_s}/#{item["profile_id"].as_s}" }
    require!(actual == expected, "helper case/profile roster or order differs")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "helper case input keys differ")
    end
    results = cases.map { |item| process_case(item, output_root, capture_root) }
    puts JSON::Any.new({
      "format" => JSON::Any.new(FORMAT_OUTPUT),
      "case_ids" => JSON::Any.new(CASE_IDS.map { |name| JSON::Any.new(name) }),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "cases" => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W204 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckRecursiveDynamicJSONW204.main(ARGV)
