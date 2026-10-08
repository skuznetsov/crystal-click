require "./spec_helper"

private W164_ADDED_CARRIERS = [
  {"UInt128", 0x05_u8, 16, [0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8]},
  {"Int128", 0x0b_u8, 16, [0xff_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0x80_u8]},
  {"UInt256", 0x06_u8, 32, [0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8, 0x11_u8, 0x33_u8, 0x55_u8, 0x77_u8, 0x99_u8, 0xbb_u8, 0xdd_u8, 0xff_u8, 0xee_u8, 0xcc_u8, 0xaa_u8, 0x88_u8, 0x66_u8, 0x44_u8, 0x22_u8, 0x80_u8]},
  {"Int256", 0x0c_u8, 32, [0xff_u8, 0xdd_u8, 0xbb_u8, 0x99_u8, 0x77_u8, 0x55_u8, 0x33_u8, 0x11_u8, 0x00_u8, 0x22_u8, 0x44_u8, 0x66_u8, 0x88_u8, 0xaa_u8, 0xcc_u8, 0xee_u8, 0x10_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8, 0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x80_u8]},
  {"BFloat16", 0x31_u8, 2, [0x81_u8, 0x7f_u8]},
]

private W164_ADDED_INTEGER_CARRIERS = [
  {"UInt128", 0x05_u8, 16, [0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8]},
  {"Int128", 0x0b_u8, 16, [0xff_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0x80_u8]},
  {"UInt256", 0x06_u8, 32, [0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8, 0x11_u8, 0x33_u8, 0x55_u8, 0x77_u8, 0x99_u8, 0xbb_u8, 0xdd_u8, 0xff_u8, 0xee_u8, 0xcc_u8, 0xaa_u8, 0x88_u8, 0x66_u8, 0x44_u8, 0x22_u8, 0x80_u8]},
  {"Int256", 0x0c_u8, 32, [0xff_u8, 0xdd_u8, 0xbb_u8, 0x99_u8, 0x77_u8, 0x55_u8, 0x33_u8, 0x11_u8, 0x00_u8, 0x22_u8, 0x44_u8, 0x66_u8, 0x88_u8, 0xaa_u8, 0xcc_u8, 0xee_u8, 0x10_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8, 0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x80_u8]},
]

private W164_ADDED_FUNCTIONS = [
  {"any", CrystalClick::BinarySimpleAggregateType::Function::Any, W164_ADDED_CARRIERS},
  {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast, W164_ADDED_CARRIERS},
  {"min", CrystalClick::BinarySimpleAggregateType::Function::Min, W164_ADDED_CARRIERS},
  {"max", CrystalClick::BinarySimpleAggregateType::Function::Max, W164_ADDED_CARRIERS},
  {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, W164_ADDED_CARRIERS},
  {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, W164_ADDED_INTEGER_CARRIERS},
  {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd, W164_ADDED_INTEGER_CARRIERS},
  {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr, W164_ADDED_INTEGER_CARRIERS},
  {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor, W164_ADDED_INTEGER_CARRIERS},
]

private def w164_literal_descriptor(
  function_name : String,
  storage_tag : UInt8,
  nullable : Bool = false,
  nullable_child_depth : Int32 = 0,
) : Array(UInt8)
  bytes = [] of UInt8
  bytes << 0x23_u8 if nullable # Nullable wraps the complete aggregate node.
  bytes << 0x2e_u8             # SimpleAggregateFunction descriptor tag.
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # zero Field parameters
  bytes << 1_u8 # one recursive child descriptor
  nullable_child_depth.times { bytes << 0x23_u8 }
  bytes << storage_tag
  bytes
end

private def w164_bytes(values : Array(UInt8)) : Bytes
  Bytes.new(values.size) { |index| values[index] }
end

