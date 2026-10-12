require "../../src/crystal_click"
require "./compact_part_writer_w269_fixture"

module CompactPartWriterW270Fixture
  extend self

  COLUMN_NAME = "nested_dynamic_json"
  SITE_PATH   = CompactPartWriterW269Fixture::ARRAY_SITE
  KEY_NAME    = CompactPartWriterW269Fixture::KEY_NAME
  KEYS        = CompactPartWriterW269Fixture::KEYS
  ROWS_PER_MARK = CompactPartWriterW269Fixture::ROWS_PER_MARK
  ROW_COUNT     = CompactPartWriterW269Fixture::ROW_COUNT
  MARK_COUNT    = CompactPartWriterW269Fixture::MARK_COUNT

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint8_type)
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  end

  def object_plan : CrystalClick::ObjectDocumentPlan
    # The first mark has exactly one typed-Dynamic document; later marks do
    # not rewrite this caller-owned V3 prefix sample.
    dynamic_statistics = CrystalClick::StructureStatistics.new(
      [1_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    dynamic = CrystalClick::DynamicStructure.new(
      [array_type] of CrystalClick::BinaryDataType,
      dynamic_statistics,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
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
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
      {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
    )
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {SITE_PATH => object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def object_value(array_values : Array(UInt8)) : CrystalClick::StorageColumnValue
    actual_values = array_values.map do |value|
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
    end
    actual_array = CrystalClick::BinaryValue.array(array_type, actual_values)
    typed_value = CrystalClick::BinaryValue.dynamic(dynamic_type, actual_array)
    document = CrystalClick::ObjectDocument.new(
      {"payload" => typed_value} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([
        object_value([11_u8] of UInt8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        object_value([31_u8, 32_u8] of UInt8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      CompactPartWriterW269Fixture.granules(rows),
      context,
    )
  end
end
