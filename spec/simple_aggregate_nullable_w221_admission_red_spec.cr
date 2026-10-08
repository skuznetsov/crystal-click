require "./spec_helper"

private W221_RESPECT_NULLS_FUNCTIONS = [
  "any_respect_nulls",
  "anyLast_respect_nulls",
]

private def w221_var_uint(value : UInt64) : Array(UInt8)
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  bytes
end

private def w221_bytes(values : Array(UInt8)) : Bytes
  Bytes.new(values.size) { |index| values[index] }
end

private def w221_le_u64(value : UInt64) : Array(UInt8)
  Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w221_nullable_wire(child_wire : Array(UInt8)) : Array(UInt8)
  [CrystalClick::BinaryDataType::TAG_NULLABLE] + child_wire
end

# Build the SAF descriptor shell from literal wire grammar. Child descriptors
# come from the already-admitted child codec; no new SAF function enum or
# production SAF encoder is used as the test oracle.
private def w221_saf_wire(
  function_name : String,
  child_wire : Array(UInt8),
  inner_nullable : Bool = false,
  outer_nullable : Bool = false,
  parameter_count : UInt64 = 0_u64,
  argument_count : UInt64 = 1_u64,
) : Bytes
  storage_wire = inner_nullable ? w221_nullable_wire(child_wire) : child_wire
  bytes = [] of UInt8
  bytes << CrystalClick::BinaryDataType::TAG_NULLABLE if outer_nullable
  bytes << CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
  bytes.concat(w221_var_uint(function_name.bytesize.to_u64))
  bytes.concat(function_name.to_slice.to_a)
  bytes.concat(w221_var_uint(parameter_count))
  bytes.concat(w221_var_uint(argument_count))
  argument_count.to_i.times do
    bytes.concat(storage_wire)
  end
  w221_bytes(bytes)
end

private def w221_try_decode_type(wire : Bytes) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataTypeCodec.decode(wire)
rescue ex : CrystalClick::UnsupportedFormatError
  # Keep the pre-admission codec refusal visible as an expectation failure.
  nil
end

private def w221_try_build_min(storage_type : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.simple_aggregate(
    CrystalClick::BinarySimpleAggregateType::Function::Min,
    storage_type,
  )
rescue ex : ArgumentError
  # The existing constructor must fail this expectation at the current frontier.
  nil
end

private def w221_representative_storage_types : Array(Tuple(String, CrystalClick::BinaryDataType))
  [
    {"UInt64", CrystalClick::BinaryDataType.primitive("UInt64")},
    {"String", CrystalClick::BinaryDataType.primitive("String")},
    {"FixedString(3)", CrystalClick::BinaryDataType.fixed_string(3)},
    {"Decimal(20, 3)", CrystalClick::BinaryDataType.decimal(128, 20, 3)},
    {"Date", CrystalClick::BinaryDataType.primitive("Date")},
    {"DateTime64(3)", CrystalClick::BinaryDataType.datetime64(3)},
  ] of Tuple(String, CrystalClick::BinaryDataType)
end

private def w221_make_aggregate_value(
  aggregate_type : CrystalClick::BinaryDataType,
  nullable_type : CrystalClick::BinaryDataType,
  string_value : String?,
) : CrystalClick::BinaryValue
  child = if value = string_value
           CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(value))
         else
           CrystalClick::BinaryValue.nullable(nullable_type)
         end
  CrystalClick::BinaryValue.simple_aggregate(aggregate_type, child)
end

