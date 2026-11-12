require "../../src/crystal_click"

module CompactPartWriterW278Fixture
  extend self

  KEY_NAME      = "pk"
  ROOT_COLUMN   = "root_json"
  ARRAY_COLUMN  = "array_json"
  TAGGED_COLUMN = "tagged_json"
  PAIR_COLUMN   = "pair_json"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096
  ROOT_SITE     = "root"
  ARRAY_SITE    = "root/array[0]"
  TAGGED_SITE   = "root/array[0]/tuple[0]"
  LEFT_SITE     = "root/tuple[0]"
  RIGHT_SITE    = "root/tuple[1]"
  PAYLOAD_PATH  = "payload"

  COLUMN_NAMES = [ROOT_COLUMN, ARRAY_COLUMN, TAGGED_COLUMN, PAIR_COLUMN] of String
  # These pinned shared keys span both Object V3 hash buckets.
  SHARED_PATHS = ["alpha", "aa", "beta"] of String
  LONG_STRING  = "long:" + ("x" * 256)

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => uint64_type,
        "label" => string_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def json_schema : CrystalClick::StorageColumnSchema
    schema_for_declaration(json_type.name)
  end

  def schemas : Hash(String, CrystalClick::StorageColumnSchema)
    {
      ROOT_COLUMN   => json_schema,
      ARRAY_COLUMN  => schema_for_declaration("Array(#{json_type.name})"),
      TAGGED_COLUMN => schema_for_declaration("Array(Tuple(#{json_type.name}, UInt8))"),
      PAIR_COLUMN   => schema_for_declaration("Tuple(#{json_type.name}, #{json_type.name})"),
    } of String => CrystalClick::StorageColumnSchema
  end

  def columns(shared_data_version : UInt64 = 0_u64) : Array(CrystalClick::CompactPartColumn)
    COLUMN_NAMES.map { |name| column(name, shared_data_version) }
  end

  def column(name : String, shared_data_version : UInt64 = 0_u64) : CrystalClick::CompactPartColumn
    case name
    when ROOT_COLUMN
      json_column(name, root_rows, ROOT_SITE, shared_data_version, 2_u64, 1_u64)
    when ARRAY_COLUMN
      json_column(name, array_rows, ARRAY_SITE, shared_data_version, 2_u64, 2_u64)
    when TAGGED_COLUMN
      json_column(name, tagged_rows, TAGGED_SITE, shared_data_version, 2_u64, 2_u64)
    when PAIR_COLUMN
      left = object_plan(shared_data_version, 2_u64, 1_u64)
      right = object_plan(shared_data_version, 2_u64, 0_u64)
      CrystalClick::CompactPartColumn.json(
        name,
        schemas[name],
        storage_granules(pair_rows),
        CrystalClick::CompactJsonWriteContext.new(
          {
            LEFT_SITE  => left,
            RIGHT_SITE => right,
          } of String => CrystalClick::ObjectDocumentPlan,
        ),
      )
    else
      raise ArgumentError.new("unknown W278 column: #{name}")
    end
  end

  def rows_for(name : String) : Array(CrystalClick::StorageColumnValue)
    case name
    when ROOT_COLUMN
      root_rows
    when ARRAY_COLUMN
      array_rows
    when TAGGED_COLUMN
      tagged_rows
    when PAIR_COLUMN
      pair_rows
    else
      raise ArgumentError.new("unknown W278 column: #{name}")
    end
  end

  def root_rows : Array(CrystalClick::StorageColumnValue)
    payloads = [
      string_value(""),
      nil,
      string_value("root-2"),
      string_value(LONG_STRING),
      string_value(raw_binary_string),
      string_value("nul\0tail"),
      string_value("root-6"),
      string_value("root-7"),
    ] of CrystalClick::BinaryValue?

    payloads.each_with_index.map do |payload, index|
      object_value(document(index.to_u64 + 1_u64, "root-#{index}", payload, index))
    end.to_a
  end

  def array_rows : Array(CrystalClick::StorageColumnValue)
    [
      array_value([
        object_value(document(101_u64, "array-0a", string_value("array-first"), 0)),
        object_value(document(102_u64, "array-0b", string_value(""), 1)),
      ] of CrystalClick::StorageColumnValue),
      array_value([] of CrystalClick::StorageColumnValue),
      array_value([] of CrystalClick::StorageColumnValue),
      array_value([] of CrystalClick::StorageColumnValue),
      array_value([
        object_value(document(105_u64, "array-4", string_value(raw_binary_string), 4)),
      ] of CrystalClick::StorageColumnValue),
      array_value([
        object_value(document(106_u64, "array-5a", string_value(LONG_STRING), 5)),
        object_value(document(107_u64, "array-5b", string_value("array\0tail"), 6)),
      ] of CrystalClick::StorageColumnValue),
      array_value([] of CrystalClick::StorageColumnValue),
      array_value([
        object_value(document(108_u64, "array-7a", string_value("last-a"), 7)),
        object_value(document(109_u64, "array-7b", string_value("last-b"), 0)),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def tagged_rows : Array(CrystalClick::StorageColumnValue)
    [
      tagged_array([
        tagged_document(201_u64, "tag-0a", "tag-first", 1_u8, 0),
        tagged_document(202_u64, "tag-0b", "", 2_u8, 1),
      ] of CrystalClick::StorageColumnValue),
      tagged_array([] of CrystalClick::StorageColumnValue),
      tagged_array([] of CrystalClick::StorageColumnValue),
      tagged_array([] of CrystalClick::StorageColumnValue),
      tagged_array([
        tagged_document(205_u64, "tag-4", raw_binary_string, 5_u8, 4),
      ] of CrystalClick::StorageColumnValue),
      tagged_array([
        tagged_document(206_u64, "tag-5a", LONG_STRING, 6_u8, 5),
        tagged_document(207_u64, "tag-5b", "tag\0tail", 7_u8, 6),
      ] of CrystalClick::StorageColumnValue),
      tagged_array([] of CrystalClick::StorageColumnValue),
      tagged_array([
        tagged_document(208_u64, "tag-7a", "last-a", 8_u8, 7),
        tagged_document(209_u64, "tag-7b", "last-b", 9_u8, 0),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def pair_rows : Array(CrystalClick::StorageColumnValue)
    [
      pair_value(
        document(301_u64, "left-0", string_value("left-first"), 0),
        document(401_u64, "right-0", nil, 1),
      ),
      pair_value(
        document(302_u64, "left-1", nil, 2),
        document(402_u64, "right-1", nil, 3),
      ),
      pair_value(
        document(303_u64, "left-2", string_value("left-middle"), 4),
        document(403_u64, "right-2", string_value("right-middle"), 5),
      ),
      pair_value(
        document(304_u64, "left-3", nil, 6),
        document(404_u64, "right-3", nil, 7),
      ),
      pair_value(
        document(305_u64, "left-4", string_value(LONG_STRING), 0),
        document(405_u64, "right-4", nil, 1),
      ),
      pair_value(
        document(306_u64, "left-5", nil, 2),
        document(406_u64, "right-5", string_value(raw_binary_string), 3),
      ),
      pair_value(
        document(307_u64, "left-6", string_value("left\0tail"), 4),
        document(407_u64, "right-6", nil, 5),
      ),
      pair_value(
        document(308_u64, "left-7", nil, 6),
        document(408_u64, "right-7", string_value("right-last"), 7),
      ),
    ] of CrystalClick::StorageColumnValue
  end

  private def json_column(
    name : String,
    rows : Array(CrystalClick::StorageColumnValue),
    site : String,
    shared_data_version : UInt64,
    first_object_count : UInt64,
    first_string_count : UInt64,
  ) : CrystalClick::CompactPartColumn
    plan = object_plan(shared_data_version, first_object_count, first_string_count)
    CrystalClick::CompactPartColumn.json(
      name,
      schemas[name],
      storage_granules(rows),
      CrystalClick::CompactJsonWriteContext.new(
        {site => plan} of String => CrystalClick::ObjectDocumentPlan,
      ),
    )
  end

  private def object_plan(
    shared_data_version : UInt64,
    first_object_count : UInt64,
    first_string_count : UInt64,
  ) : CrystalClick::ObjectDocumentPlan
    bucket_count = shared_data_version == 0_u64 ? 1_u64 : 2_u64
    object = CrystalClick::ObjectStructure.new(
      [PAYLOAD_PATH] of String,
      version: 4_u64,
      shared_data_version: shared_data_version,
      bucket_count: bucket_count,
      statistics: CrystalClick::StructureStatistics.new(
        [first_object_count] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    dynamic = CrystalClick::DynamicStructure.new(
      [string_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [0_u64, first_string_count] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {PAYLOAD_PATH => dynamic} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, json_schema.object_schema.typed_paths)
  end

  private def document(
    id : UInt64,
    label : String,
    payload : CrystalClick::BinaryValue?,
    shared_index : Int32,
  ) : CrystalClick::ObjectDocument
    fields = {
      "id"    => CrystalClick::BinaryValue.uint64(id),
      "label" => string_value(label),
    } of String => CrystalClick::BinaryValue
    SHARED_PATHS.each do |path|
      fields[path] = string_value(shared_value(path, shared_index))
    end
    fields[PAYLOAD_PATH] = payload if payload
    CrystalClick::ObjectDocument.new(fields)
  end

  private def tagged_document(
    id : UInt64,
    label : String,
    payload : String,
    tag : UInt8,
    shared_index : Int32,
  ) : CrystalClick::StorageColumnValue
    json = object_value(document(id, label, string_value(payload), shared_index))
    tag_value = CrystalClick::StorageColumnValue.bulk(
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[tag]),
    )
    CrystalClick::StorageColumnValue.tuple([json, tag_value] of CrystalClick::StorageColumnValue)
  end

  private def object_value(document : CrystalClick::ObjectDocument) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(document)
  end

  private def array_value(items : Array(CrystalClick::StorageColumnValue)) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.array(items)
  end

  private def tagged_array(items : Array(CrystalClick::StorageColumnValue)) : CrystalClick::StorageColumnValue
    array_value(items)
  end

  private def pair_value(
    left : CrystalClick::ObjectDocument,
    right : CrystalClick::ObjectDocument,
  ) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple([
      object_value(left),
      object_value(right),
    ] of CrystalClick::StorageColumnValue)
  end

  private def array_granules(
    rows : Array(CrystalClick::StorageColumnValue),
  ) : Array(Array(CrystalClick::StorageColumnValue))
    rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def storage_granules(
    rows : Array(CrystalClick::StorageColumnValue),
  ) : Array(Array(CrystalClick::StorageColumnValue))
    array_granules(rows)
  end

  private def schema_for_declaration(declaration : String) : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declaration) ||
      raise CrystalClick::UnsupportedFormatError.new("W278 fixture JSON declaration is not admitted")
  end

  private def string_value(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def raw_binary_string : String
    String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])
  end

  private def shared_value(path : String, row : Int32) : String
    return "" if path == "alpha" && row == 0
    return LONG_STRING if path == "alpha" && row == 3
    return raw_binary_string if path == "aa" && row == 1
    return "shared\0nul" if path == "beta" && row == 5

    "#{path}-shared-#{row}"
  end
end
