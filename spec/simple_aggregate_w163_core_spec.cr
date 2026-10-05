require "./spec_helper"

private W163_NUMERIC_CARRIERS = [
  {"UInt8", 0x01_u8},
  {"UInt16", 0x02_u8},
  {"UInt32", 0x03_u8},
  {"UInt64", 0x04_u8},
  {"Int8", 0x07_u8},
  {"Int16", 0x08_u8},
  {"Int32", 0x09_u8},
  {"Int64", 0x0a_u8},
  {"Float32", 0x0d_u8},
  {"Float64", 0x0e_u8},
]

private W163_INTEGER_CARRIERS = [
  {"UInt8", 0x01_u8},
  {"UInt16", 0x02_u8},
  {"UInt32", 0x03_u8},
  {"UInt64", 0x04_u8},
  {"Int8", 0x07_u8},
  {"Int16", 0x08_u8},
  {"Int32", 0x09_u8},
  {"Int64", 0x0a_u8},
]

private W163_SUM_CARRIERS = [
  {"UInt64", 0x04_u8},
  {"Int64", 0x0a_u8},
  {"Float64", 0x0e_u8},
]

private W163_ELIGIBLE_FUNCTIONS = [
  {"any", CrystalClick::BinarySimpleAggregateType::Function::Any, W163_NUMERIC_CARRIERS},
  {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast, W163_NUMERIC_CARRIERS},
  {"min", CrystalClick::BinarySimpleAggregateType::Function::Min, W163_NUMERIC_CARRIERS},
  {"max", CrystalClick::BinarySimpleAggregateType::Function::Max, W163_NUMERIC_CARRIERS},
  {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, W163_NUMERIC_CARRIERS},
  {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd, W163_INTEGER_CARRIERS},
  {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr, W163_INTEGER_CARRIERS},
  {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor, W163_INTEGER_CARRIERS},
  {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, W163_SUM_CARRIERS},
]

private def w163_literal_descriptor(
  function_name : String,
  storage_tag : UInt8,
  nullable : Bool = false,
) : Array(UInt8)
  bytes = [] of UInt8
  bytes << 0x23_u8 if nullable # BinaryTypeIndex::Nullable wraps the full aggregate node.
  bytes << 0x2e_u8             # BinaryTypeIndex::SimpleAggregateFunction
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # zero Field parameters
  bytes << 1_u8 # one recursive child descriptor
  bytes << storage_tag
  bytes
end

private def w163_bytes(values : Array(UInt8)) : Bytes
  Bytes.new(values.size) { |index| values[index] }
end

private def w163_literal_storage_bytes(storage_name : String) : Array(UInt8)
  case storage_name
  when "UInt8"   then [0xfe_u8]
  when "UInt16"  then [0x34_u8, 0x12_u8]
  when "UInt32"  then [0x78_u8, 0x56_u8, 0x34_u8, 0x12_u8]
  when "UInt64"  then [0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x01_u8]
  when "Int8"    then [0xfe_u8]
  when "Int16"   then [0xcc_u8, 0xed_u8]
  when "Int32"   then [0x88_u8, 0xa9_u8, 0xcb_u8, 0xed_u8]
  when "Int64"   then [0x11_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8]
  when "Float32" then [0x00_u8, 0x00_u8, 0xc0_u8, 0x3f_u8]
  when "Float64" then [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x02_u8, 0xc0_u8]
  else
    raise ArgumentError.new("unrecognized W163 test carrier")
  end
end

