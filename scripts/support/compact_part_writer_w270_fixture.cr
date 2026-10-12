require "../../src/crystal_click"
require "json"

module CompactPartWriterW270NativeFixture
  extend self

  KEY_NAME              = "pk"
  ROOT_COLUMN           = "root_json"
  ARRAY_COLUMN          = "array_json"
  TAGGED_COLUMN         = "tagged_json"
  PAIR_COLUMN           = "pair_json"
  UINT8_BASELINE_COLUMN = "uint8_json"
  ROW_COUNT             = 6_u64
  ROWS_PER_MARK         =     2
  MARK_COUNT            =     3
  FRAME_BYTES           =  4096
  KEYS                  = Slice.new(ROW_COUNT.to_i) { |index| index.to_u64 + 1_u64 }

  ROOT_SITE   = "root"
  ARRAY_SITE  = "root/array[0]"
  TAGGED_SITE = "root/array[0]/tuple[0]"
  LEFT_SITE   = "root/tuple[0]"
  RIGHT_SITE  = "root/tuple[1]"

  def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def nullable_int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(int64_type)
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

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def payload_array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nullable_int64_type)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {
        "id"      => uint64_type,
        "label"   => string_type,
        "payload" => dynamic_type,
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

  private def nullable_int64_values(values : Array(Int64)) : Array(Int64?)
    values.map { |value| value.as(Int64?) }
  end

  private def uint8_value(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
  end

  private def payload_value(value : Array(Int64?) | String | Nil) : CrystalClick::BinaryValue
    child = case value
            when Array(Int64?)
              nullable_type = nullable_int64_type
              items = value.map do |item|
                item ? CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.int64(item)) : CrystalClick::BinaryValue.nullable(nullable_type)
              end
              CrystalClick::BinaryValue.array(payload_array_type, items)
            when String
              string_value(value)
            when Nil
              nil
            end
    CrystalClick::BinaryValue.dynamic(dynamic_type, child)
  end

  private def object_document(
    id : UInt64,
    label : String,
    payload : Array(Int64?) | String | Nil,
    hot : CrystalClick::BinaryValue,
    mid : CrystalClick::BinaryValue,
    spill : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::StorageColumnValue
    values = {
      "id"      => CrystalClick::BinaryValue.uint64(id),
      "label"   => CrystalClick::BinaryValue.string(label),
      "payload" => payload_value(payload),
      "hot"     => hot,
      "mid"     => mid,
    } of String => CrystalClick::BinaryValue
    values["spill"] = spill if spill
    CrystalClick::StorageColumnValue.object_document(CrystalClick::ObjectDocument.new(values))
  end

  private def json_payload(value : Array(Int64?) | String | Nil) : JSON::Any
    case value
    when Array(Int64?)
      JSON::Any.new(value.map { |item| item ? JSON::Any.new(item) : JSON::Any.new(nil) })
    when String
      JSON::Any.new(value)
    when Nil
      JSON::Any.new(nil)
    end
  end

  private def json_scalar(value : String | Bool) : JSON::Any
    case value
    when String then JSON::Any.new(value)
    when Bool   then JSON::Any.new(value)
    end
  end

  # The JSON literal renderer is separate from the StorageColumnValue builder:
  # it is a semantic oracle, not a serialization round-trip.
  private def json_document(
    id : UInt64,
    label : String,
    payload : Array(Int64?) | String | Nil,
    hot : String | Bool,
    mid : String | Bool,
    spill : String | Bool | Nil = nil,
  ) : JSON::Any
    values = {
      "id"      => JSON::Any.new(id.to_i64),
      "label"   => JSON::Any.new(label),
      "payload" => json_payload(payload),
      "hot"     => json_scalar(hot),
      "mid"     => json_scalar(mid),
    } of String => JSON::Any
    values["spill"] = json_scalar(spill) unless spill.nil?
    JSON::Any.new(values)
  end

  private def document(
    id : UInt64,
    label : String,
    payload : Array(Int64?) | String | Nil,
    hot : String | Bool,
    mid : String | Bool,
    spill : String | Bool | Nil = nil,
  ) : CrystalClick::StorageColumnValue
    hot_value = hot.is_a?(String) ? string_value(hot) : bool_value(hot)
    mid_value = mid.is_a?(String) ? string_value(mid) : bool_value(mid)
    spill_value = if spill.nil?
                    nil
                  elsif spill.is_a?(String)
                    string_value(spill)
                  else
                    bool_value(spill)
                  end
    object_document(id, label, payload, hot_value, mid_value, spill_value)
  end

  def root_rows : Array(CrystalClick::StorageColumnValue)
    [
      document(1_u64, "r1", nullable_int64_values([11_i64]), "r1-hot", true, "r1-spill"),
      document(2_u64, "r2", nullable_int64_values([12_i64]), "r2-hot", false),
      document(3_u64, "r3", nil, "r3-hot", true),
      document(4_u64, "r4", [] of Int64?, "r4-hot", "r4-mid"),
      document(5_u64, "r5", "late-root", true, true),
      document(6_u64, "r6", [16_i64, nil, 17_i64] of Int64?, false, false, "r6-spill"),
    ] of CrystalClick::StorageColumnValue
  end

  def root_literals : Array(JSON::Any)
    [
      json_document(1_u64, "r1", nullable_int64_values([11_i64]), "r1-hot", true, "r1-spill"),
      json_document(2_u64, "r2", nullable_int64_values([12_i64]), "r2-hot", false),
      json_document(3_u64, "r3", nil, "r3-hot", true),
      json_document(4_u64, "r4", [] of Int64?, "r4-hot", "r4-mid"),
      json_document(5_u64, "r5", "late-root", true, true),
      json_document(6_u64, "r6", [16_i64, nil, 17_i64] of Int64?, false, false, "r6-spill"),
    ] of JSON::Any
  end

  def array_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([
        document(101_u64, "a11", nullable_int64_values([21_i64]), true, "a11-mid", "a11-spill"),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(102_u64, "a21", nil, false, "a21-mid"),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(105_u64, "a51", nullable_int64_values([55_i64]), true, "a51-mid"),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        document(106_u64, "a61", [26_i64, nil] of Int64?, "a61-hot", true),
        document(107_u64, "a62", "late-array", true, "a62-mid", "a62-spill"),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def array_literals : Array(JSON::Any)
    [
      JSON::Any.new([json_document(101_u64, "a11", nullable_int64_values([21_i64]), true, "a11-mid", "a11-spill")]),
      JSON::Any.new([json_document(102_u64, "a21", nil, false, "a21-mid")]),
      JSON::Any.new([] of JSON::Any),
      JSON::Any.new([] of JSON::Any),
      JSON::Any.new([json_document(105_u64, "a51", nullable_int64_values([55_i64]), true, "a51-mid")]),
      JSON::Any.new([
        json_document(106_u64, "a61", [26_i64, nil] of Int64?, "a61-hot", true),
        json_document(107_u64, "a62", "late-array", true, "a62-mid", "a62-spill"),
      ]),
    ] of JSON::Any
  end

  private def tagged_item(
    id : UInt64,
    label : String,
    payload : Array(Int64?) | String | Nil,
    hot : String | Bool,
    mid : String | Bool,
    tag : UInt8,
    spill : String | Bool | Nil = nil,
  ) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple([
      document(id, label, payload, hot, mid, spill),
      CrystalClick::StorageColumnValue.bulk(uint8_value(tag)),
    ] of CrystalClick::StorageColumnValue)
  end

  private def tagged_literal(
    id : UInt64,
    label : String,
    payload : Array(Int64?) | String | Nil,
    hot : String | Bool,
    mid : String | Bool,
    tag : UInt8,
    spill : String | Bool | Nil = nil,
  ) : JSON::Any
    JSON::Any.new({
      "doc" => json_document(id, label, payload, hot, mid, spill),
      "tag" => JSON::Any.new(tag.to_i64),
    })
  end

  def tagged_rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([
        tagged_item(201_u64, "t1", nullable_int64_values([31_i64]), "t1-hot", true, 11_u8, "t1-spill"),
        tagged_item(202_u64, "t2", nil, "t2-hot", false, 12_u8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tagged_item(203_u64, "t3", nullable_int64_values([33_i64]), "t3-hot", true, 13_u8, true),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tagged_item(204_u64, "t4", "late-tagged", "t4-hot", "t4-mid", 14_u8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tagged_item(205_u64, "t5", nullable_int64_values([35_i64]), true, true, 15_u8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tagged_item(206_u64, "t6", nullable_int64_values([36_i64]), false, false, 16_u8, "t6-spill"),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        tagged_item(207_u64, "t7", "late-tagged-2", true, false, 17_u8),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def tagged_literals : Array(JSON::Any)
    [
      JSON::Any.new([
        tagged_literal(201_u64, "t1", nullable_int64_values([31_i64]), "t1-hot", true, 11_u8, "t1-spill"),
        tagged_literal(202_u64, "t2", nil, "t2-hot", false, 12_u8),
      ]),
      JSON::Any.new([tagged_literal(203_u64, "t3", nullable_int64_values([33_i64]), "t3-hot", true, 13_u8, true)]),
      JSON::Any.new([tagged_literal(204_u64, "t4", "late-tagged", "t4-hot", "t4-mid", 14_u8)]),
      JSON::Any.new([tagged_literal(205_u64, "t5", nullable_int64_values([35_i64]), true, true, 15_u8)]),
      JSON::Any.new([tagged_literal(206_u64, "t6", nullable_int64_values([36_i64]), false, false, 16_u8, "t6-spill")]),
      JSON::Any.new([tagged_literal(207_u64, "t7", "late-tagged-2", true, false, 17_u8)]),
    ] of JSON::Any
  end

  private def pair(left : CrystalClick::StorageColumnValue, right : CrystalClick::StorageColumnValue) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple([left, right] of CrystalClick::StorageColumnValue)
  end

  def pair_rows : Array(CrystalClick::StorageColumnValue)
    [
      pair(document(301_u64, "l1", nullable_int64_values([51_i64]), true, "l1-mid", "l1-spill"), document(401_u64, "q1", nullable_int64_values([61_i64]), "q1-hot", true, "q1-spill")),
      pair(document(302_u64, "l2", nullable_int64_values([52_i64]), false, "l2-mid"), document(402_u64, "q2", nil, "q2-hot", false)),
      pair(document(303_u64, "l3", nil, true, "l3-mid", false), document(403_u64, "q3", nullable_int64_values([63_i64]), "q3-hot", true, true)),
      pair(document(304_u64, "l4", nullable_int64_values([54_i64]), true, "l4-mid"), document(404_u64, "q4", "late-right", "q4-hot", "q4-mid")),
      pair(document(305_u64, "l5", "late-left", "l5-hot", "l5-mid", "l5-spill"), document(405_u64, "q5", nullable_int64_values([65_i64]), true, true, "q5-spill")),
      pair(document(306_u64, "l6", nullable_int64_values([56_i64]), "l6-hot", false), document(406_u64, "q6", "late-right-2", false, false, "q6-spill")),
    ] of CrystalClick::StorageColumnValue
  end

  def pair_literals : Array(JSON::Any)
    [
      JSON::Any.new({"left" => json_document(301_u64, "l1", nullable_int64_values([51_i64]), true, "l1-mid", "l1-spill"), "right" => json_document(401_u64, "q1", nullable_int64_values([61_i64]), "q1-hot", true, "q1-spill")}),
      JSON::Any.new({"left" => json_document(302_u64, "l2", nullable_int64_values([52_i64]), false, "l2-mid"), "right" => json_document(402_u64, "q2", nil, "q2-hot", false)}),
      JSON::Any.new({"left" => json_document(303_u64, "l3", nil, true, "l3-mid", false), "right" => json_document(403_u64, "q3", nullable_int64_values([63_i64]), "q3-hot", true, true)}),
      JSON::Any.new({"left" => json_document(304_u64, "l4", nullable_int64_values([54_i64]), true, "l4-mid"), "right" => json_document(404_u64, "q4", "late-right", "q4-hot", "q4-mid")}),
      JSON::Any.new({"left" => json_document(305_u64, "l5", "late-left", "l5-hot", "l5-mid", "l5-spill"), "right" => json_document(405_u64, "q5", nullable_int64_values([65_i64]), true, true, "q5-spill")}),
      JSON::Any.new({"left" => json_document(306_u64, "l6", nullable_int64_values([56_i64]), "l6-hot", false), "right" => json_document(406_u64, "q6", "late-right-2", false, false, "q6-spill")}),
    ] of JSON::Any
  end

  def rows_for(column : String) : Array(CrystalClick::StorageColumnValue)
    case column
    when ROOT_COLUMN   then root_rows
    when ARRAY_COLUMN  then array_rows
    when TAGGED_COLUMN then tagged_rows
    when PAIR_COLUMN   then pair_rows
    else                    raise ArgumentError.new("unknown W270 fixture column")
    end
  end

  def literals_for(column : String) : Array(JSON::Any)
    case column
    when ROOT_COLUMN   then root_literals
    when ARRAY_COLUMN  then array_literals
    when TAGGED_COLUMN then tagged_literals
    when PAIR_COLUMN   then pair_literals
    else                    raise ArgumentError.new("unknown W270 fixture column")
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
    ordinary_type : CrystalClick::BinaryDataType,
    ordinary_count : UInt64,
    shared_name : String,
    shared_count : UInt64,
  ) : CrystalClick::DynamicStructure
    ordinary_name = ordinary_type.name
    canonical_names = [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME, ordinary_name].sort
    counts = canonical_names.map do |name|
      name == CrystalClick::DynamicStructure::SHARED_VARIANT_NAME ? shared_count : ordinary_count
    end
    shared = [] of CrystalClick::StructureStatistic
    shared << CrystalClick::StructureStatistic.new(shared_name, shared_count) if shared_count > 0_u64
    CrystalClick::DynamicStructure.new(
      [ordinary_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, shared),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  private def payload_plan(site : String) : CrystalClick::DynamicStructure
    arrays, shared = case site
                     when ROOT_SITE   then {4_u64, 1_u64}
                     when ARRAY_SITE  then {3_u64, 1_u64}
                     when TAGGED_SITE then {4_u64, 2_u64}
                     when LEFT_SITE   then {4_u64, 1_u64}
                     when RIGHT_SITE  then {3_u64, 2_u64}
                     else                  raise ArgumentError.new("unknown W270 typed Dynamic site")
                     end
    dynamic_plan(payload_array_type, arrays, "String", shared)
  end

  # Plans carry the full six-row INSERT-block sample. NULL values are counted
  # separately by the fixture census and do not enter Dynamic statistics.
  # These counts are intentionally independent of the first physical mark.
  def object_plan(site : String, shared_layout : String) : CrystalClick::ObjectDocumentPlan
    object_count, spill_count, hot_name, hot_ordinary, hot_shared_name, hot_shared, mid_name, mid_ordinary, mid_shared_name, mid_shared = case site
                                                                                                                                          when ROOT_SITE
                                                                                                                                            {6_u64, 2_u64, "String", 4_u64, "Bool", 2_u64, "Bool", 5_u64, "String", 1_u64}
                                                                                                                                          when ARRAY_SITE
                                                                                                                                            {5_u64, 2_u64, "Bool", 4_u64, "String", 1_u64, "String", 4_u64, "Bool", 1_u64}
                                                                                                                                          when TAGGED_SITE
                                                                                                                                            {7_u64, 3_u64, "String", 4_u64, "Bool", 3_u64, "Bool", 6_u64, "String", 1_u64}
                                                                                                                                          when LEFT_SITE
                                                                                                                                            {6_u64, 3_u64, "Bool", 4_u64, "String", 2_u64, "String", 5_u64, "Bool", 1_u64}
                                                                                                                                          when RIGHT_SITE
                                                                                                                                            {6_u64, 4_u64, "String", 4_u64, "Bool", 2_u64, "Bool", 5_u64, "String", 1_u64}
                                                                                                                                          else
                                                                                                                                            raise ArgumentError.new("unknown W270 Object site")
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
      "hot" => dynamic_plan(CrystalClick::BinaryDataType.primitive(hot_name), hot_ordinary, hot_shared_name, hot_shared),
      "mid" => dynamic_plan(CrystalClick::BinaryDataType.primitive(mid_name), mid_ordinary, mid_shared_name, mid_shared),
    } of String => CrystalClick::DynamicStructure
    structures = CrystalClick::ObjectDynamicStructureSet.new(object, dynamics)
    typed = {"payload" => payload_plan(site)} of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(structures, json_schema.object_schema.typed_paths, typed)
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
      if values.size == 2 && values[0].as_h?
        if values[1].as_h?
          JSON::Any.new({"left" => values[0], "right" => values[1]})
        elsif values[1].as_i?
          JSON::Any.new({"doc" => values[0], "tag" => values[1]})
        else
          JSON::Any.new(values)
        end
      else
        JSON::Any.new(values)
      end
    else
      binary_json(value.bulk_value)
    end
  end

  private def binary_json(value : CrystalClick::BinaryValue) : JSON::Any
    return JSON::Any.new(nil) if value.is_null?
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      return JSON::Any.new(nil) if value.child_count == 0
      binary_json(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      return JSON::Any.new(nil) if value.child_count == 0
      binary_json(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |child| binary_json(child) })
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string)
    when CrystalClick::BinaryDataType::TAG_BOOL
      JSON::Any.new(value.as_bool)
    when CrystalClick::BinaryDataType::TAG_INT64
      JSON::Any.new(value.as_int64)
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
        raise CrystalClick::CorruptPartError.new("W270 #{type.name} payload width differs from its descriptor")
      end
      number = 0_u64
      bytes.each_with_index { |byte, index| number |= byte.to_u64 << (index * 8) }
      JSON::Any.new(number.to_i64)
    else
      raise CrystalClick::UnsupportedFormatError.new("W270 signature renderer does not admit #{type.name}")
    end
  end
end

module CompactPartWriterW270UInt8NativeFixture
  extend self

  KEY_NAME      = "pk"
  COLUMN_NAME   = "nested_dynamic_json"
  SITE_PATH     = "root/array[0]"
  ROW_COUNT     = 8_u64
  ROWS_PER_MARK =     2
  MARK_COUNT    =     4
  FRAME_BYTES   =  4096
  KEYS          = Slice.new(ROW_COUNT.to_i) { |index| index.to_u64 + 1_u64 }

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
    # This is the full eight-row INSERT-block sample: row 1 holds one and row
    # 5 holds two non-NULL Array(UInt8) Dynamic values. The first mark has one.
    dynamic_statistics = CrystalClick::StructureStatistics.new(
      [3_u64, 0_u64] of UInt64,
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

  private def object_value(values : Array(UInt8)) : CrystalClick::StorageColumnValue
    children = values.map do |value|
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
    end
    payload = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      CrystalClick::BinaryValue.array(array_type, children),
    )
    document = CrystalClick::ObjectDocument.new({"payload" => payload} of String => CrystalClick::BinaryValue)
    CrystalClick::StorageColumnValue.object_document(document)
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    [
      CrystalClick::StorageColumnValue.array([object_value([11_u8] of UInt8)] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([
        object_value([] of UInt8),
        object_value([31_u8, 32_u8] of UInt8),
      ] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
      CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue
  end

  def granules(values : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    unless values.size == ROW_COUNT && values.size == ROWS_PER_MARK * MARK_COUNT
      raise ArgumentError.new("W270 UInt8 fixture must contain exactly eight rows")
    end
    output = [] of Array(CrystalClick::StorageColumnValue)
    MARK_COUNT.times do |mark|
      output << values[mark * ROWS_PER_MARK, ROWS_PER_MARK]
    end
    output
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules(rows),
      context,
    )
  end
end
