require "../../src/crystal_click"

module CompactPartWriterW283Fixture
  extend self

  JSON_DECLARATION    = "JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)"
  VARIANT_DECLARATION = "Variant(Array(UInt8), String, UInt64)"

  KEY_NAME      = "pk"
  COLUMN_NAME   = "recursive_variant_w283"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096

  def schema_declaration : String
    "Tuple(#{JSON_DECLARATION}, Array(Tuple(#{VARIANT_DECLARATION}, LowCardinality(String))), #{JSON_DECLARATION}, Tuple(LowCardinality(String), #{VARIANT_DECLARATION}, Map(String, #{VARIANT_DECLARATION}), Nested(choice #{VARIANT_DECLARATION}, label LowCardinality(String))))"
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(schema_declaration)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"id" => CrystalClick::BinaryDataType.primitive("UInt64")} of String => CrystalClick::BinaryDataType,
    )
  end

  def array_bulk_type : CrystalClick::BinaryDataType
    schema.child_at(1).bulk_type
  end

  def tuple_bulk_type : CrystalClick::BinaryDataType
    schema.child_at(3).bulk_type
  end

  def variant_type : CrystalClick::BinaryDataType
    array_bulk_type.child_at(0).child_at(0)
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    Array(CrystalClick::StorageColumnValue).new(ROW_COUNT) do |index|
      id = index.to_u64 + 1_u64
      CrystalClick::StorageColumnValue.tuple(
        [
          object_value(id),
          CrystalClick::StorageColumnValue.bulk(array_bulk_value(index)),
          object_value(id + 100_u64),
          CrystalClick::StorageColumnValue.bulk(tuple_bulk_value(index)),
        ] of CrystalClick::StorageColumnValue,
      )
    end
  end

  def column : CrystalClick::CompactPartColumn
    granules = rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    plans = {
      "root/tuple[0]" => object_plan,
      "root/tuple[2]" => object_plan,
    } of String => CrystalClick::ObjectDocumentPlan
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
  end

  # Two binary-invalid UTF-8 values make the late String arms distinguishable
  # from accidental text normalization in either parent-mark traversal.
  def invalid_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def object_value(id : UInt64) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {"id" => CrystalClick::BinaryValue.uint64(id)} of String => CrystalClick::BinaryValue,
      ),
    )
  end

  private def object_plan : CrystalClick::ObjectDocumentPlan
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
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  private def array_bulk_value(row : Int32) : CrystalClick::BinaryValue
    type = array_bulk_type
    entry_type = type.child_at(0)
    variant = entry_type.child_at(0)
    entries = [] of CrystalClick::BinaryValue

    case row
    when 2
      entries << array_entry(entry_type, variant_null(variant), "null-2")
    when 3
      entries << array_entry(entry_type, variant_null(variant), "null-3")
    when 4
      entries << array_entry(entry_type, variant_array(variant, [] of UInt8), "empty-array")
      entries << array_entry(entry_type, variant_string(variant, ""), "empty-string")
      entries << array_entry(entry_type, variant_uint64(variant, 0_u64), "zero-u64")
    when 5
      entries << array_entry(entry_type, variant_null(variant), "null-5")
      entries << array_entry(entry_type, variant_array(variant, [0_u8, 255_u8] of UInt8), "bytes-5")
      entries << array_entry(entry_type, variant_string(variant, "middle\0"), "middle")
    when 6
      entries << array_entry(entry_type, variant_string(variant, invalid_binary_string), "late-binary")
      entries << array_entry(entry_type, variant_uint64(variant, 0x0102_0304_0506_0708_u64), "late-u64")
    when 7
      entries << array_entry(entry_type, variant_array(variant, [255_u8, 0_u8, 127_u8] of UInt8), "tail-bytes")
      entries << array_entry(entry_type, variant_uint64(variant, 0xfedc_ba98_7654_3210_u64), "tail-u64")
      entries << array_entry(entry_type, variant_string(variant, "tail\0"), "tail-string")
    end

    CrystalClick::BinaryValue.array(type, entries)
  end

  private def array_entry(
    type : CrystalClick::BinaryDataType,
    selected : CrystalClick::BinaryValue,
    label : String,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(
      type,
      [selected, low_cardinality_string(type.child_at(1), label)] of CrystalClick::BinaryValue,
    )
  end

  private def tuple_bulk_value(row : Int32) : CrystalClick::BinaryValue
    type = tuple_bulk_type
    variant = type.child_at(1)
    map_type = type.child_at(2)
    nested_type = type.child_at(3)
    map_values = [] of CrystalClick::BinaryValue
    nested_values = [] of CrystalClick::BinaryValue

    case row
    when 2
      append_map_variant(map_values, map_type, "null-2", variant_null(variant))
      nested_values << nested_entry(nested_type, variant_null(variant), "null-2")
    when 3
      append_map_variant(map_values, map_type, "null-3", variant_null(variant))
      nested_values << nested_entry(nested_type, variant_null(variant), "null-3")
    when 4
      append_map_variant(map_values, map_type, "empty", variant_array(variant, [] of UInt8))
      append_map_variant(map_values, map_type, "null", variant_null(variant))
      nested_values << nested_entry(nested_type, variant_array(variant, [] of UInt8), "empty")
      nested_values << nested_entry(nested_type, variant_null(variant), "null")
    when 5
      append_map_variant(map_values, map_type, "middle", variant_string(variant, "map\0"))
      nested_values << nested_entry(nested_type, variant_string(variant, "nested\0"), "middle")
    when 6
      append_map_variant(map_values, map_type, "late-u64", variant_uint64(variant, 0x1122_3344_5566_7788_u64))
      nested_values << nested_entry(nested_type, variant_uint64(variant, 0x8877_6655_4433_2211_u64), "late-u64")
    when 7
      append_map_variant(map_values, map_type, "late-binary", variant_string(variant, invalid_binary_string))
      nested_values << nested_entry(nested_type, variant_string(variant, invalid_binary_string), "late-binary")
    end

    root_variant = case row
                   when 0, 1, 2, 3 then variant_null(variant)
                   when 4          then variant_array(variant, [] of UInt8)
                   when 5          then variant_string(variant, "root\0")
                   when 6          then variant_uint64(variant, 0xdead_beef_cafe_babe_u64)
                   else                 variant_string(variant, invalid_binary_string)
                   end

    CrystalClick::BinaryValue.tuple(
      type,
      [
        low_cardinality_string(type.child_at(0), "root-lc-#{row}"),
        root_variant,
        CrystalClick::BinaryValue.map(map_type, map_values),
        CrystalClick::BinaryValue.nested(nested_type, nested_values),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def append_map_variant(
    values : Array(CrystalClick::BinaryValue),
    type : CrystalClick::BinaryDataType,
    key : String,
    selected : CrystalClick::BinaryValue,
  ) : Nil
    values << CrystalClick::BinaryValue.string(key)
    values << selected
  end

  private def nested_entry(
    type : CrystalClick::BinaryDataType,
    selected : CrystalClick::BinaryValue,
    label : String,
  ) : CrystalClick::BinaryValue
    tuple_type = type.child_at(0)
    CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        selected,
        low_cardinality_string(tuple_type.child_at(1), label),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def variant_null(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.variant_null(type)
  end

  private def variant_array(type : CrystalClick::BinaryDataType, bytes : Array(UInt8)) : CrystalClick::BinaryValue
    array_type = type.child_at(0)
    values = bytes.map do |byte|
      CrystalClick::BinaryValue.fixed(array_type.child_at(0), Bytes[byte])
    end
    CrystalClick::BinaryValue.variant(
      type,
      0,
      CrystalClick::BinaryValue.array(array_type, values),
    )
  end

  private def variant_string(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string(value))
  end

  private def variant_uint64(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.variant(type, 2, CrystalClick::BinaryValue.uint64(value))
  end

  private def low_cardinality_string(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
  end
end

module CompactPartWriterW283LCVariantFixture
  extend self

  JSON_DECLARATION    = "JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)"
  VARIANT_DECLARATION = "Variant(Array(LowCardinality(String)), LowCardinality(String), UInt64)"

  KEY_NAME      = "pk"
  COLUMN_NAME   = "recursive_variant_lc_arm_w283"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    4
  MARK_COUNT    =    2
  FRAME_BYTES   = 4096

  def schema_declaration : String
    "Tuple(#{JSON_DECLARATION}, #{VARIANT_DECLARATION})"
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(schema_declaration)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"id" => CrystalClick::BinaryDataType.primitive("UInt64")} of String => CrystalClick::BinaryDataType,
    )
  end

  def variant_type : CrystalClick::BinaryDataType
    schema.child_at(1).bulk_type
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    Array(CrystalClick::StorageColumnValue).new(ROW_COUNT) do |index|
      id = index.to_u64 + 1_u64
      CrystalClick::StorageColumnValue.tuple(
        [
          object_value(id),
          CrystalClick::StorageColumnValue.bulk(variant_value(index)),
        ] of CrystalClick::StorageColumnValue,
      )
    end
  end

  def column : CrystalClick::CompactPartColumn
    granules = rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    plans = {"root/tuple[0]" => object_plan} of String => CrystalClick::ObjectDocumentPlan
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
  end

  # This arm is deliberately selected with an empty Array. It creates a real
  # selected Variant occurrence while the nested LC element lane has Q=0.
  private def variant_value(row : Int32) : CrystalClick::BinaryValue
    type = variant_type
    case row
    when 0
      arm = type.child_at(0)
      CrystalClick::BinaryValue.variant(
        type,
        0,
        CrystalClick::BinaryValue.array(arm, [] of CrystalClick::BinaryValue),
      )
    when 1
      CrystalClick::BinaryValue.variant(type, 2, CrystalClick::BinaryValue.uint64(0x0102_0304_0506_0708_u64))
    when 2
      low_cardinality = type.child_at(1)
      selected = CrystalClick::BinaryValue.low_cardinality(
        low_cardinality,
        CrystalClick::BinaryValue.string(invalid_binary_string),
      )
      CrystalClick::BinaryValue.variant(type, 1, selected)
    else
      CrystalClick::BinaryValue.variant(type, 2, CrystalClick::BinaryValue.uint64(0xfedc_ba98_7654_3210_u64))
    end
  end

  def invalid_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def object_value(id : UInt64) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {"id" => CrystalClick::BinaryValue.uint64(id)} of String => CrystalClick::BinaryValue,
      ),
    )
  end

  private def object_plan : CrystalClick::ObjectDocumentPlan
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
      json_type.json_type.not_nil!.typed_paths,
    )
  end
end
