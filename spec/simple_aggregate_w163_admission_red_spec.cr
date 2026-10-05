require "./spec_helper"
require "file_utils"

module CrystalClick::WidePartWriter
  # Exercise the existing typed-pair implementation without adding a
  # production entry point just for this admission probe.
  def self.w163_test_write_typed_pair_with_type(
    destination : String,
    keys : Slice(UInt64),
    values : Slice(T),
    type_name : String,
  ) : String forall T
    write_uint64_typed_pair_with_type(destination, "pk", keys, "v", values, type_name, 2)
  end
end

private W163_SIMPLE_AGGREGATE_NUMERIC_TYPES = [
  {"UInt8", "UInt8"},
  {"UInt16", "UInt16"},
  {"UInt32", "UInt32"},
  {"UInt64", "UInt64"},
  {"Int8", "Int8"},
  {"Int16", "Int16"},
  {"Int32", "Int32"},
  {"Int64", "Int64"},
  {"Float32", "Float32"},
  {"Float64", "Float64"},
]

describe "W163 SimpleAggregateFunction standard numeric admission RED" do
  W163_SIMPLE_AGGREGATE_NUMERIC_TYPES.each do |storage_type, _label|
    it "admits scalar and outer Nullable any(#{storage_type}) through the existing type surfaces" do
      type_name = "SimpleAggregateFunction(any, #{storage_type})"
      nullable_type_name = "Nullable(#{type_name})"

      CrystalClick::WidePart.supports_typed_type?(type_name).should be_true
      CrystalClick::WidePart.supports_typed_type?(nullable_type_name).should be_true

      parsed = CrystalClick::SimpleAggregateColumnType.parse(type_name)
      parsed.should_not be_nil
      parsed.not_nil!.type_name.should eq(type_name)

      nullable = CrystalClick::SimpleAggregateColumnType.parse(nullable_type_name)
      nullable.should_not be_nil
      nullable.not_nil!.type_name.should eq(nullable_type_name)

      descriptor = CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Any,
        CrystalClick::BinaryDataType.primitive(storage_type)
      )
      descriptor.name.should eq(type_name)
      encoded = CrystalClick::BinaryDataTypeCodec.encode(descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(encoded).should eq(descriptor)
    end
  end

  it "writes a UInt32 SimpleAggregateFunction pair through the existing typed writer" do
    parent = File.tempname("crystal-click-simple-aggregate-w163-admission")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    values = [0_u32, 0x8000_0000_u32, UInt32::MAX, 17_u32]

    begin
      CrystalClick::WidePartWriter.w163_test_write_typed_pair_with_type(
        destination,
        keys.to_unsafe.to_slice(keys.size),
        values.to_unsafe.to_slice(values.size),
        "SimpleAggregateFunction(any, UInt32)"
      ).should eq(destination)

      part = CrystalClick::WidePart.open_typed(destination, "v")
      part.column_type.should eq("SimpleAggregateFunction(any, UInt32)")
      part.row_count.should eq(4_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
