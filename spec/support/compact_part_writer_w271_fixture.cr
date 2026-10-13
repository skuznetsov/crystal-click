require "../../src/crystal_click"

module CompactPartWriterW271Fixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  COLUMN_NAME  = "typed_dynamic_json"
  KEY_NAME     = "pk"
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

  # Ordinary JSON is the actual Dynamic arm. The parent declaration remains
  # JSON(payload Dynamic(max_types=1)); the child JSON layout is independently
  # bound to an existing ObjectDocumentPlan below.
  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {VALUE_PATH => uint8_type} of String => CrystalClick::BinaryDataType,
    )
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
      raise CrystalClick::UnsupportedFormatError.new("W271 fixture JSON declaration is not admitted")
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

  def actuals : CrystalClick::DynamicStructure
    # Statistics are the caller-owned complete first-block sample: four
    # ordinary JSON arms and no SharedVariant value. NULLs do not increment
    # either count.
    statistics = CrystalClick::StructureStatistics.new(
      [4_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new(
      [json_type] of CrystalClick::BinaryDataType,
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
      roster.canonical_index_for(json_type),
      [] of Int32,
    )
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
    CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{VALUE_PATH, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
  end

  private def row(value : UInt8?) : CrystalClick::StorageColumnValue
    dynamic_value = if selected = value
                     CrystalClick::BinaryValue.dynamic(dynamic_type, json_value(selected))
                   else
                     CrystalClick::BinaryValue.dynamic(dynamic_type, nil)
                   end
    document = CrystalClick::ObjectDocument.new(
      {PAYLOAD_PATH => dynamic_value} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      row(11_u8),
      row(nil),
      row(nil),
      row(nil),
      row(51_u8),
      row(61_u8),
      row(nil),
      row(81_u8),
    ] of CrystalClick::StorageColumnValue
  end

  def granules(values : Array(CrystalClick::StorageColumnValue) = rows) : Array(Array(CrystalClick::StorageColumnValue))
    output = Array(Array(CrystalClick::StorageColumnValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      output << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  def expected_literals : Array(UInt8?)
    [11_u8, nil, nil, nil, 51_u8, 61_u8, nil, 81_u8] of UInt8?
  end

  def expected_mark_arm_counts : Array(Int32)
    [1, 0, 2, 1]
  end

  def arm_count(values : Array(CrystalClick::StorageColumnValue)) : Int32
    values.count { |value| !literal_for(value).nil? }
  end

  def literal_for(value : CrystalClick::StorageColumnValue) : UInt8?
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W271 value is not a root Object row")
    end
    selected = value.object_document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W271 payload descriptor is not the declared typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == json_type
      raise CrystalClick::CorruptPartError.new("W271 selected Dynamic child is not the bound JSON actual")
    end
    selected.child_at(0).json_row.value_for(VALUE_PATH).not_nil!.byte_at(0)
  end

  private def literal_for(document : CrystalClick::ObjectDocument) : UInt8?
    selected = document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W271 codec payload is not the declared typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == json_type
      raise CrystalClick::CorruptPartError.new("W271 codec Dynamic child is not the bound JSON actual")
    end
    selected.child_at(0).json_row.value_for(VALUE_PATH).not_nil!.byte_at(0)
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      context,
    )
  end

  # The existing paired Object codec is the control for the exact W215 leaf
  # binding; it intentionally does not claim Compact physical admission.
  def common_codec_roundtrip! : Nil
    document_granules = granules.map do |mark_rows|
      mark_rows.map(&.object_document)
    end
    streams = CrystalClick::ObjectDocumentCodec.encode(object_plan, document_granules)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.object_schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: json_bindings,
    )
    unless decoded.size == MARK_COUNT && decoded.all? { |mark_rows| mark_rows.size == ROWS_PER_MARK }
      raise CrystalClick::CorruptPartError.new("W271 common-codec mark grid differs from fixture")
    end
    actual_literals = decoded.flat_map do |mark_rows|
      mark_rows.map { |document| literal_for(document) }
    end
    unless actual_literals == expected_literals
      raise CrystalClick::CorruptPartError.new("W271 common-codec JSON literals differ from fixture")
    end
    observed_mark_counts = decoded.map do |mark_rows|
      mark_rows.count { |document| !literal_for(document).nil? }
    end
    unless observed_mark_counts == expected_mark_arm_counts
      raise CrystalClick::CorruptPartError.new("W271 common-codec arm counts differ from fixture")
    end
    nil
  end
end
