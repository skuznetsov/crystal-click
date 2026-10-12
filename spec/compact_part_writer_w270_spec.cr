require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w270_fixture"
require "./support/compact_part_writer_w269_fixture"

module CompactPartWriterW270OccurrenceFixture
  extend self

  COLUMN_NAME   = "nested_dynamic_array_lengths"
  ROWS_PER_MARK = CompactPartWriterW269Fixture::ROWS_PER_MARK
  MARK_COUNT    = CompactPartWriterW269Fixture::MARK_COUNT
  ROW_COUNT     = CompactPartWriterW269Fixture::ROW_COUNT

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

  def context : CrystalClick::CompactJsonWriteContext
    # The supplied first-block sample describes three ordinary Array values;
    # later marks do not replace or recompute this V3 prefix.
    dynamic = CrystalClick::DynamicStructure.new(
      [array_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [3_u64, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
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
      {CompactPartWriterW269Fixture::ARRAY_SITE => object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def actual_array(items : Array(UInt8)) : CrystalClick::BinaryValue
    children = Array(CrystalClick::BinaryValue).new(items.size)
    items.each do |item|
      children << CrystalClick::BinaryValue.fixed(uint8_type, Bytes[item])
    end
    CrystalClick::BinaryValue.array(array_type, children)
  end

  private def object_value(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {"payload" => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def outer_row(actuals : Array(CrystalClick::BinaryValue?)) : CrystalClick::StorageColumnValue
    objects = Array(CrystalClick::StorageColumnValue).new(actuals.size)
    actuals.each { |actual| objects << object_value(actual) }
    CrystalClick::StorageColumnValue.array(objects)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      # First mark's per-occurrence Array sizes are exactly [0, 2, 1]: two
      # Objects in row zero and one in row one. This distinguishes lengths
      # from cumulative offsets and from a first-row-only traversal.
      outer_row([
        actual_array([] of UInt8),
        actual_array([21_u8, 22_u8] of UInt8),
      ] of CrystalClick::BinaryValue?),
      outer_row([actual_array([31_u8] of UInt8)] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      # After a zero-occurrence mark, later rows exercise NULL, an ordinary
      # Array arm, and a late String in Dynamic's SharedVariant arm.
      outer_row([nil] of CrystalClick::BinaryValue?),
      outer_row([
        actual_array([51_u8] of UInt8),
        CrystalClick::BinaryValue.string("late-shared"),
      ] of CrystalClick::BinaryValue?),
      outer_row([actual_array([61_u8, 62_u8, 63_u8] of UInt8)] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
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

  def payload(row : CrystalClick::StorageColumnValue, index : Int32 = 0) : CrystalClick::BinaryValue
    row.array_values[index].object_document.value_for("payload")
  end
end

module CompactPartWriterW270OwnerIsolationFixture
  extend self

  COLUMN_NAME   = "typed_dynamic_owner_isolation"
  ROWS_PER_MARK = CompactPartWriterW269Fixture::ROWS_PER_MARK
  ROW_COUNT     = CompactPartWriterW269Fixture::ROW_COUNT
  MARK_COUNT    = CompactPartWriterW269Fixture::MARK_COUNT

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt16")
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def left_dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def right_dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def left_actual_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint8_type)
  end

  def right_tuple_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple([
      uint8_type,
      CrystalClick::BinaryDataType.nullable(uint16_type),
    ] of CrystalClick::BinaryDataType)
  end

  def right_actual_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(right_tuple_type)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 2,
      typed_paths: {
        "left"  => left_dynamic_type,
        "right" => right_dynamic_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  end

  private def dynamic_structure(type : CrystalClick::BinaryDataType) : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(
      [type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [3_u64, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  def object_plan : CrystalClick::ObjectDocumentPlan
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
    typed_types = {
      "left"  => left_dynamic_type,
      "right" => right_dynamic_type,
    } of String => CrystalClick::BinaryDataType
    typed_dynamics = {
      "left"  => dynamic_structure(left_actual_type),
      "right" => dynamic_structure(right_actual_type),
    } of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(structures, typed_types, typed_dynamics)
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ARRAY_SITE => object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def fixed_uint8(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
  end

  private def fixed_uint16(value : UInt16) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      uint16_type,
      Bytes[(value & 0xff_u16).to_u8, ((value >> 8) & 0xff_u16).to_u8],
    )
  end

  private def left_array(values : Array(UInt8)) : CrystalClick::BinaryValue
    items = values.map { |value| fixed_uint8(value) }
    CrystalClick::BinaryValue.array(left_actual_type, items)
  end

  private def right_tuple(marker : UInt8, value : UInt16?) : CrystalClick::BinaryValue
    nullable_type = right_tuple_type.child_at(1)
    nullable = if selected = value
                 CrystalClick::BinaryValue.nullable(nullable_type, fixed_uint16(selected))
               else
                 CrystalClick::BinaryValue.nullable(nullable_type)
               end
    CrystalClick::BinaryValue.tuple(
      right_tuple_type,
      [fixed_uint8(marker), nullable] of CrystalClick::BinaryValue,
    )
  end

  private def right_array(items : Array(Tuple(UInt8, UInt16?))) : CrystalClick::BinaryValue
    children = items.map { |marker, value| right_tuple(marker, value) }
    CrystalClick::BinaryValue.array(right_actual_type, children)
  end

  private def object_value(
    left_actual : CrystalClick::BinaryValue?,
    right_actual : CrystalClick::BinaryValue?,
  ) : CrystalClick::StorageColumnValue
    fields = {
      "left"  => CrystalClick::BinaryValue.dynamic(left_dynamic_type, left_actual),
      "right" => CrystalClick::BinaryValue.dynamic(right_dynamic_type, right_actual),
    } of String => CrystalClick::BinaryValue
    document = CrystalClick::ObjectDocument.new(fields)
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def outer_row(items : Array(Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?))) : CrystalClick::StorageColumnValue
    objects = items.map do |left, right|
      object_value(left, right)
    end
    CrystalClick::StorageColumnValue.array(objects)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      # Both independent typed fields have three Dynamic occurrences in the
      # caller's first-prefix sample. Their nested Array lengths differ so a
      # role-only or cross-field count cursor cannot accidentally satisfy both.
      outer_row([
        {left_array([] of UInt8), right_array([] of Tuple(UInt8, UInt16?))},
        {
          left_array([21_u8, 22_u8] of UInt8),
          right_array([{1_u8, nil}, {2_u8, 200_u16}] of Tuple(UInt8, UInt16?)),
        },
      ] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([
        {
          left_array([31_u8] of UInt8),
          right_array([{3_u8, nil}] of Tuple(UInt8, UInt16?)),
        },
      ] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([
        {nil.as(CrystalClick::BinaryValue?), nil.as(CrystalClick::BinaryValue?)},
      ] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([
        {
          left_array([41_u8] of UInt8),
          CrystalClick::BinaryValue.string("late-shared"),
        },
      ] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([
        {
          left_array([51_u8, 52_u8] of UInt8),
          right_array([{4_u8, 404_u16}] of Tuple(UInt8, UInt16?)),
        },
      ] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
      outer_row([] of Tuple(CrystalClick::BinaryValue?, CrystalClick::BinaryValue?)),
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

module CompactPartWriterW270IndependentSiteFixture
  extend self

  COLUMN_NAME   = "independent_typed_dynamic_sites"
  ROWS_PER_MARK = CompactPartWriterW269Fixture::ROWS_PER_MARK
  MARK_COUNT    = CompactPartWriterW269Fixture::MARK_COUNT

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt16")
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def array8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint8_type)
  end

  def array16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint16_type)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Tuple(#{json_type.name}, #{json_type.name})")
  end

  private def dynamic_structure(type : CrystalClick::BinaryDataType) : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(
      [type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [2_u64, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  private def object_plan(actual_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
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
      {"payload" => dynamic_structure(actual_type)} of String => CrystalClick::DynamicStructure,
    )
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {
        CompactPartWriterW269Fixture::LEFT_SITE  => object_plan(array8_type),
        CompactPartWriterW269Fixture::RIGHT_SITE => object_plan(array16_type),
      } of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def fixed(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    bytes = if type == uint8_type
              Bytes[value.to_u8]
            else
              Bytes[(value & 0xff_u16).to_u8, ((value >> 8) & 0xff_u16).to_u8]
            end
    CrystalClick::BinaryValue.fixed(type, bytes)
  end

  private def array8(values : Array(UInt8)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(
      array8_type,
      values.map { |value| fixed(uint8_type, value.to_u16) },
    )
  end

  private def array16(values : Array(UInt16)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(
      array16_type,
      values.map { |value| fixed(uint16_type, value) },
    )
  end

  private def object_value(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    value = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new({"payload" => value} of String => CrystalClick::BinaryValue),
    )
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([] of UInt8)),
        object_value(array16([101_u16] of UInt16)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([11_u8, 12_u8] of UInt8)),
        object_value(array16([] of UInt16)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(nil),
        object_value(array16([202_u16, 203_u16] of UInt16)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([14_u8] of UInt8)),
        object_value(CrystalClick::BinaryValue.string("site-shared")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([15_u8] of UInt8)),
        object_value(nil),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([] of UInt8)),
        object_value(array16([606_u16] of UInt16)),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(nil),
        object_value(nil),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.tuple([
        object_value(array8([18_u8, 19_u8] of UInt8)),
        object_value(array16([] of UInt16)),
      ] of CrystalClick::StorageColumnValue),
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

module CompactPartWriterW270NullableFixture
  extend self

  COLUMN_NAME   = "typed_dynamic_nullable_int64"
  ROWS_PER_MARK = CompactPartWriterW269Fixture::ROWS_PER_MARK
  ROW_COUNT     = CompactPartWriterW269Fixture::ROW_COUNT
  MARK_COUNT    = CompactPartWriterW269Fixture::MARK_COUNT

  def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def nullable_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(int64_type)
  end

  def array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nullable_type)
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
    dynamic = CrystalClick::DynamicStructure.new(
      [array_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [5_u64, 1_u64] of UInt64,
        [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
      ),
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
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType,
      {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ARRAY_SITE => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def fixed_int64(value : Int64) : CrystalClick::BinaryValue
    bits = value.to_u64
    bytes = Bytes.new(sizeof(Int64)) do |index|
      ((bits >> (index * 8)) & 0xff_u64).to_u8
    end
    CrystalClick::BinaryValue.fixed(int64_type, bytes)
  end

  private def nullable(value : Int64?) : CrystalClick::BinaryValue
    if selected = value
      CrystalClick::BinaryValue.nullable(nullable_type, fixed_int64(selected))
    else
      CrystalClick::BinaryValue.nullable(nullable_type)
    end
  end

  private def array_actual(values : Array(Int64?)) : CrystalClick::BinaryValue
    children = values.map { |value| nullable(value) }
    CrystalClick::BinaryValue.array(array_type, children)
  end

  private def object_value(actual : CrystalClick::BinaryValue?) : CrystalClick::StorageColumnValue
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {"payload" => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def outer_row(actuals : Array(CrystalClick::BinaryValue?)) : CrystalClick::StorageColumnValue
    objects = actuals.map { |actual| object_value(actual) }
    CrystalClick::StorageColumnValue.array(objects)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      # The caller-supplied Dynamic V3 sample contains five ordinary
      # Array(Nullable(Int64)) values and one SharedVariant String. The nested
      # nullable values include two NULL elements; later marks do not redefine
      # this first-block census.
      outer_row([array_actual([nil] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([array_actual([32_i64] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      outer_row([] of CrystalClick::BinaryValue?),
      outer_row([nil] of CrystalClick::BinaryValue?),
      outer_row([
        array_actual([64_i64] of Int64?),
        CrystalClick::BinaryValue.string("late-shared"),
      ] of CrystalClick::BinaryValue?),
      outer_row([array_actual([nil, 96_i64] of Int64?)] of CrystalClick::BinaryValue?),
      outer_row([array_actual([] of Int64?)] of CrystalClick::BinaryValue?),
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

describe CrystalClick::CompactPartWriter do
  it "frames every nested typed-Dynamic Array size per occurrence and per MRK3 mark" do
    fixture = CompactPartWriterW270OccurrenceFixture
    modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]

    modes.each do |mode|
      suffix = mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w270-array-sizes-#{suffix}-")
      part_path = File.join(parent, "all_1_1_0")

      begin
        Dir.mkdir(parent)
        columns = [fixture.column] of CrystalClick::CompactPartColumn
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          CompactPartWriterW269Fixture::KEYS,
          columns,
          rows_per_mark: CompactPartWriterW270OccurrenceFixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          variant_discriminator_mode: mode,
        ).should eq(part_path)

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW270OccurrenceFixture::COLUMN_NAME,
          fixture.schema,
        )
        reader.mark_count.should eq(CompactPartWriterW270OccurrenceFixture::MARK_COUNT)
        reader.row_count.should eq(CompactPartWriterW270OccurrenceFixture::ROW_COUNT.to_u64)

        [
          {0, CompactPartWriterW270OccurrenceFixture::MARK_COUNT},
          {1, 2},
          {CompactPartWriterW270OccurrenceFixture::MARK_COUNT - 1, 1},
          {CompactPartWriterW270OccurrenceFixture::MARK_COUNT, 0},
        ].each do |first_mark, count|
          actual_marks = reader.read_marks(first_mark, count)
          actual_marks.size.should eq(count)
          expected_start = first_mark * CompactPartWriterW270OccurrenceFixture::ROWS_PER_MARK
          expected_rows = fixture.rows[expected_start, count * CompactPartWriterW270OccurrenceFixture::ROWS_PER_MARK]
          actual_rows = actual_marks.flatten
          actual_rows.size.should eq(expected_rows.size)
          actual_rows.each_with_index do |actual, index|
            budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
            CrystalClick::CompactPartValueComparison.storage!(actual, expected_rows[index], budget)
          end
        end

        full = reader.read_marks(0, CompactPartWriterW270OccurrenceFixture::MARK_COUNT)
        first_row = full[0][0]
        first_payloads = first_row.array_values.map do |object|
          object.object_document.value_for("payload")
        end
        first_payloads.size.should eq(2)
        first_payloads.map do |payload|
          payload.type.should eq(fixture.dynamic_type)
          payload.is_null?.should be_false
          payload.child_at(0).type.should eq(fixture.array_type)
          payload.child_at(0).child_count
        end.should eq([0, 2])
        fixture.payload(full[0][1]).child_at(0).child_count.should eq(1)

        # Mark one has no Object occurrences at either outer Array row; mark
        # two resumes with NULL and SharedVariant after the reset.
        full[1].map { |row| row.array_values.size }.should eq([0, 0])
        fixture.payload(full[2][0]).is_null?.should be_true
        mark_two_payloads = full[2][1].array_values.map do |object|
          object.object_document.value_for("payload")
        end
        mark_two_payloads[0].child_at(0).child_count.should eq(1)
        mark_two_payloads[1].child_at(0).type.name.should eq("String")
        fixture.payload(full[3][0]).child_at(0).child_count.should eq(3)
        full[3][1].array_values.should be_empty
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "keeps two typed-Dynamic field owners independent through recursive Array Tuple Nullable framing" do
    fixture = CompactPartWriterW270OwnerIsolationFixture
    modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]

    modes.each do |mode|
      parent = File.tempname("crystal-click-w270-owner-isolation-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        columns = [fixture.column] of CrystalClick::CompactPartColumn
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          CompactPartWriterW269Fixture::KEYS,
          columns,
          rows_per_mark: CompactPartWriterW270OwnerIsolationFixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          variant_discriminator_mode: mode,
        ).should eq(part_path)

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW270OwnerIsolationFixture::COLUMN_NAME,
          fixture.schema,
        )
        full = reader.read_marks(0, CompactPartWriterW270OwnerIsolationFixture::MARK_COUNT)
        actual = full.flatten
        expected = fixture.rows
        actual.size.should eq(expected.size)
        actual.each_with_index do |value, index|
          budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
          CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
        end

        full[1].map { |row| row.array_values.size }.should eq([0, 0])
        first_pair = full[0][0].array_values
        first_pair.size.should eq(2)
        first_pair[0].object_document.value_for("left").child_at(0).child_count.should eq(0)
        first_pair[0].object_document.value_for("right").child_at(0).child_count.should eq(0)
        first_pair[1].object_document.value_for("left").child_at(0).child_count.should eq(2)
        right_tuples = first_pair[1].object_document.value_for("right").child_at(0)
        right_tuples.child_count.should eq(2)
        right_tuples.child_at(0).child_at(1).is_null?.should be_true
        right_tuples.child_at(1).child_at(1).child_at(0).bytes.should eq(Bytes[200_u8, 0_u8])
        full[2][0].array_values[0].object_document.value_for("left").is_null?.should be_true
        full[2][1].array_values[0].object_document.value_for("right").child_at(0).type.name.should eq("String")
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "binds nested typed-Dynamic prefix and body state independently at each Object site" do
    fixture = CompactPartWriterW270IndependentSiteFixture
    modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]

    modes.each do |mode|
      parent = File.tempname("crystal-click-w270-independent-sites-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        columns = [fixture.column] of CrystalClick::CompactPartColumn
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          CompactPartWriterW269Fixture::KEYS,
          columns,
          rows_per_mark: CompactPartWriterW270IndependentSiteFixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          variant_discriminator_mode: mode,
        ).should eq(part_path)

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW270IndependentSiteFixture::COLUMN_NAME,
          fixture.schema,
        )
        full = reader.read_marks(0, CompactPartWriterW270IndependentSiteFixture::MARK_COUNT)
        actual = full.flatten
        expected = fixture.rows
        actual.size.should eq(expected.size)
        actual.each_with_index do |value, index|
          budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
          CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
        end

        first = full[0][0].tuple_values
        first[0].object_document.value_for("payload").child_at(0).child_count.should eq(0)
        first[1].object_document.value_for("payload").child_at(0).child_count.should eq(1)
        second = full[0][1].tuple_values
        second[0].object_document.value_for("payload").child_at(0).child_count.should eq(2)
        second[1].object_document.value_for("payload").child_at(0).child_count.should eq(0)
        full[1][1].tuple_values[1].object_document.value_for("payload").child_at(0).type.name.should eq("String")
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "preserves nested Nullable(Int64) flags and later SharedVariant occurrences" do
    fixture = CompactPartWriterW270NullableFixture
    modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]

    modes.each do |mode|
      parent = File.tempname("crystal-click-w270-nullable-int64-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        columns = [fixture.column] of CrystalClick::CompactPartColumn
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          CompactPartWriterW269Fixture::KEYS,
          columns,
          rows_per_mark: CompactPartWriterW270NullableFixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          variant_discriminator_mode: mode,
        ).should eq(part_path)

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW270NullableFixture::COLUMN_NAME,
          fixture.schema,
        )
        full = reader.read_marks(0, CompactPartWriterW270NullableFixture::MARK_COUNT)
        actual = full.flatten
        expected = fixture.rows
        actual.size.should eq(expected.size)
        actual.each_with_index do |value, index|
          budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
          CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
        end

        first_null = full[0][0].array_values[0].object_document.value_for("payload")
        first_null.is_null?.should be_false
        first_null.child_at(0).type.should eq(fixture.array_type)
        first_null.child_at(0).child_at(0).is_null?.should be_true
        first_value = full[0][1].array_values[0].object_document.value_for("payload")
        first_value.child_at(0).child_at(0).child_at(0).bytes.should eq(Bytes[32_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
        full[1].map { |row| row.array_values.size }.should eq([0, 0])
        full[2][0].array_values[0].object_document.value_for("payload").is_null?.should be_true
        full[2][1].array_values[0].object_document.value_for("payload").child_at(0).type.should eq(fixture.array_type)
        full[2][1].array_values[1].object_document.value_for("payload").child_at(0).type.name.should eq("String")
        last_values = full[3][0].array_values[0].object_document.value_for("payload").child_at(0)
        last_values.child_at(0).is_null?.should be_true
        last_values.child_at(1).is_null?.should be_false
        full[3][1].array_values[0].object_document.value_for("payload").child_at(0).child_count.should eq(0)
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
