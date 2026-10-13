require "../../src/crystal_click"

module CompactPartWriterW272Fixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  COLUMN_NAME    = "typed_dynamic_array_json"
  KEY_NAME       = "pk"
  ROWS_PER_MARK  = 2
  ROW_COUNT      = 8
  MARK_COUNT     = 4
  FRAME_BYTES    = 4096
  SITE_PATH      = "root"
  PAYLOAD_PATH   = "payload"
  VALUE_PATH     = "value"
  KEYS           = Slice.new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }

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

  def array_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(json_type)
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
      raise CrystalClick::UnsupportedFormatError.new("W272 fixture JSON declaration is not admitted")
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

  # Statistics are the caller-owned complete first-block sample: four
  # ordinary Array(JSON) arms and no SharedVariant value. Empty arrays count
  # as selected arms; NULL Dynamics do not.
  def actuals : CrystalClick::DynamicStructure
    statistics = CrystalClick::StructureStatistics.new(
      [4_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new(
      [array_json_type] of CrystalClick::BinaryDataType,
      statistics,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  def json_bindings : Hash(String, Array(LeafPlan))
    roster = actuals
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      empty_structures,
      json_type.json_type.not_nil!.typed_paths,
    )
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      SITE_PATH,
      roster.canonical_index_for(array_json_type),
      [] of Int32,
    ).with_child(0)
    {PAYLOAD_PATH => [{key, child_plan}] of LeafPlan} of String => Array(LeafPlan)
  end

  def object_plan : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      empty_structures,
      schema.object_schema.typed_paths,
      {PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: json_bindings,
    )
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {SITE_PATH => object_plan} of String => CrystalClick::ObjectDocumentPlan,
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

  private def array_value(values : Array(UInt8)) : CrystalClick::BinaryValue
    children = Array(CrystalClick::BinaryValue).new(values.size)
    values.each { |value| children << json_value(value) }
    CrystalClick::BinaryValue.array(array_json_type, children)
  end

  private def row(values : Array(UInt8)?) : CrystalClick::StorageColumnValue
    actual = values.try { |items| array_value(items) }
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      row([11_u8, 12_u8] of UInt8),
      row(nil),
      row(nil),
      row(nil),
      row([] of UInt8),
      row([61_u8] of UInt8),
      row(nil),
      row([81_u8, 82_u8, 83_u8] of UInt8),
    ] of CrystalClick::StorageColumnValue
  end

  def granules(values : Array(CrystalClick::StorageColumnValue) = rows) : Array(Array(CrystalClick::StorageColumnValue))
    output = Array(Array(CrystalClick::StorageColumnValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      output << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  # nil denotes SQL NULL; an empty UInt8 array denotes a selected ordinary
  # Array(JSON) whose child element count is zero.
  def expected_literals : Array(Array(UInt8)?)
    [
      ([11_u8, 12_u8] of UInt8),
      nil,
      nil,
      nil,
      ([] of UInt8),
      ([61_u8] of UInt8),
      nil,
      ([81_u8, 82_u8, 83_u8] of UInt8),
    ] of Array(UInt8)?
  end

  def expected_mark_actual_counts : Array(Int32)
    [1, 0, 2, 1]
  end

  def expected_mark_json_element_counts : Array(Int32)
    [2, 0, 1, 3]
  end

  def literal_for(value : CrystalClick::StorageColumnValue) : Array(UInt8)?
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W272 value is not a root Object row")
    end
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W272 payload descriptor is not the declared typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == array_json_type
      raise CrystalClick::CorruptPartError.new("W272 selected Dynamic child is not the bound Array(JSON) actual")
    end
    selected.child_at(0).elements.map do |json|
      unless json.type == json_type && json.json_row.type == json_type
        raise CrystalClick::CorruptPartError.new("W272 Array(JSON) element has the wrong JSON descriptor")
      end
      cell = json.json_row.value_for(VALUE_PATH).not_nil!
      unless cell.type == uint8_type
        raise CrystalClick::CorruptPartError.new("W272 JSON value has the wrong UInt8 descriptor")
      end
      cell.byte_at(0)
    end
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      context,
    )
  end

  # Validate the exact nested Dynamic -> Array -> JSON leaf binding and the
  # independent values/count grids through the common Object codec. This is
  # a fixture control, not evidence of Compact physical admission.
  def common_codec_roundtrip! : Nil
    actual_roster = actuals
    bindings = json_bindings
    bindings.size.should eq(1)
    leaves = bindings[PAYLOAD_PATH]
    leaves.size.should eq(1)
    key, child_plan = leaves[0]
    key.dynamic_site.should eq(SITE_PATH)
    key.canonical_arm_index.should eq(actual_roster.canonical_index_for(array_json_type))
    key.descriptor_child_path.should eq([0] of Int32)
    child_plan.typed_paths.should eq(json_type.json_type.not_nil!.typed_paths)
    actual_roster.statistics.not_nil!.counts.should eq([4_u64, 0_u64])

    document_granules = granules.map do |mark_rows|
      mark_rows.map(&.object_document)
    end
    streams = CrystalClick::ObjectDocumentCodec.encode(object_plan, document_granules)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.object_schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    unless decoded.size == MARK_COUNT && decoded.all? { |mark_rows| mark_rows.size == ROWS_PER_MARK }
      raise CrystalClick::CorruptPartError.new("W272 common-codec mark grid differs from fixture")
    end

    actual_literals = decoded.flat_map do |mark_rows|
      mark_rows.map { |document| literal_for(CrystalClick::StorageColumnValue.object_document(document)) }
    end
    unless actual_literals == expected_literals
      raise CrystalClick::CorruptPartError.new("W272 common-codec Array(JSON) literals differ from fixture")
    end

    observed_actual_counts = decoded.map do |mark_rows|
      mark_rows.count do |document|
        !literal_for(CrystalClick::StorageColumnValue.object_document(document)).nil?
      end
    end
    unless observed_actual_counts == expected_mark_actual_counts
      raise CrystalClick::CorruptPartError.new("W272 common-codec actual-arm counts differ from fixture")
    end

    observed_json_element_counts = decoded.map do |mark_rows|
      mark_rows.sum do |document|
        literal_for(CrystalClick::StorageColumnValue.object_document(document)).try(&.size) || 0
      end
    end
    unless observed_json_element_counts == expected_mark_json_element_counts
      raise CrystalClick::CorruptPartError.new("W272 common-codec child JSON element counts differ from fixture")
    end
    nil
  end
end
