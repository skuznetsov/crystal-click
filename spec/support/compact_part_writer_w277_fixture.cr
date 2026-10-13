require "../../src/crystal_click"

module CompactPartWriterW277Fixture
  extend self

  KEY_NAME      = "pk"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096
  ROOT_SITE     = "root"
  PAYLOAD_PATH  = "payload"
  VALUE_PATH    = "value"

  ROOT_DYNAMIC_COLUMN = "root_dynamic_string"
  TUPLE_ARRAY_COLUMN  = "tuple_array_dynamic_string"
  ROOT_JSON_COLUMN    = "json_root_string"
  TYPED_JSON_COLUMN   = "typed_dynamic_depth2_array_json_string"

  BASE_COLUMN_NAMES = [ROOT_DYNAMIC_COLUMN, TUPLE_ARRAY_COLUMN, ROOT_JSON_COLUMN] of String
  COLUMN_NAMES      = [ROOT_DYNAMIC_COLUMN, TUPLE_ARRAY_COLUMN, ROOT_JSON_COLUMN, TYPED_JSON_COLUMN] of String

  LONG_STRING = "long:" + ("x" * 256)

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def uint16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt16")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def root_dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def tuple_array_dynamic_type : CrystalClick::BinaryDataType
    array_type = CrystalClick::BinaryDataType.array(root_dynamic_type)
    CrystalClick::BinaryDataType.tuple(
      [string_type, array_type] of CrystalClick::BinaryDataType,
      ["label", "items"] of String,
    )
  end

  def root_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => uint64_type,
        "label" => string_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def typed_json_leaf_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {VALUE_PATH => string_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def typed_dynamic_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {PAYLOAD_PATH => root_dynamic_type} of String => CrystalClick::BinaryDataType,
    )
  end

  # One shared layout is selected per native case. MAP0 admits the W273-shaped
  # typed-Dynamic child; MAP_WITH_BUCKETS deliberately omits that child because
  # Compact currently guards this owner intersection and stock selection is
  # global, not per-root.
  def column_names_for(
    shared_layout : Symbol = :map,
    typed_json_child_layout : Symbol? = nil,
  ) : Array(String)
    validate_layout!(shared_layout)
    names = BASE_COLUMN_NAMES.dup
    child_layout = typed_json_child_layout || (shared_layout == :map ? :map : nil)
    if child_layout
      validate_layout!(child_layout)
      names << TYPED_JSON_COLUMN
    end
    names
  end

  def types : Hash(String, CrystalClick::BinaryDataType)
    {
      ROOT_DYNAMIC_COLUMN => root_dynamic_type,
      TUPLE_ARRAY_COLUMN  => tuple_array_dynamic_type,
      ROOT_JSON_COLUMN    => root_json_type,
      TYPED_JSON_COLUMN   => typed_dynamic_json_type,
    } of String => CrystalClick::BinaryDataType
  end

  def schemas(
    shared_layout : Symbol = :map,
    typed_json_child_layout : Symbol? = nil,
  ) : Hash(String, CrystalClick::StorageColumnSchema)
    selected = Hash(String, CrystalClick::StorageColumnSchema).new
    column_names_for(shared_layout, typed_json_child_layout).each do |name|
      case name
      when ROOT_JSON_COLUMN
        selected[name] = schema_for(root_json_type)
      when TYPED_JSON_COLUMN
        selected[name] = schema_for(typed_dynamic_json_type)
      end
    end
    selected
  end

  def columns(
    shared_layout : Symbol = :map,
    typed_json_child_layout : Symbol? = nil,
  ) : Array(CrystalClick::CompactPartColumn)
    selected = column_names_for(shared_layout, typed_json_child_layout)
    output = Array(CrystalClick::CompactPartColumn).new(selected.size)
    selected.each do |name|
      case name
      when ROOT_DYNAMIC_COLUMN
        output << CrystalClick::CompactPartColumn.dynamic_bulk(
          name,
          root_dynamic_type,
          binary_granules(root_dynamic_rows),
          root_dynamic_context,
        )
      when TUPLE_ARRAY_COLUMN
        output << CrystalClick::CompactPartColumn.dynamic_bulk(
          name,
          tuple_array_dynamic_type,
          binary_granules(tuple_array_rows),
          tuple_array_dynamic_context,
        )
      when ROOT_JSON_COLUMN
        output << CrystalClick::CompactPartColumn.json(
          name,
          schema_for(root_json_type),
          storage_granules(root_json_rows),
          root_json_context(shared_layout),
        )
      when TYPED_JSON_COLUMN
        child_layout = typed_json_child_layout || :map
        output << typed_dynamic_json_column(child_layout)
      else
        raise ArgumentError.new("unknown W277 column: #{name}")
      end
    end
    output
  end

  # This factory is also used directly by the adversary spec. Its parent Object
  # is always MAP0; changing the child to MAP_WITH_BUCKETS must remain guarded.
  def typed_dynamic_json_column(child_layout : Symbol = :map) : CrystalClick::CompactPartColumn
    validate_layout!(child_layout)
    CrystalClick::CompactPartColumn.json(
      TYPED_JSON_COLUMN,
      schema_for(typed_dynamic_json_type),
      storage_granules(typed_dynamic_json_rows),
      typed_dynamic_json_context(child_layout),
    )
  end

  # Exposes the bounded child-plan shape used by the exact prepared-layout
  # adversary. This is not a new carrier or writer path: it builds the same
  # root Dynamic -> Array -> Array -> JSON(String) binding as the column
  # fixture, with only the parent String profile or child Object layout varied.
  def typed_dynamic_bulk_plan(
    profile : CrystalClick::BinaryBulkProfile,
    child_layout : Symbol = :map,
  ) : CrystalClick::BinaryDynamicBulkPlan
    child_version, child_buckets = shared_layout_values(child_layout)
    actual_type = array_type_at_depth(2)
    actuals = CrystalClick::DynamicStructure.new(
      [actual_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([4_u64, 0_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    child_object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: child_version,
      bucket_count: child_buckets,
      statistics: CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      child_object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      schema_for(typed_json_leaf_type).object_schema.typed_paths,
    )
    leaf_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      ROOT_SITE,
      actuals.canonical_index_for(actual_type),
      [0_i32, 0_i32] of Int32,
    )
    leaf_plans = [{leaf_key, child_plan}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      root_dynamic_type,
      {ROOT_SITE => actuals} of String => CrystalClick::DynamicStructure,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      profile,
      nil,
      leaf_plans,
    )
  end

  def rows_for(name : String) : Array(CrystalClick::StorageColumnValue)
    case name
    when ROOT_DYNAMIC_COLUMN
      root_dynamic_rows.map { |value| CrystalClick::StorageColumnValue.bulk(value) }
    when TUPLE_ARRAY_COLUMN
      tuple_array_rows.map { |value| CrystalClick::StorageColumnValue.bulk(value) }
    when ROOT_JSON_COLUMN
      root_json_rows
    when TYPED_JSON_COLUMN
      typed_dynamic_json_rows
    else
      raise ArgumentError.new("unknown W277 column: #{name}")
    end
  end

  # Literal expected signatures are intentionally separate from the rows fed
  # to the writer. String payloads are represented as byte length plus hex so
  # empty, NUL, and non-UTF8 data cannot be mistaken for text normalization.
  def expected_signatures(name : String) : Array(String)
    long = "S261:6c6f6e673a" + ("78" * 256)
    binary = "S4:00ff8041"
    case name
    when ROOT_DYNAMIC_COLUMN
      [
        "S0:",
        "NULL",
        "S6:726f6f742d32",
        long,
        binary,
        "S8:6e756c007461696c",
        "S6:726f6f742d36",
        "S6:726f6f742d37",
      ] of String
    when TUPLE_ARRAY_COLUMN
      [
        "row00:[UInt16:1,S0:]",
        "row01:[]",
        "row02:[S6:6e6573746564,UInt16:2]",
        "row03:[NULL]",
        "row04:[UInt16:3]",
        "row05:[#{binary}]",
        "row06:[]",
        "row07:[#{long}]",
      ] of String
    when ROOT_JSON_COLUMN
      [
        "U64:1|S6:6a736f6e2d30|S0:|S8:7368617265642d30",
        "U64:2|S6:6a736f6e2d31|NULL|S8:7368617265642d31",
        "U64:3|S6:6a736f6e2d32|S9:7061796c6f61642d32|S8:7368617265642d32",
        "U64:4|S6:6a736f6e2d33|#{long}|S8:7368617265642d33",
        "U64:5|S6:6a736f6e2d34|#{binary}|S8:7368617265642d34",
        "U64:6|S6:6a736f6e2d35|S9:6a736f6e007461696c|S8:7368617265642d35",
        "U64:7|S6:6a736f6e2d36|S9:7061796c6f61642d36|S8:7368617265642d36",
        "U64:8|S6:6a736f6e2d37|S9:7061796c6f61642d37|S8:7368617265642d37",
      ] of String
    when TYPED_JSON_COLUMN
      [
        "D:[[J(S5:616c706861),J(S0:)],[J(#{long})]]",
        "NULL",
        "NULL",
        "NULL",
        "D:[]",
        "D:[[]]",
        "NULL",
        "D:[[J(#{binary})]]",
      ] of String
    else
      raise ArgumentError.new("unknown W277 column: #{name}")
    end
  end

  def signatures_from(
    name : String,
    marks : Array(Array(CrystalClick::BinaryValue)),
  ) : Array(String)
    marks.flatten.map do |value|
      case name
      when ROOT_DYNAMIC_COLUMN
        dynamic_signature(value)
      when TUPLE_ARRAY_COLUMN
        tuple_array_signature(value)
      else
        raise ArgumentError.new("W277 BinaryValue signature requested for non-binary column: #{name}")
      end
    end
  end

  def signatures_from(
    name : String,
    marks : Array(Array(CrystalClick::StorageColumnValue)),
  ) : Array(String)
    marks.flatten.map do |value|
      case name
      when ROOT_JSON_COLUMN
        root_json_signature(value)
      when TYPED_JSON_COLUMN
        typed_dynamic_json_signature(value)
      when ROOT_DYNAMIC_COLUMN, TUPLE_ARRAY_COLUMN
        binary_signature = value.bulk_value
        name == ROOT_DYNAMIC_COLUMN ? dynamic_signature(binary_signature) : tuple_array_signature(binary_signature)
      else
        raise ArgumentError.new("unknown W277 column: #{name}")
      end
    end
  end

  private def root_dynamic_rows : Array(CrystalClick::BinaryValue)
    type = root_dynamic_type
    [
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("")),
      CrystalClick::BinaryValue.dynamic(type),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-2")),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string(LONG_STRING)),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string(raw_binary_string)),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("nul\0tail")),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-6")),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-7")),
    ] of CrystalClick::BinaryValue
  end

  private def tuple_array_rows : Array(CrystalClick::BinaryValue)
    tuple = tuple_array_dynamic_type
    array_type = tuple.child_at(1)
    dynamic = root_dynamic_type
    uint16 = uint16_type
    entries = [
      [dynamic_value(dynamic, uint16_value(uint16, 1_u16)), dynamic_value(dynamic, string_value(""))] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, string_value("nested")), dynamic_value(dynamic, uint16_value(uint16, 2_u16))] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, nil)] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, uint16_value(uint16, 3_u16))] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, string_value(raw_binary_string))] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, string_value(LONG_STRING))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    rows = Array(CrystalClick::BinaryValue).new(ROW_COUNT)
    entries.each_with_index do |items, index|
      label = "row#{index.to_s.rjust(2, '0')}"
      rows << CrystalClick::BinaryValue.tuple(
        tuple,
        [
          CrystalClick::BinaryValue.string(label),
          CrystalClick::BinaryValue.array(array_type, items),
        ] of CrystalClick::BinaryValue,
      )
    end
    rows
  end

  private def root_json_rows : Array(CrystalClick::StorageColumnValue)
    payloads = [
      CrystalClick::BinaryValue.string(""),
      nil,
      CrystalClick::BinaryValue.string("payload-2"),
      CrystalClick::BinaryValue.string(LONG_STRING),
      CrystalClick::BinaryValue.string(raw_binary_string),
      CrystalClick::BinaryValue.string("json\0tail"),
      CrystalClick::BinaryValue.string("payload-6"),
      CrystalClick::BinaryValue.string("payload-7"),
    ] of CrystalClick::BinaryValue?
    rows = Array(CrystalClick::StorageColumnValue).new(ROW_COUNT)
    payloads.each_with_index do |actual, index|
      fields = {
        "id"          => CrystalClick::BinaryValue.uint64(index.to_u64 + 1_u64),
        "label"       => CrystalClick::BinaryValue.string("json-#{index}"),
        "shared_text" => CrystalClick::BinaryValue.string("shared-#{index}"),
      } of String => CrystalClick::BinaryValue
      fields[PAYLOAD_PATH] = actual if actual
      rows << CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new(fields))
    end
    rows
  end

  private def typed_dynamic_json_rows : Array(CrystalClick::StorageColumnValue)
    actuals = [
      array_value(2, [
        array_value(1, [leaf_json("alpha"), leaf_json("")] of CrystalClick::BinaryValue),
        array_value(1, [leaf_json(LONG_STRING)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue),
      nil,
      nil,
      nil,
      array_value(2, [] of CrystalClick::BinaryValue),
      array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
      nil,
      array_value(2, [array_value(1, [leaf_json(raw_binary_string)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue?
    actuals.map do |actual|
      document = CrystalClick::ObjectDocument.new(
        {PAYLOAD_PATH => dynamic_value(root_dynamic_type, actual)} of String => CrystalClick::BinaryValue,
      )
      CrystalClick::StorageColumnValue.object_document(document)
    end
  end

  private def root_dynamic_context : CrystalClick::CompactDynamicWriteContext
    structure = CrystalClick::DynamicStructure.new(
      [string_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    CrystalClick::CompactDynamicWriteContext.new({ROOT_SITE => structure} of String => CrystalClick::DynamicStructure)
  end

  private def tuple_array_dynamic_context : CrystalClick::CompactDynamicWriteContext
    structure = CrystalClick::DynamicStructure.new(
      [uint16_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    CrystalClick::CompactDynamicWriteContext.new(
      {"root.field.1.elements" => structure} of String => CrystalClick::DynamicStructure,
    )
  end

  private def root_json_context(shared_layout : Symbol) : CrystalClick::CompactJsonWriteContext
    shared_version, bucket_count = shared_layout_values(shared_layout)
    object = CrystalClick::ObjectStructure.new(
      [PAYLOAD_PATH] of String,
      version: 4_u64,
      shared_data_version: shared_version,
      bucket_count: bucket_count,
      statistics: CrystalClick::StructureStatistics.new([2_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    dynamic = CrystalClick::DynamicStructure.new(
      [string_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {PAYLOAD_PATH => dynamic} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema_for(root_json_type).object_schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new({ROOT_SITE => plan} of String => CrystalClick::ObjectDocumentPlan)
  end

  private def typed_dynamic_json_context(child_layout : Symbol) : CrystalClick::CompactJsonWriteContext
    child_version, child_buckets = shared_layout_values(child_layout)
    parent_object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    actual_type = array_type_at_depth(2)
    actuals = CrystalClick::DynamicStructure.new(
      [actual_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([4_u64, 0_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    child_object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: child_version,
      bucket_count: child_buckets,
      statistics: CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      child_object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      schema_for(typed_json_leaf_type).object_schema.typed_paths,
    )
    leaf_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      ROOT_SITE,
      actuals.canonical_index_for(actual_type),
      [0_i32, 0_i32] of Int32,
    )
    parent_structures = CrystalClick::ObjectDynamicStructureSet.new(
      parent_object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    parent_plan = CrystalClick::ObjectDocumentPlan.new(
      parent_structures,
      schema_for(typed_dynamic_json_type).object_schema.typed_paths,
      {PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        PAYLOAD_PATH => [{leaf_key, child_plan}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan),
      } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )
    CrystalClick::CompactJsonWriteContext.new({ROOT_SITE => parent_plan} of String => CrystalClick::ObjectDocumentPlan)
  end

  private def tuple_array_signature(value : CrystalClick::BinaryValue) : String
    label = String.new(value.child_at(0).bytes)
    entries = value.child_at(1).elements.map { |item| dynamic_signature(item) }
    "#{label}:[#{entries.join(",")}]"
  end

  private def root_json_signature(value : CrystalClick::StorageColumnValue) : String
    document = value.object_document
    id = document.value_for("id").as_uint64
    label = string_signature(document.value_for("label"))
    payload = if document.has_path?(PAYLOAD_PATH)
                payload_value = document.value_for(PAYLOAD_PATH)
                payload_value.is_null? ? "NULL" : scalar_signature(payload_value)
              else
                "NULL"
              end
    shared = string_signature(document.value_for("shared_text"))
    "U64:#{id}|#{label}|#{payload}|#{shared}"
  end

  private def typed_dynamic_json_signature(value : CrystalClick::StorageColumnValue) : String
    dynamic_signature(value.object_document.value_for(PAYLOAD_PATH))
  end

  private def dynamic_signature(value : CrystalClick::BinaryValue) : String
    return "NULL" if value.is_null?
    actual = value.child_at(0)
    if actual.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY
      "D:#{array_json_signature(actual, 2)}"
    else
      scalar_signature(actual)
    end
  end

  private def array_json_signature(value : CrystalClick::BinaryValue, depth : Int) : String
    children = value.elements.map do |child|
      if depth == 1
        leaf = child.json_row.value_for(VALUE_PATH) ||
               raise ArgumentError.new("W277 typed JSON leaf is missing its value String")
        "J(#{string_signature(leaf)})"
      else
        array_json_signature(child, depth - 1)
      end
    end
    "[#{children.join(",")}]"
  end

  private def scalar_signature(value : CrystalClick::BinaryValue) : String
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      string_signature(value)
    when CrystalClick::BinaryDataType::TAG_UINT16
      decoded = value.byte_at(0).to_u16 | (value.byte_at(1).to_u16 << 8)
      "UInt16:#{decoded}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "U64:#{value.as_uint64}"
    else
      raise ArgumentError.new("unexpected W277 scalar descriptor: #{value.type.name}")
    end
  end

  private def string_signature(value : CrystalClick::BinaryValue) : String
    bytes = value.bytes
    "S#{bytes.size}:#{bytes.map { |byte| byte.to_s(16).rjust(2, '0') }.join}"
  end

  private def dynamic_value(
    type : CrystalClick::BinaryDataType,
    actual : CrystalClick::BinaryValue?,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, actual)
  end

  private def string_value(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def uint16_value(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      type,
      Bytes[(value & 0x00ff_u16).to_u8, (value >> 8).to_u8],
    )
  end

  private def leaf_json(value : String) : CrystalClick::BinaryValue
    row = CrystalClick::BinaryJsonRow.new(
      typed_json_leaf_type,
      [{VALUE_PATH, string_value(value)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(typed_json_leaf_type, row)
  end

  private def array_type_at_depth(depth : Int) : CrystalClick::BinaryDataType
    unless depth == 1 || depth == 2
      raise ArgumentError.new("W277 Array-chain depth is outside the fixture's bounded range")
    end
    type = typed_json_leaf_type
    depth.times { type = CrystalClick::BinaryDataType.array(type) }
    type
  end

  private def array_value(depth : Int, children : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    type = array_type_at_depth(depth)
    child_type = depth == 1 ? typed_json_leaf_type : array_type_at_depth(depth - 1)
    unless children.all? { |child| child.type == child_type }
      raise ArgumentError.new("W277 Array child does not match its recursive descriptor")
    end
    CrystalClick::BinaryValue.array(type, children)
  end

  private def storage_granules(
    rows : Array(CrystalClick::StorageColumnValue),
  ) : Array(Array(CrystalClick::StorageColumnValue))
    rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def binary_granules(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def schema_for(type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("W277 fixture JSON declaration is not admitted")
  end

  private def shared_layout_values(layout : Symbol) : Tuple(UInt64, UInt64)
    case layout
    when :map
      {0_u64, 1_u64}
    when :map_with_buckets
      {1_u64, 2_u64}
    else
      raise ArgumentError.new("unknown W277 Object shared layout: #{layout}")
    end
  end

  private def validate_layout!(layout : Symbol) : Nil
    shared_layout_values(layout)
    nil
  end

  private def raw_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end
end
