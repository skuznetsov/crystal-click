# W284-only recursive Compact JSON + Dynamic fixture.
# The JSON Dynamic context API is design-sealed but not present at this task's
# base revision; do not compile this file until production integration lands.
require "../../src/crystal_click"

module CompactRecursiveDynamicW284Fixture
  extend self

  KEY_NAME            = "pk"
  COLUMN_NAME         = "trace"
  JSON_DECLARATION    = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  DYNAMIC_DECLARATION = "Dynamic(max_types=1)"
  TRACE_DECLARATION   = "Array(Tuple(doc #{JSON_DECLARATION}, sample #{DYNAMIC_DECLARATION}))"
  SCHEMA_DECLARATION  = TRACE_DECLARATION

  JSON_SITE_PATH     = "root/array[0]/tuple[0]"
  DYNAMIC_SITE_PATH  = "root/array[0]/tuple[1]"
  DYNAMIC_LOCAL_SITE = "root"

  ROWS_PER_MARK =  2
  ROW_COUNT     =  8
  MARK_COUNT    =  4
  FRAME_BYTES   = 32

  # Per-row Dynamic value-occurrence Q. NULL counts as an occurrence; an empty
  # parent Array contributes no Dynamic occurrence.
  DYNAMIC_OCCURRENCES_BY_ROW    = [0_u64, 1_u64, 2_u64, 1_u64, 0_u64, 0_u64, 1_u64, 1_u64]
  DYNAMIC_OCCURRENCES_BY_MARK   = [1_u64, 3_u64, 0_u64, 2_u64]
  DYNAMIC_NONNULL_BY_MARK       = [1_u64, 2_u64, 0_u64, 0_u64]
  DYNAMIC_NULL_BY_MARK          = [0_u64, 1_u64, 0_u64, 2_u64]
  DYNAMIC_SHARED_STRING_BY_MARK = [0_u64, 1_u64, 0_u64, 0_u64]
  DYNAMIC_UINT64_BY_MARK        = [1_u64, 1_u64, 0_u64, 0_u64]

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(SCHEMA_DECLARATION)
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 103_u64 }
  end

  # The first four rows preserve the W257 transformed trace literals exactly.
  # Rows 107-108 are a whole zero-Q mark; 109-110 are NULL-only Dynamic.
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
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple(18_u8, CrystalClick::BinaryValue.dynamic(dynamic)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tuple(19_u8, CrystalClick::BinaryValue.dynamic(dynamic)),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def dynamic_context : CrystalClick::CompactDynamicWriteContext
    # W284 API assumption: the outer Dynamic context is keyed by the exact
    # recursive schema path; its inner DynamicWriteContext retains local "root".
    CrystalClick::CompactDynamicWriteContext.new(
      {DYNAMIC_LOCAL_SITE => dynamic_structure} of String => CrystalClick::DynamicStructure,
    )
  end

  def dynamic_contexts : Hash(String, CrystalClick::CompactDynamicWriteContext)
    {DYNAMIC_SITE_PATH => dynamic_context} of String => CrystalClick::CompactDynamicWriteContext
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
      dynamic_contexts: dynamic_contexts,
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

  private def dynamic_structure : CrystalClick::DynamicStructure
    # Global V3 full-stat candidate for the part: one SharedVariant String,
    # two ordinary UInt64 values. NULL contributes to Q, not to either arm.
    statistics = CrystalClick::StructureStatistics.new(
      [1_u64, 2_u64],
      [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
      statistics: statistics,
    )
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
end
