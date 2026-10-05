require "./spec_helper"

private def w170_temporal_wire_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w170_temporal_wire_concat(left : Bytes, right : Bytes) : Bytes
  Bytes.new(left.size + right.size) do |index|
    index < left.size ? left[index] : right[index - left.size]
  end
end

private def w170_temporal_wire_descriptor(function_name : String, child : Bytes) : Bytes
  function_bytes = function_name.to_slice
  descriptor = [CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE] of UInt8
  descriptor.concat(w170_temporal_wire_var_uint(function_bytes.size.to_u64).to_a)
  descriptor.concat(function_bytes.to_a)
  descriptor << 0_u8 # parameter count
  descriptor << 1_u8 # unary argument count
  descriptor.concat(child.to_a)
  Bytes.new(descriptor.size) { |index| descriptor[index] }
end

private def w170_temporal_wire_leaf_cases : Array(Tuple(
  CrystalClick::BinaryDataType,
  Bytes,
  CrystalClick::TemporalStorageType::Family,
  Int32?,
  String?,
))
  cases = [] of Tuple(
    CrystalClick::BinaryDataType,
    Bytes,
    CrystalClick::TemporalStorageType::Family,
    Int32?,
    String?,
  )

  cases << {
    CrystalClick::BinaryDataType.primitive("Date"),
    Bytes[0x0f_u8],
    CrystalClick::TemporalStorageType::Family::Date,
    nil,
    nil,
  }
  cases << {
    CrystalClick::BinaryDataType.primitive("Date32"),
    Bytes[0x10_u8],
    CrystalClick::TemporalStorageType::Family::Date32,
    nil,
    nil,
  }
  cases << {
    CrystalClick::BinaryDataType.datetime,
    Bytes[0x11_u8],
    CrystalClick::TemporalStorageType::Family::DateTime,
    nil,
    nil,
  }
  cases << {
    CrystalClick::BinaryDataType.datetime("Europe/Berlin"),
    Bytes[0x12_u8, 0x0d_u8, 0x45_u8, 0x75_u8, 0x72_u8, 0x6f_u8, 0x70_u8, 0x65_u8,
      0x2f_u8, 0x42_u8, 0x65_u8, 0x72_u8, 0x6c_u8, 0x69_u8, 0x6e_u8],
    CrystalClick::TemporalStorageType::Family::DateTime,
    nil,
    "Europe/Berlin",
  }

  10.times do |scale|
    cases << {
      CrystalClick::BinaryDataType.datetime64(scale),
      Bytes[0x13_u8, scale.to_u8],
      CrystalClick::TemporalStorageType::Family::DateTime64,
      scale,
      nil,
    }
    cases << {
      CrystalClick::BinaryDataType.datetime64(scale, "Europe/Berlin"),
      w170_temporal_wire_concat(
        Bytes[0x14_u8, scale.to_u8, 0x0d_u8],
        Bytes[0x45_u8, 0x75_u8, 0x72_u8, 0x6f_u8, 0x70_u8, 0x65_u8, 0x2f_u8,
          0x42_u8, 0x65_u8, 0x72_u8, 0x6c_u8, 0x69_u8, 0x6e_u8],
      ),
      CrystalClick::TemporalStorageType::Family::DateTime64,
      scale,
      "Europe/Berlin",
    }
    cases << {
      CrystalClick::BinaryDataType.time64(scale),
      Bytes[0x34_u8, scale.to_u8],
      CrystalClick::TemporalStorageType::Family::Time64,
      scale,
      nil,
    }
  end

  cases << {
    CrystalClick::BinaryDataType.datetime64(3, "UTC"),
    Bytes[0x14_u8, 0x03_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8],
    CrystalClick::TemporalStorageType::Family::DateTime64,
    3,
    "UTC",
  }
  cases << {
    CrystalClick::BinaryDataType.primitive("Time"),
    Bytes[0x32_u8],
    CrystalClick::TemporalStorageType::Family::Time,
    nil,
    nil,
  }

  cases
end

