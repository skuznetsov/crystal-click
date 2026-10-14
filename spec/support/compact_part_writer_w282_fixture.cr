require "../../src/crystal_click"

module CompactPartWriterW282Fixture
  extend self

  JSON_DECLARATION = "JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)"

  KEY_NAME                = "pk"
  COLUMN_NAME             = "recursive_lc_w282"
  OUTER_ARRAY_COLUMN_NAME = "recursive_lc_outer_array_w282"
  ROWS_PER_MARK           =    2
  ROW_COUNT               =    8
  MARK_COUNT              =    4
  FRAME_BYTES             = 4096

  OUTER_ARRAY_ROWS_PER_MARK = 1
  OUTER_ARRAY_ROW_COUNT     = 4
  OUTER_ARRAY_MARK_COUNT    = 4

  def schema_declaration : String
    "Tuple(#{JSON_DECLARATION}, Array(Tuple(LowCardinality(String), LowCardinality(Nullable(String)))), #{JSON_DECLARATION}, Tuple(Map(String, LowCardinality(UInt16)), Array(LowCardinality(String)), Nested(label LowCardinality(String), code LowCardinality(UInt16))))"
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

  def bulk_a_type : CrystalClick::BinaryDataType
    schema.child_at(1).bulk_type
  end

  def bulk_b_type : CrystalClick::BinaryDataType
    schema.child_at(3).bulk_type
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
          CrystalClick::StorageColumnValue.bulk(bulk_a_value(index)),
          object_value(id + 100_u64),
          CrystalClick::StorageColumnValue.bulk(bulk_b_value(index)),
        ] of CrystalClick::StorageColumnValue,
      )
    end
  end

  def expected_signatures : Array(String)
    [
      "1|A[]|101|M[]|E[]|N[]",
      "2|A[]|102|M[]|E[]|N[]",
      "3|A[6100,V6e00;00ff8041,N]|103|M[6d00=0a00;00ff8041=0b00]|E[]|N[6e00=ffff]",
      "4|A[78,V]|104|M[6b=0c00]|E[]|N[626164=0000;7461696c=2a00]",
      "5|A[]|105|M[]|E[]|N[]",
      "6|A[]|106|M[]|E[]|N[]",
      "7|A[656e64,V6c617374]|107|M[61=0400]|E[]|N[=0700]",
      "8|A[,N;00ff8041,V7a00]|108|M[62=0500;63=0600]|E[]|N[66696e616c00=0800]",
    ] of String
  end

  def signatures_from(marks : Array(Array(CrystalClick::StorageColumnValue))) : Array(String)
    marks.flatten.map { |row| signature(row) }
  end

  def signature(row : CrystalClick::StorageColumnValue) : String
    left_id = row.child_at(0).object_document.value_for("id").as_uint64
    right_id = row.child_at(2).object_document.value_for("id").as_uint64
    bulk_a = row.child_at(1).bulk_value
    bulk_b = row.child_at(3).bulk_value
    map = bulk_b.child_at(0)
    empty_strings = bulk_b.child_at(1)
    nested = bulk_b.child_at(2)

    map_values = map.elements
    map_entries = Array(String).new(map_values.size // 2)
    (map_values.size // 2).times do |index|
      key = map_values[index * 2]
      value = map_values[index * 2 + 1]
      map_entries << "#{key.bytes.hexstring}=#{low_cardinality_hex(value)}"
    end

    nested_entries = nested.elements.map do |record|
      "#{low_cardinality_hex(record.child_at(0))}=#{low_cardinality_hex(record.child_at(1))}"
    end

    empty_entries = empty_strings.elements.map { |value| low_cardinality_hex(value) }
    "#{left_id}|#{bulk_a_signature(bulk_a)}|#{right_id}|M[#{map_entries.join(";")}]|E[#{empty_entries.join(";")}]|N[#{nested_entries.join(";")}]"
  end

  def column : CrystalClick::CompactPartColumn
    values = rows
    granules = values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
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

  def outer_array_schema_declaration : String
    "Array(Tuple(Tuple(LowCardinality(String), Array(LowCardinality(UInt16))), #{JSON_DECLARATION}))"
  end

  def outer_array_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(outer_array_schema_declaration)
  end

  def outer_array_keys : Slice(UInt64)
    Slice(UInt64).new(OUTER_ARRAY_ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def outer_array_rows : Array(CrystalClick::StorageColumnValue)
    Array(CrystalClick::StorageColumnValue).new(OUTER_ARRAY_ROW_COUNT) do |index|
      entries = [] of CrystalClick::StorageColumnValue
      case index
      when 1
        entries << outer_array_entry("one\0", [7_u16] of UInt16, 102_u64)
      when 3
        entries << outer_array_entry(invalid_binary_string, [8_u16, 9_u16] of UInt16, 104_u64)
        entries << outer_array_entry("last", [] of UInt16, 105_u64)
      end
      CrystalClick::StorageColumnValue.array(entries)
    end
  end

  def expected_outer_array_signatures : Array(String)
    [
      "[]",
      "[6f6e6500/[0700]@102]",
      "[]",
      "[00ff8041/[0800;0900]@104;6c617374/[]@105]",
    ] of String
  end

  def outer_array_signatures_from(marks : Array(Array(CrystalClick::StorageColumnValue))) : Array(String)
    marks.flatten.map do |row|
      entries = row.array_values.map do |entry|
        bulk = entry.child_at(0).bulk_value
        text = low_cardinality_hex(bulk.child_at(0))
        codes = bulk.child_at(1).elements.map { |value| low_cardinality_hex(value) }
        id = entry.child_at(1).object_document.value_for("id").as_uint64
        "#{text}/[#{codes.join(";")}]@#{id}"
      end
      "[#{entries.join(";")}]"
    end
  end

  def outer_array_column : CrystalClick::CompactPartColumn
    granules = outer_array_rows.each_slice(OUTER_ARRAY_ROWS_PER_MARK).map(&.to_a).to_a
    plans = {
      "root/array[0]/tuple[1]" => object_plan,
    } of String => CrystalClick::ObjectDocumentPlan
    CrystalClick::CompactPartColumn.json(
      OUTER_ARRAY_COLUMN_NAME,
      outer_array_schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
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

  private def bulk_a_value(row : Int32) : CrystalClick::BinaryValue
    type = bulk_a_type
    tuple_type = type.child_at(0)
    entries = [] of CrystalClick::BinaryValue
    case row
    when 2
      entries << bulk_a_entry(tuple_type, "a\0", "n\0")
      entries << bulk_a_entry(tuple_type, invalid_binary_string, nil)
    when 3
      entries << bulk_a_entry(tuple_type, "x", "")
    when 6
      entries << bulk_a_entry(tuple_type, "end", "last")
    when 7
      entries << bulk_a_entry(tuple_type, "", nil)
      entries << bulk_a_entry(tuple_type, invalid_binary_string, "z\0")
    end
    CrystalClick::BinaryValue.array(type, entries)
  end

  private def bulk_a_entry(type : CrystalClick::BinaryDataType, text : String, nullable_text : String?) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(
      type,
      [
        low_cardinality_string(type.child_at(0), text),
        low_cardinality_nullable_string(type.child_at(1), nullable_text),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def bulk_b_value(row : Int32) : CrystalClick::BinaryValue
    type = bulk_b_type
    map_type = type.child_at(0)
    empty_array_type = type.child_at(1)
    nested_type = type.child_at(2)
    map_values = [] of CrystalClick::BinaryValue
    nested_values = [] of CrystalClick::BinaryValue

    case row
    when 2
      append_map_entry(map_values, map_type, "m\0", 10_u16)
      append_map_entry(map_values, map_type, invalid_binary_string, 11_u16)
      nested_values << nested_entry(nested_type, "n\0", 65_535_u16)
    when 3
      append_map_entry(map_values, map_type, "k", 12_u16)
      nested_values << nested_entry(nested_type, "bad", 0_u16)
      nested_values << nested_entry(nested_type, "tail", 42_u16)
    when 6
      append_map_entry(map_values, map_type, "a", 4_u16)
      nested_values << nested_entry(nested_type, "", 7_u16)
    when 7
      append_map_entry(map_values, map_type, "b", 5_u16)
      append_map_entry(map_values, map_type, "c", 6_u16)
      nested_values << nested_entry(nested_type, "final\0", 8_u16)
    end

    CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.map(map_type, map_values),
        CrystalClick::BinaryValue.array(empty_array_type, [] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.nested(nested_type, nested_values),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def append_map_entry(
    values : Array(CrystalClick::BinaryValue),
    map_type : CrystalClick::BinaryDataType,
    key : String,
    value : UInt16,
  ) : Nil
    values << CrystalClick::BinaryValue.string(key)
    values << low_cardinality_uint16(map_type.child_at(1), value)
  end

  private def nested_entry(type : CrystalClick::BinaryDataType, label : String, code : UInt16) : CrystalClick::BinaryValue
    tuple_type = type.child_at(0)
    CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        low_cardinality_string(tuple_type.child_at(0), label),
        low_cardinality_uint16(tuple_type.child_at(1), code),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def outer_array_entry(text : String, codes : Array(UInt16), id : UInt64) : CrystalClick::StorageColumnValue
    bulk_type = outer_array_schema.child_at(0).child_at(0).bulk_type
    string_type = bulk_type.child_at(0)
    codes_type = bulk_type.child_at(1)
    code_values = codes.map { |code| low_cardinality_uint16(codes_type.child_at(0), code) }
    bulk = CrystalClick::BinaryValue.tuple(
      bulk_type,
      [
        low_cardinality_string(string_type, text),
        CrystalClick::BinaryValue.array(codes_type, code_values),
      ] of CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.tuple(
      [
        CrystalClick::StorageColumnValue.bulk(bulk),
        object_value(id),
      ] of CrystalClick::StorageColumnValue,
    )
  end

  private def low_cardinality_string(type : CrystalClick::BinaryDataType, text : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(text))
  end

  private def low_cardinality_nullable_string(type : CrystalClick::BinaryDataType, text : String?) : CrystalClick::BinaryValue
    nullable_type = type.child_at(0)
    nullable_value = if text
                       CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(text))
                     else
                       CrystalClick::BinaryValue.nullable(nullable_type)
                     end
    CrystalClick::BinaryValue.low_cardinality(type, nullable_value)
  end

  private def low_cardinality_uint16(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    uint16 = type.child_at(0)
    CrystalClick::BinaryValue.low_cardinality(
      type,
      CrystalClick::BinaryValue.fixed(uint16, Bytes[(value & 0xff_u16).to_u8, (value >> 8).to_u8]),
    )
  end

  private def low_cardinality_hex(value : CrystalClick::BinaryValue) : String
    value.child_at(0).bytes.hexstring
  end

  private def bulk_a_signature(value : CrystalClick::BinaryValue) : String
    entries = value.elements.map do |entry|
      "#{low_cardinality_hex(entry.child_at(0))},#{low_cardinality_nullable_signature(entry.child_at(1))}"
    end
    "A[#{entries.join(";")}]"
  end

  private def low_cardinality_nullable_signature(value : CrystalClick::BinaryValue) : String
    nullable = value.child_at(0)
    if nullable.is_null?
      "N"
    else
      "V#{nullable.child_at(0).bytes.hexstring}"
    end
  end
end
