require "../../src/crystal_click"

module CompactPartWriterW279NativeFixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  KEY_NAME      = "pk"
  ROWS_PER_MARK =  2
  ROW_COUNT     =  8
  MARK_COUNT    =  4
  FRAME_BYTES   = 64
  SITE_PATH     = "root"
  PAYLOAD_PATH  = "payload"

  COLUMN_NAMES = [
    "typed_dynamic_json_w279",
    "typed_dynamic_array2_json_w279",
    "typed_dynamic_array3_json_w279",
  ] of String
  COLUMN_DEPTHS = {
    "typed_dynamic_json_w279"        => 0,
    "typed_dynamic_array2_json_w279" => 2,
    "typed_dynamic_array3_json_w279" => 3,
  }
  SHARED_PATHS = ["alpha", "aa", "beta"] of String
  LONG_STRING  = "long:" + ("x" * 256)

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
      raise ArgumentError.new("W279 Array depth is outside the bounded native fixture")
    end
    type = json_type
    depth.times { type = CrystalClick::BinaryDataType.array(type) }
    type
  end

  # These are the only registered Dynamic actuals in the native witness.
  def actual_type(depth : Int) : CrystalClick::BinaryDataType
    case depth
    when 0    then json_type
    when 2, 3 then array_type_at_depth(depth)
    else
      raise ArgumentError.new("W279 admits direct JSON and Array-chain depths two and three only")
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
      raise CrystalClick::UnsupportedFormatError.new("W279 native fixture root declaration is not admitted")
  end

  def schemas : Hash(String, CrystalClick::StorageColumnSchema)
    COLUMN_NAMES.to_h { |name| {name, schema} }
  end

  def depth_for(name : String) : Int32
    COLUMN_DEPTHS[name]? || raise ArgumentError.new("unknown W279 native fixture column: #{name}")
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
    CrystalClick::ObjectDynamicStructureSet.new(object, Hash(String, CrystalClick::DynamicStructure).new)
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

  def expected_leaf_ids(depth : Int) : Array(Array(UInt64))
    case depth
    when 0
      [[11_u64], [] of UInt64, [] of UInt64, [] of UInt64, [82_u64], [] of UInt64, [] of UInt64, [83_u64]]
    when 2
      [[11_u64, 12_u64, 13_u64], [] of UInt64, [] of UInt64, [] of UInt64,
       [] of UInt64, [] of UInt64, [] of UInt64, [81_u64, 82_u64, 83_u64]]
    when 3
      [[11_u64, 12_u64, 13_u64, 14_u64], [] of UInt64, [] of UInt64, [] of UInt64,
       [] of UInt64, [] of UInt64, [] of UInt64, [81_u64, 82_u64, 83_u64]]
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

  private def child_json_plan(depth : Int, shared_data_version : UInt64) : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      empty_structures(shared_data_version),
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  def json_bindings(depth : Int, shared_data_version : UInt64) : Hash(String, Array(LeafPlan))
    roster = actuals(depth)
    child_plan = child_json_plan(depth, shared_data_version)
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

  private def shared_index_for_child(id : UInt64) : Int32
    case id
    when 11_u64 then 0
    when 12_u64 then 1
    when 13_u64 then 5
    when 14_u64 then 2
    when 81_u64 then 4
    when 82_u64 then 3
    when 83_u64 then 6
    else
      raise ArgumentError.new("W279 child JSON id has no shared-string fixture row")
    end
  end

  private def shared_value(path : String, index : Int32, prefix : String) : String
    return "" if path == "alpha" && index == 0
    return LONG_STRING if path == "alpha" && index == 3
    return raw_binary_string if path == "aa" && index == 1
    return "shared\0nul" if path == "beta" && index == 5

    "#{prefix}-#{path}-shared-#{index}"
  end

  private def raw_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def json_value(id : UInt64) : CrystalClick::BinaryValue
    index = shared_index_for_child(id)
    entries = [
      {"id", CrystalClick::BinaryValue.uint64(id)},
      {"label", CrystalClick::BinaryValue.string("child-#{id}")},
    ] of Tuple(String, CrystalClick::BinaryValue)
    SHARED_PATHS.each do |path|
      entries << {path, CrystalClick::BinaryValue.string(shared_value(path, index, "child"))}
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

  private def parent_row(
    actual : CrystalClick::BinaryValue?,
    row_index : Int32,
    column_name : String,
  ) : CrystalClick::StorageColumnValue
    fields = {
      PAYLOAD_PATH => CrystalClick::BinaryValue.dynamic(dynamic_type, actual),
    } of String => CrystalClick::BinaryValue
    SHARED_PATHS.each do |path|
      fields[path] = CrystalClick::BinaryValue.string(shared_value(path, row_index, column_name))
    end
    CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new(fields))
  end

  private def depth_zero_rows(column_name : String) : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(json_value(11_u64), 0, column_name),
      parent_row(nil, 1, column_name),
      parent_row(nil, 2, column_name),
      parent_row(nil, 3, column_name),
      parent_row(json_value(82_u64), 4, column_name),
      parent_row(nil, 5, column_name),
      parent_row(nil, 6, column_name),
      parent_row(json_value(83_u64), 7, column_name),
    ] of CrystalClick::StorageColumnValue
  end

  private def depth_two_rows(column_name : String) : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(array_value(2, [
        array_value(1, [json_value(11_u64), json_value(12_u64)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(13_u64)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue), 0, column_name),
      parent_row(nil, 1, column_name),
      parent_row(nil, 2, column_name),
      parent_row(nil, 3, column_name),
      parent_row(array_value(2, [] of CrystalClick::BinaryValue), 4, column_name),
      parent_row(array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue), 5, column_name),
      parent_row(nil, 6, column_name),
      parent_row(array_value(2, [
        array_value(1, [json_value(81_u64)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(82_u64), json_value(83_u64)] of CrystalClick::BinaryValue),
        array_value(1, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue), 7, column_name),
    ] of CrystalClick::StorageColumnValue
  end

  private def depth_three_rows(column_name : String) : Array(CrystalClick::StorageColumnValue)
    [
      parent_row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(11_u64), json_value(12_u64)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(13_u64), json_value(14_u64)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue), 0, column_name),
      parent_row(nil, 1, column_name),
      parent_row(nil, 2, column_name),
      parent_row(nil, 3, column_name),
      parent_row(array_value(3, [] of CrystalClick::BinaryValue), 4, column_name),
      parent_row(array_value(3, [array_value(2, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue), 5, column_name),
      parent_row(array_value(3, [
        array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue), 6, column_name),
      parent_row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(81_u64)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(82_u64), json_value(83_u64)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue), 7, column_name),
    ] of CrystalClick::StorageColumnValue
  end

  def rows(name : String) : Array(CrystalClick::StorageColumnValue)
    depth = depth_for(name)
    case depth
    when 0 then depth_zero_rows(name)
    when 2 then depth_two_rows(name)
    when 3 then depth_three_rows(name)
    else
      raise ArgumentError.new("W279 rows are defined for direct JSON and Array-chain depths two and three")
    end
  end

  def rows_for(name : String) : Array(CrystalClick::StorageColumnValue)
    rows(name)
  end

  def granules(name : String) : Array(Array(CrystalClick::StorageColumnValue))
    rows(name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  def column(name : String, shared_data_version : UInt64) : CrystalClick::CompactPartColumn
    unless COLUMN_NAMES.includes?(name)
      raise ArgumentError.new("unknown W279 native fixture column: #{name}")
    end
    CrystalClick::CompactPartColumn.json(name, schema, granules(name), context(depth_for(name), shared_data_version))
  end

  def columns(shared_data_version : UInt64) : Array(CrystalClick::CompactPartColumn)
    COLUMN_NAMES.map { |name| column(name, shared_data_version) }
  end
end
