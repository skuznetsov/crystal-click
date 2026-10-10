require "./spec_helper"

private def w251_dynamic_json_prefix(version : UInt64, type_name : String) : Bytes
  has_v1_maximum = version == 1_u64
  prefix_size = 8 + (has_v1_maximum ? 1 : 0) + 1 + 1 + type_name.bytesize

  Bytes.new(prefix_size) do |index|
    if index < 8
      index == 0 ? version.to_u8 : 0_u8
    elsif has_v1_maximum && index == 8
      9_u8 # Literal legacy maximum, intentionally independent of roster count.
    elsif index == (has_v1_maximum ? 9 : 8)
      1_u8 # One ordinary type.
    elsif index == (has_v1_maximum ? 10 : 9)
      type_name.bytesize.to_u8 # StringBinary byte length.
    else
      type_name.to_slice[index - (has_v1_maximum ? 11 : 10)]
    end
  end
end

private def w251_dynamic_json_complete_frame(prefix : Bytes) : Bytes
  # Literal V1/V2 statistics for canonical variants [JSON(...), SharedVariant]:
  # counts [2, 7], followed by an empty shared-statistics map.
  statistics = Bytes[0x02_u8, 0x07_u8, 0x00_u8]
  Bytes.new(prefix.size + statistics.size) do |index|
    index < prefix.size ? prefix[index] : statistics[index - prefix.size]
  end
end

