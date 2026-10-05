require "./spec_helper"

private def w169_try_build_simple_aggregate(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  storage_type : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  begin
    CrystalClick::BinaryDataType.simple_aggregate(function, storage_type)
  rescue ex : ArgumentError
    # Keep the pre-admission behavior observable as a failed expectation.
    nil
  end
end

describe "W169 Decimal SimpleAggregateFunction admission RED" do
  it "retains the existing UInt64 positive control" do
    name = "SimpleAggregateFunction(min, UInt64)"

    aggregate = CrystalClick::BinarySimpleAggregateType.parse(name)
    aggregate.should_not be_nil
    aggregate.not_nil!.type_name.should eq(name)

    column = CrystalClick::SimpleAggregateColumnType.parse(name)
    column.should_not be_nil
    column.not_nil!.type_name.should eq(name)

    built = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    built.name.should eq(name)
  end

  it "parses the canonical bare Decimal storage declaration" do
    name = "SimpleAggregateFunction(min, Decimal(19, 3))"
    aggregate = CrystalClick::BinarySimpleAggregateType.parse(name)

    aggregate.should_not be_nil
    if parsed = aggregate
      parsed.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::Min)
      parsed.storage_type_name.should eq("Decimal(19, 3)")
      parsed.type_name.should eq(name)
    end
  end

  it "parses canonical Decimal scalar and outer-Nullable column identities" do
    scalar_name = "SimpleAggregateFunction(min, Decimal(19, 3))"
    scalar = CrystalClick::SimpleAggregateColumnType.parse(scalar_name)

    scalar.should_not be_nil
    if column = scalar
      column.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::Min)
      column.storage_type_name.should eq("Decimal(19, 3)")
      column.nullable?.should be_false
      column.type_name.should eq(scalar_name)

      nullable_name = "Nullable(#{scalar_name})"
      nullable = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
      nullable.should_not be_nil
      if nullable_column = nullable
        nullable_column.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::Min)
        nullable_column.storage_type_name.should eq("Decimal(19, 3)")
        nullable_column.nullable?.should be_true
        nullable_column.type_name.should eq(nullable_name)
      end
    end
  end

  it "constructs min over a width- and parameter-preserving Decimal128 child" do
    child = CrystalClick::BinaryDataType.decimal(128, 19, 3)
    aggregate = w169_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      child,
    )

    aggregate.should_not be_nil
    if built = aggregate
      built.name.should eq("SimpleAggregateFunction(min, Decimal(19, 3))")
      built.child_count.should eq(1)
      built.child_at(0).should eq(child)
    end
  end

  it "keeps unqualified Decimal aliases, parameters, wrappers, and result-mismatched pairs out" do
    [
      "SimpleAggregateFunction(min, Decimal32(3))",
      "SimpleAggregateFunction(min, Decimal64(3))",
      "SimpleAggregateFunction(min, Decimal128(3))",
      "SimpleAggregateFunction(min, Decimal256(3))",
      "SimpleAggregateFunction(any_value, Decimal(19, 3))",
      "SimpleAggregateFunction(sum(1), Decimal(19, 3))",
      "SimpleAggregateFunction(min, Nullable(Decimal(19, 3)))",
      "SimpleAggregateFunction(min, LowCardinality(Decimal(19, 3)))",
    ].each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
    end

    [
      {32, 8, 2},
      {64, 17, 2},
    ].each do |width_bits, precision, scale|
      child = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)
      w169_try_build_simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        child,
      ).should be_nil
    end

    [
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd,
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr,
      CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor,
    ].each do |function|
      child = CrystalClick::BinaryDataType.decimal(128, 19, 3)
      w169_try_build_simple_aggregate(function, child).should be_nil
    end

    # Display-name normalization must not admit a noncanonical wire width or
    # SQL-invalid scale merely because BinaryDecimalType can represent it.
    noncanonical_width = CrystalClick::BinaryDataType.decimal(64, 8, 2)
    w169_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      noncanonical_width,
    ).should be_nil

    invalid_sql_scale = CrystalClick::BinaryDataType.decimal(128, 19, 20)
    w169_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      invalid_sql_scale,
    ).should be_nil
  end
end