describe "W164 SimpleAggregateFunction wide numeric carrier descriptors" do
  it "round-trips the literal 41 newly stock-qualified pairs and outer Nullable forms" do
    pair_count = 0

    W164_ADDED_FUNCTIONS.each do |function_name, function, carriers|
      carriers.each do |storage_name, storage_tag, width, _raw|
        pair_count += 1
        scalar_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
        scalar_wire = w164_literal_descriptor(function_name, storage_tag)
        descriptor = CrystalClick::BinarySimpleAggregateType.parse(scalar_name).not_nil!
        descriptor.function.should eq(function)
        descriptor.storage_type_name.should eq(storage_name)
        descriptor.type_name.should eq(scalar_name)
        descriptor.name_byte_size.should eq(scalar_name.bytesize.to_u64)

        scalar = CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(scalar_wire))
        scalar.name.should eq(scalar_name)
        scalar.simple_aggregate_type.not_nil!.function.should eq(function)
        scalar.child_count.should eq(1)
        scalar.child_at(0).should eq(CrystalClick::BinaryDataType.primitive(storage_name))
        CrystalClick::BinaryDataTypeCodec.encode(scalar).to_a.should eq(scalar_wire)
        CrystalClick::BinaryDataType.simple_aggregate(
          function,
          CrystalClick::BinaryDataType.primitive(storage_name)
        ).should eq(scalar)

        column_type = CrystalClick::SimpleAggregateColumnType.parse(scalar_name).not_nil!
        column_type.function.should eq(function)
        column_type.storage_type_name.should eq(storage_name)
        column_type.raw_width.should eq(width)
        column_type.nullable?.should be_false
        column_type.type_name.should eq(scalar_name)

        nullable_name = "Nullable(#{scalar_name})"
        nullable_wire = w164_literal_descriptor(function_name, storage_tag, nullable: true)
        nullable = CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(nullable_wire))
        nullable.name.should eq(nullable_name)
        nullable.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
        nullable.child_at(0).should eq(scalar)
        CrystalClick::BinaryDataTypeCodec.encode(nullable).to_a.should eq(nullable_wire)

        nullable_column_type = CrystalClick::SimpleAggregateColumnType.parse(nullable_name).not_nil!
        nullable_column_type.function.should eq(function)
        nullable_column_type.storage_type_name.should eq(storage_name)
        nullable_column_type.raw_width.should eq(width)
        nullable_column_type.nullable?.should be_true
        nullable_column_type.type_name.should eq(nullable_name)
      end
    end

    pair_count.should eq(41)
  end

  it "rejects BFloat16 widening and integer-only aggregates while preserving wrapper boundaries" do
    bfloat_storage = CrystalClick::BinaryDataType.primitive("BFloat16")
    rejected_pairs = [
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor},
    ]

    rejected_pairs.each do |function_name, function|
      wire = w164_literal_descriptor(function_name, 0x31_u8)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(wire))
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(function, bfloat_storage)
      end
      CrystalClick::BinarySimpleAggregateType.parse(
        "SimpleAggregateFunction(#{function_name}, BFloat16)"
      ).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(
        "SimpleAggregateFunction(#{function_name}, BFloat16)"
      ).should be_nil
    end

    # The single child Nullable is retained as part of the exact aggregate
    # identity; the legacy column model still only represents outer Nullable.
    valid_bfloat = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Any,
      bfloat_storage
    )
    outer_nullable = CrystalClick::BinaryDataType.nullable(valid_bfloat)
    outer_nullable.name.should eq("Nullable(SimpleAggregateFunction(any, BFloat16))")
    CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(
      w164_literal_descriptor("any", 0x31_u8, nullable: true)
    )).should eq(outer_nullable)

    nullable_bfloat = CrystalClick::BinaryDataType.nullable(bfloat_storage)
    nullable_name = "SimpleAggregateFunction(any, Nullable(BFloat16))"
    nullable_wire = w164_literal_descriptor("any", 0x31_u8, nullable_child_depth: 1)
    inner_nullable = CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(nullable_wire))
    inner_nullable.name.should eq(nullable_name)
    inner_nullable.child_at(0).should eq(nullable_bfloat)
    inner_nullable.should eq(CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Any,
      nullable_bfloat
    ))
    CrystalClick::BinaryDataTypeCodec.encode(inner_nullable).to_a.should eq(nullable_wire)
    parsed_inner_nullable = CrystalClick::BinarySimpleAggregateType.parse(nullable_name).not_nil!
    parsed_inner_nullable.type_name.should eq(nullable_name)
    parsed_inner_nullable.storage_type_name.should eq("Nullable(BFloat16)")
    CrystalClick::SimpleAggregateColumnType.parse(nullable_name).should be_nil

    # The nested Nullable factory rejects this descriptor before the SAF
    # constructor can observe it; wire and SQL parser controls follow below.
    expect_raises(ArgumentError) do
      double_nullable_bfloat = CrystalClick::BinaryDataType.nullable(nullable_bfloat)
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Any,
        double_nullable_bfloat
      )
    end
    double_nullable_name = "SimpleAggregateFunction(any, Nullable(Nullable(BFloat16)))"
    CrystalClick::BinarySimpleAggregateType.parse(double_nullable_name).should be_nil
    CrystalClick::SimpleAggregateColumnType.parse(double_nullable_name).should be_nil
    double_nullable_wire = w164_literal_descriptor("any", 0x31_u8, nullable_child_depth: 2)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(double_nullable_wire))
    end

    [
      {CrystalClick::BinaryDataType.low_cardinality(bfloat_storage), [0x26_u8, 0x31_u8]},
      {CrystalClick::BinaryDataType.array(bfloat_storage), [0x1e_u8, 0x31_u8]},
    ].each do |wrapped_child, child_wire|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(
          CrystalClick::BinarySimpleAggregateType::Function::Any,
          wrapped_child
        )
      end
      aggregate_wire = [0x2e_u8, 3_u8] + "any".to_slice.to_a + [0_u8, 1_u8] + child_wire
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w164_bytes(aggregate_wire))
      end
    end
  end

  it "preserves signedness, same-width carrier, and function identity" do
    same_width_pairs = [
      {"UInt128", "Int128", 0x05_u8, 0x0b_u8},
      {"UInt256", "Int256", 0x06_u8, 0x0c_u8},
      {"UInt16", "BFloat16", 0x02_u8, 0x31_u8},
    ]
    min = CrystalClick::BinarySimpleAggregateType::Function::Min

    same_width_pairs.each do |left_name, right_name, left_tag, right_tag|
      left_sql_name = "SimpleAggregateFunction(min, #{left_name})"
      right_sql_name = "SimpleAggregateFunction(min, #{right_name})"
      left = CrystalClick::BinarySimpleAggregateType.parse(left_sql_name).not_nil!
      right = CrystalClick::BinarySimpleAggregateType.parse(right_sql_name).not_nil!
      left.type_name.should eq(left_sql_name)
      right.type_name.should eq(right_sql_name)
      left.should_not eq(right)
      {left => "left", right => "right"}.size.should eq(2)

      CrystalClick::BinaryDataTypeCodec.decode(
        w164_bytes(w164_literal_descriptor("min", left_tag))
      ).name.should eq(left_sql_name)
      CrystalClick::BinaryDataTypeCodec.decode(
        w164_bytes(w164_literal_descriptor("min", right_tag))
      ).name.should eq(right_sql_name)

      left_type = CrystalClick::BinaryDataType.simple_aggregate(
        min,
        CrystalClick::BinaryDataType.primitive(left_name)
      )
      right_type = CrystalClick::BinaryDataType.simple_aggregate(
        min,
        CrystalClick::BinaryDataType.primitive(right_name)
      )
      left_type.should_not eq(right_type)
      {left_type => "left", right_type => "right"}.size.should eq(2)
    end

    minimum = CrystalClick::BinaryDataType.simple_aggregate(
      min,
      CrystalClick::BinaryDataType.primitive("UInt128")
    )
    maximum = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Max,
      CrystalClick::BinaryDataType.primitive("UInt128")
    )
    minimum.should_not eq(maximum)
    minimum.name.should eq("SimpleAggregateFunction(min, UInt128)")
    maximum.name.should eq("SimpleAggregateFunction(max, UInt128)")
  end

  it "preserves all literal wide-integer and BFloat16 bytes through value, bulk, and physical paths" do
    W164_ADDED_CARRIERS.each do |storage_name, storage_tag, width, raw|
      raw.size.should eq(width)
      child_type = CrystalClick::BinaryDataType.primitive(storage_name)
      aggregate_type = CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        child_type
      )
      column_type = CrystalClick::SimpleAggregateColumnType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        storage_name
      )
      column_type.storage_type_name.should eq(storage_name)
      column_type.raw_width.should eq(width)

      # The test-authored child bytes must survive the nominal aggregate wrapper
      # without signedness conversion, floating-point conversion, or narrowing.
      child_value = CrystalClick::BinaryValueCodec.decode_value(child_type, w164_bytes(raw))
      child_value.bytes.to_a.should eq(raw)
      aggregate_value = CrystalClick::BinaryValue.simple_aggregate(aggregate_type, child_value)
      CrystalClick::BinaryValueCodec.encode_value(aggregate_value).to_a.should eq(raw)
      decoded_value = CrystalClick::BinaryValueCodec.decode_value(aggregate_type, w164_bytes(raw))
      decoded_value.type.name.should eq("SimpleAggregateFunction(min, #{storage_name})")
      decoded_value.child_at(0).bytes.to_a.should eq(raw)

      envelope_wire = w164_literal_descriptor("min", storage_tag) + raw
      envelope = CrystalClick::BinaryValueCodec.decode(w164_bytes(envelope_wire))
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
    end
  end

  it "keeps the longest new carrier SQL name inside exact byte budgets" do
    sql_name = "Nullable(SimpleAggregateFunction(sumWithOverflow, BFloat16))"
    sql_name.bytesize.should be <= CrystalClick::SimpleAggregateColumnType::MAX_TYPE_BYTES
    plan = CrystalClick::SimpleAggregateColumnType.parse(sql_name).not_nil!
    plan.type_name.should eq(sql_name)

    type = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow,
        CrystalClick::BinaryDataType.primitive("BFloat16")
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