private def w251_json_name_limits(
  max_depth : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
  max_nodes : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
  max_elements : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
  max_bytes : Int = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W251 canonical JSON SQL type names in Dynamic V1/V2" do
  it "parses the bare and parameterized names without losing descriptor identity" do
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {"a" => CrystalClick::BinaryDataType.primitive("UInt8")},
    )
    parameterized_name = "JSON(max_dynamic_types=1, max_dynamic_paths=2, a UInt8)"

    json_type.name.should eq(parameterized_name)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON").should eq(
      CrystalClick::BinaryDataType.json
    )
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(parameterized_name).should eq(json_type)
  end

  it "round-trips literal V1/V2 prefixes with typed-path and capacity metadata intact" do
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {"a" => CrystalClick::BinaryDataType.primitive("UInt8")},
    )
    type_name = "JSON(max_dynamic_types=1, max_dynamic_paths=2, a UInt8)"

    {1_u64, 2_u64}.each do |version|
      prefix = w251_dynamic_json_prefix(version, type_name)
      decoded = CrystalClick::DynamicStructureCodec.decode_prefix_without_statistics(prefix)

      decoded.version.should eq(version)
      decoded.types.should eq([json_type] of CrystalClick::BinaryDataType)
      decoded.canonical_variant_names.should eq([type_name, "SharedVariant"] of String)
      metadata = decoded.type_at(0).json_type.not_nil!
      metadata.max_dynamic_types.should eq(1_u8)
      metadata.max_dynamic_paths.should eq(2)
      metadata.typed_path_count.should eq(1)
      metadata.typed_path_at(0).should eq("a")
      metadata.typed_type_for("a").not_nil!.should eq(CrystalClick::BinaryDataType.primitive("UInt8"))
      CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(decoded).should eq(prefix)

      if version == 1_u64
        decoded.legacy_max_dynamic_types.should eq(9_u64)
      else
        decoded.legacy_max_dynamic_types.should be_nil
      end
    end
  end

  it "retains literal full-frame statistics and the relative statistics offset" do
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: {"a" => CrystalClick::BinaryDataType.primitive("UInt8")},
    )
    type_name = "JSON(max_dynamic_types=1, max_dynamic_paths=2, a UInt8)"
    statistics = CrystalClick::StructureStatistics.new(
      [2_u64, 7_u64],
      [] of CrystalClick::StructureStatistic,
    )

    {1_u64, 2_u64}.each do |version|
      prefix = w251_dynamic_json_prefix(version, type_name)
      wire = w251_dynamic_json_complete_frame(prefix)
      context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, wire)
      decoded, statistics_offset = CrystalClick::DynamicStructureCodec.read_with_statistics_offset(context)
      context.ensure_consumed

      decoded.version.should eq(version)
      decoded.types.should eq([json_type] of CrystalClick::BinaryDataType)
      decoded.statistics.not_nil!.counts.should eq([2_u64, 7_u64])
      decoded.statistics.not_nil!.shared.should be_empty
      statistics_offset.should eq(prefix.size)
      CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)

      structure = if version == 1_u64
                    CrystalClick::DynamicStructure.new(
                      [json_type] of CrystalClick::BinaryDataType,
                      statistics,
                      version: version,
                      legacy_max_dynamic_types: 9_u64,
                    )
                  else
                    CrystalClick::DynamicStructure.new(
                      [json_type] of CrystalClick::BinaryDataType,
                      statistics,
                      version: version,
                    )
                  end
      writer = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, nil, true)
      written_offset = CrystalClick::DynamicStructureCodec.write_with_statistics_offset(structure, writer)
      written_offset.should eq(prefix.size)
      writer.finish_bytes.should eq(wire)
    end
  end

  it "preserves canonical defaults, cap bounds, option order, and recursively typed JSON names" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")

    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON")
      .should eq(CrystalClick::BinaryDataType.json)

    zero_caps = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    zero_caps.name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0)")
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(zero_caps.name).should eq(zero_caps)

    maximum_caps = CrystalClick::BinaryDataType.json(max_dynamic_paths: 10_000, max_dynamic_types: 254)
    maximum_caps.name.should eq("JSON(max_dynamic_types=254, max_dynamic_paths=10000)")
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(maximum_caps.name).should eq(maximum_caps)

    # The token is an option only when followed by '='. Without '=', the same
    # spelling is an ordinary typed path and its type remains part of identity.
    option_named_path = CrystalClick::BinaryDataType.json(
      max_dynamic_types: 1,
      typed_paths: {"max_dynamic_types" => uint8},
    )
    option_named_path.name.should eq("JSON(max_dynamic_types=1, max_dynamic_types UInt8)")
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(option_named_path.name)
      .should eq(option_named_path)

    inner_json = CrystalClick::BinaryDataType.json(
      typed_paths: {"leaf" => CrystalClick::BinaryDataType.primitive("UInt16")},
    )
    recursive_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 3,
      max_dynamic_types: 2,
      typed_paths: {
        "root"  => string,
        "child" => CrystalClick::BinaryDataType.array(
          CrystalClick::BinaryDataType.nullable(inner_json)
        ),
      },
    )
    recursive_name = "JSON(max_dynamic_types=2, max_dynamic_paths=3, child Array(Nullable(JSON(leaf UInt16))), root String)"
    recursive_json.name.should eq(recursive_name)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(recursive_name).should eq(recursive_json)
  end

  it "rejects noncanonical names and path syntax outside the represented JSON descriptor" do
    invalid_names = [
      "JSON()",
      "JSON(max_dynamic_paths=1, max_dynamic_types=1)", # options are rendered types-first
      "JSON(max_dynamic_paths=1, max_dynamic_paths=2)",
      "JSON(max_dynamic_types=1, max_dynamic_types=2)",
      "JSON(max_dynamic_types=01)",
      "JSON(max_dynamic_paths=10001)",
      "JSON(max_dynamic_types=255)",
      "JSON(unknown=1)",
      "JSON(foo UInt8, foo String)",
      "JSON(foo.bar UInt8)",
      "JSON(`foo` UInt8)",
      "JSON(SKIP UInt8)",
      "JSON(SKIP REGEXP '.*')",
      "JSON( max_dynamic_types=1)",
      "JSON(max_dynamic_types=1) trailing",
      "Array(JSON(foo.bar UInt8))",
      "JSON(bad Nullable(Nothing))",
      "JSON(bad Map(UInt8, String))",
    ]

    invalid_names.each do |name|
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(name).should be_nil
    end

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    {
      {"SKIP", "JSON(`SKIP` UInt8)"},
      {"with.dot", "JSON(`with.dot` UInt8)"},
      {"quoted`path", "JSON(`quoted\\`path` UInt8)"},
    }.each do |path, expected_name|
      type = CrystalClick::BinaryDataType.json(typed_paths: {path => uint8})
      type.name.should eq(expected_name)
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(expected_name).should eq(type)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(
        typed_paths: {"map" => CrystalClick::BinaryDataType.map(uint8, CrystalClick::BinaryDataType.primitive("String"))},
      )
    end
  end

  it "shares exact node, edge, and name-work byte limits across successive JSON parses" do
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    expected = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 4,
      max_dynamic_types: 5,
      typed_paths: {
        "payload" => CrystalClick::BinaryDataType.array(
          CrystalClick::BinaryDataType.nullable(uint16)
        ),
      },
    )
    name = expected.name

    measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    2.times do
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, measured)
        .should eq(expected)
    end
    # Per parse: JSON + path metadata + Array + Nullable + UInt16 = 5 nodes;
    # the JSON path-record/descriptor edges and two container edges = 4.
    # Parsing and then recursively measuring/materializing each of two names
    # charges those same independently counted visits twice per name.
    measured.node_count.should eq(20_i64)
    measured.element_count.should eq(16_i64)
    measured.node_count.should be > 1
    measured.element_count.should be > 0
    measured.wire_byte_count.should be > name.bytesize

    exact_limits = w251_json_name_limits(
      max_nodes: measured.node_count.to_i,
      max_elements: measured.element_count.to_i,
      max_bytes: measured.wire_byte_count.to_i,
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits)
    2.times do
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, exact_budget)
        .should eq(expected)
    end
    exact_budget.node_count.should eq(measured.node_count)
    exact_budget.element_count.should eq(measured.element_count)
    exact_budget.wire_byte_count.should eq(measured.wire_byte_count)

    node_short_budget = CrystalClick::BinaryCodecBudget.new(w251_json_name_limits(
      max_nodes: measured.node_count.to_i - 1,
      max_elements: measured.element_count.to_i,
      max_bytes: measured.wire_byte_count.to_i,
    ))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, node_short_budget)
      .should eq(expected)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, node_short_budget)
      .should be_nil

    edge_short_budget = CrystalClick::BinaryCodecBudget.new(w251_json_name_limits(
      max_nodes: measured.node_count.to_i,
      max_elements: measured.element_count.to_i - 1,
      max_bytes: measured.wire_byte_count.to_i,
    ))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, edge_short_budget)
      .should eq(expected)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, edge_short_budget)
      .should be_nil

    byte_short_budget = CrystalClick::BinaryCodecBudget.new(w251_json_name_limits(
      max_nodes: measured.node_count.to_i,
      max_elements: measured.element_count.to_i,
      max_bytes: measured.wire_byte_count.to_i - 1,
    ))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, byte_short_budget)
      .should eq(expected)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, byte_short_budget)
      .should be_nil
  end

  it "admits the maximum JSON path length and typed-path count but rejects one beyond each" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    path_256 = "a" * 256
    at_path_limit = CrystalClick::BinaryDataType.json(
      typed_paths: {path_256 => uint8},
    )
    at_path_limit.json_type.not_nil!.typed_path_count.should eq(1)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(at_path_limit.name)
      .should eq(at_path_limit)

    path_257 = "a" * 257
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {path_257 => uint8})
    end
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON(#{path_257} UInt8)")
      .should be_nil

    at_count_limit = Hash(String, CrystalClick::BinaryDataType).new
    1_000.times do |index|
      at_count_limit["path_#{index}"] = uint8
    end
    maximum_paths = CrystalClick::BinaryDataType.json(typed_paths: at_count_limit)
    maximum_paths.json_type.not_nil!.typed_path_count.should eq(1_000)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(maximum_paths.name)
      .should eq(maximum_paths)

    above_count_limit = Hash(String, CrystalClick::BinaryDataType).new
    1_001.times do |index|
      above_count_limit["path_#{index}"] = uint8
    end
    error = expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: above_count_limit)
    end
    error.message.to_s.should eq("JSON typed path count exceeds the admitted limit")

    too_many_paths_name = String.build do |io|
      io << "JSON("
      1_001.times do |index|
        io << ", " unless index == 0
        io << "path_" << index << " UInt8"
      end
      io << ')'
    end
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(too_many_paths_name)
      .should be_nil
  end

  it "enforces recursive JSON-name depth and one-short descriptor-work byte limits" do
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    inner_json = CrystalClick::BinaryDataType.json(typed_paths: {"leaf" => uint16})
    recursive_json = CrystalClick::BinaryDataType.json(
      typed_paths: {
        "child" => CrystalClick::BinaryDataType.array(
          CrystalClick::BinaryDataType.nullable(inner_json)
        ),
      },
    )
    name = recursive_json.name

    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      name, w251_json_name_limits(max_depth: 5)
    ).should eq(recursive_json)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      name, w251_json_name_limits(max_depth: 4)
    ).should be_nil

    measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, measured)
      .should eq(recursive_json)
    exact_bytes = measured.wire_byte_count.to_i
    exact = CrystalClick::BinaryCodecBudget.new(w251_json_name_limits(max_bytes: exact_bytes))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, exact)
      .should eq(recursive_json)
    short = CrystalClick::BinaryCodecBudget.new(w251_json_name_limits(max_bytes: exact_bytes - 1))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(name, short)
      .should be_nil
  end

  it "does not let neutral JSON-name parsing widen the physical Count argument boundary" do
    json = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("JSON").not_nil!
    json.should eq(CrystalClick::BinaryDataType.json)

    # The Count argument name parser owns syntax only, but its separate
    # admission policy and nominal state owner must not inherit JSON merely
    # because the shared SQL grammar can now parse it.
    CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical("JSON").should eq(json)
    arguments = [
      json,
      CrystalClick::BinaryDataType.array(json),
      CrystalClick::BinaryDataType.tuple([
        json, CrystalClick::BinaryDataType.primitive("UInt8"),
      ] of CrystalClick::BinaryDataType),
    ] of CrystalClick::BinaryDataType
    arguments.each do |argument|
      CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(argument).should be_false
      error = expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateCountType.new(argument)
      end
      error.message.to_s.should eq("AggregateFunction(count) argument is outside the bounded canonical profile")
    end

    error = expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_count(json)
    end
    error.message.to_s.should eq("JSON is not admitted in AggregateFunction(count) arguments")
  end

  it "keeps exact V1/V2 frame consumption and error boundaries for truncated and trailing bytes" do
    type_name = "JSON(max_dynamic_types=1, max_dynamic_paths=2, a UInt8)"

    {1_u64, 2_u64}.each do |version|
      wire = w251_dynamic_json_complete_frame(w251_dynamic_json_prefix(version, type_name))
      truncated = wire[0, wire.size - 1]
      truncation = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicStructureCodec.decode(truncated)
      end
      truncation.message.to_s.should eq("binary codec input is truncated")

      trailing = Bytes.new(wire.size + 1) do |index|
        index == wire.size ? 0_u8 : wire[index]
      end
      excess = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::DynamicStructureCodec.decode(trailing)
      end
      excess.message.to_s.should eq("binary codec input has trailing bytes")
    end
  end
end