private def w170_temporal_function_cases : Array(Tuple(
  String,
  CrystalClick::BinarySimpleAggregateType::Function,
))
  [
    {"any", CrystalClick::BinarySimpleAggregateType::Function::Any},
    {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
    {"min", CrystalClick::BinarySimpleAggregateType::Function::Min},
    {"max", CrystalClick::BinarySimpleAggregateType::Function::Max},
  ] of Tuple(String, CrystalClick::BinarySimpleAggregateType::Function)
end

describe "W170 temporal SimpleAggregateFunction core" do
  it "admits the frozen temporal function/profile grid with exact leaf metadata" do
    w170_temporal_wire_leaf_cases.each do |child, child_wire, family, precision, zone|
      leaf = CrystalClick::TemporalStorageType.parse(child.name)
      leaf.should_not be_nil
      if parsed_leaf = leaf
        parsed_leaf.family.should eq(family)
        parsed_leaf.type_name.should eq(child.name)
        parsed_leaf.precision?.should eq(precision)
        parsed_leaf.time_zone?.try(&.name).should eq(zone)
        parsed_leaf.storage_width.should eq(child.fixed_width)
      end

      w170_temporal_function_cases.each do |function_name, function|
        name = "SimpleAggregateFunction(#{function_name}, #{child.name})"
        expected_wire = w170_temporal_wire_descriptor(function_name, child_wire)

        descriptor = CrystalClick::BinarySimpleAggregateType.parse(name)
        descriptor.should_not be_nil
        if parsed_descriptor = descriptor
          parsed_descriptor.function.should eq(function)
          parsed_descriptor.storage_type_name.should eq(child.name)
          parsed_descriptor.temporal_storage_type.should eq(leaf)
          parsed_descriptor.type_name.should eq(name)
        end

        column = CrystalClick::SimpleAggregateColumnType.parse(name)
        column.should_not be_nil
        if parsed_column = column
          parsed_column.function.should eq(function)
          parsed_column.storage_type_name.should eq(child.name)
          parsed_column.temporal_storage_type.should eq(leaf)
          parsed_column.type_name.should eq(name)
          expect_raises(ArgumentError) { parsed_column.raw_width }
        end

        aggregate = CrystalClick::BinaryDataType.simple_aggregate(function, child)
        aggregate.name.should eq(name)
        aggregate.child_count.should eq(1)
        aggregate.child_at(0).should eq(child)
        CrystalClick::BinaryDataTypeCodec.encode(aggregate).should eq(expected_wire)
        CrystalClick::BinaryDataTypeCodec.decode(expected_wire).should eq(aggregate)

        nullable = CrystalClick::BinaryDataType.nullable(aggregate)
        nullable_wire = w170_temporal_wire_concat(Bytes[CrystalClick::BinaryDataType::TAG_NULLABLE], expected_wire)
        nullable.name.should eq("Nullable(#{name})")
        CrystalClick::BinaryDataTypeCodec.encode(nullable).should eq(nullable_wire)
        CrystalClick::BinaryDataTypeCodec.decode(nullable_wire).should eq(nullable)
      end
    end

    w170_temporal_wire_leaf_cases.size.should eq(36)
  end

  it "keeps nominal descriptors transparent through value, bulk, and physical codecs" do
    function = CrystalClick::BinarySimpleAggregateType::Function::Min
    function_name = "min"

    w170_temporal_wire_leaf_cases.each do |child, child_wire, _, _, _|
      aggregate = CrystalClick::BinaryDataType.simple_aggregate(function, child)
      descriptor_wire = w170_temporal_wire_descriptor(function_name, child_wire)
      payload = Bytes.new(child.fixed_width.not_nil!) { |index| (0x31 + index).to_u8 }
      child_value = CrystalClick::BinaryValue.fixed(child, payload)
      aggregate_value = CrystalClick::BinaryValue.simple_aggregate(aggregate, child_value)

      CrystalClick::BinaryValueCodec.encode_value(aggregate_value).should eq(payload)
      decoded_value = CrystalClick::BinaryValueCodec.decode_value(aggregate, payload)
      decoded_value.type.should eq(aggregate)
      decoded_value.child_at(0).type.should eq(child)
      decoded_value.child_at(0).bytes.should eq(payload)

      envelope = w170_temporal_wire_concat(descriptor_wire, payload)
      CrystalClick::BinaryValueCodec.encode(aggregate_value).should eq(envelope)
      decoded_envelope = CrystalClick::BinaryValueCodec.decode(envelope)
      decoded_envelope.type.should eq(aggregate)
      decoded_envelope.child_at(0).bytes.should eq(payload)

      child_bulk = CrystalClick::BinaryBulkCodec.encode(
        child,
        [[child_value] of CrystalClick::BinaryValue],
      )
      aggregate_bulk = CrystalClick::BinaryBulkCodec.encode(
        aggregate,
        [[aggregate_value] of CrystalClick::BinaryValue],
      )
      aggregate_bulk.roles.should eq(child_bulk.roles)
      aggregate_bulk.stream("root.data").bytes.should eq(payload)
      decoded_bulk = CrystalClick::BinaryBulkCodec.decode(aggregate, aggregate_bulk, [1_u64])
      decoded_bulk[0][0].child_at(0).bytes.should eq(payload)

      child_physical = CrystalClick::BinaryBulkPhysicalPlan.new(child, "v").stream_names
      aggregate_physical = CrystalClick::BinaryBulkPhysicalPlan.new(aggregate, "v").stream_names
      aggregate_physical.should eq(child_physical)

      nullable = CrystalClick::BinaryDataType.nullable(aggregate)
      nullable_value = CrystalClick::BinaryValue.nullable(nullable, aggregate_value)
      null_value = CrystalClick::BinaryValue.nullable(nullable)
      nullable_bulk = CrystalClick::BinaryBulkCodec.encode(
        nullable,
        [[nullable_value, null_value] of CrystalClick::BinaryValue],
      )
      nullable_bulk.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8])
      expected_nested_payload = Bytes.new(payload.size * 2) do |index|
        index < payload.size ? payload[index] : 0_u8
      end
      nullable_bulk.stream("root.nested.data").bytes.should eq(expected_nested_payload)
      nullable_decoded = CrystalClick::BinaryBulkCodec.decode(nullable, nullable_bulk, [2_u64])
      nullable_decoded[0][0].child_at(0).child_at(0).bytes.should eq(payload)
      nullable_decoded[0][1].is_null?.should be_true

      expected_nullable_physical = {
        "root.nested.data" => "v",
        "root.nulls"       => "v.null",
      }
      CrystalClick::BinaryBulkPhysicalPlan.new(nullable, "v").stream_names.should eq(expected_nullable_physical)
    end
  end

  it "rejects all unfrozen aggregate laws, wrappers, malformed leaves, and unbounded names" do
    cases = w170_temporal_wire_leaf_cases
    refused_functions = [
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum},
      {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor},
    ] of Tuple(String, CrystalClick::BinarySimpleAggregateType::Function)

    cases.each do |child, child_wire, _, _, _|
      refused_functions.each do |function_name, function|
        name = "SimpleAggregateFunction(#{function_name}, #{child.name})"
        CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
        CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
        expect_raises(ArgumentError) do
          CrystalClick::BinaryDataType.simple_aggregate(function, child)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDataTypeCodec.decode(
            w170_temporal_wire_descriptor(function_name, child_wire)
          )
        end
      end
    end

    malformed = [
      "SimpleAggregateFunction(min, Nullable(DateTime64(3)))",
      "SimpleAggregateFunction(min, LowCardinality(DateTime64(3)))",
      "SimpleAggregateFunction(min, DateTime64(03))",
      "SimpleAggregateFunction(min, DateTime64(10))",
      "SimpleAggregateFunction(min, DateTime64(3, 'Definitely/Not_A_Zone'))",
      "SimpleAggregateFunction(min, DateTime64(3, 'Europe/Berlin', 'UTC'))",
      "SimpleAggregateFunction(min, Time64(03))",
      "SimpleAggregateFunction(min, Time64(10))",
      "SimpleAggregateFunction(min, Time64(3, 'UTC'))",
    ]
    malformed.each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
    end

    wrapped = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.datetime64(3))
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        wrapped,
      )
    end
  end

  it "keeps the temporal carrier plan exact and separate from numeric raw_width" do
    w170_temporal_wire_leaf_cases.each do |child, _, family, _, _|
      name = "SimpleAggregateFunction(any, #{child.name})"
      plan = CrystalClick::SimpleAggregateTemporalStoragePlan.for_type_name(name)
      plan.should_not be_nil
      if parsed = plan
        parsed.type_name.should eq(name)
        parsed.storage_type_name.should eq(child.name)
        parsed.storage_width.should eq(child.fixed_width)
        parsed.temporal_type.family.should eq(family)

        case family
        when CrystalClick::TemporalStorageType::Family::Date
          parsed.validate_carrier!(UInt16)
          expect_raises(CrystalClick::UnsupportedFormatError) { parsed.validate_carrier!(Int16) }
        when CrystalClick::TemporalStorageType::Family::Date32,
             CrystalClick::TemporalStorageType::Family::Time
          parsed.validate_carrier!(Int32)
          expect_raises(CrystalClick::UnsupportedFormatError) { parsed.validate_carrier!(UInt32) }
        when CrystalClick::TemporalStorageType::Family::DateTime
          parsed.validate_carrier!(UInt32)
          expect_raises(CrystalClick::UnsupportedFormatError) { parsed.validate_carrier!(Int32) }
        when CrystalClick::TemporalStorageType::Family::DateTime64,
             CrystalClick::TemporalStorageType::Family::Time64
          parsed.validate_carrier!(Int64)
          expect_raises(CrystalClick::UnsupportedFormatError) { parsed.validate_carrier!(UInt64) }
        else
          fail "unexpected temporal family"
        end
      end
    end
  end

  it "accepts the full bounded timezone spelling through the outer Nullable parser" do
    zone = "America/Argentina/ComodRivadavia"
    child = CrystalClick::BinaryDataType.datetime64(3, zone)
    scalar = "SimpleAggregateFunction(min, #{child.name})"
    scalar.bytesize.should eq(79)
    nullable_name = "Nullable(#{scalar})"
    nullable_name.bytesize.should eq(89)

    scalar_descriptor = CrystalClick::BinarySimpleAggregateType.parse(scalar)
    scalar_descriptor.should_not be_nil
    scalar_descriptor.not_nil!.type_name.should eq(scalar)

    column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
    column.should_not be_nil
    if parsed = column
      parsed.nullable?.should be_true
      parsed.temporal_storage_type.not_nil!.time_zone?.not_nil!.name.should eq(zone)
      parsed.type_name.should eq(nullable_name)
    end
  end

  it "preserves exact timezone identity behind detached names and enforces parser caps" do
    zone = "Europe/Berlin"
    canonical = "DateTime64(3, 'Europe/Berlin')"
    mutable_input = String.new(canonical.to_slice)
    temporal = CrystalClick::TemporalStorageType.parse(mutable_input).not_nil!
    mutable_input.to_unsafe[0] = 'X'.ord.to_u8
    temporal.type_name.should eq(canonical)

    returned_type_name = temporal.type_name
    returned_type_name.to_unsafe[0] = 'X'.ord.to_u8
    temporal.type_name.should eq(canonical)

    zone_owner = temporal.time_zone?.not_nil!
    returned_zone_name = zone_owner.name
    returned_zone_name.to_unsafe[0] = 'X'.ord.to_u8
    zone_owner.name.should eq(zone)

    CrystalClick::TemporalStorageType.parse("DateTime64(3)").should_not eq(temporal)
    CrystalClick::TemporalStorageType.parse("DateTime64(4, 'Europe/Berlin')").should_not eq(temporal)
    CrystalClick::TemporalStorageType.parse("DateTime64(3, 'UTC')").should_not eq(temporal)

    over_core_cap = "x" * (CrystalClick::BinarySimpleAggregateType::MAX_TYPE_BYTES + 1)
    over_column_cap = "x" * (CrystalClick::SimpleAggregateColumnType::MAX_TYPE_BYTES + 1)
    over_core_cap.bytesize.should eq(97)
    over_column_cap.bytesize.should eq(107)
    CrystalClick::BinarySimpleAggregateType.parse(over_core_cap).should be_nil
    CrystalClick::SimpleAggregateColumnType.parse(over_column_cap).should be_nil
  end

  it "roundtrips the literal longest witnessed anyLast scalar and Nullable names" do
    zone = "America/Argentina/ComodRivadavia"
    child = CrystalClick::BinaryDataType.datetime64(3, zone)
    scalar = "SimpleAggregateFunction(anyLast, #{child.name})"
    scalar.bytesize.should eq(83)
    nullable_name = "Nullable(#{scalar})"
    nullable_name.bytesize.should eq(93)

    descriptor = CrystalClick::BinarySimpleAggregateType.parse(scalar)
    descriptor.should_not be_nil
    descriptor.not_nil!.type_name.should eq(scalar)

    column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
    column.should_not be_nil
    if parsed = column
      parsed.function.should eq(CrystalClick::BinarySimpleAggregateType::Function::AnyLast)
      parsed.storage_type_name.should eq(child.name)
      parsed.nullable?.should be_true
      parsed.type_name.should eq(nullable_name)
    end
  end
end
