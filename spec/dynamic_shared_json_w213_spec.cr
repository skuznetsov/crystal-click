require "./spec_helper"

private def w213_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"id" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w213_json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w213_empty_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json
end

private def w213_empty_json_value : CrystalClick::BinaryValue
  type = w213_empty_json_type
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w213_nullable_typed_json_value : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable = CrystalClick::BinaryDataType.nullable(uint8)
  typed_paths = Hash(String, CrystalClick::BinaryDataType).new
  typed_paths["maybe"] = nullable
  type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: typed_paths,
  )
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"maybe", CrystalClick::BinaryValue.null(nullable)}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w213_concat(parts : Array(Bytes)) : Bytes
  total = 0
  parts.each { |part| total += part.size }
  output = Bytes.new(total)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      output[offset] = byte
      offset += 1
    end
  end
  output
end

private def w213_expect_grids_equal!(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |rows, mark|
    rows.size.should eq(expected[mark].size)
    rows.each_with_index do |value, row|
      CrystalClick::BinaryValueCodec.encode(value).should eq(
        CrystalClick::BinaryValueCodec.encode(expected[mark][row])
      )
    end
  end
end

describe "W213 Dynamic SharedVariant inline JSON" do
  it "round-trips direct and wrapped JSON actuals without Object JSON bindings" do
    json = w213_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    tuple_json_json = CrystalClick::BinaryDataType.tuple(
      [json, json] of CrystalClick::BinaryDataType,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    wrap = ->(actual : CrystalClick::BinaryValue) {
      CrystalClick::BinaryValue.dynamic(dynamic, actual)
    }
    empty_array = CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)
    one_json_array = CrystalClick::BinaryValue.array(
      array_json,
      [w213_json_value(json, 12_u8)] of CrystalClick::BinaryValue,
    )
    tuple_jsons = CrystalClick::BinaryValue.tuple(
      tuple_json_json,
      [w213_json_value(json, 14_u8), w213_json_value(json, 15_u8)] of CrystalClick::BinaryValue,
    )
    granules = [
      [
        wrap.call(w213_json_value(json, 11_u8)),
        wrap.call(one_json_array),
        wrap.call(empty_array),
        wrap.call(tuple_jsons),
        wrap.call(w213_nullable_typed_json_value),
        CrystalClick::BinaryValue.dynamic(dynamic),
      ] of CrystalClick::BinaryValue,
      [wrap.call(w213_json_value(json, 13_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    profiles.each do |profile|
      streams = CrystalClick::BinaryDynamicBulkCodec.encode(
        dynamic, structures, granules, profile: profile)
      streams.json_object_count.should eq(0)
      streams.data.stream("root.discriminators").bytes.should eq(
        Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0xff_u8, 0_u8]
      )

      decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic, streams, [6_u64, 1_u64], profile: profile)
      w213_expect_grids_equal!(decoded, granules)
    end
  end

  it "preserves the literal inline JSON envelope under both outer String profiles" do
    json = w213_empty_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    granules = [[CrystalClick::BinaryValue.dynamic(dynamic, w213_empty_json_value)]] of Array(CrystalClick::BinaryValue)
    envelope = Bytes[
      0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8,
    ]

    single = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic, structures, granules)
    single.data.stream("root.arm.0.data").bytes.should eq(Bytes[
      0x09_u8, 0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])
    w213_expect_grids_equal!(
      CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, single, [1_u64]),
      granules,
    )

    sized_profile = CrystalClick::BinaryBulkProfile.with_size_stream
    sized = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic, structures, granules, profile: sized_profile)
    sized.data.stream("root.arm.0.data").bytes.should eq(envelope)
    sized.data.stream("root.arm.0.string_sizes").bytes.should eq(
      Bytes[0x09_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    )
    w213_expect_grids_equal!(
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic, sized, [1_u64], profile: sized_profile),
      granules,
    )
  end

  it "keeps JSON opt-in local to the shared-child caller" do
    json = w213_empty_json_type
    value = w213_empty_json_value
    descriptor = CrystalClick::BinaryDataTypeCodec.encode(json)
    full_wire = CrystalClick::BinaryValueCodec.encode(value)

    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        descriptor,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
      )
    end

    explicit_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      true,
    )
    CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      value, explicit_budget, 1, allow_json: true).should eq(full_wire)
    explicit_budget.wire_byte_count.should eq(0_i64)
    decoded_type, decoded_value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      full_wire,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      1,
      allow_json: true,
    )
    decoded_type.should eq(json)
    decoded_value.not_nil!.is_null?.should be_false

    borrowed_write = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    borrowed_write.message.to_s.should contain("JSON")
    borrowed_read = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        full_wire,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    borrowed_read.message.to_s.should contain("JSON")

    legacy = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(
        CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        [[value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      )
    end
    legacy.message.to_s.should contain("JSON")

    object_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    empty_object_plan = CrystalClick::ObjectDocumentPlan.new(
      object_structures,
      {} of String => CrystalClick::BinaryDataType,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, value)
    shared_structure = {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
    extra_binding = expect_raises(ArgumentError, "exactly cover") do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        dynamic,
        shared_structure,
        [[dynamic_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
        json_object_plans: [{"root", 0, empty_object_plan}] of Tuple(
          String, Int32, CrystalClick::ObjectDocumentPlan,
        ),
      )
    end
    extra_binding.message.to_s.should contain("exactly cover")

    ordinary_type = CrystalClick::BinaryDataType.array(json)
    ordinary_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    ordinary_structure = CrystalClick::DynamicStructure.new(
      [ordinary_type] of CrystalClick::BinaryDataType,
    )
    ordinary_actual = CrystalClick::BinaryValue.array(
      ordinary_type,
      [value] of CrystalClick::BinaryValue,
    )
    ordinary_value = CrystalClick::BinaryValue.dynamic(ordinary_dynamic, ordinary_actual)
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        ordinary_dynamic,
        {"root" => ordinary_structure},
        [[ordinary_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      )
    end

    map_row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new(Bytes[0x78_u8], value),
    ] of CrystalClick::ObjectSharedMapEntry)
    copy_structure = CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      ["x"] of String,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    )
    copy_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode(
        [map_row] of CrystalClick::ObjectSharedMapRow,
        [copy_structure] of CrystalClick::ObjectSharedChunkStructure,
      )
    end
    copy_error.message.to_s.should contain("JSON")
  end

  it "preserves an independently authored untyped Array(UInt8) JSON path envelope" do
    json = w213_empty_json_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array_type = CrystalClick::BinaryDataType.array(uint8)
    runtime_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[42_u8]),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[43_u8]),
    ] of CrystalClick::BinaryValue)
    value = CrystalClick::BinaryValue.json(json, CrystalClick::BinaryJsonRow.new(
      json, [{"x", runtime_value}] of Tuple(String, CrystalClick::BinaryValue),
    ))
    # Default JSON descriptor; one x path with Array(UInt8) descriptor and
    # scalar Array length/data. No Object streams or inner bulk String profile.
    literal = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00,
      0x01, 0x01, 0x78, 0x1e, 0x01, 0x02, 0x2a, 0x2b,
    ]
    CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      value,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      2,
      allow_json: true,
    ).should eq(literal)
    decoded_type, decoded = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      literal,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      2,
      allow_json: true,
    )
    decoded_type.should eq(json)
    row = decoded.not_nil!.json_row
    row.path_at(0).should eq("x")
    row.value_at(0).type.should eq(array_type)
    row.value_at(0).child_at(0).bytes.should eq(Bytes[42_u8])
    row.value_at(0).child_at(1).bytes.should eq(Bytes[43_u8])
  end

  it "rejects malformed, duplicate, trailing, and missing-typed JSON inside an opted-in envelope" do
    typed_json = w213_json_type
    typed_descriptor = CrystalClick::BinaryDataTypeCodec.encode(typed_json)
    typed_value = w213_json_value(typed_json, 42_u8)
    typed_wire = CrystalClick::BinaryValueCodec.encode(typed_value)
    typed_row = Bytes[0x01_u8, 0x02_u8, 0x69_u8, 0x64_u8, 0x2a_u8]
    typed_wire.should eq(w213_concat([typed_descriptor, typed_row] of Bytes))

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        w213_concat([typed_wire, Bytes[0xff_u8]] of Bytes),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
        allow_json: true,
      )
    end

    expect_raises(CrystalClick::UnsupportedFormatError, "missing") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        w213_concat([typed_descriptor, Bytes[0x00_u8]] of Bytes),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
        allow_json: true,
      )
    end

    empty_descriptor = CrystalClick::BinaryDataTypeCodec.encode(w213_empty_json_type)
    duplicate_dynamic_path = Bytes[
      0x02_u8,
      0x01_u8, 0x78_u8, 0x00_u8,          # x: Nothing NULL sentinel
      0x01_u8, 0x78_u8, 0x01_u8, 0x2a_u8, # x: UInt8(42), duplicate key
    ]
    expect_raises(CrystalClick::CorruptPartError, "duplicate") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        w213_concat([empty_descriptor, duplicate_dynamic_path] of Bytes),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
        allow_json: true,
      )
    end
  end

  it "preserves inherited depth, cumulative budgets, and pending-frame reservation" do
    value = w213_empty_json_value
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 2,
      max_elements: 0,
      max_bytes: 10,
    )
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    wire = CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      value, write_budget, 2, 1_u64, allow_json: true)
    wire.should eq(CrystalClick::BinaryValueCodec.encode(value))
    write_budget.node_count.should eq(2_i64)
    write_budget.wire_byte_count.should eq(0_i64)
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        value, write_budget, 2, 1_u64, allow_json: true)
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      wire, read_budget, 2, allow_json: true)[0].should eq(value.type)
    read_budget.node_count.should eq(2_i64)
    expect_raises(CrystalClick::CorruptPartError, "node limit") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        wire, read_budget, 2, allow_json: true)
    end

    shallow = CrystalClick::BinaryCodecLimits.new(
      max_depth: 1,
      max_nodes: 8,
      max_elements: 0,
      max_bytes: 32,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        value,
        CrystalClick::BinaryCodecBudget.new(shallow, true),
        2,
        allow_json: true,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        wire,
        CrystalClick::BinaryCodecBudget.new(shallow),
        2,
        allow_json: true,
      )
    end

    reserved_tight = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 8,
      max_elements: 0,
      max_bytes: 9,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "byte limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        value,
        CrystalClick::BinaryCodecBudget.new(reserved_tight, true),
        2,
        1_u64,
        allow_json: true,
      )
    end
  end

  it "charges typed NULL JSON descriptor and value work to one shared budget" do
    value = w213_nullable_typed_json_value
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 7,
      max_elements: 5,
      max_bytes: 64,
    )
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    wire = CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      value, write_budget, 2, allow_json: true)
    write_budget.node_count.should eq(7_i64)
    write_budget.element_count.should eq(5_i64)

    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    decoded_type, decoded_value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      wire, read_budget, 2, allow_json: true)
    decoded_type.should eq(value.type)
    decoded_value.not_nil!.is_null?.should be_false
    decoded_value.not_nil!.json_row.value_at(0).is_null?.should be_true
    read_budget.node_count.should eq(7_i64)
    read_budget.element_count.should eq(5_i64)

    one_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 7,
      max_elements: 4,
      max_bytes: 64,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "element limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        value,
        CrystalClick::BinaryCodecBudget.new(one_short, true),
        2,
        allow_json: true,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "element limit") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        wire,
        CrystalClick::BinaryCodecBudget.new(one_short),
        2,
        allow_json: true,
      )
    end
  end

  it "supports SharedVariant JSON under an outer Array(Dynamic) site" do
    json = w213_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    parent_array = CrystalClick::BinaryDataType.array(dynamic)
    structures = {
      "root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    child = CrystalClick::BinaryValue.dynamic(dynamic, w213_json_value(json, 31_u8))
    parent = CrystalClick::BinaryValue.array(parent_array, [child] of CrystalClick::BinaryValue)
    granules = [[parent] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    inherited_depth = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        parent_array, structures, granules, limits: inherited_depth)
    end

    admitted_depth = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      parent_array, structures, granules, limits: admitted_depth)
    streams.json_object_count.should eq(0)
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        parent_array, streams, [1_u64], limits: inherited_depth)
    end
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      parent_array, streams, [1_u64], limits: admitted_depth)
    w213_expect_grids_equal!(decoded, granules)
  end

  it "validates full lane grids but parses only selected shared JSON frames" do
    json = w213_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    granules = [
      [CrystalClick::BinaryValue.dynamic(dynamic, w213_json_value(json, 41_u8))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.dynamic(dynamic, w213_json_value(json, 42_u8))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic, structures, granules)

    malformed_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    streams.data.roles.each do |role|
      lane = streams.data.stream(role)
      bytes = lane.bytes
      if role == "root.arm.0.data"
        # The single-stream mark starts with its frame length, followed by the
        # scalar descriptor. Corrupt only mark zero's descriptor tag.
        bytes[lane.offset_at(0).to_i + 1] = 0xff_u8
      end
      malformed_lanes[role] = CrystalClick::BinaryBulkStream.new(bytes, lane.offsets)
    end
    malformed_streams = CrystalClick::BinaryDynamicBulkStreams.new(
      streams.structures,
      CrystalClick::BinaryBulkStreams.new(streams.data.mark_count, malformed_lanes),
    )

    empty = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic, malformed_streams, [1_u64, 1_u64], first_mark: 0, mark_count: 0)
    empty.should eq([] of Array(CrystalClick::BinaryValue))

    selected_later = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic, malformed_streams, [1_u64, 1_u64], first_mark: 1, mark_count: 1)
    w213_expect_grids_equal!(selected_later, [granules[1]])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic, malformed_streams, [1_u64, 1_u64], first_mark: 0, mark_count: 1)
    end
  end
end
