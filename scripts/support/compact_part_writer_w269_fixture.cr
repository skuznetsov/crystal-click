require "../../src/crystal_click"
require "json"

module CompactPartWriterW269Fixture
  extend self

  KEY_NAME      = "pk"
  ROOT_COLUMN   = "root_json"
  ARRAY_COLUMN  = "array_json"
  TAGGED_COLUMN = "tagged_json"
  PAIR_COLUMN   = "pair_json"
  ROW_COUNT     = 6_u64
  ROWS_PER_MARK =     2
  MARK_COUNT    =     3
  FRAME_BYTES   =  4096
  KEYS          = Slice.new(ROW_COUNT.to_i) { |index| index.to_u64 + 1_u64 }

  ROOT_SITE   = "root"
  ARRAY_SITE  = "root/array[0]"
  TAGGED_SITE = "root/array[0]/tuple[0]"
  LEFT_SITE   = "root/tuple[0]"
  RIGHT_SITE  = "root/tuple[1]"

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def bool_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Bool")
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {
        "id"    => uint64_type,
        "label" => string_type,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def object_document_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.parse_declaration(json_type.name)
  end

  def json_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.object(object_document_schema, json_type.name)
  end

  def array_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(#{json_type.name})")
  end

  def tagged_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Array(Tuple(doc #{json_type.name}, tag UInt8))")
  end

  def pair_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse("Tuple(left #{json_type.name}, right #{json_type.name})")
  end

  def schemas : Hash(String, CrystalClick::StorageColumnSchema)
    {
      ROOT_COLUMN   => json_schema,
      ARRAY_COLUMN  => array_schema,
      TAGGED_COLUMN => tagged_schema,
      PAIR_COLUMN   => pair_schema,
    } of String => CrystalClick::StorageColumnSchema
  end

  private def string_value(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def bool_value(value : Bool) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.bool(value)
  end

  private def document(
    id : UInt64,
    label : String,
    hot : CrystalClick::BinaryValue,
    mid : CrystalClick::BinaryValue,
    spill : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::StorageColumnValue
    values = {
      "id"    => CrystalClick::BinaryValue.uint64(id),
      "label" => CrystalClick::BinaryValue.string(label),
      "hot"   => hot,
      "mid"   => mid,
    } of String => CrystalClick::BinaryValue
    values["spill"] = spill if spill
    CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new(values))
  end

  private def json_object(
    id : UInt64,
    label : String,
    hot : String | Bool,
    mid : String | Bool,
    spill : String | Bool | Nil = nil,
  ) : JSON::Any
    values = {
      "id"    => JSON::Any.new(id.to_i64),
      "label" => JSON::Any.new(label),
      "hot"   => json_scalar(hot),
      "mid"   => json_scalar(mid),
    } of String => JSON::Any
    values["spill"] = json_scalar(spill) unless spill.nil?
    JSON::Any.new(values)
  end

  private def json_scalar(value : String | Bool) : JSON::Any
    case value
    when String then JSON::Any.new(value)
    when Bool   then JSON::Any.new(value)
    end
  end

  def root_rows : Array(CrystalClick::StorageColumnValue)
    [
      document(1_u64, "r1", string_value("r1-hot"), bool_value(true), string_value("r1-spill")),
      document(2_u64, "r2", string_value("r2-hot"), bool_value(false)),
      document(3_u64, "r3", string_value("r3-hot"), bool_value(true)),
      document(4_u64, "r4", string_value("r4-hot"), string_value("r4-mid")),
      document(5_u64, "r5", bool_value(true), bool_value(true)),
      document(6_u64, "r6", bool_value(false), bool_value(false), string_value("r6-spill")),
    ] of CrystalClick::StorageColumnValue
  end

  # Literal row oracle mirrors root_rows; it is intentionally not derived from
  # ObjectDocument or from the candidate writer's encoder.
  def root_literals : Array(JSON::Any)
    [
      json_object(1_u64, "r1", "r1-hot", true, "r1-spill"),
      json_object(2_u64, "r2", "r2-hot", false),
      json_object(3_u64, "r3", "r3-hot", true),
      json_object(4_u64, "r4", "r4-hot", "r4-mid"),
      json_object(5_u64, "r5", true, true),
      json_object(6_u64, "r6", false, false, "r6-spill"),
    ] of JSON::Any
  end

  def array_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([
        document(101_u64, "a11", bool_value(true), string_value("a11-mid"), string_value("a11-spill")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(102_u64, "a21", bool_value(false), string_value("a21-mid")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(105_u64, "a51", bool_value(true), string_value("a51-mid")),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(106_u64, "a61", string_value("a61-hot"), bool_value(true)),
        document(107_u64, "a62", string_value("a62-hot"), bool_value(false), string_value("a62-spill")),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def array_literals : Array(JSON::Any)
    [
      JSON::Any.new([json_object(101_u64, "a11", true, "a11-mid", "a11-spill")]),
      JSON::Any.new([json_object(102_u64, "a21", false, "a21-mid")]),
      JSON::Any.new([] of JSON::Any),
      JSON::Any.new([] of JSON::Any),
      JSON::Any.new([json_object(105_u64, "a51", true, "a51-mid")]),
      JSON::Any.new([
        json_object(106_u64, "a61", "a61-hot", true),
        json_object(107_u64, "a62", "a62-hot", false, "a62-spill"),
      ]),
    ] of JSON::Any
  end

  private def tuple_json(id : UInt64, label : String, hot : String | Bool, mid : String | Bool, tag : UInt8, spill : String | Bool | Nil = nil) : CrystalClick::StorageColumnValue
    item = document(
      id,
      label,
      hot.is_a?(String) ? string_value(hot) : bool_value(hot),
      mid.is_a?(String) ? string_value(mid) : bool_value(mid),
      spill ? (spill.is_a?(String) ? string_value(spill) : bool_value(spill)) : nil,
    )
    CrystalClick::StorageColumnValue.tuple([
      item,
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.fixed(uint8_type, Bytes[tag])),
    ] of CrystalClick::StorageColumnValue)
  end

  def tagged_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([tuple_json(201_u64, "t1", "t1-hot", true, 11_u8, "t1-spill")] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([tuple_json(202_u64, "t2", "t2-hot", false, 12_u8)] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([tuple_json(203_u64, "t3", "t3-hot", true, 13_u8, true)] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([tuple_json(204_u64, "t4", "t4-hot", "t4-mid", 14_u8)] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([tuple_json(205_u64, "t5", true, true, 15_u8, "t5-spill")] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([tuple_json(206_u64, "t6", false, false, 16_u8, "t6-spill")] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def tagged_literals : Array(JSON::Any)
    [
      JSON::Any.new([JSON::Any.new({"doc" => json_object(201_u64, "t1", "t1-hot", true, "t1-spill"), "tag" => JSON::Any.new(11_i64)})]),
      JSON::Any.new([JSON::Any.new({"doc" => json_object(202_u64, "t2", "t2-hot", false), "tag" => JSON::Any.new(12_i64)})]),
      JSON::Any.new([JSON::Any.new({"doc" => json_object(203_u64, "t3", "t3-hot", true, true), "tag" => JSON::Any.new(13_i64)})]),
      JSON::Any.new([JSON::Any.new({"doc" => json_object(204_u64, "t4", "t4-hot", "t4-mid"), "tag" => JSON::Any.new(14_i64)})]),
      JSON::Any.new([JSON::Any.new({"doc" => json_object(205_u64, "t5", true, true, "t5-spill"), "tag" => JSON::Any.new(15_i64)})]),
      JSON::Any.new([JSON::Any.new({"doc" => json_object(206_u64, "t6", false, false, "t6-spill"), "tag" => JSON::Any.new(16_i64)})]),
    ] of JSON::Any
  end

  private def pair(left : CrystalClick::StorageColumnValue, right : CrystalClick::StorageColumnValue) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple([left, right] of CrystalClick::StorageColumnValue)
  end

  def pair_rows : Array(CrystalClick::StorageColumnValue)
    [
      pair(document(301_u64, "l1", bool_value(true), string_value("l1-mid"), string_value("l1-spill")), document(401_u64, "q1", string_value("q1-hot"), bool_value(true), string_value("q1-spill"))),
      pair(document(302_u64, "l2", bool_value(false), string_value("l2-mid")), document(402_u64, "q2", string_value("q2-hot"), bool_value(false))),
      pair(document(303_u64, "l3", bool_value(true), string_value("l3-mid"), bool_value(false)), document(403_u64, "q3", string_value("q3-hot"), bool_value(true), bool_value(true))),
      pair(document(304_u64, "l4", bool_value(true), string_value("l4-mid")), document(404_u64, "q4", string_value("q4-hot"), string_value("q4-mid"))),
      pair(document(305_u64, "l5", string_value("l5-hot"), string_value("l5-mid"), string_value("l5-spill")), document(405_u64, "q5", bool_value(true), bool_value(true), string_value("q5-spill"))),
      pair(document(306_u64, "l6", string_value("l6-hot"), bool_value(false)), document(406_u64, "q6", bool_value(false), bool_value(false), string_value("q6-spill"))),
    ] of CrystalClick::StorageColumnValue
  end

  def pair_literals : Array(JSON::Any)
    [
      JSON::Any.new({"left" => json_object(301_u64, "l1", true, "l1-mid", "l1-spill"), "right" => json_object(401_u64, "q1", "q1-hot", true, "q1-spill")}),
      JSON::Any.new({"left" => json_object(302_u64, "l2", false, "l2-mid"), "right" => json_object(402_u64, "q2", "q2-hot", false)}),
      JSON::Any.new({"left" => json_object(303_u64, "l3", true, "l3-mid", false), "right" => json_object(403_u64, "q3", "q3-hot", true, true)}),
      JSON::Any.new({"left" => json_object(304_u64, "l4", true, "l4-mid"), "right" => json_object(404_u64, "q4", "q4-hot", "q4-mid")}),
      JSON::Any.new({"left" => json_object(305_u64, "l5", "l5-hot", "l5-mid", "l5-spill"), "right" => json_object(405_u64, "q5", true, true, "q5-spill")}),
      JSON::Any.new({"left" => json_object(306_u64, "l6", "l6-hot", false), "right" => json_object(406_u64, "q6", false, false, "q6-spill")}),
    ] of JSON::Any
  end

  def rows_for(column : String) : Array(CrystalClick::StorageColumnValue)
    case column
    when ROOT_COLUMN   then root_rows
    when ARRAY_COLUMN  then array_rows
    when TAGGED_COLUMN then tagged_rows
    when PAIR_COLUMN   then pair_rows
    else                    raise ArgumentError.new("unknown W269 fixture column")
    end
  end

  def literals_for(column : String) : Array(JSON::Any)
    case column
    when ROOT_COLUMN   then root_literals
    when ARRAY_COLUMN  then array_literals
    when TAGGED_COLUMN then tagged_literals
    when PAIR_COLUMN   then pair_literals
    else                    raise ArgumentError.new("unknown W269 fixture column")
    end
  end

  def granules(rows : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    output = [] of Array(CrystalClick::StorageColumnValue)
    MARK_COUNT.times do |mark|
      output << rows[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  private def dynamic_plan(
    ordinary_name : String,
    ordinary_count : UInt64,
    shared_name : String,
    shared_count : UInt64,
  ) : CrystalClick::DynamicStructure
    ordinary_type = CrystalClick::BinaryDataType.primitive(ordinary_name)
    canonical_names = [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME, ordinary_name].sort
    counts = canonical_names.map do |name|
      name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? shared_count : ordinary_count
    end
    shared = [] of CrystalClick::StructureStatistic
    shared << CrystalClick::StructureStatistic.new(shared_name, shared_count) if shared_count > 0_u64
    statistics = CrystalClick::StructureStatistics.new(counts, shared)
    CrystalClick::DynamicStructure.new(
      [ordinary_type] of CrystalClick::BinaryDataType,
      statistics,
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  # These are literal first-INSERT-block census samples, deliberately separate
  # from the value grid. In particular Array(JSON) has five documents in the
  # six-row sample although its first physical mark has only two.
  def object_plan(site : String, shared_layout : String) : CrystalClick::ObjectDocumentPlan
    object_count, spill_count, hot_name, hot_ordinary, hot_shared_name, hot_shared, mid_name, mid_ordinary, mid_shared_name, mid_shared = case site
                                                                                                                                          when ROOT_SITE, TAGGED_SITE, RIGHT_SITE
                                                                                                                                            {6_u64, site == ROOT_SITE ? 2_u64 : 4_u64,
                                                                                                                                             "String", 4_u64, "Bool", 2_u64,
                                                                                                                                             "Bool", 5_u64, "String", 1_u64}
                                                                                                                                          when ARRAY_SITE
                                                                                                                                            {5_u64, 2_u64,
                                                                                                                                             "Bool", 3_u64, "String", 2_u64,
                                                                                                                                             "String", 3_u64, "Bool", 2_u64}
                                                                                                                                          when LEFT_SITE
                                                                                                                                            {6_u64, 3_u64,
                                                                                                                                             "Bool", 4_u64, "String", 2_u64,
                                                                                                                                             "String", 5_u64, "Bool", 1_u64}
                                                                                                                                          else
                                                                                                                                            raise ArgumentError.new("unknown W269 Object site")
                                                                                                                                          end

    shared_version, bucket_count = case shared_layout
                                   when "map"              then {0_u64, 1_u64}
                                   when "map_with_buckets" then {1_u64, 2_u64}
                                   else                         raise ArgumentError.new("shared layout must be map or map_with_buckets")
                                   end
    object_shared = [] of CrystalClick::StructureStatistic
    object_shared << CrystalClick::StructureStatistic.new("spill", spill_count) if spill_count > 0_u64
    object_stats = CrystalClick::StructureStatistics.new([object_count, object_count] of UInt64, object_shared)
    object = CrystalClick::ObjectStructure.new(
      ["hot", "mid"] of String,
      version: 4_u64,
      shared_data_version: shared_version,
      bucket_count: bucket_count,
      statistics: object_stats,
    )
    dynamics = {
      "hot" => dynamic_plan(hot_name, hot_ordinary, hot_shared_name, hot_shared),
      "mid" => dynamic_plan(mid_name, mid_ordinary, mid_shared_name, mid_shared),
    } of String => CrystalClick::DynamicStructure
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    CrystalClick::ObjectDocumentPlan.new(structures, json_schema.object_schema.typed_paths)
  end

  def columns(shared_layout : String) : Array(CrystalClick::CompactPartColumn)
    [
      CrystalClick::CompactPartColumn.json(
        ROOT_COLUMN,
        json_schema,
        granules(root_rows),
        CrystalClick::CompactJsonWriteContext.new({ROOT_SITE => object_plan(ROOT_SITE, shared_layout)} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        ARRAY_COLUMN,
        array_schema,
        granules(array_rows),
        CrystalClick::CompactJsonWriteContext.new({ARRAY_SITE => object_plan(ARRAY_SITE, shared_layout)} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        TAGGED_COLUMN,
        tagged_schema,
        granules(tagged_rows),
        CrystalClick::CompactJsonWriteContext.new({TAGGED_SITE => object_plan(TAGGED_SITE, shared_layout)} of String => CrystalClick::ObjectDocumentPlan),
      ),
      CrystalClick::CompactPartColumn.json(
        PAIR_COLUMN,
        pair_schema,
        granules(pair_rows),
        CrystalClick::CompactJsonWriteContext.new({
          LEFT_SITE  => object_plan(LEFT_SITE, shared_layout),
          RIGHT_SITE => object_plan(RIGHT_SITE, shared_layout),
        } of String => CrystalClick::ObjectDocumentPlan),
      ),
    ] of CrystalClick::CompactPartColumn
  end

  def signatures(value : CrystalClick::StorageColumnValue) : JSON::Any
    if value.object?
      document = value.object_document
      fields = Hash(String, JSON::Any).new
      document.paths.each do |path|
        fields[path] = binary_json(document.value_for(path))
      end
      JSON::Any.new(fields)
    elsif value.array?
      JSON::Any.new(value.array_values.map { |child| signatures(child) })
    elsif value.tuple?
      values = value.tuple_values.map { |child| signatures(child) }
      if values.size == 2 && values[1].as_i? && values[0].as_h?
        JSON::Any.new({"doc" => values[0], "tag" => values[1]})
      elsif values.size == 2 && values.all?(&.as_h?)
        JSON::Any.new({"left" => values[0], "right" => values[1]})
      else
        JSON::Any.new(values)
      end
    else
      binary_json(value.bulk_value)
    end
  end

  private def binary_json(value : CrystalClick::BinaryValue) : JSON::Any
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string)
    when CrystalClick::BinaryDataType::TAG_BOOL
      JSON::Any.new(value.as_bool)
    when CrystalClick::BinaryDataType::TAG_UINT8,
         CrystalClick::BinaryDataType::TAG_UINT16,
         CrystalClick::BinaryDataType::TAG_UINT32,
         CrystalClick::BinaryDataType::TAG_UINT64
      width = case type.tag
              when CrystalClick::BinaryDataType::TAG_UINT8  then 1
              when CrystalClick::BinaryDataType::TAG_UINT16 then 2
              when CrystalClick::BinaryDataType::TAG_UINT32 then 4
              else                                               8
              end
      bytes = value.bytes
      unless bytes.size == width
        raise CrystalClick::CorruptPartError.new("W269 #{type.name} payload width differs from its descriptor")
      end
      number = 0_u64
      bytes.each_with_index { |byte, index| number |= byte.to_u64 << (index * 8) }
      JSON::Any.new(number.to_i64)
    else
      raise CrystalClick::UnsupportedFormatError.new("W269 signature renderer does not admit #{type.name}")
    end
  end
end
