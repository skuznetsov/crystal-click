require "./spec_helper"

private def w169_try_simple_aggregate(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  storage_type : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  begin
    CrystalClick::BinaryDataType.simple_aggregate(function, storage_type)
  rescue ex : ArgumentError
    nil
  end
end

private def w169_decimal_child_tag(width_bits : Int) : UInt8
  case width_bits
  when  32 then CrystalClick::BinaryDataType::TAG_DECIMAL32
  when  64 then CrystalClick::BinaryDataType::TAG_DECIMAL64
  when 128 then CrystalClick::BinaryDataType::TAG_DECIMAL128
  when 256 then CrystalClick::BinaryDataType::TAG_DECIMAL256
  else
    raise ArgumentError.new("unsupported W169 test Decimal width")
  end
end

private def w169_literal_decimal_aggregate(
  function_name : String,
  width_bits : Int,
  precision : Int,
  scale : Int,
  nullable : Bool = false,
) : Bytes
  bytes = [] of UInt8
  bytes << CrystalClick::BinaryDataType::TAG_NULLABLE if nullable
  bytes << CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # no function parameters
  bytes << 1_u8 # unary function
  bytes << w169_decimal_child_tag(width_bits)
  bytes << precision.to_u8
  bytes << scale.to_u8
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w169_signed_coefficient_bytes(width : Int32, negative_one : Bool = false, minimum : Bool = false) : Bytes
  Bytes.new(width) do |index|
    if negative_one
      0xff_u8
    elsif minimum
      index == width - 1 ? 0x80_u8 : 0_u8
    else
      index == width - 1 ? 0x7f_u8 : 0xff_u8
    end
  end
end

describe "W169 canonical Decimal SimpleAggregateFunction core" do
  it "parses exact canonical Decimal scalar and outer-Nullable identities" do
    [
      {32, 8, 3},
      {64, 17, 5},
      {128, 37, 10},
      {256, 75, 31},
    ].each do |width_bits, precision, scale|
      decimal = CrystalClick::DecimalType.new(precision, scale)
      decimal.storage_width.should eq(width_bits // 8)
      name = "SimpleAggregateFunction(min, #{decimal.type_name})"

      aggregate = CrystalClick::BinarySimpleAggregateType.parse(name)
      aggregate.should_not be_nil
      if parsed = aggregate
        parsed.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::Min)
        parsed.storage_type_name.should eq(decimal.type_name)
        parsed.decimal_type.should eq(decimal)
        parsed.type_name.should eq(name)
      end

      column = CrystalClick::SimpleAggregateColumnType.parse(name)
      column.should_not be_nil
      if parsed_column = column
        parsed_column.decimal_type.should eq(decimal)
        parsed_column.nullable?.should be_false
        parsed_column.type_name.should eq(name)
        expect_raises(ArgumentError) { parsed_column.raw_width }
      end

      nullable_name = "Nullable(#{name})"
      nullable_column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
      nullable_column.should_not be_nil
      if parsed_nullable = nullable_column
        parsed_nullable.decimal_type.should eq(decimal)
        parsed_nullable.nullable?.should be_true
        parsed_nullable.type_name.should eq(nullable_name)
        expect_raises(ArgumentError) { parsed_nullable.raw_width }
      end
    end
  end

  it "admits exactly the frozen function/carrier result-equality law for every canonical P/S" do
    functions = [
      {"any", CrystalClick::BinarySimpleAggregateType::Function::Any},
      {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
      {"min", CrystalClick::BinarySimpleAggregateType::Function::Min},
      {"max", CrystalClick::BinarySimpleAggregateType::Function::Max},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum},
      {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor},
    ]
    mismatches = [] of String
    checked_pairs = 0

    (1..76).each do |precision|
      (0..precision).each do |scale|
        decimal = CrystalClick::DecimalType.new(precision, scale)
        width_bits = decimal.storage_width * 8
        child = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)

        functions.each do |function_name, function|
          expected = case function
                     when CrystalClick::BinarySimpleAggregateType::Function::Any,
                          CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
                          CrystalClick::BinarySimpleAggregateType::Function::Min,
                          CrystalClick::BinarySimpleAggregateType::Function::Max,
                          CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow
                       true
                     when CrystalClick::BinarySimpleAggregateType::Function::Sum
                       decimal.storage_width >= 16
                     else
                       false
                     end
          name = "SimpleAggregateFunction(#{function_name}, #{decimal.type_name})"
          parsed = CrystalClick::BinarySimpleAggregateType.parse(name)
          built = w169_try_simple_aggregate(function, child)
          checked_pairs += 1

          if expected
            mismatches << "#{name} was rejected by text parsing" unless parsed
            mismatches << "#{name} was rejected by binary construction" unless built
            if aggregate = built
              mismatches << "#{name} lost its exact child descriptor" unless aggregate.child_at(0) == child
              mismatches << "#{name} changed its canonical SQL name" unless aggregate.name == name
            end
          else
            mismatches << "#{name} was admitted by text parsing" if parsed
            mismatches << "#{name} was admitted by binary construction" if built
          end
        end
      end
    end

    checked_pairs.should eq(27_018)
    mismatches.should be_empty
  end

  it "rejects SQL aliases, parameters, inner wrappers, and noncanonical binary widths" do
    [
      "SimpleAggregateFunction(min, Decimal32(3))",
      "SimpleAggregateFunction(min, Decimal64(3))",
      "SimpleAggregateFunction(min, Decimal128(3))",
      "SimpleAggregateFunction(min, Decimal256(3))",
      "SimpleAggregateFunction(any_value, Decimal(19, 3))",
      "SimpleAggregateFunction(sum(1), Decimal(19, 3))",
      "SimpleAggregateFunction(min, Decimal(08, 3))",
      "SimpleAggregateFunction(min, Decimal(19, 03))",
      "SimpleAggregateFunction(min, Decimal(19,3))",
      "SimpleAggregateFunction(min, Decimal(19, 20))",
      "SimpleAggregateFunction(min, Decimal(19, 3), UInt8)",
      "SimpleAggregateFunction(min, Nullable(Decimal(19, 3)))",
      "SimpleAggregateFunction(min, LowCardinality(Decimal(19, 3)))",
    ].each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
    end

    [
      {64, 8, 2},
      {128, 18, 4},
      {256, 38, 4},
    ].each do |width_bits, precision, scale|
      child = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(
          CrystalClick::BinarySimpleAggregateType::Function::Min,
          child,
        )
      end
    end

    invalid_scale = CrystalClick::BinaryDataType.decimal(128, 19, 20)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        invalid_scale,
      )
    end

    CrystalClick::BinarySimpleAggregateType.storage_width("Decimal(19, 3)").should be_nil

    # A descriptor can print the same SQL Decimal name while retaining a
    # different explicit binary width. SAF admission rejects that mismatch;
    # ordinary Decimal binary identity continues to distinguish the widths.
    noncanonical_width = CrystalClick::BinaryDataType.decimal(64, 8, 2)
    canonical_width = CrystalClick::BinaryDataType.decimal(32, 8, 2)
    noncanonical_width.name.should eq(canonical_width.name)
    noncanonical_width.should_not eq(canonical_width)
  end

  it "refuses foreign wire SAF descriptors when Decimal carrier or result equality fails" do
    [
      {"min", 64, 8, 2},         # Explicit width disagrees with SQL-inferred Decimal32.
      {"min", 128, 19, 20},      # Binary Decimal permits this scale; SQL Decimal does not.
      {"sum", 32, 8, 2},         # Decimal32 sum widens to Decimal128.
      {"groupBitAnd", 32, 8, 2}, # Decimal bitwise aggregates are outside the source law.
    ].each do |function_name, width_bits, precision, scale|
      # The ordinary binary Decimal descriptor grammar must continue to
      # preserve these wire-valid width/P/S coordinates independently of SAF.
      ordinary_decimal = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)
      ordinary_wire = CrystalClick::BinaryDataTypeCodec.encode(ordinary_decimal)
      CrystalClick::BinaryDataTypeCodec.decode(ordinary_wire).should eq(ordinary_decimal)

      saf_wire = w169_literal_decimal_aggregate(function_name, width_bits, precision, scale)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(saf_wire)
      end
    end
  end

  it "round-trips literal descriptors and preserves full signed raw coefficients through values and bulk lanes" do
    [
      {32, 8, 3},
      {64, 17, 5},
      {128, 37, 10},
      {256, 75, 31},
    ].each do |width_bits, precision, scale|
      child = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)
      aggregate = CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        child,
      )
      descriptor = w169_literal_decimal_aggregate("min", width_bits, precision, scale)
      aggregate.name.should eq("SimpleAggregateFunction(min, Decimal(#{precision}, #{scale}))")
      aggregate.child_at(0).should eq(child)
      CrystalClick::BinaryDataTypeCodec.encode(aggregate).should eq(descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(aggregate)

      nullable = CrystalClick::BinaryDataType.nullable(aggregate)
      nullable_descriptor = w169_literal_decimal_aggregate("min", width_bits, precision, scale, nullable: true)
      CrystalClick::BinaryDataTypeCodec.encode(nullable).should eq(nullable_descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(nullable_descriptor).should eq(nullable)

      width = child.fixed_width.not_nil!
      coefficients = [
        w169_signed_coefficient_bytes(width, negative_one: true),
        w169_signed_coefficient_bytes(width, minimum: true),
        w169_signed_coefficient_bytes(width),
      ]
      values = [] of CrystalClick::BinaryValue
      coefficients.each do |raw|
        child_value = CrystalClick::BinaryValue.fixed(child, raw)
        value = CrystalClick::BinaryValue.simple_aggregate(aggregate, child_value)
        value.as_simple_aggregate.bytes.should eq(raw)
        CrystalClick::BinaryValueCodec.encode_value(value).should eq(raw)
        decoded = CrystalClick::BinaryValueCodec.decode_value(aggregate, raw)
        decoded.type.should eq(aggregate)
        decoded.as_simple_aggregate.bytes.should eq(raw)
        values << value
      end

      literal_value = descriptor.to_a + coefficients[1].to_a
      encoded_value = CrystalClick::BinaryValueCodec.encode(values[1])
      encoded_value.to_a.should eq(literal_value)
      decoded_value = CrystalClick::BinaryValueCodec.decode(encoded_value)
      decoded_value.type.should eq(aggregate)
      decoded_value.as_simple_aggregate.bytes.should eq(coefficients[1])

      bulk = CrystalClick::BinaryBulkCodec.encode(aggregate, [values])
      bulk.roles.should eq(["root.data"] of String)
      expected_data = [] of UInt8
      coefficients.each { |raw| expected_data.concat(raw.to_a) }
      bulk.stream("root.data").bytes.to_a.should eq(expected_data)
      CrystalClick::BinaryBulkPhysicalPlan.new(aggregate, "amount").stream_names.should eq({
        "root.data" => "amount",
      })

      decoded_bulk = CrystalClick::BinaryBulkCodec.decode(aggregate, bulk, [3_u64])
      decoded_bulk[0].size.should eq(3)
      coefficients.each_with_index do |raw, index|
        decoded_bulk[0][index].type.should eq(aggregate)
        decoded_bulk[0][index].as_simple_aggregate.bytes.should eq(raw)
      end

      nullable_type = CrystalClick::BinaryDataType.nullable(aggregate)
      nullable_values = [
        CrystalClick::BinaryValue.nullable(nullable_type, values[0]),
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, values[2]),
      ] of CrystalClick::BinaryValue
      nullable_bulk = CrystalClick::BinaryBulkCodec.encode(nullable_type, [nullable_values])
      nullable_bulk.roles.should eq(["root.nested.data", "root.nulls"] of String)
      nullable_bulk.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
      nullable_data = coefficients[0].to_a + Array(UInt8).new(width, 0_u8) + coefficients[2].to_a
      nullable_bulk.stream("root.nested.data").bytes.to_a.should eq(nullable_data)
      CrystalClick::BinaryBulkPhysicalPlan.new(nullable_type, "amount").stream_names.should eq({
        "root.nested.data" => "amount",
        "root.nulls"       => "amount.null",
      })
      decoded_nullable = CrystalClick::BinaryBulkCodec.decode(nullable_type, nullable_bulk, [3_u64])
      decoded_nullable[0][0].child_at(0).as_simple_aggregate.bytes.should eq(coefficients[0])
      decoded_nullable[0][1].is_null?.should be_true
      decoded_nullable[0][2].child_at(0).as_simple_aggregate.bytes.should eq(coefficients[2])
    end
  end

  it "retains precision identity for same-width Decimal SAF descriptors" do
    lower_precision = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.decimal(128, 19, 3),
    )
    higher_precision = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.decimal(128, 37, 3),
    )
    lower_precision.child_at(0).fixed_width.should eq(higher_precision.child_at(0).fixed_width)
    lower_precision.should_not eq(higher_precision)

    lower_raw = Bytes.new(16) { |index| index.to_u8 }
    higher_raw = Bytes.new(16) { |index| index.to_u8 }
    lower_value = CrystalClick::BinaryValue.simple_aggregate(
      lower_precision,
      CrystalClick::BinaryValue.fixed(lower_precision.child_at(0), lower_raw),
    )
    higher_value = CrystalClick::BinaryValue.simple_aggregate(
      higher_precision,
      CrystalClick::BinaryValue.fixed(higher_precision.child_at(0), higher_raw),
    )
    lower_wire = CrystalClick::BinaryValueCodec.encode(lower_value)
    higher_wire = CrystalClick::BinaryValueCodec.encode(higher_value)
    lower_wire.should_not eq(higher_wire)
    CrystalClick::BinaryValueCodec.decode(lower_wire).type.should eq(lower_precision)
    CrystalClick::BinaryValueCodec.decode(higher_wire).type.should eq(higher_precision)
    lower_value.as_simple_aggregate.bytes.should eq(higher_value.as_simple_aggregate.bytes)
  end
end
