require "../../src/crystal_click"

module CompactPartWriterW279Fixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  COLUMN_NAME   = "typed_dynamic_nested_array_json_w279"
  KEY_NAME      = "pk"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096
  SITE_PATH     = "root"
  PAYLOAD_PATH  = "payload"
  SHARED_PATHS  = ["alpha", "aa", "beta"] of String
  LONG_STRING   = "long:" + ("x" * 256)

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {
        "id"    => uint64_type,
        "label" => string_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def array_type_at_depth(depth : Int) : CrystalClick::BinaryDataType
    unless depth >= 1 && depth <= CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH
      raise ArgumentError.new("W279 Array depth is outside the bounded fixture range")
    end
    type = json_type
    depth.times { type = CrystalClick::BinaryDataType.array(type) }
    type
  end

  # Depth zero is the direct typed-Dynamic JSON actual. Array-chain cases are
  # deliberately the previously qualified W273 recursive shape at depths two
  # and three; no arbitrary wrappers are represented here.
  def actual_type(depth : Int) : CrystalClick::BinaryDataType
    case depth
    when 0    then json_type
    when 2, 3 then array_type_at_depth(depth)
    else
      raise ArgumentError.new("W279 fixture admits only direct JSON or Array-chain depths two and three")
    end
  end

  def declared_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {PAYLOAD_PATH => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declared_json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("W279 fixture JSON declaration is not admitted")
  end

  def bucket_count_for(shared_data_version : UInt64) : UInt64
    shared_data_version == 0_u64 ? 1_u64 : 2_u64
  end

  private def empty_structures(shared_data_version : UInt64) : CrystalClick::ObjectDynamicStructureSet
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: shared_data_version,
      bucket_count: bucket_count_for(shared_data_version),
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
  end

  def leaf_descriptor_child_path(depth : Int) : Array(Int32)
    actual_type(depth)
    depth == 0 ? [] of Int32 : Array(Int32).new(depth) { 0_i32 }
  end

  def expected_mark_actual_counts(depth : Int) : Array(Int32)
    case depth
    when 0 then [1, 0, 1, 1]
    when 2 then [1, 0, 2, 1]
    when 3 then [1, 0, 2, 2]
    else
      raise ArgumentError.new("W279 actual-count witness is defined for depths zero, two, and three")
    end
  end

  # This literal oracle is intentionally independent of any reader/writer
  # traversal. Each inner list is the expected sequence of JSON child IDs for
  # one parent row; empty lists cover both NULLs and selected empty arrays.
  def expected_leaf_ids(depth : Int) : Array(Array(UInt64))
    case depth
    when 0
      [[11_u64], [] of UInt64, [] of UInt64, [] of UInt64, [82_u64], [] of UInt64, [] of UInt64, [83_u64]]
    when 2
      [[11_u64, 12_u64, 13_u64], [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [81_u64, 82_u64, 83_u64]]
    when 3
      [[11_u64, 12_u64, 13_u64, 14_u64], [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [] of UInt64, [81_u64, 82_u64, 83_u64]]
    else
      raise ArgumentError.new("W279 leaf-ID witness is defined for depths zero, two, and three")
    end
  end

  def actuals(depth : Int) : CrystalClick::DynamicStructure
    selected_count = expected_mark_actual_counts(depth).sum.to_u64
    CrystalClick::DynamicStructure.new(
      [actual_type(depth)] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [selected_count, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  def json_bindings(depth : Int, shared_data_version : UInt64) : Hash(String, Array(LeafPlan))
    roster = actuals(depth)
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      empty_structures(shared_data_version),
      json_type.json_type.not_nil!.typed_paths,
    )
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      SITE_PATH,
      roster.canonical_index_for(actual_type(depth)),
      leaf_descriptor_child_path(depth),
    )
    {PAYLOAD_PATH => [{key, child_plan}] of LeafPlan} of String => Array(LeafPlan)
  end

  def object_plan(depth : Int, shared_data_version : UInt64) : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      empty_structures(shared_data_version),
      schema.object_schema.typed_paths,
      {PAYLOAD_PATH => actuals(depth)} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: json_bindings(depth, shared_data_version),
    )
  end

  def context(depth : Int, shared_data_version : UInt64) : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {SITE_PATH => object_plan(depth, shared_data_version)} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def shared_index_for(id : UInt64) : Int32
    case id
    when 11_u64 then 0
    when 12_u64 then 1
    when 13_u64 then 5
    when 14_u64 then 2
    when 81_u64 then 4
    when 82_u64 then 3
    when 83_u64 then 6
    else
      raise ArgumentError.new("W279 JSON child ID has no shared-string fixture row")
    end
  end

  private def shared_value(path : String, row : Int32) : String
    return "" if path == "alpha" && row == 0
    return LONG_STRING if path == "alpha" && row == 3
    return raw_binary_string if path == "aa" && row == 1
    return "shared\0nul" if path == "beta" && row == 5

    "#{path}-shared-#{row}"
  end

  private def raw_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def json_value(id : UInt64) : CrystalClick::BinaryValue
    index = shared_index_for(id)
    entries = [
      {"id", CrystalClick::BinaryValue.uint64(id)},
      {"label", CrystalClick::BinaryValue.string("child-#{id}")},
    ] of Tuple(String, CrystalClick::BinaryValue)
    SHARED_PATHS.each do |path|
      entries << {path, CrystalClick::BinaryValue.string(shared_value(path, index))}
    end
    row = CrystalClick::BinaryJsonRow.new(json_type, entries)
    CrystalClick::BinaryValue.json(json_type, row)
  end

  private def array_value(
    depth : Int,
    children : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    expected_type = array_type_at_depth(depth)
    expected_child_type = depth == 1 ? json_type : array_type_at_depth(depth - 1)
    unless children.all? { |child| child.type == expected_child_type }
      raise ArgumentError.new("W279 Array child does not match its recursive descriptor")
    end
    CrystalClick::BinaryValue.array(expected_type, children)
  end

  private def parent_row(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def depth_zero_rows : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(json_value(11_u64)),
      parent_row(nil),
      parent_row(nil),
      parent_row(nil),
      parent_row(json_value(82_u64)),
      parent_row(nil),
      parent_row(nil),
      parent_row(json_value(83_u64)),
    ] of CrystalClick::StorageColumnValue
  end

  private def depth_two_rows : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(array_value(2, [
        array_value(1, [json_value(11_u64), json_value(12_u64)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(13_u64)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      parent_row(nil),
      parent_row(nil),
      parent_row(nil),
      parent_row(array_value(2, [] of CrystalClick::BinaryValue)),
      parent_row(array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue)),
      parent_row(nil),
      parent_row(array_value(2, [
        array_value(1, [json_value(81_u64)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(82_u64), json_value(83_u64)] of CrystalClick::BinaryValue),
        array_value(1, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::StorageColumnValue
  end

  private def depth_three_rows : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(11_u64), json_value(12_u64)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(13_u64), json_value(14_u64)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      parent_row(nil),
      parent_row(nil),
      parent_row(nil),
      parent_row(array_value(3, [] of CrystalClick::BinaryValue)),
      parent_row(array_value(3, [array_value(2, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue)),
      parent_row(array_value(3, [
        array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      parent_row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(81_u64)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(82_u64), json_value(83_u64)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::StorageColumnValue
  end

  def rows(depth : Int) : Array(CrystalClick::StorageColumnValue)
    case depth
    when 0 then depth_zero_rows
    when 2 then depth_two_rows
    when 3 then depth_three_rows
    else
      raise ArgumentError.new("W279 rows are defined for direct JSON and Array-chain depths two and three")
    end
  end

  def granules(depth : Int) : Array(Array(CrystalClick::StorageColumnValue))
    values = rows(depth)
    output = Array(Array(CrystalClick::StorageColumnValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      output << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  def column(depth : Int, shared_data_version : UInt64) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules(depth),
      context(depth, shared_data_version),
    )
  end
end
