require "./spec_helper"

private def w152_consumer_dynamic_types : Array(CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic
  array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
  nullable_tuple_dynamic = CrystalClick::BinaryDataType.nullable(
    CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType)
  )
  map_dynamic = CrystalClick::BinaryDataType.map(
    CrystalClick::BinaryDataType.primitive("String"),
    dynamic,
  )
  variant_dynamic = CrystalClick::BinaryDataType.variant([
    array_dynamic,
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
  [array_dynamic, nullable_tuple_dynamic, map_dynamic, variant_dynamic]
end

private def w152_consumer_dynamic_values : Array(CrystalClick::BinaryValue)
  dynamic_types = w152_consumer_dynamic_types
  [
    CrystalClick::BinaryValue.array(dynamic_types[0], [] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.null(dynamic_types[1]),
    CrystalClick::BinaryValue.map(dynamic_types[2], [] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.variant_null(dynamic_types[3]),
  ]
end

private def w152_consumer_value_wire(type : CrystalClick::BinaryDataType, payload : UInt8) : Bytes
  descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
  Bytes.new(descriptor.size + 1) do |index|
    if index == descriptor.size
      payload
    else
      descriptor[index]
    end
  end
end

private def w152_consumer_shared_streams(envelope : Bytes) : CrystalClick::DynamicValueStreams
  structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
  tags = [[structure.shared_index.to_u8]] of Array(UInt8)
  discriminators = CrystalClick::DynamicDiscriminatorCodec.encode(structure, tags)
  shared_type = CrystalClick::BinaryDataType.primitive("String")
  envelope_value = CrystalClick::BinaryValue.string(String.new(envelope))
  shared_lane = CrystalClick::BinaryBulkCodec.encode(
    shared_type,
    [[envelope_value]] of Array(CrystalClick::BinaryValue),
  )
  arms = Hash(String, CrystalClick::BinaryBulkStreams).new
  arms[CrystalClick::DynamicStructure::SHARED_VARIANT_NAME] = shared_lane
  CrystalClick::DynamicValueStreams.new(discriminators, arms)
end

private def w152_consumer_object_set : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w152_consumer_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  actual.type.should eq(expected.type)
  actual.is_null?.should eq(expected.is_null?)
  case expected.type.tag
  when CrystalClick::BinaryDataType::TAG_UINT64
    actual.as_uint64.should eq(expected.as_uint64)
  when CrystalClick::BinaryDataType::TAG_STRING
    actual.as_string.should eq(expected.as_string)
  when CrystalClick::BinaryDataType::TAG_ARRAY
    actual.element_count.should eq(expected.element_count)
    expected.element_count.times do |index|
      actual.element_at(index).as_uint64.should eq(expected.element_at(index).as_uint64)
    end
  else
    raise "unexpected W152 scalar-codec positive control"
  end
  nil
end

describe "W152 Dynamic descriptor consumer guards" do
  it "admits generic recursive Dynamic values while retaining borrowed storage refusals" do
    types = w152_consumer_dynamic_types
    values = w152_consumer_dynamic_values
    payloads = [0x00_u8, 0x01_u8, 0x00_u8, 0xff_u8]

    types[3].contains_dynamic?.should be_true
    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(types[3])).should eq(types[3])
    values[3].is_null?.should be_true

    types.each_with_index do |type, index|
      value = values[index]
      envelope = w152_consumer_value_wire(type, payloads[index])

      CrystalClick::BinaryValueCodec.encode(value).should eq(envelope)
      decoded = CrystalClick::BinaryValueCodec.decode(envelope)
      decoded.type.should eq(type)
      decoded.is_null?.should eq(value.is_null?)
      decoded.element_count.should eq(0)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[payloads[index]])
      scalar = CrystalClick::BinaryValueCodec.decode_value(type, Bytes[payloads[index]])
      scalar.type.should eq(type)
      scalar.is_null?.should eq(value.is_null?)
      scalar.element_count.should eq(0)
      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::BinaryValueCodec.encode_borrowed(
          value,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::BinaryValueCodec.decode_borrowed(
          envelope,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_uint64 = CrystalClick::BinaryDataType.array(uint64)
    supported = [
      CrystalClick::BinaryValue.uint64(41_u64),
      CrystalClick::BinaryValue.string("neighbor"),
      CrystalClick::BinaryValue.array(array_uint64, [CrystalClick::BinaryValue.uint64(43_u64)] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_uint64, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    supported.each do |value|
      envelope = CrystalClick::BinaryValueCodec.encode(value)
      w152_consumer_assert_value(CrystalClick::BinaryValueCodec.decode(envelope), value)
      scalar = CrystalClick::BinaryValueCodec.encode_value(value)
      w152_consumer_assert_value(CrystalClick::BinaryValueCodec.decode_value(value.type, scalar), value)
      borrowed = CrystalClick::BinaryValueCodec.encode_borrowed(
        value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
      w152_consumer_assert_value(
        CrystalClick::BinaryValueCodec.decode_borrowed(
          borrowed,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        ),
        value,
      )
    end
  end

  it "rejects recursive Dynamic before Dynamic shared-envelope reads or writes" do
    structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    w152_consumer_dynamic_types.each_with_index do |type, index|
      value = w152_consumer_dynamic_values[index]
      envelope = w152_consumer_value_wire(type, [0x00_u8, 0x01_u8, 0x00_u8, 0xff_u8][index])

      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::DynamicValueCodec.encode(structure, [[value]] of Array(CrystalClick::BinaryValue))
      end
      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::DynamicValueCodec.decode(structure, w152_consumer_shared_streams(envelope))
      end
    end

    # Ordinary UInt64 and values spilled through SharedVariant remain legal.
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_uint64 = CrystalClick::BinaryDataType.array(uint64)
    positive_structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
    positive_values = [
      CrystalClick::BinaryValue.uint64(17_u64),
      CrystalClick::BinaryValue.string("neighbor"),
      CrystalClick::BinaryValue.array(array_uint64, [CrystalClick::BinaryValue.uint64(23_u64)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    encoded = CrystalClick::DynamicValueCodec.encode(positive_structure, [positive_values])
    decoded = CrystalClick::DynamicValueCodec.decode(positive_structure, encoded)
    decoded.size.should eq(1)
    decoded[0][0].as_uint64.should eq(17_u64)
    decoded[0][1].as_string.should eq("neighbor")
    decoded[0][2].type.should eq(array_uint64)
    decoded[0][2].element_count.should eq(1)
    decoded[0][2].element_at(0).as_uint64.should eq(23_u64)
  end

  it "blocks empty-container Dynamic defaults and retains ordinary default controls" do
    profile = CrystalClick::BinaryBulkProfile.single_stream
    dynamic_types = w152_consumer_dynamic_types
    dynamic_types.each do |type|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkDefaultValue.measure(type, profile)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkDefaultValue.build(type)
      end
    end

    # A cached prior cost must not turn a forbidden descriptor into a hit.
    cached_array = dynamic_types[0]
    ordinary_cost = CrystalClick::BinaryBulkDefaultValue::Cost.new(1_u64, 0_u64, 8_u64)
    measure_cache = Hash(UInt64, CrystalClick::BinaryBulkDefaultValue::Cost).new
    measure_cache[cached_array.object_id] = ordinary_cost
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDefaultValue.measure(cached_array, profile, measure_cache)
    end
    excluded_cache = Hash(Tuple(UInt64, Bool), CrystalClick::BinaryBulkDefaultValue::Cost).new
    excluded_cache[{cached_array.object_id, true}] = ordinary_cost
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDefaultValue.measure_excluding_low_cardinality(cached_array, profile, excluded_cache)
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_uint64 = CrystalClick::BinaryDataType.array(uint64)
    [uint64, string, array_uint64].each do |type|
      CrystalClick::BinaryBulkDefaultValue.measure(type, profile).nodes.should be > 0_u64
      CrystalClick::BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile).nodes.should be > 0_u64
      CrystalClick::BinaryBulkDefaultValue.build(type).type.should eq(type)
    end
  end

  it "rejects recursive Dynamic in generic bulk plans before building roles" do
    profile = CrystalClick::BinaryBulkProfile.single_stream
    dynamic_array = w152_consumer_dynamic_types[0]
    w152_consumer_dynamic_types.each do |type|
      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::BinaryBulkTypePlan.new(type, profile)
      end
      expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
        CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile)
      end
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array_uint64 = CrystalClick::BinaryDataType.array(uint64)
    empty_array = CrystalClick::BinaryValue.array(array_uint64, [] of CrystalClick::BinaryValue)
    ordinary_streams = CrystalClick::BinaryBulkCodec.encode(
      array_uint64,
      [[empty_array]] of Array(CrystalClick::BinaryValue),
      profile: profile,
    )
    CrystalClick::BinaryBulkCodec.decode(array_uint64, ordinary_streams, [1_u64], profile: profile)[0].size.should eq(1)

    # Empty public codec inputs/windows must not skip descriptor admission.
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryBulkCodec.encode(dynamic_array, [] of Array(CrystalClick::BinaryValue), profile: profile)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryBulkCodec.decode(
        dynamic_array,
        ordinary_streams,
        [1_u64],
        first_mark: 1,
        mark_count: 0,
        profile: profile,
      )
    end

    [uint64, CrystalClick::BinaryDataType.primitive("String"), array_uint64].each do |type|
      role_plan = CrystalClick::BinaryBulkTypePlan.new(type, profile)
      role_plan.role_count.should be > 0_u64
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "payload", profile).stream_names.should_not be_empty
    end
  end

  it "keeps Dynamic out of stored rosters, Object schemas, and zero-row Object paths" do
    array_dynamic = w152_consumer_dynamic_types[0]
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([array_dynamic] of CrystalClick::BinaryDataType)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicStructureCodec.decode(
        Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0x1e_u8, 0x2b_u8, 0x20_u8, 0_u8]
      )
    end

    dynamic_schema = {"typed" => array_dynamic}
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new(dynamic_schema)
    end

    dynamic_plan = CrystalClick::ObjectDocumentPlan.new(w152_consumer_object_set, dynamic_schema)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(dynamic_plan, [] of Array(CrystalClick::ObjectDocument))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentPhysicalPlan.new("payload", dynamic_plan)
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    supported_schema = {"typed" => uint64}
    schema = CrystalClick::ObjectDocumentSchema.new(supported_schema)
    positive_plan = CrystalClick::ObjectDocumentPlan.new(w152_consumer_object_set, supported_schema)
    schema.validate_plan(positive_plan)
    document = CrystalClick::ObjectDocument.new({"typed" => CrystalClick::BinaryValue.uint64(31_u64)})
    streams = CrystalClick::ObjectDocumentCodec.encode(positive_plan, [[document]])
    decoded = CrystalClick::ObjectDocumentCodec.decode(supported_schema, streams)
    decoded[0][0].value_for("typed").as_uint64.should eq(31_u64)

    # The manually supplied typed hash is refused even when selection is empty.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.decode(dynamic_schema, streams, first_mark: 1, mark_count: 0)
    end
    # File-reader schema preflight must also win over part lookup for an empty selection.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentFileReader.read(
        "/not-read-part",
        "payload",
        dynamic_schema,
        first_mark: 0,
        mark_count: 0,
        hashed: true,
      )
    end
  end
end
