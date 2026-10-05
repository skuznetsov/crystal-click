require "./spec_helper"

private W168_TEXT_FUNCTIONS = [
  {"any", CrystalClick::BinarySimpleAggregateType::Function::Any},
  {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
  {"min", CrystalClick::BinarySimpleAggregateType::Function::Min},
  {"max", CrystalClick::BinarySimpleAggregateType::Function::Max},
]

private W168_TEXT_CHILDREN = [
  {"String", CrystalClick::BinaryDataType.primitive("String"), [0x15_u8]},
  {"FixedString(1)", CrystalClick::BinaryDataType.fixed_string(1), [0x16_u8, 0x01_u8]},
  {"FixedString(3)", CrystalClick::BinaryDataType.fixed_string(3), [0x16_u8, 0x03_u8]},
  {"FixedString(130)", CrystalClick::BinaryDataType.fixed_string(130), [0x16_u8, 0x82_u8, 0x01_u8]},
  {"FixedString(65536)", CrystalClick::BinaryDataType.fixed_string(65_536), [0x16_u8, 0x80_u8, 0x80_u8, 0x04_u8]},
]

private W168_REJECTED_TEXT_FUNCTIONS = [
  {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum},
  {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow},
  {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd},
  {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr},
  {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor},
]

private W168_NONCANONICAL_FIXED_WIDTHS = [
  "FixedString(0)",
  "FixedString(03)",
  "FixedString(65537)",
  "FixedString(+3)",
  "FixedString(3 )",
]

private def w168_var_uint(value : UInt64) : Array(UInt8)
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

private def w168_bytes(values : Array(UInt8)) : Bytes
  Bytes.new(values.size) { |index| values[index] }
end

private def w168_le_u64(value : UInt64) : Array(UInt8)
  Array(UInt8).new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w168_to_physical(
  plan : CrystalClick::BinaryBulkPhysicalPlan,
  logical : CrystalClick::BinaryBulkStreams,
) : Hash(String, CrystalClick::BinaryBulkStream)
  bindings = plan.stream_names
  unless bindings.keys.sort == logical.roles
    raise ArgumentError.new("W168 logical roles differ from the physical plan")
  end

  physical = Hash(String, CrystalClick::BinaryBulkStream).new
  bindings.each do |role, basename|
    physical[basename] = logical.stream(role)
  end
  physical
end

private def w168_from_physical(
  plan : CrystalClick::BinaryBulkPhysicalPlan,
  mark_count : Int32,
  physical : Hash(String, CrystalClick::BinaryBulkStream),
) : CrystalClick::BinaryBulkStreams
  logical = Hash(String, CrystalClick::BinaryBulkStream).new
  plan.stream_names.each do |role, basename|
    logical[role] = physical[basename]? || raise(KeyError.new("W168 physical stream binding is missing"))
  end
  unless physical.size == logical.size
    raise ArgumentError.new("W168 physical stream bindings contain unplanned lanes")
  end
  CrystalClick::BinaryBulkStreams.new(mark_count, logical)
end

private def w168_literal_descriptor(
  function_name : String,
  child_wire : Array(UInt8),
  nullable : Bool = false,
) : Bytes
  bytes = [] of UInt8
  bytes << 0x23_u8 if nullable # Nullable wraps the complete aggregate node.
  bytes << 0x2e_u8             # SimpleAggregateFunction descriptor tag.
  bytes.concat(w168_var_uint(function_name.bytesize.to_u64))
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # zero Field parameters
  bytes << 1_u8 # one argument type
  bytes.concat(child_wire)
  w168_bytes(bytes)
end

private def w168_build_type(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  child : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType
  type : CrystalClick::BinaryDataType? = nil
  begin
    type = CrystalClick::BinaryDataType.simple_aggregate(function, child)
  rescue ex : ArgumentError
    # Turn the current admission refusal into an expectation failure, not an
    # uncaught error; successful behavior uses only the existing public API.
    nil
  end
  type.should_not be_nil
  type.not_nil!
end

private def w168_decode_type(wire : Bytes) : CrystalClick::BinaryDataType
  type : CrystalClick::BinaryDataType? = nil
  begin
    type = CrystalClick::BinaryDataTypeCodec.decode(wire)
  rescue ex : CrystalClick::UnsupportedFormatError
    # The literal positive wire declaration must be admitted by this profile.
    nil
  end
  type.should_not be_nil
  type.not_nil!
end

private def w168_child_value(
  type : CrystalClick::BinaryDataType,
  salt : Int32,
) : CrystalClick::BinaryValue
  case type.tag
  when CrystalClick::BinaryDataType::TAG_STRING
    CrystalClick::BinaryValue.string(String.new(Bytes[salt.to_u8, 0x00_u8, 0xff_u8]))
  when CrystalClick::BinaryDataType::TAG_FIXED_STRING
    width = type.fixed_width.not_nil!
    raw = Bytes.new(width) { |index| ((index * 31 + salt) % 256).to_u8 }
    CrystalClick::BinaryValue.fixed(type, raw)
  else
    raise ArgumentError.new("W168 test child must be String or FixedString")
  end
end

private def w168_value_payload(value : CrystalClick::BinaryValue) : Array(UInt8)
  if value.type.tag == CrystalClick::BinaryDataType::TAG_STRING
    raw = value.as_string.to_slice.to_a
    w168_var_uint(raw.size.to_u64) + raw
  else
    value.bytes.to_a
  end
end

private def w168_assert_child_payload(
  value : CrystalClick::BinaryValue,
  expected_type : CrystalClick::BinaryDataType,
  expected_bytes : Array(UInt8),
) : Nil
  value.type.should eq(expected_type)
  if expected_type.tag == CrystalClick::BinaryDataType::TAG_STRING
    value.as_string.to_slice.to_a.should eq(expected_bytes)
  else
    value.bytes.to_a.should eq(expected_bytes)
  end
end

describe "W168 SimpleAggregateFunction String and FixedString core admission" do
  it "admits exactly the stock-qualified text carriers with canonical outer Nullable identity" do
    W168_TEXT_FUNCTIONS.each do |function_name, function|
      W168_TEXT_CHILDREN.each do |storage_name, _child, _child_wire|
        scalar_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
        scalar = CrystalClick::BinarySimpleAggregateType.parse(scalar_name)
        scalar.should_not be_nil
        if aggregate_type = scalar
          aggregate_type.function.should eq(function)
          aggregate_type.storage_type_name.should eq(storage_name)
          aggregate_type.type_name.should eq(scalar_name)
        end

        column_type = CrystalClick::SimpleAggregateColumnType.parse(scalar_name)
        column_type.should_not be_nil
        if column = column_type
          column.function.should eq(function)
          column.storage_type_name.should eq(storage_name)
          column.nullable?.should be_false
          column.type_name.should eq(scalar_name)
          if storage_name == "String"
            column.string?.should be_true
            column.fixed_string_width.should be_nil
            expect_raises(ArgumentError) { column.raw_width }
          elsif width = CrystalClick::BinarySimpleAggregateType.fixed_string_width(storage_name)
            column.string?.should be_false
            column.fixed_string_width.should eq(width)
            expect_raises(ArgumentError) { column.raw_width }
          end
        end

        nullable_name = "Nullable(#{scalar_name})"
        nullable_column = CrystalClick::SimpleAggregateColumnType.parse(nullable_name)
        nullable_column.should_not be_nil
        if column = nullable_column
          column.function.should eq(function)
          column.storage_type_name.should eq(storage_name)
          column.nullable?.should be_true
          column.type_name.should eq(nullable_name)
        end
      end
    end
  end

  it "constructs and round-trips the literal child-parameterized descriptors" do
    W168_TEXT_FUNCTIONS.each do |function_name, function|
      W168_TEXT_CHILDREN.each do |storage_name, child, child_wire|
        scalar_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
        scalar_wire = w168_literal_descriptor(function_name, child_wire)
        scalar = w168_build_type(function, child)
        scalar.name.should eq(scalar_name)
        scalar.child_count.should eq(1)
        scalar.child_at(0).should eq(child)
        CrystalClick::BinaryDataTypeCodec.encode(scalar).should eq(scalar_wire)
        w168_decode_type(scalar_wire).should eq(scalar)

        nullable = CrystalClick::BinaryDataType.nullable(scalar)
        nullable_wire = w168_literal_descriptor(function_name, child_wire, nullable: true)
        nullable.name.should eq("Nullable(#{scalar_name})")
        nullable.child_at(0).should eq(scalar)
        CrystalClick::BinaryDataTypeCodec.encode(nullable).should eq(nullable_wire)
        w168_decode_type(nullable_wire).should eq(nullable)
      end
    end

    CrystalClick::BinarySimpleAggregateType.fixed_string_width("FixedString(1)").should eq(1)
    CrystalClick::BinarySimpleAggregateType.fixed_string_width("FixedString(65536)").should eq(65_536)
    W168_NONCANONICAL_FIXED_WIDTHS.each do |storage_name|
      CrystalClick::BinarySimpleAggregateType.fixed_string_width(storage_name).should be_nil
    end
  end

  it "preserves String bytes and FixedString width through scalar values and bulk streams" do
    [
      {"any", CrystalClick::BinarySimpleAggregateType::Function::Any, W168_TEXT_CHILDREN[0]},
      {"min", CrystalClick::BinarySimpleAggregateType::Function::Min, W168_TEXT_CHILDREN[2]},
    ].each do |function_name, function, child_case|
      storage_name, child_type, child_wire = child_case
      aggregate_type = w168_build_type(function, child_type)
      aggregate_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
      aggregate_type.name.should eq(aggregate_name)

      first_child = w168_child_value(child_type, 0x41)
      second_child = w168_child_value(child_type, 0x7b)
      first_value = CrystalClick::BinaryValue.simple_aggregate(aggregate_type, first_child)
      second_value = CrystalClick::BinaryValue.simple_aggregate(aggregate_type, second_child)
      first_payload = w168_value_payload(first_child)
      second_payload = w168_value_payload(second_child)

      CrystalClick::BinaryValueCodec.encode_value(first_value).to_a.should eq(first_payload)
      decoded_value = CrystalClick::BinaryValueCodec.decode_value(aggregate_type, w168_bytes(first_payload))
      decoded_value.type.should eq(aggregate_type)
      w168_assert_child_payload(decoded_value.as_simple_aggregate, child_type, first_child.bytes.to_a)

      scalar_wire = w168_literal_descriptor(function_name, child_wire).to_a + first_payload
      CrystalClick::BinaryValueCodec.encode(first_value).to_a.should eq(scalar_wire)
      decoded_envelope = CrystalClick::BinaryValueCodec.decode(w168_bytes(scalar_wire))
      decoded_envelope.type.should eq(aggregate_type)
      w168_assert_child_payload(decoded_envelope.as_simple_aggregate, child_type, first_child.bytes.to_a)

      scalar_bulk = CrystalClick::BinaryBulkCodec.encode(
        aggregate_type,
        [[first_value, second_value] of CrystalClick::BinaryValue]
      )
      scalar_bulk.roles.should eq(["root.data"] of String)
      scalar_bulk.stream("root.data").bytes.to_a.should eq(first_payload + second_payload)
      CrystalClick::BinaryBulkPhysicalPlan.new(aggregate_type, "v").stream_names.should eq({
        "root.data" => "v",
      })
      scalar_decoded = CrystalClick::BinaryBulkCodec.decode(aggregate_type, scalar_bulk, [2_u64])
      scalar_decoded.size.should eq(1)
      scalar_decoded[0].size.should eq(2)
      scalar_decoded[0][0].type.should eq(aggregate_type)
      scalar_decoded[0][1].type.should eq(aggregate_type)
      w168_assert_child_payload(scalar_decoded[0][0].as_simple_aggregate, child_type, first_child.bytes.to_a)
      w168_assert_child_payload(scalar_decoded[0][1].as_simple_aggregate, child_type, second_child.bytes.to_a)

      nullable_type = CrystalClick::BinaryDataType.nullable(aggregate_type)
      nullable_value = CrystalClick::BinaryValue.nullable(nullable_type, first_value)
      null_value = CrystalClick::BinaryValue.nullable(nullable_type)
      nullable_wire = w168_literal_descriptor(function_name, child_wire, nullable: true)
      CrystalClick::BinaryValueCodec.encode(nullable_value).to_a.should eq(
        nullable_wire.to_a + [0_u8] + first_payload
      )
      CrystalClick::BinaryValueCodec.encode(null_value).to_a.should eq(nullable_wire.to_a + [1_u8])

      nullable_bulk_values = [nullable_value, null_value, CrystalClick::BinaryValue.nullable(nullable_type, second_value)] of CrystalClick::BinaryValue
      nullable_bulk = CrystalClick::BinaryBulkCodec.encode(nullable_type, [nullable_bulk_values])
      nullable_bulk.roles.should eq(["root.nested.data", "root.nulls"] of String)
      CrystalClick::BinaryBulkPhysicalPlan.new(nullable_type, "v").stream_names.should eq({
        "root.nested.data" => "v",
        "root.nulls"       => "v.null",
      })
      nullable_bulk.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
      default_payload = if child_type.tag == CrystalClick::BinaryDataType::TAG_STRING
                          [0_u8]
                        else
                          Array(UInt8).new(child_type.fixed_width.not_nil!, 0_u8)
                        end
      nullable_bulk.stream("root.nested.data").bytes.to_a.should eq(
        first_payload + default_payload + second_payload
      )
      nullable_decoded = CrystalClick::BinaryBulkCodec.decode(nullable_type, nullable_bulk, [3_u64])
      nullable_decoded[0][0].is_null?.should be_false
      nullable_decoded[0][0].child_at(0).type.should eq(aggregate_type)
      w168_assert_child_payload(nullable_decoded[0][0].child_at(0).as_simple_aggregate, child_type, first_child.bytes.to_a)
      nullable_decoded[0][1].is_null?.should be_true
      nullable_decoded[0][2].child_at(0).type.should eq(aggregate_type)
      w168_assert_child_payload(nullable_decoded[0][2].child_at(0).as_simple_aggregate, child_type, second_child.bytes.to_a)
    end
  end

  it "decodes hand-authored scalar and nullable literals with nominal identity and default lanes" do
    any = CrystalClick::BinarySimpleAggregateType::Function::Any
    string_type = CrystalClick::BinaryDataType.primitive("String")
    string_aggregate = CrystalClick::BinaryDataType.simple_aggregate(any, string_type)
    string_descriptor = w168_literal_descriptor("any", [0x15_u8])
    string_aggregate.name.should eq("SimpleAggregateFunction(any, String)")

    # Three independently authored String rows: empty, one NUL byte, and UTF-8
    # e-acute. The prefixes are byte lengths, not character counts.
    string_payload = Bytes[0x00_u8, 0x01_u8, 0x00_u8, 0x02_u8, 0xc3_u8, 0xa9_u8]
    literal_string_value = CrystalClick::BinaryValueCodec.decode_value(
      string_aggregate,
      Bytes[0x02_u8, 0xc3_u8, 0xa9_u8]
    )
    literal_string_value.type.should eq(string_aggregate)
    literal_string_value.as_simple_aggregate.as_string.to_slice.to_a.should eq([0xc3_u8, 0xa9_u8])
    string_envelope = string_descriptor.to_a + [0x02_u8, 0xc3_u8, 0xa9_u8]
    literal_envelope = CrystalClick::BinaryValueCodec.decode(w168_bytes(string_envelope))
    literal_envelope.type.should eq(string_aggregate)
    literal_envelope.as_simple_aggregate.as_string.to_slice.to_a.should eq([0xc3_u8, 0xa9_u8])

    string_lanes = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(string_payload, [0_u64, string_payload.size.to_u64]),
    })
    decoded_strings = CrystalClick::BinaryBulkCodec.decode(string_aggregate, string_lanes, [3_u64])
    decoded_strings[0].map { |value| value.as_simple_aggregate.as_string.to_slice.to_a }.should eq([
      [] of UInt8,
      [0x00_u8],
      [0xc3_u8, 0xa9_u8],
    ])
    CrystalClick::BinaryBulkPhysicalPlan.new(string_aggregate, "s").stream_names.should eq({
      "root.data" => "s",
    })

    nullable_string = CrystalClick::BinaryDataType.nullable(string_aggregate)
    # Empty String and NULL have equal default nested payload bytes. The null
    # bitmap, not the nested bytes, distinguishes the second row.
    nullable_string_data = Bytes[0x00_u8, 0x00_u8, 0x02_u8, 0xc3_u8, 0xa9_u8]
    nullable_string_lanes = CrystalClick::BinaryBulkStreams.new(1, {
      "root.nested.data" => CrystalClick::BinaryBulkStream.new(
        nullable_string_data,
        [0_u64, nullable_string_data.size.to_u64]
      ),
      "root.nulls" => CrystalClick::BinaryBulkStream.new(Bytes[0_u8, 1_u8, 0_u8], [0_u64, 3_u64]),
    })
    nullable_strings = CrystalClick::BinaryBulkCodec.decode(nullable_string, nullable_string_lanes, [3_u64])
    nullable_strings[0][0].is_null?.should be_false
    nullable_strings[0][0].child_at(0).as_simple_aggregate.as_string.should eq("")
    nullable_strings[0][1].is_null?.should be_true
    nullable_strings[0][2].child_at(0).as_simple_aggregate.as_string.to_slice.to_a.should eq([0xc3_u8, 0xa9_u8])
    CrystalClick::BinaryBulkPhysicalPlan.new(nullable_string, "s").stream_names.should eq({
      "root.nested.data" => "s",
      "root.nulls"       => "s.null",
    })

    fixed_type = CrystalClick::BinaryDataType.fixed_string(3)
    fixed_aggregate = CrystalClick::BinaryDataType.simple_aggregate(any, fixed_type)
    fixed_descriptor = w168_literal_descriptor("any", [0x16_u8, 0x03_u8])
    fixed_aggregate.name.should eq("SimpleAggregateFunction(any, FixedString(3))")
    literal_fixed_value = CrystalClick::BinaryValueCodec.decode_value(
      fixed_aggregate,
      Bytes[0x41_u8, 0x00_u8, 0xff_u8]
    )
    literal_fixed_value.type.should eq(fixed_aggregate)
    literal_fixed_value.as_simple_aggregate.bytes.should eq(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
    fixed_envelope = CrystalClick::BinaryValueCodec.decode(
      w168_bytes(fixed_descriptor.to_a + [0x41_u8, 0x00_u8, 0xff_u8])
    )
    fixed_envelope.type.should eq(fixed_aggregate)
    fixed_envelope.as_simple_aggregate.bytes.should eq(Bytes[0x41_u8, 0x00_u8, 0xff_u8])

    nullable_fixed = CrystalClick::BinaryDataType.nullable(fixed_aggregate)
    # The middle row is NULL with the fixed-width zero placeholder; the final
    # row is a real all-zero FixedString and must remain non-NULL.
    nullable_fixed_data = Bytes[0x41_u8, 0x00_u8, 0xff_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    nullable_fixed_lanes = CrystalClick::BinaryBulkStreams.new(1, {
      "root.nested.data" => CrystalClick::BinaryBulkStream.new(
        nullable_fixed_data,
        [0_u64, nullable_fixed_data.size.to_u64]
      ),
      "root.nulls" => CrystalClick::BinaryBulkStream.new(Bytes[0_u8, 1_u8, 0_u8], [0_u64, 3_u64]),
    })
    nullable_fixed_values = CrystalClick::BinaryBulkCodec.decode(nullable_fixed, nullable_fixed_lanes, [3_u64])
    nullable_fixed_values[0][0].is_null?.should be_false
    nullable_fixed_values[0][0].child_at(0).as_simple_aggregate.bytes.should eq(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
    nullable_fixed_values[0][1].is_null?.should be_true
    nullable_fixed_values[0][2].is_null?.should be_false
    nullable_fixed_values[0][2].child_at(0).as_simple_aggregate.bytes.should eq(Bytes[0_u8, 0_u8, 0_u8])

    min_string = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      string_type
    )
    min_string.should_not eq(string_aggregate)
    string_child = CrystalClick::BinaryValue.string("ok")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.simple_aggregate(fixed_aggregate, string_child)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.simple_aggregate(string_aggregate, literal_fixed_value.as_simple_aggregate)
    end
    fixed_width_one = CrystalClick::BinaryDataType.simple_aggregate(
      any,
      CrystalClick::BinaryDataType.fixed_string(1)
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.simple_aggregate(fixed_width_one, literal_fixed_value.as_simple_aggregate)
    end
  end

  it "binds WITH_SIZE_STREAM text lanes and round-trips literal and encoded role streams" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    any = CrystalClick::BinarySimpleAggregateType::Function::Any
    min = CrystalClick::BinarySimpleAggregateType::Function::Min

    string_type = CrystalClick::BinaryDataType.primitive("String")
    string_aggregate = CrystalClick::BinaryDataType.simple_aggregate(any, string_type)
    string_values = [
      CrystalClick::BinaryValue.simple_aggregate(string_aggregate, CrystalClick::BinaryValue.string("")),
      CrystalClick::BinaryValue.simple_aggregate(string_aggregate, CrystalClick::BinaryValue.string("a\0b")),
    ] of CrystalClick::BinaryValue
    string_encoded = CrystalClick::BinaryBulkCodec.encode(
      string_aggregate,
      [string_values, [] of CrystalClick::BinaryValue],
      profile: profile
    )
    string_encoded.roles.should eq(["root.data", "root.string_sizes"] of String)
    string_encoded.stream("root.string_sizes").bytes.should eq(w168_bytes(
      w168_le_u64(0_u64) + w168_le_u64(3_u64)
    ))
    string_encoded.stream("root.string_sizes").offsets.should eq([0_u64, 16_u64, 16_u64])
    string_encoded.stream("root.data").bytes.should eq(Bytes[0x61_u8, 0x00_u8, 0x62_u8])
    string_encoded.stream("root.data").offsets.should eq([0_u64, 3_u64, 3_u64])
    string_plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      string_aggregate,
      "s",
      profile: profile
    )
    string_plan.stream_names.should eq({
      "root.data"         => "s",
      "root.string_sizes" => "s.size",
    })
    string_physical = w168_to_physical(string_plan, string_encoded)
    string_physical.keys.sort.should eq(["s", "s.size"] of String)
    string_physical["s.size"].bytes.should eq(w168_bytes(w168_le_u64(0_u64) + w168_le_u64(3_u64)))
    string_encoded_restored = w168_from_physical(string_plan, 2, string_physical)
    string_encoded_decoded = CrystalClick::BinaryBulkCodec.decode(
      string_aggregate,
      string_encoded_restored,
      [2_u64, 0_u64],
      profile: profile
    )
    string_encoded_decoded[0].map { |value| value.type }.should eq([string_aggregate, string_aggregate])
    string_encoded_decoded[0].map { |value| value.as_simple_aggregate.as_string }.should eq(["", "a\0b"])
    string_literal = CrystalClick::BinaryBulkStreams.new(2, {
      "root.string_sizes" => CrystalClick::BinaryBulkStream.new(
        w168_bytes(w168_le_u64(0_u64) + w168_le_u64(3_u64)),
        [0_u64, 16_u64, 16_u64]
      ),
      "root.data" => CrystalClick::BinaryBulkStream.new(
        Bytes[0x61_u8, 0x00_u8, 0x62_u8],
        [0_u64, 3_u64, 3_u64]
      ),
    })
    string_literal_physical = w168_to_physical(string_plan, string_literal)
    string_restored = w168_from_physical(string_plan, 2, string_literal_physical)
    string_decoded = CrystalClick::BinaryBulkCodec.decode(
      string_aggregate,
      string_restored,
      [2_u64, 0_u64],
      profile: profile
    )
    string_decoded.map { |mark| mark.map { |value| value.type } }.should eq([
      [string_aggregate, string_aggregate],
      [] of CrystalClick::BinaryDataType,
    ])
    string_decoded[0].map { |value| value.as_simple_aggregate.as_string }.should eq(["", "a\0b"])
    string_reencoded = CrystalClick::BinaryBulkCodec.encode(string_aggregate, string_decoded, profile: profile)
    string_reencoded.roles.each do |role|
      string_reencoded.stream(role).bytes.should eq(string_literal.stream(role).bytes)
      string_reencoded.stream(role).offsets.should eq(string_literal.stream(role).offsets)
    end

    nullable_string = CrystalClick::BinaryDataType.nullable(string_aggregate)
    nullable_string_values = [
      CrystalClick::BinaryValue.nullable(
        nullable_string,
        CrystalClick::BinaryValue.simple_aggregate(string_aggregate, CrystalClick::BinaryValue.string(""))
      ),
      CrystalClick::BinaryValue.nullable(nullable_string),
      CrystalClick::BinaryValue.nullable(
        nullable_string,
        CrystalClick::BinaryValue.simple_aggregate(string_aggregate, CrystalClick::BinaryValue.string("a\0b"))
      ),
    ] of CrystalClick::BinaryValue
    nullable_string_encoded = CrystalClick::BinaryBulkCodec.encode(
      nullable_string,
      [nullable_string_values],
      profile: profile
    )
    nullable_string_encoded.roles.should eq([
      "root.nested.data",
      "root.nested.string_sizes",
      "root.nulls",
    ] of String)
    nullable_string_encoded.stream("root.nested.string_sizes").bytes.should eq(w168_bytes(
      w168_le_u64(0_u64) + w168_le_u64(0_u64) + w168_le_u64(3_u64)
    ))
    nullable_string_encoded.stream("root.nested.string_sizes").offsets.should eq([0_u64, 24_u64])
    nullable_string_encoded.stream("root.nested.data").bytes.should eq(Bytes[0x61_u8, 0x00_u8, 0x62_u8])
    nullable_string_encoded.stream("root.nested.data").offsets.should eq([0_u64, 3_u64])
    nullable_string_encoded.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
    nullable_string_encoded.stream("root.nulls").offsets.should eq([0_u64, 3_u64])
    nullable_string_plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      nullable_string,
      "s",
      profile: profile
    )
    nullable_string_plan.stream_names.should eq({
      "root.nested.data"         => "s",
      "root.nested.string_sizes" => "s.size",
      "root.nulls"               => "s.null",
    })
    nullable_string_encoded_physical = w168_to_physical(nullable_string_plan, nullable_string_encoded)
    nullable_string_encoded_physical.keys.sort.should eq(["s", "s.null", "s.size"] of String)
    nullable_string_encoded_restored = w168_from_physical(
      nullable_string_plan,
      1,
      nullable_string_encoded_physical
    )
    nullable_string_encoded_decoded = CrystalClick::BinaryBulkCodec.decode(
      nullable_string,
      nullable_string_encoded_restored,
      [3_u64],
      profile: profile
    )
    nullable_string_encoded_decoded[0][0].type.should eq(nullable_string)
    nullable_string_encoded_decoded[0][0].child_at(0).type.should eq(string_aggregate)
    nullable_string_encoded_decoded[0][0].child_at(0).as_simple_aggregate.as_string.should eq("")
    nullable_string_encoded_decoded[0][1].is_null?.should be_true
    nullable_string_encoded_decoded[0][2].child_at(0).type.should eq(string_aggregate)
    nullable_string_encoded_decoded[0][2].child_at(0).as_simple_aggregate.as_string.should eq("a\0b")
    nullable_string_literal = CrystalClick::BinaryBulkStreams.new(1, {
      "root.nested.string_sizes" => CrystalClick::BinaryBulkStream.new(
        w168_bytes(w168_le_u64(0_u64) + w168_le_u64(0_u64) + w168_le_u64(3_u64)),
        [0_u64, 24_u64]
      ),
      "root.nested.data" => CrystalClick::BinaryBulkStream.new(
        Bytes[0x61_u8, 0x00_u8, 0x62_u8],
        [0_u64, 3_u64]
      ),
      "root.nulls" => CrystalClick::BinaryBulkStream.new(Bytes[0_u8, 1_u8, 0_u8], [0_u64, 3_u64]),
    })
    nullable_string_physical = w168_to_physical(nullable_string_plan, nullable_string_literal)
    nullable_string_restored = w168_from_physical(nullable_string_plan, 1, nullable_string_physical)
    nullable_string_decoded = CrystalClick::BinaryBulkCodec.decode(
      nullable_string,
      nullable_string_restored,
      [3_u64],
      profile: profile
    )
    nullable_string_decoded[0][0].type.should eq(nullable_string)
    nullable_string_decoded[0][0].child_at(0).type.should eq(string_aggregate)
    nullable_string_decoded[0][0].child_at(0).as_simple_aggregate.as_string.should eq("")
    nullable_string_decoded[0][1].is_null?.should be_true
    nullable_string_decoded[0][2].child_at(0).child_at(0).type.should eq(string_type)
    nullable_string_decoded[0][2].child_at(0).as_simple_aggregate.as_string.should eq("a\0b")

    fixed_type = CrystalClick::BinaryDataType.fixed_string(3)
    fixed_aggregate = CrystalClick::BinaryDataType.simple_aggregate(min, fixed_type)
    fixed_values = [
      CrystalClick::BinaryValue.simple_aggregate(
        fixed_aggregate,
        CrystalClick::BinaryValue.fixed(fixed_type, Bytes[0x41_u8, 0x00_u8, 0xff_u8])
      ),
      CrystalClick::BinaryValue.simple_aggregate(
        fixed_aggregate,
        CrystalClick::BinaryValue.fixed(fixed_type, Bytes[0x00_u8, 0x00_u8, 0x00_u8])
      ),
    ] of CrystalClick::BinaryValue
    fixed_encoded = CrystalClick::BinaryBulkCodec.encode(fixed_aggregate, [fixed_values], profile: profile)
    fixed_encoded.roles.should eq(["root.data"] of String)
    fixed_encoded.stream("root.data").bytes.should eq(Bytes[0x41_u8, 0x00_u8, 0xff_u8, 0x00_u8, 0x00_u8, 0x00_u8])
    fixed_plan = CrystalClick::BinaryBulkPhysicalPlan.new(fixed_aggregate, "f", profile: profile)
    fixed_plan.stream_names.should eq({"root.data" => "f"})
    fixed_physical = w168_to_physical(fixed_plan, fixed_encoded)
    fixed_physical.keys.should eq(["f"] of String)
    fixed_physical["f"].bytes.should eq(fixed_encoded.stream("root.data").bytes)
    fixed_literal = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(
        Bytes[0x41_u8, 0x00_u8, 0xff_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        [0_u64, 6_u64]
      ),
    })
    fixed_restored = w168_from_physical(fixed_plan, 1, w168_to_physical(fixed_plan, fixed_literal))
    fixed_decoded = CrystalClick::BinaryBulkCodec.decode(fixed_aggregate, fixed_restored, [2_u64], profile: profile)
    fixed_decoded[0].map { |value| value.type }.should eq([fixed_aggregate, fixed_aggregate])
    fixed_decoded[0].map { |value| value.as_simple_aggregate.bytes.to_a }.should eq([
      [0x41_u8, 0x00_u8, 0xff_u8],
      [0x00_u8, 0x00_u8, 0x00_u8],
    ])

    nullable_fixed = CrystalClick::BinaryDataType.nullable(fixed_aggregate)
    nullable_fixed_values = [
      CrystalClick::BinaryValue.nullable(nullable_fixed, fixed_values[0]),
      CrystalClick::BinaryValue.nullable(nullable_fixed),
      CrystalClick::BinaryValue.nullable(nullable_fixed, fixed_values[1]),
    ] of CrystalClick::BinaryValue
    nullable_fixed_encoded = CrystalClick::BinaryBulkCodec.encode(
      nullable_fixed,
      [nullable_fixed_values],
      profile: profile
    )
    nullable_fixed_encoded.stream("root.nested.data").bytes.should eq(
      Bytes[0x41_u8, 0x00_u8, 0xff_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    )
    nullable_fixed_encoded.stream("root.nulls").bytes.should eq(Bytes[0_u8, 1_u8, 0_u8])
    nullable_fixed_plan = CrystalClick::BinaryBulkPhysicalPlan.new(nullable_fixed, "f", profile: profile)
    nullable_fixed_plan.stream_names.should eq({
      "root.nested.data" => "f",
      "root.nulls"       => "f.null",
    })
    nullable_fixed_physical = w168_to_physical(nullable_fixed_plan, nullable_fixed_encoded)
    nullable_fixed_decoded = CrystalClick::BinaryBulkCodec.decode(
      nullable_fixed,
      w168_from_physical(nullable_fixed_plan, 1, nullable_fixed_physical),
      [3_u64],
      profile: profile
    )
    nullable_fixed_decoded[0][0].type.should eq(nullable_fixed)
    nullable_fixed_decoded[0][0].child_at(0).type.should eq(fixed_aggregate)
    nullable_fixed_decoded[0][1].is_null?.should be_true
    nullable_fixed_decoded[0][2].is_null?.should be_false
    nullable_fixed_decoded[0][2].child_at(0).child_at(0).type.should eq(fixed_type)
    nullable_fixed_decoded[0][2].child_at(0).as_simple_aggregate.bytes.should eq(Bytes[0_u8, 0_u8, 0_u8])
  end

  it "rejects the other five functions, wrapped or parameterized children, and noncanonical widths" do
    W168_TEXT_CHILDREN.each do |storage_name, child_type, child_wire|
      W168_REJECTED_TEXT_FUNCTIONS.each do |function_name, function|
        scalar_name = "SimpleAggregateFunction(#{function_name}, #{storage_name})"
        CrystalClick::BinarySimpleAggregateType.parse(scalar_name).should be_nil
        CrystalClick::SimpleAggregateColumnType.parse(scalar_name).should be_nil
        expect_raises(ArgumentError) do
          CrystalClick::BinaryDataType.simple_aggregate(function, child_type)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDataTypeCodec.decode(w168_literal_descriptor(function_name, child_wire))
        end
      end
    end

    string = CrystalClick::BinaryDataType.primitive("String")
    wrapped_children = [
      CrystalClick::BinaryDataType.nullable(string),
      CrystalClick::BinaryDataType.low_cardinality(string),
      CrystalClick::BinaryDataType.array(string),
    ]
    wrapped_child_wires = [
      [0x23_u8, 0x15_u8],
      [0x26_u8, 0x15_u8],
      [0x1e_u8, 0x15_u8],
    ]
    wrapped_children.each_with_index do |child, index|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(CrystalClick::BinarySimpleAggregateType::Function::Any, child)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(w168_literal_descriptor("any", wrapped_child_wires[index]))
      end
    end

    [
      "SimpleAggregateFunction(any, FixedString(0))",
      "SimpleAggregateFunction(any, FixedString(03))",
      "SimpleAggregateFunction(any, FixedString(65537))",
      "SimpleAggregateFunction(any, fixedstring(3))",
      "SimpleAggregateFunction(anylast, String)",
      "SimpleAggregateFunction(any, Nullable(String))",
      "SimpleAggregateFunction(any, LowCardinality(String))",
    ].each do |type_name|
      CrystalClick::BinarySimpleAggregateType.parse(type_name).should be_nil
      CrystalClick::SimpleAggregateColumnType.parse(type_name).should be_nil
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Any,
        CrystalClick::BinaryDataType.fixed_string(65_537)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        w168_literal_descriptor("any", [0x16_u8] + w168_var_uint(65_537_u64))
      )
    end
  end

  it "keeps the established numeric law and default UInt64 identity unchanged" do
    default_type = CrystalClick::BinarySimpleAggregateType.new(
      CrystalClick::BinarySimpleAggregateType::Function::Any
    )
    default_type.storage_type_name.should eq("UInt64")
    default_type.type_name.should eq("SimpleAggregateFunction(any, UInt64)")

    sum = CrystalClick::BinarySimpleAggregateType.parse("SimpleAggregateFunction(sum, UInt64)")
    sum.should_not be_nil
    sum_with_overflow = CrystalClick::BinarySimpleAggregateType.parse("SimpleAggregateFunction(sumWithOverflow, UInt64)")
    sum_with_overflow.should_not be_nil
    CrystalClick::BinarySimpleAggregateType.parse("SimpleAggregateFunction(sum, UInt8)").should be_nil
  end
end
