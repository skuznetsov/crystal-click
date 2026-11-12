require "../../src/crystal_click"

module CompactPartWriterW273NativeFixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  COLUMN_NAME   = "typed_dynamic_nested_array_json"
  KEY_NAME      = "pk"
  ROWS_PER_MARK = 2
  ROW_COUNT     = 8
  MARK_COUNT    = 4
  FRAME_BYTES   = 4096
  SITE_PATH     = "root"
  PAYLOAD_PATH  = "payload"
  VALUE_PATH    = "value"
  KEYS          = Slice.new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }

  # This fixture mirrors the native stock SQL's inferred Int64 JSON leaf,
  # independently of the public W273 spec fixture's typed UInt8 leaf.
  def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json
  end

  private def array_type_at_depth(depth : Int) : CrystalClick::BinaryDataType
    unless depth >= 1 && depth <= CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH
      raise ArgumentError.new("W273 native Array-chain depth is outside the bounded fixture range")
    end
    type = json_type
    depth.times { type = CrystalClick::BinaryDataType.array(type) }
    type
  end

  def array_chain_type(depth : Int) : CrystalClick::BinaryDataType
    unless depth >= 2
      raise ArgumentError.new("W273 native Dynamic Array-chain depth must be at least two")
    end
    array_type_at_depth(depth)
  end

  def leaf_descriptor_child_path(depth : Int) : Array(Int32)
    array_chain_type(depth)
    Array(Int32).new(depth) { 0_i32 }
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
      raise CrystalClick::UnsupportedFormatError.new("W273 native-shaped JSON declaration is not admitted")
  end

  private def empty_structures(
    statistics : CrystalClick::StructureStatistics? = nil,
  ) : CrystalClick::ObjectDynamicStructureSet
    object_statistics = statistics || CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: object_statistics,
    )
    CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
  end

  def literal_strings(depth : Int) : Array(String?)
    case depth
    when 2
      [
        "[[11,12],[13]]", nil, nil, nil, "[]", "[[]]", nil,
        "[[81],[82,83],[]]",
      ] of String?
    when 3
      [
        "[[[11,12],[]],[[13,14]]]", nil, nil, nil, "[]", "[[]]", "[[[]]]",
        "[[[81]],[[82,83],[]],[]]",
      ] of String?
    else
      raise ArgumentError.new("W273 native literal witness is defined for depths two and three")
    end
  end

  def expected_literals(depth : Int) : Array(JSON::Any?)
    literal_strings(depth).map do |literal|
      literal ? JSON.parse(literal) : nil
    end
  end

  def expected_mark_actual_counts(depth : Int) : Array(Int32)
    case depth
    when 2 then [1, 0, 2, 1]
    when 3 then [1, 0, 2, 2]
    else raise ArgumentError.new("W273 native actual-count witness is defined for depths two and three")
    end
  end

  def expected_mark_array_size_vectors(depth : Int) : Array(Array(Array(Int32)))
    case depth
    when 2
      [
        [[2], [2, 1]],
        [[] of Int32, [] of Int32],
        [[0, 1], [0]],
        [[3], [1, 2, 0]],
      ] of Array(Array(Int32))
    when 3
      [
        [[2], [2, 1], [2, 0, 2]],
        [[] of Int32, [] of Int32, [] of Int32],
        [[0, 1], [0], [] of Int32],
        [[1, 3], [1, 1, 2, 0], [0, 1, 2, 0]],
      ] of Array(Array(Int32))
    else
      raise ArgumentError.new("W273 native size-vector witness is defined for depths two and three")
    end
  end

  def expected_mark_array_element_counts(depth : Int) : Array(Array(Int32))
    case depth
    when 2
      [[2, 0, 1, 3], [3, 0, 0, 3]] of Array(Int32)
    when 3
      [[2, 0, 1, 4], [3, 0, 0, 4], [4, 0, 0, 3]] of Array(Int32)
    else
      raise ArgumentError.new("W273 native Array-element witness is defined for depths two and three")
    end
  end

  def expected_mark_json_element_counts(depth : Int) : Array(Int32)
    case depth
    when 2 then [3, 0, 0, 3]
    when 3 then [4, 0, 0, 3]
    else raise ArgumentError.new("W273 native JSON-element witness is defined for depths two and three")
    end
  end

  def actuals(depth : Int) : CrystalClick::DynamicStructure
    count = expected_mark_actual_counts(depth).sum.to_u64
    CrystalClick::DynamicStructure.new(
      [array_chain_type(depth)] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [count, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  private def child_json_plan(depth : Int) : CrystalClick::ObjectDocumentPlan
    leaf_count = expected_mark_json_element_counts(depth).sum.to_u64
    child_dynamic = CrystalClick::DynamicStructure.new(
      [int64_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [leaf_count, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    child_object = CrystalClick::ObjectStructure.new(
      [VALUE_PATH] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [leaf_count] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      child_object,
      {VALUE_PATH => child_dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, json_type.json_type.not_nil!.typed_paths)
  end

  def json_bindings(depth : Int) : Hash(String, Array(LeafPlan))
    roster = actuals(depth)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      SITE_PATH,
      roster.canonical_index_for(array_chain_type(depth)),
      leaf_descriptor_child_path(depth),
    )
    {PAYLOAD_PATH => [{key, child_json_plan(depth)}] of LeafPlan} of String => Array(LeafPlan)
  end

  def object_plan(depth : Int) : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      empty_structures,
      schema.object_schema.typed_paths,
      {PAYLOAD_PATH => actuals(depth)} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: json_bindings(depth),
    )
  end

  def context(depth : Int) : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {SITE_PATH => object_plan(depth)} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def json_value(value : JSON::Any) : CrystalClick::BinaryValue
    cell = CrystalClick::BinaryValue.int64(value.as_i64)
    row = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{VALUE_PATH, cell}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(json_type, row)
  end

  private def array_value(value : JSON::Any, depth : Int) : CrystalClick::BinaryValue
    unless depth >= 1 && value.raw.is_a?(Array)
      raise CrystalClick::CorruptPartError.new("W273 native literal does not match its Array depth")
    end
    children = Array(CrystalClick::BinaryValue).new
    value.as_a.each do |child|
      children << (depth == 1 ? json_value(child) : array_value(child, depth - 1))
    end
    CrystalClick::BinaryValue.array(array_type_at_depth(depth), children)
  end

  private def row(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new({PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue),
    )
  end

  def rows(depth : Int) : Array(CrystalClick::StorageColumnValue)
    expected_literals(depth).map do |literal|
      selected = literal.try { |value| array_value(value, depth) }
      row(selected)
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

  private def json_leaf(value : CrystalClick::BinaryValue) : Int64
    unless value.type == json_type && value.json_row.type == json_type
      raise CrystalClick::CorruptPartError.new("W273 native Array leaf has the wrong JSON descriptor")
    end
    cell = value.json_row.value_for(VALUE_PATH).not_nil!
    unless cell.type == int64_type
      raise CrystalClick::CorruptPartError.new("W273 native JSON leaf has the wrong Int64 descriptor")
    end
    cell.as_int64
  end

  private def nested_literal(value : CrystalClick::BinaryValue, depth : Int) : JSON::Any
    unless value.type == array_type_at_depth(depth)
      raise CrystalClick::CorruptPartError.new("W273 native nested Array descriptor differs")
    end
    children = value.elements.map do |child|
      depth == 1 ? JSON::Any.new(json_leaf(child)) : nested_literal(child, depth - 1)
    end
    JSON::Any.new(children)
  end

  def literal_for(value : CrystalClick::StorageColumnValue, depth : Int) : JSON::Any?
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W273 native reader returned a non-Object row")
    end
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W273 native payload descriptor is not typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == array_chain_type(depth)
      raise CrystalClick::CorruptPartError.new("W273 native selected Dynamic child has the wrong Array chain")
    end
    nested_literal(selected.child_at(0), depth)
  end

  private def collect_array_sizes(
    value : CrystalClick::BinaryValue,
    remaining_depth : Int,
    root_depth : Int,
    levels : Array(Array(Int32)),
  ) : Nil
    unless value.type == array_type_at_depth(remaining_depth)
      raise CrystalClick::CorruptPartError.new("W273 native size schedule encountered the wrong Array descriptor")
    end
    levels[root_depth - remaining_depth] << value.elements.size
    if remaining_depth == 1
      value.elements.each { |leaf| json_leaf(leaf) }
    else
      value.elements.each { |child| collect_array_sizes(child, remaining_depth - 1, root_depth, levels) }
    end
    nil
  end

  def array_size_vectors_for_row(
    value : CrystalClick::StorageColumnValue,
    depth : Int,
  ) : Array(Array(Int32))
    levels = Array(Array(Int32)).new(depth) { [] of Int32 }
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W273 native size schedule payload is not typed Dynamic")
    end
    return levels if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == array_chain_type(depth)
      raise CrystalClick::CorruptPartError.new("W273 native size schedule actual has the wrong Array chain")
    end
    collect_array_sizes(selected.child_at(0), depth, depth, levels)
    levels
  end

  def array_size_vectors_for_mark(
    mark_rows : Array(CrystalClick::StorageColumnValue),
    depth : Int,
  ) : Array(Array(Int32))
    levels = Array(Array(Int32)).new(depth) { [] of Int32 }
    mark_rows.each do |row_value|
      row_levels = array_size_vectors_for_row(row_value, depth)
      depth.times { |level| levels[level].concat(row_levels[level]) }
    end
    levels
  end

  def column(depth : Int) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(COLUMN_NAME, schema, granules(depth), context(depth))
  end

  def common_codec_roundtrip!(depth : Int) : Nil
    roster = actuals(depth)
    bindings = json_bindings(depth)
    unless bindings.size == 1 && bindings[PAYLOAD_PATH].size == 1
      raise CrystalClick::CorruptPartError.new("W273 native exact Array-chain leaf binding differs")
    end
    key, plan = bindings[PAYLOAD_PATH][0]
    unless key.dynamic_site == SITE_PATH &&
           key.canonical_arm_index == roster.canonical_index_for(array_chain_type(depth)) &&
           key.descriptor_child_path == leaf_descriptor_child_path(depth) &&
           plan.typed_paths == json_type.json_type.not_nil!.typed_paths
      raise CrystalClick::CorruptPartError.new("W273 native Array-chain leaf identity differs")
    end
    expected_counts = expected_mark_actual_counts(depth)
    unless roster.statistics.not_nil!.counts == [expected_counts.sum.to_u64, 0_u64]
      raise CrystalClick::CorruptPartError.new("W273 native Dynamic actual statistics differ")
    end

    document_granules = granules(depth).map { |mark_rows| mark_rows.map(&.object_document) }
    streams = CrystalClick::ObjectDocumentCodec.encode(object_plan(depth), document_granules)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.object_schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    unless decoded.size == MARK_COUNT && decoded.all? { |mark_rows| mark_rows.size == ROWS_PER_MARK }
      raise CrystalClick::CorruptPartError.new("W273 native common-codec mark grid differs")
    end
    values = decoded.flat_map do |mark_rows|
      mark_rows.map { |document| literal_for(CrystalClick::StorageColumnValue.object_document(document), depth) }
    end
    unless values == expected_literals(depth)
      raise CrystalClick::CorruptPartError.new("W273 native common-codec nested literals differ")
    end
    actual_counts = decoded.map do |mark_rows|
      mark_rows.count do |document|
        !literal_for(CrystalClick::StorageColumnValue.object_document(document), depth).nil?
      end
    end
    unless actual_counts == expected_counts
      raise CrystalClick::CorruptPartError.new("W273 native common-codec Dynamic arm counts differ")
    end
    vectors = decoded.map do |mark_rows|
      array_size_vectors_for_mark(mark_rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }, depth)
    end
    unless vectors == expected_mark_array_size_vectors(depth)
      raise CrystalClick::CorruptPartError.new("W273 native common-codec nested size vectors differ")
    end
    levels = Array(Array(Int32)).new(depth) { [] of Int32 }
    leaves = [] of Int32
    vectors.each do |mark_levels|
      depth.times { |level| levels[level] << mark_levels[level].sum }
      leaves << mark_levels[depth - 1].sum
    end
    unless levels == expected_mark_array_element_counts(depth) && leaves == expected_mark_json_element_counts(depth)
      raise CrystalClick::CorruptPartError.new("W273 native common-codec per-level counts differ")
    end
    nil
  end
end
