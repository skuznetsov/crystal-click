require "./spec_helper"
require "../src/crystal_click/binary_aggregate_count_argument_name_parser"

describe CrystalClick::BinaryAggregateCountArgumentNameParser do
  primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }

  it "parses canonical scalar, parameterized, and compound argument names" do
    cases = [
      {"UInt8", primitive.call("UInt8")},
      {"String", primitive.call("String")},
      {"Nothing", primitive.call("Nothing")},
      {"Nullable(Nothing)", CrystalClick::BinaryDataType.nullable(primitive.call("Nothing"))},
      {"Nullable(String)", CrystalClick::BinaryDataType.nullable(primitive.call("String"))},
      {"FixedString(3)", CrystalClick::BinaryDataType.fixed_string(3)},
      {"Decimal(9, 2)", CrystalClick::BinaryDataType.decimal(32, 9, 2)},
      {"DateTime64(3, 'America/New_York')", CrystalClick::BinaryDataType.datetime64(3, "America/New_York")},
      {"IntervalNanosecond", CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Nanosecond)},
      {"Array(Nullable(UInt64))", CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(primitive.call("UInt64")))},
      {"Map(String, Tuple(UInt8, Decimal(18, 3)))", CrystalClick::BinaryDataType.map(
        primitive.call("String"),
        CrystalClick::BinaryDataType.tuple([
          primitive.call("UInt8"), CrystalClick::BinaryDataType.decimal(64, 18, 3),
        ] of CrystalClick::BinaryDataType)
      )},
      {"LowCardinality(String)", CrystalClick::BinaryDataType.low_cardinality(primitive.call("String"))},
      {"Variant(Int8, UInt8)", CrystalClick::BinaryDataType.variant([
        primitive.call("Int8"), primitive.call("UInt8"),
      ] of CrystalClick::BinaryDataType)},
      {"Dynamic", CrystalClick::BinaryDataType.dynamic},
      {"Dynamic(max_types=7)", CrystalClick::BinaryDataType.dynamic(7)},
      {"SimpleAggregateFunction(min, Decimal(9, 2))", CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        CrystalClick::BinaryDataType.decimal(32, 9, 2)
      )},
    ]

    cases.each do |name, expected|
      actual = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(name)
      actual.should_not be_nil
      actual.not_nil!.should eq(expected)
      actual.not_nil!.name.should eq(name)
    end

    nested = CrystalClick::BinaryDataType.nested(
      [primitive.call("UInt8"), primitive.call("String")] of CrystalClick::BinaryDataType,
      ["id", "payload"]
    )
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(nested.name).should eq(nested)
  end

  it "keeps canonical Enum quoting and named Tuple labels intact" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"comma, label", 1_i16}, {"it's\\safe", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    enum_name = enum_type.name
    enum_name.should contain("comma, label")
    enum_name.should contain("\\\\")
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(enum_name).should eq(enum_type)

    negative_enum8_min = CrystalClick::BinaryDataType.enum8([
      {"minimum", -128_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(negative_enum8_min.name).should eq(negative_enum8_min)

    negative_enum8_one = CrystalClick::BinaryDataType.enum8([
      {"negative", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(negative_enum8_one.name).should eq(negative_enum8_one)

    negative_enum16_min = CrystalClick::BinaryDataType.enum16([
      {"minimum", -32_768_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(negative_enum16_min.name).should eq(negative_enum16_min)

    negative_enum16_one = CrystalClick::BinaryDataType.enum16([
      {"negative", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(negative_enum16_one.name).should eq(negative_enum16_one)

    tuple = CrystalClick::BinaryDataType.tuple(
      [primitive.call("UInt64"), primitive.call("String")] of CrystalClick::BinaryDataType,
      ["from", "a`b"]
    )
    tuple_name = tuple.name
    tuple_name.should contain("`from`")
    tuple_name.should contain("\\`")
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(tuple_name).should eq(tuple)
  end

  it "selects the canonical Decimal width and does not alias another nominal width" do
    canonical = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    same_name_other_width = CrystalClick::BinaryDataType.decimal(64, 5, 2)

    canonical.name.should eq(same_name_other_width.name)
    parsed = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical("Decimal(5, 2)")
    parsed.should eq(canonical)
    parsed.should_not eq(same_name_other_width)
  end

  it "rejects invalid shapes, unsupported names, malformed syntax, and noncanonical whitespace" do
    invalid_names = [
      "Nullable(Array(UInt8))",
      "Nullable(Nullable(UInt8))",
      "Map(Nullable(UInt8), String)",
      "Map(LowCardinality(Nullable(UInt8)), String)",
      "Array(AggregateFunction(count))",
      "AggregateFunction(count)",
      "AggregateFunction(sum, UInt64)",
      "Object('json')",
      "UnknownType",
      "Enum8('duplicate' = 1, 'duplicate' = 2)",
      "Decimal(5, 6)",
      "Decimal32(5, 2)",
      "Dynamic(max_types=32)",
      "Map(UInt8)",
      "Array(UInt8",
      "Array(UInt8))",
      "UInt8 trailing",
      " UInt8",
      "UInt8 ",
      "Array( UInt8)",
      "Array(UInt8 )",
    ]

    invalid_names.each do |name|
      CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(name).should be_nil
    end
  end

  it "accepts JSON syntax without admitting JSON to Count state metadata" do
    json = CrystalClick::BinaryDataType.json(
      typed_paths: {"a" => primitive.call("UInt8")},
    )

    parsed = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(json.name)
    parsed.should eq(json)
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(parsed).should be_false
  end

  it "applies depth, node, element, and name-byte limits before admitting a name" do
    deep = "Array(Array(UInt8))"
    depth_limit = CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 20, max_elements: 20, max_bytes: 1024)
    node_limit = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 1, max_elements: 20, max_bytes: 1024)
    element_limit = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 20, max_elements: 0, max_bytes: 1024)
    byte_limit = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 20, max_elements: 20, max_bytes: 4)

    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(deep, depth_limit).should be_nil
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical("Array(UInt8)", node_limit).should be_nil
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical("Array(UInt8)", element_limit).should be_nil
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical("UInt8", byte_limit).should be_nil
  end
end
