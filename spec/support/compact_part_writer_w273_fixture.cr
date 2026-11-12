require "../../src/crystal_click"

module CompactPartWriterW273Fixture
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

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  # This child layout is deliberately local and parameterized. It is not the
  # separately qualified native inferred-Int64 child from W271.
  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {VALUE_PATH => uint8_type} of String => CrystalClick::BinaryDataType,
    )
  end

  private def array_type_at_depth(depth : Int) : CrystalClick::BinaryDataType
    unless depth >= 1 && depth <= CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH
      raise ArgumentError.new("W273 Array-chain depth is outside the bounded fixture range")
    end
    type = json_type
    depth.times { type = CrystalClick::BinaryDataType.array(type) }
    type
  end

  # Build an Array^depth(JSON) actual descriptor rather than spelling out one
  # or two special cases. The fixture witnesses depth two and three; descriptor,
  # leaf-key, and value walkers remain reusable for deeper bounded chains.
  def array_chain_type(depth : Int) : CrystalClick::BinaryDataType
    unless depth >= 2
      raise ArgumentError.new("W273 actual Array-chain depth must be at least two")
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
      raise CrystalClick::UnsupportedFormatError.new("W273 fixture JSON declaration is not admitted")
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

  def expected_mark_actual_counts(depth : Int) : Array(Int32)
    case depth
    when 2 then [1, 0, 2, 1]
    when 3 then [1, 0, 2, 2]
    else
      raise ArgumentError.new("W273 actual-count witness is defined for depths two and three")
    end
  end

  # Each row is one mark; each entry within that row is the independently
  # expected size vector for one successive Array level. These are deliberately
  # explicit, not reconstructed from leaf totals.
  private def size_levels(levels : Array(Array(Int32))) : Array(Array(Int32))
    levels
  end

  def expected_mark_array_size_vectors(depth : Int) : Array(Array(Array(Int32)))
    case depth
    when 2
      [
        size_levels([[2], [2, 1]] of Array(Int32)),
        size_levels([[] of Int32, [] of Int32]),
        size_levels([[0, 1], [0]] of Array(Int32)),
        size_levels([[3], [1, 2, 0]] of Array(Int32)),
      ] of Array(Array(Int32))
    when 3
      [
        size_levels([[2], [2, 1], [2, 0, 2]] of Array(Int32)),
        size_levels([[] of Int32, [] of Int32, [] of Int32]),
        size_levels([[0, 1], [0], [] of Int32]),
        size_levels([[1, 3], [1, 1, 2, 0], [0, 1, 2, 0]] of Array(Int32)),
      ] of Array(Array(Int32))
    else
      raise ArgumentError.new("W273 size-vector witness is defined for depths two and three")
    end
  end

  # Counts are sums of each level's per-parent size vectors, stated separately
  # from those vectors and from literal expectations.
  def expected_mark_array_element_counts(depth : Int) : Array(Array(Int32))
    case depth
    when 2
      [
        [2, 0, 1, 3],
        [3, 0, 0, 3],
      ] of Array(Int32)
    when 3
      [
        [2, 0, 1, 4],
        [3, 0, 0, 4],
        [4, 0, 0, 3],
      ] of Array(Int32)
    else
      raise ArgumentError.new("W273 element-count witness is defined for depths two and three")
    end
  end

  def expected_mark_json_element_counts(depth : Int) : Array(Int32)
    case depth
    when 2 then [3, 0, 0, 3]
    when 3 then [4, 0, 0, 3]
    else
      raise ArgumentError.new("W273 JSON-element witness is defined for depths two and three")
    end
  end

  def actuals(depth : Int) : CrystalClick::DynamicStructure
    selected_count = expected_mark_actual_counts(depth).sum.to_u64
    statistics = CrystalClick::StructureStatistics.new(
      [selected_count, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new(
      [array_chain_type(depth)] of CrystalClick::BinaryDataType,
      statistics,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  def json_bindings(depth : Int) : Hash(String, Array(LeafPlan))
    roster = actuals(depth)
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      empty_structures,
      json_type.json_type.not_nil!.typed_paths,
    )
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      SITE_PATH,
      roster.canonical_index_for(array_chain_type(depth)),
      leaf_descriptor_child_path(depth),
    )
    {PAYLOAD_PATH => [{key, child_plan}] of LeafPlan} of String => Array(LeafPlan)
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

  private def json_value(value : UInt8) : CrystalClick::BinaryValue
    cell = CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
    row = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{VALUE_PATH, cell}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(json_type, row)
  end

  private def array_value(
    depth : Int,
    children : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    expected_type = array_type_at_depth(depth)
    expected_child_type = depth == 1 ? json_type : array_type_at_depth(depth - 1)
    unless children.all? { |child| child.type == expected_child_type }
      raise ArgumentError.new("W273 Array child does not match its recursive descriptor")
    end
    CrystalClick::BinaryValue.array(expected_type, children)
  end

  private def row(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def depth_two_rows : Array(CrystalClick::StorageColumnValue)
    [
      row(array_value(2, [
        array_value(1, [json_value(11_u8), json_value(12_u8)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(13_u8)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      row(nil),
      row(nil),
      row(nil),
      row(array_value(2, [] of CrystalClick::BinaryValue)),
      row(array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue)),
      row(nil),
      row(array_value(2, [
        array_value(1, [json_value(81_u8)] of CrystalClick::BinaryValue),
        array_value(1, [json_value(82_u8), json_value(83_u8)] of CrystalClick::BinaryValue),
        array_value(1, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::StorageColumnValue
  end

  private def depth_three_rows : Array(CrystalClick::StorageColumnValue)
    [
      row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(11_u8), json_value(12_u8)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(13_u8), json_value(14_u8)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      row(nil),
      row(nil),
      row(nil),
      row(array_value(3, [] of CrystalClick::BinaryValue)),
      row(array_value(3, [array_value(2, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue)),
      row(array_value(3, [
        array_value(2, [array_value(1, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
      row(array_value(3, [
        array_value(2, [
          array_value(1, [json_value(81_u8)] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [
          array_value(1, [json_value(82_u8), json_value(83_u8)] of CrystalClick::BinaryValue),
          array_value(1, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        array_value(2, [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::StorageColumnValue
  end

  def rows(depth : Int) : Array(CrystalClick::StorageColumnValue)
    case depth
    when 2 then depth_two_rows
    when 3 then depth_three_rows
    else
      raise ArgumentError.new("W273 row witness is defined for depths two and three")
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

  # Canonical nested literals are independent fixture observations. nil is a
  # NULL Dynamic; "[]" and "[[]]" remain distinct selected actuals.
  def expected_literals(depth : Int) : Array(String?)
    case depth
    when 2
      [
        "[[11,12],[13]]",
        nil,
        nil,
        nil,
        "[]",
        "[[]]",
        nil,
        "[[81],[82,83],[]]",
      ] of String?
    when 3
      [
        "[[[11,12],[]],[[13,14]]]",
        nil,
        nil,
        nil,
        "[]",
        "[[]]",
        "[[[]]]",
        "[[[81]],[[82,83],[]],[]]",
      ] of String?
    else
      raise ArgumentError.new("W273 literal witness is defined for depths two and three")
    end
  end

  private def json_byte(value : CrystalClick::BinaryValue) : UInt8
    unless value.type == json_type && value.json_row.type == json_type
      raise CrystalClick::CorruptPartError.new("W273 Array leaf has the wrong JSON descriptor")
    end
    cell = value.json_row.value_for(VALUE_PATH).not_nil!
    unless cell.type == uint8_type
      raise CrystalClick::CorruptPartError.new("W273 JSON value has the wrong UInt8 descriptor")
    end
    cell.byte_at(0)
  end

  private def nested_literal(value : CrystalClick::BinaryValue, depth : Int) : String
    unless value.type == array_type_at_depth(depth)
      raise CrystalClick::CorruptPartError.new("W273 nested Array value has the wrong descriptor")
    end
    children = value.elements.map do |child|
      if depth == 1
        json_byte(child).to_s
      else
        nested_literal(child, depth - 1)
      end
    end
    "[#{children.join(",")}]"
  end

  def literal_for(value : CrystalClick::StorageColumnValue, depth : Int) : String?
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W273 value is not a root Object row")
    end
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W273 payload descriptor is not the declared typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == array_chain_type(depth)
      raise CrystalClick::CorruptPartError.new("W273 selected Dynamic child is not the bound Array-chain actual")
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
      raise CrystalClick::CorruptPartError.new("W273 size schedule encountered the wrong Array descriptor")
    end
    level = root_depth - remaining_depth
    levels[level] << value.elements.size
    if remaining_depth == 1
      value.elements.each { |json| json_byte(json) }
    else
      value.elements.each do |child|
        collect_array_sizes(child, remaining_depth - 1, root_depth, levels)
      end
    end
    nil
  end

  def array_size_vectors_for_row(
    value : CrystalClick::StorageColumnValue,
    depth : Int,
  ) : Array(Array(Int32))
    levels = Array(Array(Int32)).new(depth) { [] of Int32 }
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W273 size schedule row is not a root Object")
    end
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W273 size schedule payload is not typed Dynamic")
    end
    return levels if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == array_chain_type(depth)
      raise CrystalClick::CorruptPartError.new("W273 size schedule actual has the wrong Array-chain descriptor")
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
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules(depth),
      context(depth),
    )
  end

  # Validate the exact nested Dynamic -> Array^depth -> JSON leaf binding and
  # independent values/count grids through the common Object codec. This is a
  # fixture control, not evidence of Compact physical admission.
  def common_codec_roundtrip!(depth : Int) : Nil
    actual_roster = actuals(depth)
    bindings = json_bindings(depth)
    unless bindings.size == 1
      raise CrystalClick::CorruptPartError.new("W273 fixture does not have one typed-Dynamic JSON leaf binding")
    end
    leaves = bindings[PAYLOAD_PATH]
    unless leaves.size == 1
      raise CrystalClick::CorruptPartError.new("W273 fixture does not have one leaf plan for its Dynamic field")
    end
    key, child_plan = leaves[0]
    unless key.dynamic_site == SITE_PATH &&
           key.canonical_arm_index == actual_roster.canonical_index_for(array_chain_type(depth)) &&
           key.descriptor_child_path == leaf_descriptor_child_path(depth)
      raise CrystalClick::CorruptPartError.new("W273 exact Dynamic Array-chain leaf key differs from fixture")
    end
    unless child_plan.typed_paths == json_type.json_type.not_nil!.typed_paths
      raise CrystalClick::CorruptPartError.new("W273 local typed UInt8 JSON child plan differs from fixture")
    end
    unless actual_roster.statistics.not_nil!.counts == [expected_mark_actual_counts(depth).sum.to_u64, 0_u64]
      raise CrystalClick::CorruptPartError.new("W273 caller-owned complete V3 actual statistics differ from fixture")
    end

    document_granules = granules(depth).map do |mark_rows|
      mark_rows.map(&.object_document)
    end
    streams = CrystalClick::ObjectDocumentCodec.encode(object_plan(depth), document_granules)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.object_schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    unless decoded.size == MARK_COUNT && decoded.all? { |mark_rows| mark_rows.size == ROWS_PER_MARK }
      raise CrystalClick::CorruptPartError.new("W273 common-codec mark grid differs from fixture")
    end

    expected = expected_literals(depth)
    actual_literals = decoded.flat_map do |mark_rows|
      mark_rows.map { |document| literal_for(CrystalClick::StorageColumnValue.object_document(document), depth) }
    end
    unless actual_literals == expected
      raise CrystalClick::CorruptPartError.new("W273 common-codec nested Array literals differ from fixture")
    end

    observed_actual_counts = decoded.map do |mark_rows|
      mark_rows.count do |document|
        !literal_for(CrystalClick::StorageColumnValue.object_document(document), depth).nil?
      end
    end
    unless observed_actual_counts == expected_mark_actual_counts(depth)
      raise CrystalClick::CorruptPartError.new("W273 common-codec actual-arm counts differ from fixture")
    end

    observed_size_vectors = decoded.map do |mark_rows|
      rows = mark_rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
      array_size_vectors_for_mark(rows, depth)
    end
    unless observed_size_vectors == expected_mark_array_size_vectors(depth)
      raise CrystalClick::CorruptPartError.new("W273 common-codec per-parent Array size vectors differ from fixture")
    end

    observed_array_element_counts = Array(Array(Int32)).new(depth) { [] of Int32 }
    observed_json_element_counts = [] of Int32
    observed_size_vectors.each do |mark_levels|
      depth.times do |level|
        observed_array_element_counts[level] << mark_levels[level].sum
      end
      observed_json_element_counts << mark_levels[depth - 1].sum
    end
    unless observed_array_element_counts == expected_mark_array_element_counts(depth)
      raise CrystalClick::CorruptPartError.new("W273 common-codec per-level Array element counts differ from fixture")
    end
    unless observed_json_element_counts == expected_mark_json_element_counts(depth)
      raise CrystalClick::CorruptPartError.new("W273 common-codec JSON leaf element counts differ from fixture")
    end
    nil
  end
end