describe "W221 SimpleAggregateFunction respect-nulls and inner Nullable admission RED" do
  it "retains the old Min(UInt64) profile as a positive control" do
    name = "SimpleAggregateFunction(min, UInt64)"

    parsed = CrystalClick::BinarySimpleAggregateType.parse(name)
    parsed.should_not be_nil
    if descriptor = parsed
      descriptor.function_name.should eq("min")
      descriptor.storage_type_name.should eq("UInt64")
      descriptor.type_name.should eq(name)
    end

    column = CrystalClick::SimpleAggregateColumnType.parse(name)
    column.should_not be_nil
    column.not_nil!.type_name.should eq(name)

    child = CrystalClick::BinaryDataType.primitive("UInt64")
    aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      child,
    )
    aggregate.name.should eq(name)

    literal = w221_saf_wire("min", [CrystalClick::BinaryDataType::TAG_UINT64])
    CrystalClick::BinaryDataTypeCodec.decode(literal).should eq(aggregate)
    CrystalClick::BinaryDataTypeCodec.encode(aggregate).should eq(literal)
  end

  it "parses both exact respect-nulls identities over existing storage leaves and their inner Nullable forms" do
    W221_RESPECT_NULLS_FUNCTIONS.each do |function_name|
      w221_representative_storage_types.each do |storage_name, storage_type|
        [false, true].each do |inner_nullable|
          declared_storage_name = inner_nullable ? "Nullable(#{storage_name})" : storage_name
          scalar_name = "SimpleAggregateFunction(#{function_name}, #{declared_storage_name})"

          parsed = CrystalClick::BinarySimpleAggregateType.parse(scalar_name)
          parsed.should_not be_nil
          if descriptor = parsed
            descriptor.function_name.should eq(function_name)
            descriptor.storage_type_name.should eq(declared_storage_name)
            descriptor.type_name.should eq(scalar_name)
          end

          column = CrystalClick::SimpleAggregateColumnType.parse(scalar_name)
          if inner_nullable
            # The legacy Wide-part facade models only outer Nullable around a
            # scalar-child SAF; it must not reinterpret inner storage NULL as
            # its nullable flag.
            column.should be_nil
          else
            column.should_not be_nil
            if parsed_column = column
              parsed_column.simple_aggregate_type.function_name.should eq(function_name)
              parsed_column.storage_type_name.should eq(declared_storage_name)
              parsed_column.nullable?.should be_false
              parsed_column.type_name.should eq(scalar_name)
            end
          end

          child_wire = CrystalClick::BinaryDataTypeCodec.encode(storage_type).to_a
          literal = w221_saf_wire(function_name, child_wire, inner_nullable: inner_nullable)
          decoded = w221_try_decode_type(literal)
          decoded.should_not be_nil
          if aggregate = decoded
            aggregate.name.should eq(scalar_name)
            aggregate.simple_aggregate_type.not_nil!.function_name.should eq(function_name)
            aggregate.child_count.should eq(1)
            if inner_nullable
              aggregate.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
              aggregate.child_at(0).child_at(0).should eq(storage_type)
            else
              aggregate.child_at(0).should eq(storage_type)
            end
            CrystalClick::BinaryDataTypeCodec.encode(aggregate).should eq(literal)
          end

          # Outer Nullable is supported around a bare SAF child. ClickHouse
          # rejects Nullable(SAF(..., Nullable(T))) because the actual SAF
          # child cannot itself be nested inside an outer Nullable.
          outer_name = "Nullable(#{scalar_name})"
          outer_column = CrystalClick::SimpleAggregateColumnType.parse(outer_name)
          outer_literal = w221_saf_wire(
            function_name,
            child_wire,
            inner_nullable: inner_nullable,
            outer_nullable: true,
          )
          if inner_nullable
            outer_column.should be_nil
            expect_raises(CrystalClick::CorruptPartError) do
              CrystalClick::BinaryDataTypeCodec.decode(outer_literal)
            end
            if aggregate = decoded
              expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(aggregate) }
            end
          else
            outer_column.should_not be_nil
            if parsed_outer = outer_column
              parsed_outer.simple_aggregate_type.function_name.should eq(function_name)
              parsed_outer.storage_type_name.should eq(declared_storage_name)
              parsed_outer.nullable?.should be_true
              parsed_outer.type_name.should eq(outer_name)
            end

            outer_decoded = w221_try_decode_type(outer_literal)
            outer_decoded.should_not be_nil
            if outer_type = outer_decoded
              outer_type.name.should eq(outer_name)
              outer_type.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
              outer_type.child_at(0).should eq(decoded.not_nil!)
              outer_type.should_not eq(decoded.not_nil!)
              CrystalClick::BinaryDataTypeCodec.encode(outer_type).should eq(outer_literal)
            end
          end
        end
      end
    end
  end

  it "admits Min over inner Nullable through descriptor, value, and bulk paths without collapsing outer placement" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable_uint64 = CrystalClick::BinaryDataType.nullable(uint64)
    child_wire = CrystalClick::BinaryDataTypeCodec.encode(uint64).to_a
    inner_name = "SimpleAggregateFunction(min, Nullable(UInt64))"
    inner_wire = w221_saf_wire("min", child_wire, inner_nullable: true)

    literal_type = w221_try_decode_type(inner_wire)
    literal_type.should_not be_nil
    constructed_type = w221_try_build_min(nullable_uint64)
    constructed_type.should_not be_nil
    if inner_type = literal_type
      inner_type.name.should eq(inner_name)
      inner_type.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
      inner_type.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      inner_type.child_at(0).child_at(0).should eq(uint64)
      inner_type.should eq(constructed_type.not_nil!)
      CrystalClick::BinaryDataTypeCodec.encode(inner_type).should eq(inner_wire)
      expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(inner_type) }
      CrystalClick::SimpleAggregateColumnType.parse("Nullable(#{inner_name})").should be_nil
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("min", child_wire, inner_nullable: true, outer_nullable: true))
      end

      parsed_inner_descriptor = CrystalClick::BinarySimpleAggregateType.parse(inner_name)
      parsed_inner_descriptor.should_not be_nil
      if descriptor = parsed_inner_descriptor
        descriptor.function_name.should eq("min")
        descriptor.storage_type_name.should eq("Nullable(UInt64)")
        descriptor.type_name.should eq(inner_name)
      end

      inner_column = CrystalClick::SimpleAggregateColumnType.parse(inner_name)
      inner_column.should be_nil
      expect_raises(ArgumentError) do
        CrystalClick::SimpleAggregateColumnType.new(
          CrystalClick::BinarySimpleAggregateType::Function::Min,
          false,
          "Nullable(UInt64)",
        )
      end

      inner_null_value = CrystalClick::BinaryValue.simple_aggregate(
        inner_type,
        CrystalClick::BinaryValue.nullable(nullable_uint64),
      )
      nullable_uint32 = CrystalClick::BinaryDataType.nullable(
        CrystalClick::BinaryDataType.primitive("UInt32")
      )
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.simple_aggregate(
          inner_type,
          CrystalClick::BinaryValue.nullable(
            nullable_uint32,
            CrystalClick::BinaryValue.fixed(
              nullable_uint32.child_at(0),
              Bytes[7_u8, 0_u8, 0_u8, 0_u8],
            ),
          ),
        )
      end
      inner_zero_value = CrystalClick::BinaryValue.simple_aggregate(
        inner_type,
        CrystalClick::BinaryValue.nullable(nullable_uint64, CrystalClick::BinaryValue.uint64(0_u64)),
      )
      inner_seven_value = CrystalClick::BinaryValue.simple_aggregate(
        inner_type,
        CrystalClick::BinaryValue.nullable(nullable_uint64, CrystalClick::BinaryValue.uint64(7_u64)),
      )

      CrystalClick::BinaryValueCodec.encode(inner_null_value).should eq(w221_bytes(inner_wire.to_a + [1_u8]))
      decoded_inner_null = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(inner_null_value))
      decoded_inner_null.type.should eq(inner_type)
      decoded_inner_null.as_simple_aggregate.is_null?.should be_true
      decoded_inner_zero = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(inner_zero_value))
      decoded_inner_zero.type.should eq(inner_type)
      decoded_inner_zero.as_simple_aggregate.child_at(0).as_uint64.should eq(0_u64)
      CrystalClick::BinaryValueCodec.decode_value(inner_type, w221_bytes([0_u8] + w221_le_u64(0_u64))).as_simple_aggregate.child_at(0).as_uint64.should eq(0_u64)

      rows = [
        inner_null_value,
        inner_zero_value,
        inner_seven_value,
        inner_null_value,
        CrystalClick::BinaryValue.simple_aggregate(
          inner_type,
          CrystalClick::BinaryValue.nullable(nullable_uint64, CrystalClick::BinaryValue.uint64(9_u64)),
        ),
      ] of CrystalClick::BinaryValue
      bulk = CrystalClick::BinaryBulkCodec.encode(inner_type, [rows])
      bulk.roles.should eq(["root.nested.data", "root.nulls"] of String)
      bulk.stream("root.nulls").bytes.to_a.should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      expected_data = [] of UInt8
      [0_u64, 0_u64, 7_u64, 0_u64, 9_u64].each do |value|
        expected_data.concat(w221_le_u64(value))
      end
      bulk.stream("root.nested.data").bytes.to_a.should eq(expected_data)

      decoded_rows = CrystalClick::BinaryBulkCodec.decode(inner_type, bulk, [5_u64])
      decoded_rows[0].map { |value| value.type }.should eq([
        inner_type,
        inner_type,
        inner_type,
        inner_type,
        inner_type,
      ])
      decoded_rows[0][0].as_simple_aggregate.is_null?.should be_true
      decoded_rows[0][1].as_simple_aggregate.child_at(0).as_uint64.should eq(0_u64)
      decoded_rows[0][2].as_simple_aggregate.child_at(0).as_uint64.should eq(7_u64)
      decoded_rows[0][3].as_simple_aggregate.is_null?.should be_true
      decoded_rows[0][4].as_simple_aggregate.child_at(0).as_uint64.should eq(9_u64)

      inner_plan = CrystalClick::BinaryBulkPhysicalPlan.new(inner_type, "v")
      inner_plan.stream_names.should eq({
        "root.nested.data" => "v",
        "root.nulls"       => "v.null",
      })

      # This is outer Nullable around SAF(min, UInt64), a distinct placement
      # from SAF(min, Nullable(UInt64)).
      plain_min = CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        uint64,
      )
      outer_wire = w221_saf_wire("min", child_wire, outer_nullable: true)
      outer_type = CrystalClick::BinaryDataTypeCodec.decode(outer_wire)
      outer_type.name.should eq("Nullable(SimpleAggregateFunction(min, UInt64))")
      outer_type.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      outer_type.child_at(0).should eq(plain_min)
      outer_type.should_not eq(inner_type)
      CrystalClick::BinaryDataTypeCodec.encode(outer_type).should eq(outer_wire)

      outer_column = CrystalClick::SimpleAggregateColumnType.parse(outer_type.name)
      outer_column.should_not be_nil
      if parsed_outer = outer_column
        parsed_outer.storage_type_name.should eq("UInt64")
        parsed_outer.nullable?.should be_true
      end

      outer_value = CrystalClick::BinaryValue.nullable(
        outer_type,
        CrystalClick::BinaryValue.simple_aggregate(plain_min, CrystalClick::BinaryValue.uint64(0_u64)),
      )
      decoded_outer_value = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(outer_value))
      decoded_outer_value.type.should eq(outer_type)
      decoded_outer_value.is_null?.should be_false
      decoded_outer_value.child_at(0).as_simple_aggregate.as_uint64.should eq(0_u64)
    end
  end

  it "round-trips inner Nullable(String) in both bulk String profiles" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    name = "SimpleAggregateFunction(any_respect_nulls, Nullable(String))"
    wire = w221_saf_wire(
      "any_respect_nulls",
      CrystalClick::BinaryDataTypeCodec.encode(string).to_a,
      inner_nullable: true,
    )
    aggregate = w221_try_decode_type(wire)
    aggregate.should_not be_nil
    if aggregate_type = aggregate
      aggregate_type.name.should eq(name)
      rows = [
        w221_make_aggregate_value(aggregate_type, nullable_string, nil),
        w221_make_aggregate_value(aggregate_type, nullable_string, ""),
        w221_make_aggregate_value(aggregate_type, nullable_string, "a\0b"),
        w221_make_aggregate_value(aggregate_type, nullable_string, nil),
        w221_make_aggregate_value(aggregate_type, nullable_string, "z"),
      ] of CrystalClick::BinaryValue

      [
        {"single", CrystalClick::BinaryBulkProfile.single_stream},
        {"with-size", CrystalClick::BinaryBulkProfile.with_size_stream},
      ].each do |profile_name, profile|
        bulk = CrystalClick::BinaryBulkCodec.encode(aggregate_type, [rows], profile: profile)
        expected_roles = profile.single_stream? ? ["root.nested.data", "root.nulls"] : [
          "root.nested.data",
          "root.nested.string_sizes",
          "root.nulls",
        ]
        bulk.roles.should eq(expected_roles)
        bulk.stream("root.nulls").bytes.to_a.should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
        if profile.single_stream?
          # The single-stream profile prefixes every String with a VarUInt
          # byte length; NULL rows recurse through the empty default String.
          bulk.stream("root.nested.data").bytes.should eq(Bytes[
            0_u8, 0_u8, 3_u8, 0x61_u8, 0x00_u8, 0x62_u8, 0_u8, 1_u8, 0x7a_u8,
          ])
          bulk.stream("root.nested.data").offsets.should eq([0_u64, 9_u64])
        else
          bulk.stream("root.nested.data").bytes.should eq(Bytes[0x61_u8, 0x00_u8, 0x62_u8, 0x7a_u8])
          bulk.stream("root.nested.data").offsets.should eq([0_u64, 4_u64])
        end

        if profile.with_size_stream?
          sizes = [] of UInt8
          [0_u64, 0_u64, 3_u64, 0_u64, 1_u64].each { |size| sizes.concat(w221_le_u64(size)) }
          bulk.stream("root.nested.string_sizes").bytes.to_a.should eq(sizes)
          bulk.stream("root.nested.string_sizes").offsets.should eq([0_u64, 40_u64])
        end

        decoded = CrystalClick::BinaryBulkCodec.decode(
          aggregate_type,
          bulk,
          [5_u64],
          profile: profile,
        )
        decoded[0].map { |value| value.type }.should eq([
          aggregate_type,
          aggregate_type,
          aggregate_type,
          aggregate_type,
          aggregate_type,
        ])
        decoded[0][0].as_simple_aggregate.is_null?.should be_true
        decoded[0][1].as_simple_aggregate.child_at(0).as_string.should eq("")
        decoded[0][2].as_simple_aggregate.child_at(0).as_string.should eq("a\0b")
        decoded[0][3].as_simple_aggregate.is_null?.should be_true
        decoded[0][4].as_simple_aggregate.child_at(0).as_string.should eq("z")
        profile_name.should_not be_empty
      end
    end
  end

  it "composes an admitted inner-Nullable SAF descriptor through Array, Tuple, and Map roots" do
    child_wire = [CrystalClick::BinaryDataType::TAG_UINT64]
    inner_wire = w221_saf_wire("min", child_wire, inner_nullable: true)
    aggregate = w221_try_decode_type(inner_wire)
    aggregate.should_not be_nil
    if aggregate_type = aggregate
      wrappers = [
        CrystalClick::BinaryDataType.array(aggregate_type),
        CrystalClick::BinaryDataType.tuple([aggregate_type] of CrystalClick::BinaryDataType),
        CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), aggregate_type),
      ] of CrystalClick::BinaryDataType

      wrappers.each do |wrapper|
        encoded = CrystalClick::BinaryDataTypeCodec.encode(wrapper)
        decoded = CrystalClick::BinaryDataTypeCodec.decode(encoded)
        decoded.should eq(wrapper)
        decoded.name.should eq(wrapper.name)
        decoded.contains_qbit?.should be_false
        decoded.child_count.should be > 0
      end

      wrappers.map(&.name).should eq([
        "Array(SimpleAggregateFunction(min, Nullable(UInt64)))",
        "Tuple(SimpleAggregateFunction(min, Nullable(UInt64)))",
        "Map(String, SimpleAggregateFunction(min, Nullable(UInt64)))",
      ])
    end
  end

  it "honors the longest function and existing 32-byte timezone witness under derived name bounds" do
    zone = "America/Argentina/ComodRivadavia"
    zone.bytesize.should eq(CrystalClick::TimezoneName::MAX_NAME_BYTES)
    storage = CrystalClick::BinaryDataType.datetime64(3, zone)
    storage_name = storage.name
    inner_storage_name = "Nullable(#{storage_name})"
    scalar_name = "SimpleAggregateFunction(anyLast_respect_nulls, #{inner_storage_name})"
    scalar_name.bytesize.should eq(107)

    parsed = CrystalClick::BinarySimpleAggregateType.parse(scalar_name)
    parsed.should_not be_nil
    if descriptor = parsed
      descriptor.function_name.should eq("anyLast_respect_nulls")
      descriptor.storage_type_name.should eq(inner_storage_name)
      descriptor.type_name.should eq(scalar_name)
    end

    column = CrystalClick::SimpleAggregateColumnType.parse(scalar_name)
    column.should be_nil

    literal = w221_saf_wire(
      "anyLast_respect_nulls",
      CrystalClick::BinaryDataTypeCodec.encode(storage).to_a,
      inner_nullable: true,
    )
    decoded = w221_try_decode_type(literal)
    decoded.should_not be_nil
    if aggregate = decoded
      aggregate.name.should eq(scalar_name)
      aggregate.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      aggregate.child_at(0).child_at(0).should eq(storage)
      CrystalClick::BinaryDataTypeCodec.encode(aggregate).should eq(literal)
    end

    respect_functions = [
      {"any_respect_nulls", CrystalClick::BinarySimpleAggregateType::Function::AnyRespectNulls},
      {"anyLast_respect_nulls", CrystalClick::BinarySimpleAggregateType::Function::AnyLastRespectNulls},
    ] of Tuple(String, CrystalClick::BinarySimpleAggregateType::Function)
    respect_functions.each do |function_name, function|
      bare_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
      bare_column = CrystalClick::SimpleAggregateColumnType.parse(bare_name)
      bare_column.should_not be_nil
      if parsed_column = bare_column
        parsed_column.function.should eq(function)
        parsed_column.nullable?.should be_false
      end

      bare_plan = CrystalClick::SimpleAggregateTemporalStoragePlan.for_type_name(bare_name)
      bare_plan.should_not be_nil
      if bare_plan_value = bare_plan
        bare_plan_value.function.should eq(function)
        bare_plan_value.storage_type_name.should eq(storage_name)
        bare_plan_value.nullable?.should be_false
      end

      outer_name = "Nullable(#{bare_name})"
      outer_name.bytesize.should eq(bare_name.bytesize + "Nullable()".bytesize)
      if function == CrystalClick::BinarySimpleAggregateType::Function::AnyLastRespectNulls
        outer_name.bytesize.should eq(CrystalClick::SimpleAggregateColumnType::MAX_TYPE_BYTES)
      end
      outer_plan = CrystalClick::SimpleAggregateTemporalStoragePlan.for_type_name(outer_name)
      outer_plan.should_not be_nil
      if outer_plan_value = outer_plan
        outer_plan_value.function.should eq(function)
        outer_plan_value.storage_type_name.should eq(storage_name)
        outer_plan_value.nullable?.should be_true
        outer_plan_value.type_name.should eq(outer_name)
      end
      CrystalClick::SimpleAggregateTemporalStoragePlan.type_name(function, storage_name, true).should eq(outer_name)
    end
  end

  it "rejects wrong function/result pairs, parameters, extra args, aliases, noncanonical text, and repeated Nullable" do
    invalid_names = [
      "SimpleAggregateFunction(sum, Nullable(String))",
      "SimpleAggregateFunction(sum, Nullable(UInt8))",
      "SimpleAggregateFunction(anyRespectNulls, Nullable(UInt64))",
      "SimpleAggregateFunction(any_respect_null, Nullable(UInt64))",
      "SimpleAggregateFunction(anyLastRespectNulls, Nullable(UInt64))",
      "SimpleAggregateFunction(AnyLast_respect_nulls, Nullable(UInt64))",
      "SimpleAggregateFunction(any_respect_nulls , Nullable(UInt64))",
      "SimpleAggregateFunction(any_respect_nulls, Nullable( UInt64))",
      "SimpleAggregateFunction(any_respect_nulls, Nullable(UInt64) )",
      "SimpleAggregateFunction(any_respect_nulls, Nullable(UInt64, UInt8))",
      "SimpleAggregateFunction(min, Nullable(Nullable(UInt64)))",
      "Nullable(Nullable(SimpleAggregateFunction(min, UInt64)))",
    ]
    invalid_names.each do |name|
      CrystalClick::BinarySimpleAggregateType.parse(name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(name).should be_nil
    end

    nullable_uint64_wire = w221_nullable_wire([CrystalClick::BinaryDataType::TAG_UINT64])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("sum", [CrystalClick::BinaryDataType::TAG_STRING], inner_nullable: true))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("sum", [CrystalClick::BinaryDataType::TAG_UINT8], inner_nullable: true))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("any_respect_nulls", [CrystalClick::BinaryDataType::TAG_UINT64], parameter_count: 1_u64))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("any_respect_nulls", [CrystalClick::BinaryDataType::TAG_UINT64], argument_count: 2_u64))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("anyRespectNulls", nullable_uint64_wire))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(w221_saf_wire("min", nullable_uint64_wire, inner_nullable: true))
    end
    double_outer_wire = w221_bytes(
      [CrystalClick::BinaryDataType::TAG_NULLABLE] +
        w221_saf_wire("min", [CrystalClick::BinaryDataType::TAG_UINT64], outer_nullable: true).to_a
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(double_outer_wire)
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.nullable(
          CrystalClick::BinaryDataType.primitive("UInt64")
        )),
      )
    end
  end

  it "bounds direct inner-Nullable admission before extracting its child name" do
    repeated_nullable = "Nullable(Nullable(UInt64))"
    CrystalClick::BinarySimpleAggregateType.admitted_function_storage?(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      repeated_nullable,
    ).should be_false
    expect_raises(ArgumentError) do
      CrystalClick::BinarySimpleAggregateType.new(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        repeated_nullable,
      )
    end
    CrystalClick::BinarySimpleAggregateType.from_name("min", repeated_nullable).should be_nil

    oversized_nullable = "Nullable(" +
                         ("x" * CrystalClick::BinarySimpleAggregateType::MAX_STORAGE_TYPE_BYTES) + ")"
    CrystalClick::BinarySimpleAggregateType.admitted_function_storage?(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      oversized_nullable,
    ).should be_false
    expect_raises(ArgumentError) do
      CrystalClick::BinarySimpleAggregateType.new(
        CrystalClick::BinarySimpleAggregateType::Function::Min,
        oversized_nullable,
      )
    end
    CrystalClick::BinarySimpleAggregateType.from_name("min", oversized_nullable).should be_nil
    CrystalClick::BinarySimpleAggregateType.parse(
      "SimpleAggregateFunction(min, #{oversized_nullable})"
    ).should be_nil
  end
end
