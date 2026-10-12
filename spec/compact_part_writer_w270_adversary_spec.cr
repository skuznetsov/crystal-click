require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w270_fixture"

module CompactPartWriterW270LowCardinalityFixture
  extend self

  COLUMN_NAME = "typed_dynamic_low_cardinality_stop"

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def low_cardinality_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.low_cardinality(uint8_type)
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

  def context : CrystalClick::CompactJsonWriteContext
    candidate = CrystalClick::DynamicStructure.new(
      [low_cardinality_type] of CrystalClick::BinaryDataType,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    counts = candidate.canonical_variant_names.map do |name|
      name == low_cardinality_type.name ? 1_u64 : 0_u64
    end
    dynamic = CrystalClick::DynamicStructure.new(
      [low_cardinality_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
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
    object_plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
      {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW270Fixture::SITE_PATH => object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def object_value : CrystalClick::StorageColumnValue
    low = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[7_u8]),
    )
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, low)
    document = CrystalClick::ObjectDocument.new(
      {"payload" => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  def column : CrystalClick::CompactPartColumn
    rows = [
      CrystalClick::StorageColumnValue.array([object_value] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      CompactPartWriterW269Fixture.granules(rows),
      context,
    )
  end
end

private def w270a_expect_no_publication(part_path : String, parent : String, &block) : Nil
  expect_raises(CrystalClick::UnsupportedFormatError) do
    yield
  end
  File.exists?(part_path).should be_false
  Dir.children(parent).should be_empty
end

private def w270a_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW270Fixture::KEY_NAME,
    CompactPartWriterW270Fixture::KEYS,
    columns,
    rows_per_mark: CompactPartWriterW270Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
    limits: limits,
    mark_format: CrystalClick::CompactMarkFormat::Mrk3,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
  )
end

describe CrystalClick::CompactPartWriter do
  it "rejects a LowCardinality typed-Dynamic arm while constructing the Object plan" do
    parent = File.tempname("crystal-click-w270-low-cardinality-stop-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      error = expect_raises(ArgumentError) do
        column = CompactPartWriterW270LowCardinalityFixture.column
        w270a_write(part_path, [column] of CrystalClick::CompactPartColumn)
      end
      error.message.to_s.should contain("invalid typed Object Dynamic actual roster")
      File.exists?(part_path).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses nested typed-Dynamic work beyond the caller codec depth before publication" do
    fixture = CompactPartWriterW270Fixture
    parent = File.tempname("crystal-click-w270-depth-guard-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      limits = CrystalClick::BinaryCodecLimits.new(
        1,
        1_000_000,
        1_000_000,
        1_000_000,
      )
      w270a_expect_no_publication(part_path, parent) do
        w270a_write(
          part_path,
          ([fixture.column] of CrystalClick::CompactPartColumn),
          limits,
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
