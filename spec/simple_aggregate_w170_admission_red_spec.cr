require "./spec_helper"

private def w170_try_build_simple_aggregate(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  storage_type : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  begin
    CrystalClick::BinaryDataType.simple_aggregate(function, storage_type)
  rescue ex : ArgumentError
    # Keep the current admission refusal visible as an expectation failure.
    nil
  end
end

private def w170_temporal_children : Array(Tuple(String, CrystalClick::BinaryDataType))
  [
    {"Date", CrystalClick::BinaryDataType.primitive("Date")},
    {"Date32", CrystalClick::BinaryDataType.primitive("Date32")},
    {"DateTime", CrystalClick::BinaryDataType.datetime},
    {"DateTime('Europe/Berlin')", CrystalClick::BinaryDataType.datetime("Europe/Berlin")},
    {"DateTime64(3)", CrystalClick::BinaryDataType.datetime64(3)},
    {"DateTime64(3, 'Europe/Berlin')", CrystalClick::BinaryDataType.datetime64(3, "Europe/Berlin")},
    {"Time", CrystalClick::BinaryDataType.primitive("Time")},
    {"Time64(3)", CrystalClick::BinaryDataType.time64(3)},
  ] of Tuple(String, CrystalClick::BinaryDataType)
end

describe "W170 temporal SimpleAggregateFunction admission RED" do
  it "retains the admitted UInt64 positive control" do
    name = "SimpleAggregateFunction(min, UInt64)"

    descriptor = CrystalClick::BinarySimpleAggregateType.parse(name)
    descriptor.should_not be_nil
    descriptor.not_nil!.type_name.should eq(name)

    column = CrystalClick::SimpleAggregateColumnType.parse(name)
    column.should_not be_nil
    column.not_nil!.type_name.should eq(name)

    built = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    built.name.should eq(name)
  end

  it "retains the admitted Decimal128 positive control" do
    name = "SimpleAggregateFunction(min, Decimal(20, 3))"

    descriptor = CrystalClick::BinarySimpleAggregateType.parse(name)
    descriptor.should_not be_nil
    descriptor.not_nil!.type_name.should eq(name)

    column = CrystalClick::SimpleAggregateColumnType.parse(name)
    column.should_not be_nil
    column.not_nil!.type_name.should eq(name)

    built = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.decimal(128, 20, 3),
    )
    built.name.should eq(name)
  end

  it "constructs and parses canonical any/min descriptors with exact temporal identity" do
    functions = [
      {"any", CrystalClick::BinarySimpleAggregateType::Function::Any},
      {"min", CrystalClick::BinarySimpleAggregateType::Function::Min},
    ]

    functions.each do |function_name, function|
      w170_temporal_children.each do |storage_type_name, child|
        name = "SimpleAggregateFunction(#{function_name}, #{storage_type_name})"

        built = w170_try_build_simple_aggregate(function, child)
        built.should_not be_nil
        if aggregate = built
          aggregate.name.should eq(name)
          aggregate.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
          aggregate.simple_aggregate_type.not_nil!.function.should eq(function)
          aggregate.simple_aggregate_type.not_nil!.storage_type_name.should eq(storage_type_name)
          aggregate.child_count.should eq(1)
          aggregate.child_at(0).should eq(child)

          nullable = CrystalClick::BinaryDataType.nullable(aggregate)
          nullable.name.should eq("Nullable(#{name})")
          nullable.child_at(0).should eq(aggregate)
        end

        parsed_descriptor = CrystalClick::BinarySimpleAggregateType.parse(name)
        parsed_descriptor.should_not be_nil
        if parsed = parsed_descriptor
          parsed.function.should eq(function)
          parsed.storage_type_name.should eq(storage_type_name)
          parsed.type_name.should eq(name)
        end

        parsed_column = CrystalClick::SimpleAggregateColumnType.parse(name)
        parsed_column.should_not be_nil
        if column = parsed_column
          column.function.should eq(function)
          column.storage_type_name.should eq(storage_type_name)
          column.nullable?.should be_false
          column.type_name.should eq(name)
          expect_raises(ArgumentError) { column.raw_width }
        end

        nullable_name = "Nullable(#{name})"
        nullable_column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
        nullable_column.should_not be_nil
        if column = nullable_column
          column.function.should eq(function)
          column.storage_type_name.should eq(storage_type_name)
          column.nullable?.should be_true
          column.type_name.should eq(nullable_name)
          expect_raises(ArgumentError) { column.raw_width }
        end
      end
    end
  end

  it "keeps the 32-byte timezone leaf within the existing scalar-name bound" do
    zone = "America/Argentina/ComodRivadavia"
    zone.bytesize.should eq(CrystalClick::TimezoneName::MAX_NAME_BYTES)

    child = CrystalClick::BinaryDataType.datetime64(3, zone)
    name = "SimpleAggregateFunction(min, #{child.name})"
    name.bytesize.should eq(79)

    built = w170_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      child,
    )
    built.should_not be_nil
    if aggregate = built
      aggregate.name.should eq(name)
      aggregate.child_at(0).temporal_type.should eq(child.temporal_type)
    end

    parsed = CrystalClick::BinarySimpleAggregateType.parse(name)
    parsed.should_not be_nil
    if descriptor = parsed
      descriptor.storage_type_name.should eq(child.name)
      descriptor.type_name.should eq(name)
    end

    column = CrystalClick::SimpleAggregateColumnType.parse(name)
    column.should_not be_nil
    column.not_nil!.type_name.should eq(name)
  end

  it "parses outer Nullable around the admitted 32-byte timezone leaf" do
    zone = "America/Argentina/ComodRivadavia"
    child = CrystalClick::BinaryDataType.datetime64(3, zone)
    scalar_name = "SimpleAggregateFunction(min, #{child.name})"
    nullable_name = "Nullable(#{scalar_name})"
    nullable_name.bytesize.should eq(89)

    column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
    column.should_not be_nil
    if parsed = column
      parsed.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::Min)
      parsed.storage_type_name.should eq(child.name)
      parsed.nullable?.should be_true
      parsed.type_name.should eq(nullable_name)
    end
  end

  it "rejects wrapped leaves, malformed temporal parameters, and unknown zones" do
    wrapped_child = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.datetime64(3)
    )
    w170_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Any,
      wrapped_child,
    ).should be_nil

    rejected_names = [
      "SimpleAggregateFunction(min, Nullable(DateTime64(3)))",
      "SimpleAggregateFunction(min, LowCardinality(DateTime64(3)))",
      "SimpleAggregateFunction(min, DateTime64(03))",
      "SimpleAggregateFunction(min, DateTime64(10))",
      "SimpleAggregateFunction(min, DateTime64(3, 'Definitely/Not_A_Zone'))",
      "SimpleAggregateFunction(min, DateTime64(3, 'Europe/Berlin', 'UTC'))",
      "SimpleAggregateFunction(min, Time64(03))",
      "SimpleAggregateFunction(min, Time64(10))",
    ]

    rejected_names.each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Any,
        wrapped_child,
      )
    end
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.datetime64(10) }
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.datetime64(3, "Definitely/Not_A_Zone")
    end
  end
end
