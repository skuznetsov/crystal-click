require "../../src/crystal_click"

module CompactPartWriterW269Fixture
  extend self

  KEY_NAME      = "pk"
  ROOT_COLUMN   = "root_json"
  ARRAY_COLUMN  = "array_json"
  TAGGED_COLUMN = "tagged_json"
  PAIR_COLUMN   = "pair_json"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096
  KEYS          = Slice.new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  ROOT_SITE     = "root"
  ARRAY_SITE    = "root/array[0]"
  TAGGED_SITE   = "root/array[0]/tuple[0]"
  LEFT_SITE     = "root/tuple[0]"
  RIGHT_SITE    = "root/tuple[1]"

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 2,
      typed_paths: {
        "id"    => uint64_type,
        "label" => string_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def json_schema : CrystalClick::StorageColumnSchema
    schema_for_json_declaration(json_type.name)
  end

  def array_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  end

  def tagged_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(Tuple(#{json_type.name}, UInt8))")
  end

  def pair_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Tuple(#{json_type.name}, #{json_type.name})")
  end

  private def schema_for_json_declaration(declaration : String) : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declaration) ||
      raise CrystalClick::UnsupportedFormatError.new("W269 fixture JSON declaration is not admitted")
  end

  def schemas : Hash(String, CrystalClick::StorageColumnSchema)
    {
      ROOT_COLUMN   => json_schema,
      ARRAY_COLUMN  => array_schema,
      TAGGED_COLUMN => tagged_schema,
      PAIR_COLUMN   => pair_schema,
    } of String => CrystalClick::StorageColumnSchema
  end

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def string_value(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  def document(
    id : UInt64,
    label : String,
    payload : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::ObjectDocument
    values = {
      "id"    => CrystalClick::BinaryValue.uint64(id),
      "label" => CrystalClick::BinaryValue.string(label),
    } of String => CrystalClick::BinaryValue
    values["payload"] = payload if payload
    CrystalClick::ObjectDocument.new(values)
  end

  def object_value(value : CrystalClick::ObjectDocument) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(value)
  end

  def root_rows : Array(CrystalClick::StorageColumnValue)
    [
      object_value(document(1_u64, "r1", string_value("root-first"))),
      object_value(document(2_u64, "r2")),
      object_value(document(3_u64, "r3", CrystalClick::BinaryValue.uint64(22_u64))),
      object_value(document(4_u64, "r4", CrystalClick::BinaryValue.null)),
      object_value(document(5_u64, "r5", string_value("root-five"))),
      object_value(document(6_u64, "r6", CrystalClick::BinaryValue.bool(true))),
      object_value(document(7_u64, "r7", CrystalClick::BinaryValue.uint64(77_u64))),
      object_value(document(8_u64, "r8")),
    ] of CrystalClick::StorageColumnValue
  end

  def array_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([
        object_value(document(101_u64, "a1", string_value("array-first"))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        object_value(document(105_u64, "a5", CrystalClick::BinaryValue.bool(false))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        object_value(document(106_u64, "a6", CrystalClick::BinaryValue.null)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        object_value(document(107_u64, "a7", string_value("array-last"))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def tagged_rows : Array(CrystalClick::StorageColumnValue)
    tuple = ->(id : UInt64, label : String, mark : UInt8, payload : CrystalClick::BinaryValue?) do
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(id, label, payload)),
        CrystalClick::StorageColumnValue.bulk(
          CrystalClick::BinaryValue.fixed(uint8_type, Bytes[mark]),
        ),
      ] of CrystalClick::StorageColumnValue)
    end
    array = ->(items : Array(CrystalClick::StorageColumnValue)) do
      CrystalClick::StorageColumnValue.array(items)
    end

    [
      array.call([tuple.call(201_u64, "t1", 1_u8, string_value("tag-first"))] of CrystalClick::StorageColumnValue),
      array.call([] of CrystalClick::StorageColumnValue),
      array.call([
        tuple.call(203_u64, "t3", 3_u8, CrystalClick::BinaryValue.uint64(303_u64)),
        tuple.call(204_u64, "t4", 4_u8, nil),
      ] of CrystalClick::StorageColumnValue),
      array.call([] of CrystalClick::StorageColumnValue),
      array.call([tuple.call(205_u64, "t5", 5_u8, string_value("tag-five"))] of CrystalClick::StorageColumnValue),
      array.call([] of CrystalClick::StorageColumnValue),
      array.call([tuple.call(207_u64, "t7", 7_u8, CrystalClick::BinaryValue.bool(true))] of CrystalClick::StorageColumnValue),
      array.call([] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def pair_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(301_u64, "l1", string_value("left-first"))),
        object_value(document(401_u64, "q1")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(302_u64, "l2")),
        object_value(document(402_u64, "q2")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(303_u64, "l3", CrystalClick::BinaryValue.uint64(303_u64))),
        object_value(document(403_u64, "q3", string_value("right-late"))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(304_u64, "l4", CrystalClick::BinaryValue.null)),
        object_value(document(404_u64, "q4", CrystalClick::BinaryValue.bool(false))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(305_u64, "l5", string_value("left-five"))),
        object_value(document(405_u64, "q5", CrystalClick::BinaryValue.uint64(405_u64))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(306_u64, "l6")),
        object_value(document(406_u64, "q6", CrystalClick::BinaryValue.null)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(307_u64, "l7", CrystalClick::BinaryValue.bool(true))),
        object_value(document(407_u64, "q7", string_value("right-last"))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(document(308_u64, "l8")),
        object_value(document(408_u64, "q8")),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def granules(rows : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    output = Array(Array(CrystalClick::StorageColumnValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      output << rows[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  def object_plan(
    first_object_count : UInt64,
    first_string_count : UInt64,
    first_uint64_count : UInt64,
    dynamic_version : UInt64,
    shared_data_version : UInt64,
    bucket_count : UInt64 = 1_u64,
    object_version : UInt64 = 4_u64,
    include_object_statistics : Bool = true,
    include_dynamic_statistics : Bool = true,
    first_shared_count : UInt64 = 0_u64,
  ) : CrystalClick::ObjectDocumentPlan
    object_statistics = if include_object_statistics
                          CrystalClick::StructureStatistics.new(
                            [first_object_count] of UInt64,
                            [] of CrystalClick::StructureStatistic,
                          )
                        end
    dynamic_statistics = if include_dynamic_statistics
                           shared_statistics = Array(CrystalClick::StructureStatistic).new
                           if first_shared_count > 0_u64
                             shared_statistics << CrystalClick::StructureStatistic.new("Bool", first_shared_count)
                           end
                           CrystalClick::StructureStatistics.new(
                             [first_shared_count, first_string_count, first_uint64_count] of UInt64,
                             shared_statistics,
                           )
                         end
    object = CrystalClick::ObjectStructure.new(
      ["payload"] of String,
      version: object_version,
      shared_data_version: shared_data_version,
      bucket_count: bucket_count,
      statistics: object_statistics,
    )
    dynamic = CrystalClick::DynamicStructure.new(
      [string_type, uint64_type] of CrystalClick::BinaryDataType,
      dynamic_statistics,
      version: dynamic_version,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, json_schema.object_schema.typed_paths)
  end

  def json_context(site_plans : Hash(String, CrystalClick::ObjectDocumentPlan)) : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(site_plans)
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    # Root's caller-owned first-block statistics are an explicit sample, not a
    # recomputed mark-zero or final-part census.
    root_plan = object_plan(
      3_u64,
      1_u64,
      1_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
      first_shared_count: 1_u64,
    )
    array_plan = object_plan(1_u64, 1_u64, 0_u64, CrystalClick::DynamicStructure::VERSION_V2, 1_u64, 2_u64)
    tagged_plan = object_plan(1_u64, 1_u64, 0_u64, CrystalClick::DynamicStructure::VERSION_V3, 1_u64, 2_u64)
    left_plan = object_plan(1_u64, 1_u64, 0_u64, CrystalClick::DynamicStructure::VERSION_V1, 0_u64)
    right_plan = object_plan(0_u64, 0_u64, 0_u64, CrystalClick::DynamicStructure::VERSION_V2, 1_u64, 2_u64)

    [
      CrystalClick::CompactPartColumn.json(
        ROOT_COLUMN,
        json_schema,
        granules(root_rows),
        json_context({ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        ARRAY_COLUMN,
        array_schema,
        granules(array_rows),
        json_context({ARRAY_SITE => array_plan} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        TAGGED_COLUMN,
        tagged_schema,
        granules(tagged_rows),
        json_context({TAGGED_SITE => tagged_plan} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        PAIR_COLUMN,
        pair_schema,
        granules(pair_rows),
        json_context({LEFT_SITE => left_plan, RIGHT_SITE => right_plan} of String => CrystalClick::ObjectDocumentPlan),
      ),
    ] of CrystalClick::CompactPartColumn
  end

  def rows_for(column_name : String) : Array(CrystalClick::StorageColumnValue)
    case column_name
    when ROOT_COLUMN   then root_rows
    when ARRAY_COLUMN  then array_rows
    when TAGGED_COLUMN then tagged_rows
    when PAIR_COLUMN   then pair_rows
    else                    raise ArgumentError.new("unknown W269 fixture column")
    end
  end

  def signature(value : CrystalClick::StorageColumnValue) : String
    if value.object?
      document = value.object_document
      payload = if document.has_path?("payload")
                  selected = document.value_for("payload")
                  selected.is_null? ? "NULL" : selected.type.name
                else
                  "-"
                end
      "#{document.value_for("id").as_uint64}:#{document.value_for("label").as_string}:#{payload}"
    elsif value.array?
      "[#{value.array_values.map { |child| signature(child) }.join(",")}]"
    elsif value.tuple?
      "(#{value.tuple_values.map { |child| signature(child) }.join(",")})"
    else
      value.bulk_value.type.name
    end
  end

  def static_guard_column : CrystalClick::CompactPartColumn
    values = (1_u64..ROW_COUNT.to_u64).map do |row|
      CrystalClick::BinaryValue.string("guard-#{row}")
    end
    marks = Array(Array(CrystalClick::BinaryValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      marks << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    CrystalClick::CompactPartColumn.binary_bulk(
      "guard",
      string_type,
      marks,
    )
  end

  # The original baseline's exact BinaryValue JSON values remain available as
  # the historical source oracle for the unbound-JSON rejection test.
  def legacy_json_value(
    type : CrystalClick::BinaryDataType,
    typed_values : Array(Tuple(String, CrystalClick::BinaryValue)),
    dynamic_path : String,
    dynamic_value : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    entries = typed_values.dup
    entries << {dynamic_path, dynamic_value}
    row = CrystalClick::BinaryJsonRow.new(type, entries)
    CrystalClick::BinaryValue.json(type, row)
  end

  def legacy_root_json(
    type : CrystalClick::BinaryDataType,
    id : UInt64,
    label : String,
    dynamic_path : String,
    dynamic_value : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    legacy_json_value(
      type,
      [
        {"id", CrystalClick::BinaryValue.uint64(id)},
        {"label", CrystalClick::BinaryValue.string(label)},
      ] of Tuple(String, CrystalClick::BinaryValue),
      dynamic_path,
      dynamic_value,
    )
  end

  def legacy_nested_json(
    type : CrystalClick::BinaryDataType,
    sequence : UInt64,
    state : String,
    dynamic_path : String,
    dynamic_value : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    legacy_json_value(
      type,
      [
        {"sequence", CrystalClick::BinaryValue.uint64(sequence)},
        {"state", CrystalClick::BinaryValue.string(state)},
      ] of Tuple(String, CrystalClick::BinaryValue),
      dynamic_path,
      dynamic_value,
    )
  end

  def legacy_binary_fixtures : Tuple(
    CrystalClick::BinaryDataType,
    CrystalClick::BinaryDataType,
    Array(Array(CrystalClick::BinaryValue)),
    Array(Array(CrystalClick::BinaryValue)),
  )
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = string_type
    uint8 = uint8_type
    root = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 2,
      typed_paths: {"id" => uint64, "label" => string} of String => CrystalClick::BinaryDataType,
    )
    nested = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 2,
      typed_paths: {"sequence" => uint64, "state" => string} of String => CrystalClick::BinaryDataType,
    )
    tuple_type = CrystalClick::BinaryDataType.tuple([nested, uint8] of CrystalClick::BinaryDataType)
    wrapped_type = CrystalClick::BinaryDataType.array(tuple_type)
    root_rows = [
      legacy_root_json(root, 1_u64, "r1", "note", string_value("first")),
      legacy_root_json(root, 2_u64, "r2", "note", string_value("second")),
      legacy_root_json(root, 3_u64, "r3", "score", CrystalClick::BinaryValue.uint64(300_u64)),
      legacy_root_json(root, 4_u64, "r4", "score", CrystalClick::BinaryValue.uint64(400_u64)),
    ] of CrystalClick::BinaryValue
    nested_value = ->(sequence : UInt64, state : String, marker : UInt8, path : String, value : CrystalClick::BinaryValue) do
      document = legacy_nested_json(nested, sequence, state, path, value)
      marker_value = CrystalClick::BinaryValue.fixed(uint8, Bytes[marker])
      CrystalClick::BinaryValue.tuple(tuple_type, [document, marker_value] of CrystalClick::BinaryValue)
    end
    wrapped_rows = [
      CrystalClick::BinaryValue.array(wrapped_type, [nested_value.call(101_u64, "one", 1_u8, "detail", string_value("a"))] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(wrapped_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(wrapped_type, [
        nested_value.call(103_u64, "three", 3_u8, "extra", CrystalClick::BinaryValue.uint64(30_u64)),
        nested_value.call(104_u64, "four", 4_u8, "extra", CrystalClick::BinaryValue.uint64(40_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(wrapped_type, [nested_value.call(105_u64, "five", 5_u8, "extra", CrystalClick::BinaryValue.uint64(50_u64))] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    {
      root,
      wrapped_type,
      [root_rows[0, 2], root_rows[2, 2]] of Array(CrystalClick::BinaryValue),
      [wrapped_rows[0, 2], wrapped_rows[2, 2]] of Array(CrystalClick::BinaryValue),
    }
  end
end
