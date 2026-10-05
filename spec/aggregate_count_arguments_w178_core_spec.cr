require "./spec_helper"

private def w178_count_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      result[offset] = byte
      offset += 1
    end
  end
  result
end

describe "W178 AggregateFunction(count) argument descriptors" do
  it "retains canonical scalar and recursive descriptors as nominal metadata leaves" do
    primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }
    arguments = [
      primitive.call("UInt8"),
      primitive.call("UInt128"),
      primitive.call("String"),
      primitive.call("Nothing"),
      CrystalClick::BinaryDataType.fixed_string(3),
      CrystalClick::BinaryDataType.decimal(32, 9, 2),
      CrystalClick::BinaryDataType.datetime64(3, "America/New_York"),
      CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Nanosecond),
      CrystalClick::BinaryDataType.enum8([
        {"comma, label", 1_i16}, {"negative", -1_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry),
      CrystalClick::BinaryDataType.nullable(primitive.call("String")),
      CrystalClick::BinaryDataType.array(
        CrystalClick::BinaryDataType.nullable(primitive.call("UInt64"))
      ),
      CrystalClick::BinaryDataType.map(
        primitive.call("String"),
        CrystalClick::BinaryDataType.tuple(
          [primitive.call("UInt8"), CrystalClick::BinaryDataType.decimal(64, 18, 3)] of CrystalClick::BinaryDataType,
          ["id", "amount"] of String,
        ),
      ),
      CrystalClick::BinaryDataType.nested(
        [primitive.call("UInt8"), primitive.call("String")] of CrystalClick::BinaryDataType,
        ["id", "payload"],
      ),
      CrystalClick::BinaryDataType.low_cardinality(primitive.call("String")),
      CrystalClick::BinaryDataType.variant([
        primitive.call("Int8"), primitive.call("UInt8"),
      ] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.dynamic(7),
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        CrystalClick::BinaryDataType.decimal(32, 9, 2),
      ),
    ] of CrystalClick::BinaryDataType

    arguments.each do |argument|
      parsed = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(argument.name)
      parsed.should eq(argument)

      count = CrystalClick::BinaryDataType.aggregate_count(argument)
      count.name.should eq("AggregateFunction(count, #{argument.name})")
      count.child_count.should eq(0)
      count.children.should be_empty
      count.aggregate_count_argument_type.should eq(argument)
      CrystalClick::BinaryAggregateCountType.new(argument).argument_type.should eq(argument)

      values = Hash(CrystalClick::BinaryDataType, String).new
      values[count] = argument.name
      values[CrystalClick::BinaryDataType.aggregate_count(argument)].should eq(argument.name)
    end
  end

  it "round-trips independent exact literals for the four admission discriminators" do
    primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }
    cases = [
      {primitive.call("UInt8"), "AggregateFunction(count, UInt8)", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x01]},
      {primitive.call("String"), "AggregateFunction(count, String)", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x15]},
      {CrystalClick::BinaryDataType.nullable(primitive.call("String")), "AggregateFunction(count, Nullable(String))", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x23, 0x15]},
      {CrystalClick::BinaryDataType.array(primitive.call("UInt64")), "AggregateFunction(count, Array(UInt64))", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x1e, 0x04]},
    ]

    cases.each do |argument, name, literal|
      type = CrystalClick::BinaryDataType.aggregate_count(argument)
      type.name.should eq(name)
      type.aggregate_count_argument_type.should eq(argument)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(literal)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(literal)
      decoded.should eq(type)
      decoded.aggregate_count_argument_type.should eq(argument)
      CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(literal)
    end
  end

  it "owns immutable full argument identity rather than caller arrays or field names" do
    children = [
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("String"),
    ]
    names = ["id", "payload"]
    argument = CrystalClick::BinaryDataType.tuple(children, names)
    count = CrystalClick::BinaryDataType.aggregate_count(argument)
    original_hash = count.hash

    children[0] = CrystalClick::BinaryDataType.primitive("UInt64")
    names[0] = "changed"

    count.aggregate_count_argument_type.should eq(argument)
    count.aggregate_count_argument_type.not_nil!.field_names.should eq(["id", "payload"])
    count.hash.should eq(original_hash)
    count.name.should eq("AggregateFunction(count, Tuple(id UInt8, payload String))")
  end

  it "keeps the argument nominal while scalar, envelope, and bulk values use Count's leaf lane" do
    argument = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
    type = CrystalClick::BinaryDataType.aggregate_count(argument)
    value = CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
    value.type.should eq(type)
    value.count_state.should eq(128_u64)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[0x80_u8, 0x01])

    envelope = w178_count_concat([
      CrystalClick::BinaryDataTypeCodec.encode(type),
      Bytes[0x80_u8, 0x01],
    ] of Bytes)
    CrystalClick::BinaryValueCodec.encode(value).should eq(envelope)
    decoded = CrystalClick::BinaryValueCodec.decode(envelope)
    decoded.type.should eq(type)
    decoded.count_state.should eq(128_u64)

    values_by_mark = [
      [
        CrystalClick::BinaryValue.aggregate_count_state(type, 0_u64),
        CrystalClick::BinaryValue.aggregate_count_state(type, 127_u64),
      ] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)] of CrystalClick::BinaryValue,
    ]
    streams = CrystalClick::BinaryBulkCodec.encode(type, values_by_mark)
    streams.roles.should eq(["root.data"])
    lane = streams.stream("root.data")
    lane.bytes.should eq(Bytes[0x00_u8, 0x7f, 0x80, 0x01])
    lane.offsets.should eq([0_u64, 2_u64, 4_u64])

    selected = CrystalClick::BinaryBulkCodec.decode(
      type,
      streams,
      [2_u64, 1_u64],
      first_mark: 1,
      mark_count: 1,
    )
    selected.map(&.map(&.count_state)).should eq([[128_u64]])
  end

  it "keeps transformed identities, recursive Decimal aliases, and metadata budgets closed" do
    primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }
    nothing = primitive.call("Nothing")
    bare_nothing_count = CrystalClick::BinaryDataType.aggregate_count(nothing)
    bare_nothing_count.name.should eq("AggregateFunction(count, Nothing)")

    nullable_nothing = CrystalClick::BinaryDataType.nullable(nothing)
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(nullable_nothing).should be_false
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(nullable_nothing) }
    expect_raises(ArgumentError) { CrystalClick::BinaryAggregateCountType.new(nullable_nothing) }

    count = CrystalClick::BinaryDataType.aggregate_count
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(count).should be_false
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryAggregateCountType.new(count) }

    canonical_decimal = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    same_name_other_width = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    canonical_decimal.name.should eq(same_name_other_width.name)
    CrystalClick::BinaryDataType.aggregate_count(canonical_decimal).aggregate_count_argument_type.should eq(canonical_decimal)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(same_name_other_width) }
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.array(same_name_other_width))
    end

    recursive = CrystalClick::BinaryDataType.array(primitive.call("UInt8"))
    tight_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 16, max_elements: 16, max_bytes: 1024)
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(recursive, tight_limits).should be_false
    bounded_count = CrystalClick::BinaryDataType.aggregate_count(recursive)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        bounded_count,
        CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 16, max_elements: 16, max_bytes: 1024),
      )
    end
  end

  it "charges the Count root and argument edge to recursive policy limits" do
    primitive = CrystalClick::BinaryDataType.primitive("UInt8")

    depth_64_argument = primitive
    63.times { depth_64_argument = CrystalClick::BinaryDataType.array(depth_64_argument) }
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(depth_64_argument).should be_false

    depth_63_argument = primitive
    62.times { depth_63_argument = CrystalClick::BinaryDataType.array(depth_63_argument) }
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(depth_63_argument).should be_true

    full_depth_count = CrystalClick::BinaryDataType.aggregate_count(depth_63_argument)
    encoded = CrystalClick::BinaryDataTypeCodec.encode(full_depth_count)
    CrystalClick::BinaryDataTypeCodec.decode(encoded).should eq(full_depth_count)
    plan = CrystalClick::WideAggregateCountStoragePlan.for_type(full_depth_count)
    plan.should_not be_nil
    plan.not_nil!.data_type.should eq(full_depth_count)

    one_node_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 1, max_elements: 1, max_bytes: 1024)
    two_node_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 2, max_elements: 1, max_bytes: 1024)
    no_metadata_edge_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 2, max_elements: 0, max_bytes: 1024)

    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(primitive, one_node_limits).should be_false
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(primitive, two_node_limits).should be_true
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(primitive, no_metadata_edge_limits).should be_false
  end

  it "preflights the full Count shell name and allocation bound before rendering metadata" do
    argument = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count(argument)
    name_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    bounds = CrystalClick::BinaryTypeNameBudget.measure(count, name_budget)
    bounds.should eq({42_u64, 116_u64})

    below_bound = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 2,
      max_elements: 1,
      max_bytes: (bounds[1] - 1_u64).to_i,
    )
    exact_bound = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 2,
      max_elements: 1,
      max_bytes: bounds[1].to_i,
    )

    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(argument, below_bound).should be_false
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(argument, exact_bound).should be_true
  end

  it "budgets the no-argument Count root and shell name under caller limits" do
    no_depth = CrystalClick::BinaryCodecLimits.new(max_depth: 0, max_nodes: 1, max_elements: 0, max_bytes: 48)
    no_root_node = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 0, max_elements: 0, max_bytes: 48)
    short_name_budget = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 47)
    exact_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 48)

    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(nil, no_depth).should be_false
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(nil, no_root_node).should be_false
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(nil, short_name_budget).should be_false
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(nil, exact_limits).should be_true
  end
end