describe "W163 SimpleAggregateFunction numeric carrier descriptors" do
  it "round-trips literal scalar and outer-Nullable descriptors for all 77 stock-qualified pairs" do
    pair_count = 0

    W163_ELIGIBLE_FUNCTIONS.each do |function_name, function, carriers|
      carriers.each do |storage_name, storage_tag|
        pair_count += 1
        scalar_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
        scalar_wire = w163_literal_descriptor(function_name, storage_tag)
        descriptor = CrystalClick::BinarySimpleAggregateType.parse(scalar_name).not_nil!
        descriptor.function.should eq(function)
        descriptor.type_name.should eq(scalar_name)
        descriptor.name_byte_size.should eq(scalar_name.bytesize.to_u64)
        scalar = CrystalClick::BinaryDataTypeCodec.decode(w163_bytes(scalar_wire))

        scalar.name.should eq(scalar_name)
        scalar.simple_aggregate_type.not_nil!.function.should eq(function)
        scalar.child_count.should eq(1)
        scalar.child_at(0).should eq(CrystalClick::BinaryDataType.primitive(storage_name))
        CrystalClick::BinaryDataTypeCodec.encode(scalar).to_a.should eq(scalar_wire)

        column_type = CrystalClick::SimpleAggregateColumnType.parse(scalar_name).not_nil!
        column_type.function.should eq(function)
        column_type.nullable?.should be_false
        column_type.type_name.should eq(scalar_name)

        nullable_name = "Nullable(#{scalar_name})"
        nullable_wire = w163_literal_descriptor(function_name, storage_tag, nullable: true)
        nullable = CrystalClick::BinaryDataTypeCodec.decode(w163_bytes(nullable_wire))

        nullable.name.should eq(nullable_name)
        nullable.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
        nullable.child_at(0).should eq(scalar)
        CrystalClick::BinaryDataTypeCodec.encode(nullable).to_a.should eq(nullable_wire)

        nullable_column_type = CrystalClick::SimpleAggregateColumnType.parse(nullable_name).not_nil!
        nullable_column_type.function.should eq(function)
        nullable_column_type.nullable?.should be_true
        nullable_column_type.type_name.should eq(nullable_name)
      end
    end

    pair_count.should eq(77)
  end

  it "rejects stock-ineligible function/carrier pairs without broadening wrappers" do
    ineligible_pairs = [
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "UInt8", 0x01_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "UInt16", 0x02_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "UInt32", 0x03_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "Int8", 0x07_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "Int16", 0x08_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "Int32", 0x09_u8},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, "Float32", 0x0d_u8},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd, "Float32", 0x0d_u8},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd, "Float64", 0x0e_u8},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr, "Float32", 0x0d_u8},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr, "Float64", 0x0e_u8},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor, "Float32", 0x0d_u8},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor, "Float64", 0x0e_u8},
    ]

    ineligible_pairs.each do |function_name, function, storage_name, storage_tag|
      wire = w163_literal_descriptor(function_name, storage_tag)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w163_bytes(wire))
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(
          function,
          CrystalClick::BinaryDataType.primitive(storage_name)
        )
      end
      CrystalClick::BinarySimpleAggregateType.parse(
        "SimpleAggregateFunction(#{function_name}, #{storage_name})"
      ).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(
        "SimpleAggregateFunction(#{function_name}, #{storage_name})"
      ).should be_nil
    end

    [
      [0x23_u8, 0x04_u8], # Nullable(UInt64) is not a child storage carrier.
      [0x26_u8, 0x04_u8], # LowCardinality(UInt64) is not a child storage carrier.
    ].each do |child_wire|
      wire = [0x2e_u8, 3_u8] + "min".to_slice.to_a + [0_u8, 1_u8] + child_wire
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w163_bytes(wire))
      end
    end

    function = CrystalClick::BinarySimpleAggregateType::Function::Min
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        function,
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64"))
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        function,
        CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("UInt64"))
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        function,
        CrystalClick::BinaryDataType.tuple([
          CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64")),
        ] of CrystalClick::BinaryDataType)
      )
    end
  end

  it "preserves function and same-width child identity in SQL names and type equality" do
    same_width_pairs = [
      {"UInt8", "Int8"},
      {"UInt16", "Int16"},
      {"UInt32", "Float32"},
      {"Int64", "Float64"},
    ]
    function = CrystalClick::BinarySimpleAggregateType::Function::Min

    same_width_pairs.each do |left_name, right_name|
      left_sql_name = "SimpleAggregateFunction(min, #{left_name})"
      right_sql_name = "SimpleAggregateFunction(min, #{right_name})"
      left_plan = CrystalClick::SimpleAggregateColumnType.parse(left_sql_name).not_nil!
      right_plan = CrystalClick::SimpleAggregateColumnType.parse(right_sql_name).not_nil!
      left_plan.type_name.should eq(left_sql_name)
      right_plan.type_name.should eq(right_sql_name)
      left_plan.should_not eq(right_plan)
    end

    uint8_descriptor = CrystalClick::BinarySimpleAggregateType.new(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      "UInt8"
    )
    int8_descriptor = CrystalClick::BinarySimpleAggregateType.new(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      "Int8"
    )
    uint8_descriptor.should_not eq(int8_descriptor)
    {uint8_descriptor => "unsigned", int8_descriptor => "signed"}.size.should eq(2)
    CrystalClick::BinarySimpleAggregateType.from_name("min", "Int8").not_nil!.type_name.should eq(
      "SimpleAggregateFunction(min, Int8)"
    )
    CrystalClick::BinarySimpleAggregateType.from_name("sum", "UInt8").should be_nil

    signed = CrystalClick::BinaryDataType.simple_aggregate(
      function,
      CrystalClick::BinaryDataType.primitive("Int8")
    )
    unsigned = CrystalClick::BinaryDataType.simple_aggregate(
      function,
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    signed.name.should eq("SimpleAggregateFunction(min, Int8)")
    unsigned.name.should eq("SimpleAggregateFunction(min, UInt8)")
    signed.should_not eq(unsigned)
    {signed => "signed", unsigned => "unsigned"}.size.should eq(2)

    other_function = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Max,
      CrystalClick::BinaryDataType.primitive("Int8")
    )
    signed.should_not eq(other_function)
    other_function.name.should eq("SimpleAggregateFunction(max, Int8)")

    source_storage_name = String.new("Int8".to_slice)
    owned_identity = CrystalClick::BinarySimpleAggregateType.new(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      source_storage_name
    )
    source_storage_name.to_unsafe[0] = 'U'.ord.to_u8
    owned_identity.type_name.should eq("SimpleAggregateFunction(min, Int8)")
    storage_snapshot = owned_identity.storage_type_name
    storage_snapshot.to_unsafe[0] = 'U'.ord.to_u8
    owned_identity.type_name.should eq("SimpleAggregateFunction(min, Int8)")
  end

  it "preserves literal stored bytes through scalar value envelopes, bulk lanes, and physical roles" do
    W163_NUMERIC_CARRIERS.each do |storage_name, storage_tag|
      raw = w163_literal_storage_bytes(storage_name)
      width = raw.size
      child_type = CrystalClick::BinaryDataType.primitive(storage_name)
      aggregate_type = CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        child_type
      )
      value_type = CrystalClick::SimpleAggregateColumnType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        storage_name
      )
      value_type.storage_type_name.should eq(storage_name)
      value_type.raw_width.should eq(width)
      nullable_column_type = CrystalClick::SimpleAggregateColumnType.nullable_simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        storage_name
      )
      nullable_column_type.type_name.should eq("Nullable(SimpleAggregateFunction(min, #{storage_name}))")
      nullable_column_type.raw_width.should eq(width)
      value_type.with_nullable(true).should eq(nullable_column_type)

      # Decode authored child bytes independently, then wrap them nominally;
      # neither path is allowed to reinterpret or aggregate the payload.
      child_value = CrystalClick::BinaryValueCodec.decode_value(child_type, w163_bytes(raw))
      child_value.bytes.to_a.should eq(raw)
      aggregate_value = CrystalClick::BinaryValue.simple_aggregate(aggregate_type, child_value)
      CrystalClick::BinaryValueCodec.encode_value(aggregate_value).to_a.should eq(raw)
      decoded_value = CrystalClick::BinaryValueCodec.decode_value(aggregate_type, w163_bytes(raw))
      decoded_value.type.name.should eq("SimpleAggregateFunction(min, #{storage_name})")
      decoded_value.child_at(0).bytes.to_a.should eq(raw)

      envelope_wire = w163_literal_descriptor("min", storage_tag) + raw
      envelope = CrystalClick::BinaryValueCodec.decode(w163_bytes(envelope_wire))
      envelope.type.should eq(aggregate_type)
      envelope.child_at(0).bytes.to_a.should eq(raw)
      CrystalClick::BinaryValueCodec.encode(aggregate_value).to_a.should eq(envelope_wire)

      scalar_bulk = CrystalClick::BinaryBulkCodec.encode(
        aggregate_type,
        [[aggregate_value] of CrystalClick::BinaryValue]
      )
      scalar_bulk.roles.should eq(["root.data"] of String)
      scalar_bulk.stream("root.data").bytes.to_a.should eq(raw)
      scalar_decoded = CrystalClick::BinaryBulkCodec.decode(aggregate_type, scalar_bulk, [1_u64])
      scalar_decoded[0][0].child_at(0).bytes.to_a.should eq(raw)
      CrystalClick::BinaryBulkPhysicalPlan.new(aggregate_type, "v").stream_names.should eq({
        "root.data" => "v",
      })

      nullable_type = CrystalClick::BinaryDataType.nullable(aggregate_type)
      nullable_values = [
        CrystalClick::BinaryValue.nullable(nullable_type, aggregate_value),
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, aggregate_value),
      ] of CrystalClick::BinaryValue
      nullable_bulk = CrystalClick::BinaryBulkCodec.encode(nullable_type, [nullable_values])
      nullable_bulk.roles.should eq(["root.nested.data", "root.nulls"] of String)
      nullable_bulk.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
      nested_expected = raw.dup
      width.times { nested_expected << 0_u8 }
      nested_expected.concat(raw)
      nullable_bulk.stream("root.nested.data").bytes.to_a.should eq(nested_expected)
      nullable_decoded = CrystalClick::BinaryBulkCodec.decode(nullable_type, nullable_bulk, [3_u64])
      nullable_decoded[0][0].child_at(0).child_at(0).bytes.to_a.should eq(raw)
      nullable_decoded[0][1].is_null?.should be_true
      nullable_decoded[0][2].child_at(0).child_at(0).bytes.to_a.should eq(raw)
      CrystalClick::BinaryBulkPhysicalPlan.new(nullable_type, "v").stream_names.should eq({
        "root.nested.data" => "v",
        "root.nulls"       => "v.null",
      })

      envelope_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, envelope_wire.size)
      CrystalClick::BinaryValueCodec.encode(aggregate_value, envelope_limits).to_a.should eq(envelope_wire)
      too_small_envelope = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, envelope_wire.size - 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode(aggregate_value, too_small_envelope)
      end

      scalar_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, width)
      CrystalClick::BinaryBulkCodec.encode(
        aggregate_type,
        [[aggregate_value] of CrystalClick::BinaryValue],
        scalar_limits
      ).stream("root.data").bytes.to_a.should eq(raw)
      too_small_scalar = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, width - 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(
          aggregate_type,
          [[aggregate_value] of CrystalClick::BinaryValue],
          too_small_scalar
        )
      end

      nullable_bytes = 3 * (width + 1)
      nullable_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, nullable_bytes)
      nullable_limited = CrystalClick::BinaryBulkCodec.encode(nullable_type, [nullable_values], nullable_limits)
      nullable_limited.stream("root.nested.data").bytes.to_a.should eq(nested_expected)
      too_small_nullable = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, nullable_bytes - 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(nullable_type, [nullable_values], too_small_nullable)
      end
    end
  end

  it "maps only the ten qualified numeric accessor classes to storage identity" do
    CrystalClick::SimpleAggregateColumnType.storage_name(UInt8).should eq("UInt8")
    CrystalClick::SimpleAggregateColumnType.storage_name(UInt16).should eq("UInt16")
    CrystalClick::SimpleAggregateColumnType.storage_name(UInt32).should eq("UInt32")
    CrystalClick::SimpleAggregateColumnType.storage_name(UInt64).should eq("UInt64")
    CrystalClick::SimpleAggregateColumnType.storage_name(Int8).should eq("Int8")
    CrystalClick::SimpleAggregateColumnType.storage_name(Int16).should eq("Int16")
    CrystalClick::SimpleAggregateColumnType.storage_name(Int32).should eq("Int32")
    CrystalClick::SimpleAggregateColumnType.storage_name(Int64).should eq("Int64")
    CrystalClick::SimpleAggregateColumnType.storage_name(Float32).should eq("Float32")
    CrystalClick::SimpleAggregateColumnType.storage_name(Float64).should eq("Float64")
    expect_raises(ArgumentError) do
      CrystalClick::SimpleAggregateColumnType.storage_name(UInt128)
    end
  end

  it "charges the longest nullable carrier name at exact and one-short byte budgets" do
    sql_name = "Nullable(SimpleAggregateFunction(sumWithOverflow, Float64))"
    sql_name.bytesize.should be <= CrystalClick::SimpleAggregateColumnType::MAX_TYPE_BYTES
    plan = CrystalClick::SimpleAggregateColumnType.parse(sql_name).not_nil!
    plan.type_name.should eq(sql_name)

    type = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow,
        CrystalClick::BinaryDataType.primitive("Float64")
      )
    )
    type.name.should eq(sql_name)
    measured = CrystalClick::BinaryTypeNameBudget.measure(
      type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    )

    exact_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, measured[1].to_i)
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::BinaryTypeNameBudget.materialize(type, exact_budget, measured).should eq(sql_name)

    short_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, measured[1].to_i - 1)
    short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, short_budget, measured)
    end
  end
end
