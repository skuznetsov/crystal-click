require "../../src/crystal_click"

module CompactPartWriterW271NativeFixture
  extend self

  alias LeafPlan = Tuple(
    CrystalClick::BinaryDynamicJsonLeafKey,
    CrystalClick::ObjectDocumentPlan,
  )

  COLUMN_NAME   = "typed_dynamic_json"
  KEY_NAME      = "pk"
  ROWS_PER_MARK = 2
  ROW_COUNT     = 8
  MARK_COUNT    = 4
  FRAME_BYTES   = 4096
  SITE_PATH     = "root"
  PAYLOAD_PATH  = "payload"
  VALUE_PATH    = "value"
  KEYS          = Slice.new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }

  # This is deliberately distinct from the W271 UInt8 local baseline. The
  # native stock CAST path was observed to materialize an ordinary bare JSON
  # Dynamic arm whose JSON Object child has one inferred Int64 path.
  def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json
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
      raise CrystalClick::UnsupportedFormatError.new("W271 native-shaped JSON declaration is not admitted")
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

  # Canonical Dynamic order is JSON, SharedVariant. NULLs do not enter either
  # count; the independent literal census has four JSON values and no spills.
  def actuals : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(
      [json_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([4_u64, 0_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  # In the native-shaped actual JSON, `value` is an inferred Object Dynamic
  # path, not a descriptor-level typed JSON path. Keep its Object roster and
  # Int64 Dynamic statistics separate from the parent Dynamic actual census.
  private def child_json_plan : CrystalClick::ObjectDocumentPlan
    int64_dynamic = CrystalClick::DynamicStructure.new(
      [int64_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([4_u64, 0_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    child_statistics = CrystalClick::StructureStatistics.new(
      [4_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    child_object = CrystalClick::ObjectStructure.new(
      [VALUE_PATH] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: child_statistics,
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      child_object,
      {VALUE_PATH => int64_dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  def json_bindings : Hash(String, Array(LeafPlan))
    roster = actuals
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      SITE_PATH,
      roster.canonical_index_for(json_type),
      [] of Int32,
    )
    {PAYLOAD_PATH => [{key, child_json_plan}] of LeafPlan} of String => Array(LeafPlan)
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

  private def json_value(value : Int64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{VALUE_PATH, CrystalClick::BinaryValue.int64(value)}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
  end

  private def row(value : Int64?) : CrystalClick::StorageColumnValue
    dynamic_value = if selected = value
                     CrystalClick::BinaryValue.dynamic(dynamic_type, json_value(selected))
                   else
                     CrystalClick::BinaryValue.dynamic(dynamic_type, nil)
                   end
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new({PAYLOAD_PATH => dynamic_value} of String => CrystalClick::BinaryValue),
    )
  end

  def expected_literals : Array(Int64?)
    [11_i64, nil, nil, nil, 51_i64, 61_i64, nil, 81_i64] of Int64?
  end

  def expected_mark_arm_counts : Array(Int32)
    [1, 0, 2, 1]
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    expected_literals.map { |value| row(value) }
  end

  def granules(values : Array(CrystalClick::StorageColumnValue) = rows) : Array(Array(CrystalClick::StorageColumnValue))
    output = Array(Array(CrystalClick::StorageColumnValue)).new(MARK_COUNT)
    MARK_COUNT.times do |mark|
      output << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  def literal_for(document : CrystalClick::ObjectDocument) : Int64?
    selected = document.value_for(PAYLOAD_PATH)
    unless selected.type == dynamic_type
      raise CrystalClick::CorruptPartError.new("W271 native payload is not the declared typed Dynamic")
    end
    return nil if selected.is_null?
    unless selected.child_count == 1 && selected.child_at(0).type == json_type
      raise CrystalClick::CorruptPartError.new("W271 native Dynamic child is not bare JSON")
    end
    selected.child_at(0).json_row.value_for(VALUE_PATH).not_nil!.as_int64
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      context,
    )
  end

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
    unless decoded.size == MARK_COUNT && decoded.all?(&.size.==(ROWS_PER_MARK))
      raise CrystalClick::CorruptPartError.new("W271 native common-codec mark grid differs from fixture")
    end
    actual = decoded.flat_map { |mark_rows| mark_rows.map { |document| literal_for(document) } }
    unless actual == expected_literals
      raise CrystalClick::CorruptPartError.new("W271 native common-codec Int64 JSON literals differ")
    end
    counts = decoded.map { |mark_rows| mark_rows.count { |document| !literal_for(document).nil? } }
    unless counts == expected_mark_arm_counts
      raise CrystalClick::CorruptPartError.new("W271 native common-codec mark arm counts differ")
    end
    nil
  end
end
