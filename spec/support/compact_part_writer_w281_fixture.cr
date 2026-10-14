require "../../src/crystal_click"

module CompactPartWriterW281Fixture
  extend self

  FORMAT            = "compact_part_writer_w281_fixture_v1"
  KEY_NAME          = "pk"
  COLUMN_NAME       = "static_bulk_w281"
  STOCK_COLUMN_NAME = "stock_bulk_w281"
  ROWS_PER_MARK     =    2
  ROW_COUNT         =    8
  MARK_COUNT        =    4
  FRAME_BYTES       = 4096

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"id" => uint64_type} of String => CrystalClick::BinaryDataType,
    )
  end

  # Each entry is a distinct fixed-width descriptor family. Bool is included
  # in the width roster but is materialized through BinaryValue.bool rather
  # than the raw-payload constructor. Zoned and unzoned temporals both appear.
  def fixed_leaf_types : Array(Tuple(String, CrystalClick::BinaryDataType))
    enum_entries = [] of CrystalClick::BinaryEnumDefinition::Entry
    71.times { |value| enum_entries << {"v#{value}", value.to_i16} }

    [
      {"u8", CrystalClick::BinaryDataType.primitive("UInt8")},
      {"u16", CrystalClick::BinaryDataType.primitive("UInt16")},
      {"u32", CrystalClick::BinaryDataType.primitive("UInt32")},
      {"u64", CrystalClick::BinaryDataType.primitive("UInt64")},
      {"u128", CrystalClick::BinaryDataType.primitive("UInt128")},
      {"u256", CrystalClick::BinaryDataType.primitive("UInt256")},
      {"i8", CrystalClick::BinaryDataType.primitive("Int8")},
      {"i16", CrystalClick::BinaryDataType.primitive("Int16")},
      {"i32", CrystalClick::BinaryDataType.primitive("Int32")},
      {"i64", CrystalClick::BinaryDataType.primitive("Int64")},
      {"i128", CrystalClick::BinaryDataType.primitive("Int128")},
      {"i256", CrystalClick::BinaryDataType.primitive("Int256")},
      {"f32", CrystalClick::BinaryDataType.primitive("Float32")},
      {"f64", CrystalClick::BinaryDataType.primitive("Float64")},
      {"bf16", CrystalClick::BinaryDataType.primitive("BFloat16")},
      {"date", CrystalClick::BinaryDataType.primitive("Date")},
      {"date32", CrystalClick::BinaryDataType.primitive("Date32")},
      {"datetime", CrystalClick::BinaryDataType.datetime},
      {"datetime_utc", CrystalClick::BinaryDataType.datetime("UTC")},
      {"datetime64", CrystalClick::BinaryDataType.datetime64(3)},
      {"datetime64_utc", CrystalClick::BinaryDataType.datetime64(6, "UTC")},
      {"time", CrystalClick::BinaryDataType.primitive("Time")},
      {"time64", CrystalClick::BinaryDataType.time64(3)},
      {"truth", CrystalClick::BinaryDataType.primitive("Bool")},
      {"enum8", CrystalClick::BinaryDataType.enum8(enum_entries)},
      {"enum16", CrystalClick::BinaryDataType.enum16(enum_entries)},
      {"decimal32", CrystalClick::BinaryDataType.decimal(32, 9, 2)},
      {"decimal64", CrystalClick::BinaryDataType.decimal(64, 18, 2)},
      {"decimal128", CrystalClick::BinaryDataType.decimal(128, 38, 2)},
      {"decimal256", CrystalClick::BinaryDataType.decimal(256, 76, 2)},
      {"uuid", CrystalClick::BinaryDataType.primitive("UUID")},
      {"ipv4", CrystalClick::BinaryDataType.primitive("IPv4")},
      {"ipv6", CrystalClick::BinaryDataType.primitive("IPv6")},
      {"interval_day", CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Day)},
      {"fixed4", CrystalClick::BinaryDataType.fixed_string(4)},
    ] of Tuple(String, CrystalClick::BinaryDataType)
  end

  def fixed_leaf_names : Array(String)
    fixed_leaf_types.map { |entry| entry[0] }
  end

  def bulk_fields : Array(Tuple(String, CrystalClick::BinaryDataType))
    fields = fixed_leaf_types
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    uint32 = CrystalClick::BinaryDataType.primitive("UInt32")
    uint64 = uint64_type
    string = string_type
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    nullable_u8 = CrystalClick::BinaryDataType.nullable(uint8)
    nullable_u16 = CrystalClick::BinaryDataType.nullable(uint16)
    pair = CrystalClick::BinaryDataType.tuple(
      [uint16, nullable_string] of CrystalClick::BinaryDataType,
    )
    nested = CrystalClick::BinaryDataType.nested(
      [string, nullable_u8] of CrystalClick::BinaryDataType,
      ["label", "maybe_code"] of String,
    )
    point = CrystalClick::BinaryDataType.custom("Point")
    multipoint = CrystalClick::BinaryDataType.custom("MultiPoint")
    sum_state = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      uint64,
    )

    fields.concat([
      {"nothing", CrystalClick::BinaryDataType.primitive("Nothing")},
      {"empty_tuple", CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType)},
      {"text", string},
      {"text_runs", CrystalClick::BinaryDataType.array(string)},
      {"empty_texts", CrystalClick::BinaryDataType.array(string)},
      {"maybe_text", nullable_string},
      {"maybe_u16", nullable_u16},
      {"array_pairs", CrystalClick::BinaryDataType.array(pair)},
      {"lookup", CrystalClick::BinaryDataType.map(string, nullable_string)},
      {"nested_labels", nested},
      {"plain_tuple", CrystalClick::BinaryDataType.tuple([uint32, string] of CrystalClick::BinaryDataType)},
      {"point", point},
      {"multipoint", multipoint},
      {"maybe_point", CrystalClick::BinaryDataType.nullable(point)},
      {"sum_state", sum_state},
    ] of Tuple(String, CrystalClick::BinaryDataType))
    fields
  end

  def bulk_type : CrystalClick::BinaryDataType
    type_for_fields(bulk_fields)
  end

  # The stock-candidate tree mirrors the broad local static tree except for
  # bare Nothing, reserved for a separate native schema guard. The local
  # Compact test still exercises Nothing in `bulk_type`.
  def stock_bulk_fields : Array(Tuple(String, CrystalClick::BinaryDataType))
    bulk_fields.reject { |entry| entry[0] == "nothing" }
  end

  def stock_bulk_type : CrystalClick::BinaryDataType
    type_for_fields(stock_bulk_fields)
  end

  private def type_for_fields(fields : Array(Tuple(String, CrystalClick::BinaryDataType))) : CrystalClick::BinaryDataType
    children = [] of CrystalClick::BinaryDataType
    names = [] of String
    fields.each do |name, type|
      names << name
      children << type
    end
    CrystalClick::BinaryDataType.tuple(children, names)
  end

  def schema : CrystalClick::StorageColumnSchema
    schema_for(bulk_type)
  end

  def stock_schema : CrystalClick::StorageColumnSchema
    schema_for(stock_bulk_type)
  end

  private def schema_for(type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnSchema
    declaration = "Tuple(#{json_type.name}, #{type.name})"
    CrystalClick::StorageColumnSchema.parse(declaration)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    rows_for { |bulk| bulk }
  end

  def stock_rows : Array(CrystalClick::StorageColumnValue)
    rows_for { |bulk| stock_bulk_value(bulk) }
  end

  private def rows_for(&block : CrystalClick::BinaryValue -> CrystalClick::BinaryValue) : Array(CrystalClick::StorageColumnValue)
    Array(CrystalClick::StorageColumnValue).new(ROW_COUNT) do |index|
      id = index.to_u64 + 1_u64
      CrystalClick::StorageColumnValue.tuple(
        [
          object_value(id),
          CrystalClick::StorageColumnValue.bulk(yield(bulk_value(index))),
        ] of CrystalClick::StorageColumnValue,
      )
    end
  end

  def expected_signatures : Array(String)
    rows.map { |row| signature(row) }
  end

  def expected_stock_signatures : Array(String)
    stock_rows.map { |row| signature(row) }
  end

  def signatures_from(marks : Array(Array(CrystalClick::StorageColumnValue))) : Array(String)
    marks.flatten.map { |row| signature(row) }
  end

  def signature(value : CrystalClick::StorageColumnValue) : String
    case value.kind
    when CrystalClick::StorageColumnValue::OBJECT
      "J#{value.object_document.value_for("id").as_uint64}"
    when CrystalClick::StorageColumnValue::BULK
      binary_signature(value.bulk_value)
    when CrystalClick::StorageColumnValue::TUPLE
      "T(#{value.tuple_values.map { |child| signature(child) }.join(",")})"
    when CrystalClick::StorageColumnValue::ARRAY
      "A[#{value.array_values.map { |child| signature(child) }.join(",")}]"
    else
      raise ArgumentError.new("W281 signature observed an unknown storage value node")
    end
  end

  def column : CrystalClick::CompactPartColumn
    column_for(COLUMN_NAME, schema, rows)
  end

  def stock_column : CrystalClick::CompactPartColumn
    column_for(STOCK_COLUMN_NAME, stock_schema, stock_rows)
  end

  private def column_for(
    name : String,
    storage_schema : CrystalClick::StorageColumnSchema,
    values : Array(CrystalClick::StorageColumnValue),
  ) : CrystalClick::CompactPartColumn
    site = "root/tuple[0]"
    plans = {site => object_plan} of String => CrystalClick::ObjectDocumentPlan
    granules = values.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.json(
      name,
      storage_schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
  end

  # Builds a shallow JSON root plus one parser-classified opaque JSON-free
  # subtree. The values are deliberately packaged with StorageColumnValue.bulk.
  def bulk_carrier(row : CrystalClick::StorageColumnValue) : CrystalClick::BinaryValue
    row.child_at(1).bulk_value
  end

  private def field_type(name : String) : CrystalClick::BinaryDataType
    index = bulk_fields.index { |field| field[0] == name } ||
            raise ArgumentError.new("unknown W281 Bulk field: #{name}")
    bulk_type.child_at(index)
  end

  private def bulk_value(row : Int32) : CrystalClick::BinaryValue
    type = bulk_type
    values = [] of CrystalClick::BinaryValue
    fixed_leaf_types.each_with_index do |entry, index|
      leaf_type = type.child_at(index)
      values << if leaf_type.tag == CrystalClick::BinaryDataType::TAG_BOOL
        CrystalClick::BinaryValue.bool(row.even?)
      else
        CrystalClick::BinaryValue.fixed(leaf_type, fixed_payload(leaf_type, row, index))
      end
    end

    nothing = field_type("nothing")
    empty_tuple = field_type("empty_tuple")
    text = field_type("text")
    text_runs = field_type("text_runs")
    empty_texts = field_type("empty_texts")
    maybe_text = field_type("maybe_text")
    maybe_u16 = field_type("maybe_u16")
    array_pairs = field_type("array_pairs")
    lookup = field_type("lookup")
    nested = field_type("nested_labels")
    plain_tuple = field_type("plain_tuple")
    point = field_type("point")
    multipoint = field_type("multipoint")
    maybe_point = field_type("maybe_point")
    sum_state = field_type("sum_state")

    values << CrystalClick::BinaryValue.null(nothing)
    values << CrystalClick::BinaryValue.tuple(empty_tuple, [] of CrystalClick::BinaryValue)
    values << CrystalClick::BinaryValue.string(text_for_row(row))
    values << text_runs_value(text_runs, row)
    values << CrystalClick::BinaryValue.array(empty_texts, [] of CrystalClick::BinaryValue)
    values << nullable_string(maybe_text, nullable_text_for_row(row))
    values << nullable_fixed(maybe_u16, row)
    values << array_pairs_value(array_pairs, row)
    values << map_value(lookup, row)
    values << nested_value(nested, row)
    values << plain_tuple_value(plain_tuple, row)
    values << point_value(point, row)
    values << multipoint_value(multipoint, row)
    values << nullable_point_value(maybe_point, row)
    values << CrystalClick::BinaryValue.simple_aggregate(
      sum_state,
      CrystalClick::BinaryValue.uint64((row.to_u64 + 501_u64)),
    )
    CrystalClick::BinaryValue.tuple(type, values)
  end

  private def text_runs_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    values = [] of CrystalClick::BinaryValue
    case row
    when 2
      values << CrystalClick::BinaryValue.string("")
      values << CrystalClick::BinaryValue.string("inside\0tail")
    when 3
      values << CrystalClick::BinaryValue.string(invalid_string)
    when 5
      values << CrystalClick::BinaryValue.string(long_string)
    when 6
      values << CrystalClick::BinaryValue.string("tail")
    end
    CrystalClick::BinaryValue.array(type, values)
  end

  private def stock_bulk_value(value : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    source_fields = bulk_fields
    source_children = value.elements
    children = [] of CrystalClick::BinaryValue
    stock_bulk_fields.each do |name, _type|
      index = source_fields.index { |field| field[0] == name } ||
              raise ArgumentError.new("unknown W281 stock Bulk field: #{name}")
      children << source_children[index]
    end
    CrystalClick::BinaryValue.tuple(stock_bulk_type, children)
  end

  private def array_pairs_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    pair_type = type.child_at(0)
    uint16 = pair_type.child_at(0)
    nullable = pair_type.child_at(1)
    entries = [] of CrystalClick::BinaryValue
    # The first mark (rows 0-1) is wholly empty for this entire nested lane.
    # Later marks alternate populated and empty occurrences so the fixture
    # covers both retained empty callbacks and ordinary row ownership.
    case row
    when 2
      entries << pair_value(pair_type, uint16, nullable, 11_u16, "")
      entries << pair_value(pair_type, uint16, nullable, 12_u16, nil)
    when 3
      entries << pair_value(pair_type, uint16, nullable, 21_u16, "inside\0tail")
      entries << pair_value(pair_type, uint16, nullable, 22_u16, invalid_string)
    when 6
      entries << pair_value(pair_type, uint16, nullable, 61_u16, long_string)
    when 7
      entries << pair_value(pair_type, uint16, nullable, 71_u16, nil)
    end
    CrystalClick::BinaryValue.array(type, entries)
  end

  private def pair_value(
    type : CrystalClick::BinaryDataType,
    uint16 : CrystalClick::BinaryDataType,
    nullable : CrystalClick::BinaryDataType,
    key : UInt16,
    text : String?,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.fixed(uint16, Bytes[key.to_u8, (key >> 8).to_u8]),
        nullable_string(nullable, text),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def map_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    nullable = type.child_at(1)
    entries = [] of CrystalClick::BinaryValue
    # Keep the complete first mark empty for this branch. This is especially
    # useful for String1's zero-item child lanes, whose callbacks still exist.
    case row
    when 2
      entries << CrystalClick::BinaryValue.string("")
      entries << nullable_string(nullable, "")
      entries << CrystalClick::BinaryValue.string("n\0key")
      entries << nullable_string(nullable, nil)
    when 3
      entries << CrystalClick::BinaryValue.string("raw")
      entries << nullable_string(nullable, invalid_string)
    when 6
      entries << CrystalClick::BinaryValue.string("long")
      entries << nullable_string(nullable, long_string)
    end
    CrystalClick::BinaryValue.map(type, entries)
  end

  private def nested_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    record_type = type.child_at(0)
    records = [] of CrystalClick::BinaryValue
    # Like the sibling Array and Map lanes, Nested has no child records in the
    # first mark, then becomes populated in a later mark.
    case row
    when 2
      records << nested_record(record_type, "nested", nil)
    when 3
      records << nested_record(record_type, "", 2_u8)
    when 6
      records << nested_record(record_type, long_string, 6_u8)
      records << nested_record(record_type, "tail\0label", nil)
    when 7
      records << nested_record(record_type, invalid_string, 7_u8)
    end
    CrystalClick::BinaryValue.nested(type, records)
  end

  private def nested_record(
    type : CrystalClick::BinaryDataType,
    label : String,
    code : UInt8?,
  ) : CrystalClick::BinaryValue
    nullable = type.child_at(1)
    code_value = if value = code
                   CrystalClick::BinaryValue.nullable(
                     nullable,
                     CrystalClick::BinaryValue.fixed(nullable.child_at(0), Bytes[value]),
                   )
                 else
                   CrystalClick::BinaryValue.nullable(nullable)
                 end
    CrystalClick::BinaryValue.tuple(
      type,
      [CrystalClick::BinaryValue.string(label), code_value] of CrystalClick::BinaryValue,
    )
  end

  private def plain_tuple_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    uint32 = type.child_at(0)
    CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.fixed(uint32, fixed_payload(uint32, row, 41)),
        CrystalClick::BinaryValue.string(text_for_row(row)),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def point_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    tuple_type = type.child_at(0)
    x_type = tuple_type.child_at(0)
    y_type = tuple_type.child_at(1)
    CrystalClick::BinaryValue.custom(
      type,
      CrystalClick::BinaryValue.tuple(
        tuple_type,
        [
          CrystalClick::BinaryValue.fixed(x_type, fixed_payload(x_type, row, 42)),
          CrystalClick::BinaryValue.fixed(y_type, fixed_payload(y_type, row, 43)),
        ] of CrystalClick::BinaryValue,
      ),
    )
  end

  private def multipoint_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    array_type = type.child_at(0)
    point_type = array_type.child_at(0)
    points = [] of CrystalClick::BinaryValue
    if row == 2 || row == 6
      points << point_value(point_type, row)
      points << point_value(point_type, row + 1)
    elsif row == 7
      points << point_value(point_type, row)
    end
    CrystalClick::BinaryValue.custom(type, CrystalClick::BinaryValue.array(array_type, points))
  end

  private def nullable_point_value(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    if row.even?
      CrystalClick::BinaryValue.nullable(type, point_value(type.child_at(0), row))
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  end

  private def nullable_fixed(type : CrystalClick::BinaryDataType, row : Int32) : CrystalClick::BinaryValue
    if row.even?
      CrystalClick::BinaryValue.nullable(
        type,
        CrystalClick::BinaryValue.fixed(type.child_at(0), fixed_payload(type.child_at(0), row, 44)),
      )
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  end

  private def nullable_string(type : CrystalClick::BinaryDataType, value : String?) : CrystalClick::BinaryValue
    if scalar = value
      CrystalClick::BinaryValue.nullable(type, CrystalClick::BinaryValue.string(scalar))
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  end

  private def nullable_text_for_row(row : Int32) : String?
    case row
    when 0, 3, 6
      nil
    when 1, 4
      ""
    when 2
      "nullable\0tail"
    when 5
      invalid_string
    else
      long_string
    end
  end

  private def text_for_row(row : Int32) : String
    case row
    when 0, 4, 5
      ""
    when 1
      "nul\0tail"
    when 2, 7
      invalid_string
    when 3, 6
      long_string
    else
      raise ArgumentError.new("unknown W281 row")
    end
  end

  private def fixed_payload(type : CrystalClick::BinaryDataType, row : Int32, leaf : Int) : Bytes
    width = type.fixed_width || raise ArgumentError.new("W281 fixed leaf has no fixed width")
    seed = (row * 5 + leaf + 1).to_u8
    bytes = Bytes.new(width, 0_u8)
    case type.tag
    when CrystalClick::BinaryDataType::TAG_FLOAT32
      bits = 0x3f80_0000_u32 + seed.to_u32
      4.times { |index| bytes[index] = ((bits >> (index * 8)) & 0xff_u32).to_u8 }
    when CrystalClick::BinaryDataType::TAG_FLOAT64
      bits = 0x3ff0_0000_0000_0000_u64 + seed.to_u64
      8.times { |index| bytes[index] = ((bits >> (index * 8)) & 0xff_u64).to_u8 }
    when CrystalClick::BinaryDataType::TAG_BFLOAT16
      bits = 0x3f80_u16 + seed.to_u16
      bytes[0] = (bits & 0xff_u16).to_u8
      bytes[1] = ((bits >> 8) & 0xff_u16).to_u8
    when CrystalClick::BinaryDataType::TAG_FIXED_STRING
      bytes[0] = 0x41_u8
      bytes[1] = seed
      bytes[2] = 0x00_u8
      bytes[3] = 0xff_u8
    when CrystalClick::BinaryDataType::TAG_IPV4
      bytes[0] = 127_u8
      bytes[1] = 0_u8
      bytes[2] = 0_u8
      bytes[3] = seed
    when CrystalClick::BinaryDataType::TAG_IPV6
      bytes[0] = 0x20_u8
      bytes[1] = 0x01_u8
      bytes[2] = 0x0d_u8
      bytes[3] = 0xb8_u8
      bytes[15] = seed
    when CrystalClick::BinaryDataType::TAG_UUID
      bytes[0] = 0x12_u8
      bytes[1] = 0x34_u8
      bytes[2] = 0x56_u8
      bytes[3] = 0x78_u8
      bytes[15] = seed
    else
      bytes[0] = seed
    end
    bytes
  end

  private def binary_signature(value : CrystalClick::BinaryValue) : String
    type = value.type.name
    bytes = if value.is_null? || value.child_count > 0 || value.byte_size == 0
              ""
            else
              value.bytes.hexstring
            end
    children = value.elements.map { |child| binary_signature(child) }
    String.build do |io|
      io << type.bytesize << ':' << type << ':'
      io << (value.is_null? ? 'N' : 'V') << ':'
      io << bytes.bytesize << ':' << bytes << ':'
      io << children.size << '['
      children.each do |child|
        io << child.bytesize << ':' << child << ';'
      end
      io << ']'
    end
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

  private def object_value(id : UInt64) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {"id" => CrystalClick::BinaryValue.uint64(id)} of String => CrystalClick::BinaryValue,
      ),
    )
  end

  private def invalid_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def long_string : String
    "long:" + ("x" * 256)
  end
end
