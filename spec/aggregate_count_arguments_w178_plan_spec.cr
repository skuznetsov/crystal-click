require "./spec_helper"

describe CrystalClick::WideAggregateCountStoragePlan do
  primitive = ->(name : String) { CrystalClick::BinaryDataType.primitive(name) }

  it "admits canonical scalar and compound argument descriptors without adding physical streams" do
    arguments = [
      primitive.call("UInt8"),
      primitive.call("String"),
      primitive.call("Nothing"),
      CrystalClick::BinaryDataType.fixed_string(7),
      CrystalClick::BinaryDataType.decimal(32, 5, 2),
      CrystalClick::BinaryDataType.datetime64(3, "America/New_York"),
      CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Nanosecond),
      CrystalClick::BinaryDataType.enum8([
        {"comma, label", 1_i16}, {"it's\\safe", 2_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry),
      CrystalClick::BinaryDataType.tuple(
        [primitive.call("UInt64"), primitive.call("String")] of CrystalClick::BinaryDataType,
        ["from", "a`b"]
      ),
      CrystalClick::BinaryDataType.nested(
        [primitive.call("UInt8"), primitive.call("String")] of CrystalClick::BinaryDataType,
        ["id", "payload"]
      ),
      CrystalClick::BinaryDataType.map(
        primitive.call("String"),
        CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(primitive.call("UInt64")))
      ),
      CrystalClick::BinaryDataType.low_cardinality(primitive.call("String")),
      CrystalClick::BinaryDataType.variant([
        primitive.call("Int8"), primitive.call("UInt8"),
      ] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.dynamic(7),
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        CrystalClick::BinaryDataType.decimal(32, 9, 2)
      ),
    ]

    arguments.each do |argument|
      name = "AggregateFunction(count, #{argument.name})"
      plan = CrystalClick::WideAggregateCountStoragePlan.for_type_name(name)
      plan.should_not be_nil
      storage = plan.not_nil!
      storage.type_name.should eq(name)
      storage.data_type.child_count.should eq(0)
      storage.data_type.aggregate_count_argument_type.should eq(argument)
      rebound = CrystalClick::WideAggregateCountStoragePlan.for_type(storage.data_type)
      rebound.should_not be_nil
      rebound.not_nil!.data_type.should eq(storage.data_type)
      storage.physical_streams("state").should eq(["state"])
      storage.stream_width("state", "state").should eq(1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        storage.stream_width("state", "state.null")
      end
    end
  end

  it "keeps no-argument Count and its one VarUInt physical lane" do
    plan = CrystalClick::WideAggregateCountStoragePlan.for_type_name("AggregateFunction(count)")
    plan.should_not be_nil
    plan.not_nil!.data_type.aggregate_count_argument_type.should be_nil
    plan.not_nil!.physical_streams("c").should eq(["c"])
    plan.not_nil!.stream_width("c", "c").should eq(1)
    plan.not_nil!.maximum_state_bytes(2_u64).should eq(20)
  end

  it "refuses malformed, transformed, parameterized, nested, and unknown signatures" do
    invalid_names = [
      "AggregateFunction(sum, UInt64)",
      "AggregateFunction(count, )",
      "AggregateFunction(count, UInt8, UInt64)",
      "AggregateFunction(count, UInt8))",
      "AggregateFunction(count, UInt8)(1)",
      "AggregateFunction(count, UInt8) ",
      "AggregateFunction(count, UInt8 )",
      "AggregateFunction(count, Nullable(Nothing))",
      "AggregateFunction(count, AggregateFunction(count))",
      "AggregateFunction(count, AggregateFunction(avg, UInt64))",
      "AggregateFunction(count, UnknownType)",
      "AggregateFunction(count, JSON)",
      "AggregateFunction(count, Nullable(Array(UInt8)))",
      "Nullable(AggregateFunction(count, UInt8))",
    ]

    invalid_names.each do |name|
      CrystalClick::WideAggregateCountStoragePlan.for_type_name(name).should be_nil
    end
  end

  it "does not admit a Decimal descriptor whose width aliases the canonical SQL name" do
    canonical = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    noncanonical = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    canonical.name.should eq(noncanonical.name)

    plan = CrystalClick::WideAggregateCountStoragePlan.for_type_name(
      "AggregateFunction(count, Decimal(5, 2))"
    )
    plan.should_not be_nil
    plan.not_nil!.data_type.aggregate_count_argument_type.should eq(canonical)

    invalid_arguments = [
      noncanonical,
      CrystalClick::BinaryDataType.nullable(noncanonical),
      CrystalClick::BinaryDataType.tuple([noncanonical] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.map(primitive.call("String"), noncanonical),
      CrystalClick::BinaryDataType.variant([
        primitive.call("String"), noncanonical,
      ] of CrystalClick::BinaryDataType),
    ]

    invalid_arguments.each do |argument|
      invalid_type = begin
        CrystalClick::BinaryDataType.aggregate_count(argument)
      rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
        nil
      end
      invalid_type.should be_nil
    end
  end

  it "keeps a Count descriptor from becoming its own argument" do
    count = CrystalClick::BinaryDataType.aggregate_count
    invalid_type = begin
      CrystalClick::BinaryDataType.aggregate_count(count)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    invalid_type.should be_nil
  end
end
