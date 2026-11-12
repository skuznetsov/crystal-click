require "../../src/crystal_click"

module CompactRecursiveDynamicW284Fixture
  extend self

  KEY_NAME            = "pk"
  COLUMN_NAME         = "trace"
  JSON_DECLARATION    = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  DYNAMIC_DECLARATION = "Dynamic(max_types=1)"
  SCHEMA_DECLARATION  = "Array(Tuple(doc #{JSON_DECLARATION}, sample #{DYNAMIC_DECLARATION}))"

  JSON_SITE_PATH    = "root/array[0]/tuple[0]"
  DYNAMIC_SITE_PATH = "root/array[0]/tuple[1]"

  ROWS_PER_MARK =  2
  ROW_COUNT     =  4
  MARK_COUNT    =  2
  FRAME_BYTES   = 32

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(SCHEMA_DECLARATION)
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 103_u64 }
  end

  # These are the exact four transformed trace literals in the W257 fixture.
  def rows : Array(CrystalClick::StorageColumnValue)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    [
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple(14_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(1040_u64))),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple(15_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("child!"))),
        tuple(16_u8, CrystalClick::BinaryValue.dynamic(dynamic)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple(17_u8, CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.uint64(1060_u64))),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def column : CrystalClick::CompactPartColumn
    granules = rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(
        {JSON_SITE_PATH => object_plan} of String => CrystalClick::ObjectDocumentPlan,
      ),
      dynamic_contexts: {
        DYNAMIC_SITE_PATH => dynamic_context,
      } of String => CrystalClick::CompactDynamicWriteContext,
    )
  end

  private def tuple(tag : UInt8, sample : CrystalClick::BinaryValue) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(
        CrystalClick::ObjectDocument.new(
          {"t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[tag])} of String => CrystalClick::BinaryValue,
        ),
      ),
      CrystalClick::StorageColumnValue.bulk(sample),
    ] of CrystalClick::StorageColumnValue)
  end

  private def object_plan : CrystalClick::ObjectDocumentPlan
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_DECLARATION)
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def dynamic_context : CrystalClick::CompactDynamicWriteContext
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new(
      [uint64] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [1_u64, 2_u64],
        [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    CrystalClick::CompactDynamicWriteContext.new(
      {"root" => structure} of String => CrystalClick::DynamicStructure,
    )
  end
end
