require "./spec_helper"

private def w214_red_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {
      "id"    => uint8,
      "maybe" => nullable_uint8,
    } of String => CrystalClick::BinaryDataType,
  )
end

private def w214_wrap_dynamic(
  type : CrystalClick::BinaryDataType,
  child : CrystalClick::BinaryValue?,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.dynamic(type, child)
end

private def w214_json_array(
  type : CrystalClick::BinaryDataType,
  json : CrystalClick::BinaryDataType,
  ids : Array(UInt8),
) : CrystalClick::BinaryValue
  values = Array(CrystalClick::BinaryValue).new(ids.size)
  ids.each { |id| values << w214_red_json_value(json, id) }
  CrystalClick::BinaryValue.array(type, values)
end

private def w214_document(
  p : CrystalClick::BinaryValue,
  q : CrystalClick::BinaryValue,
  t : CrystalClick::BinaryValue,
  outer : CrystalClick::BinaryValue,
) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "p"     => p,
    "q"     => q,
    "t"     => t,
    "outer" => outer,
  } of String => CrystalClick::BinaryValue)
end

private struct W214Fixture
  getter schema : CrystalClick::ObjectDocumentSchema
  getter plan : CrystalClick::ObjectDocumentPlan
  getter granules : Array(Array(CrystalClick::ObjectDocument))
  getter expected : Array(Array(Array(String)))

  def initialize
    json = w214_red_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_json = CrystalClick::BinaryDataType.array(json)
    tuple_json = CrystalClick::BinaryDataType.tuple(
      [json, json] of CrystalClick::BinaryDataType,
    )
    outer_array = CrystalClick::BinaryDataType.array(dynamic)
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)

    @schema = CrystalClick::ObjectDocumentSchema.new({
      "p"     => dynamic,
      "q"     => dynamic,
      "t"     => dynamic,
      "outer" => outer_array,
    } of String => CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    @plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      @schema.typed_paths,
      {
        "p" => empty_roster,
        "q" => empty_roster,
        "t" => empty_roster,
      } of String => CrystalClick::DynamicStructure,
      typed_dynamic_sites: {
        "outer" => {"root.elements" => empty_roster} of String => CrystalClick::DynamicStructure,
      } of String => Hash(String, CrystalClick::DynamicStructure),
    )

    j = ->(id : UInt8) { w214_red_json_value(json, id) }
    d = ->(child : CrystalClick::BinaryValue?) { w214_wrap_dynamic(dynamic, child) }
    a = ->(ids : Array(UInt8)) { w214_json_array(array_json, json, ids) }
    pair = ->(left : UInt8, right : UInt8) {
      CrystalClick::BinaryValue.tuple(tuple_json, [j.call(left), j.call(right)] of CrystalClick::BinaryValue)
    }
    outer = ->(items : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(outer_array, items)
    }
    @granules = [
      [
        w214_document(d.call(j.call(1_u8)), d.call(a.call([] of UInt8)), d.call(pair.call(21_u8, 22_u8)), outer.call([] of CrystalClick::BinaryValue)),
        w214_document(d.call(nil), d.call(a.call([11_u8] of UInt8)), d.call(pair.call(23_u8, 24_u8)), outer.call([d.call(nil)] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        w214_document(d.call(j.call(2_u8)), d.call(nil), d.call(pair.call(25_u8, 26_u8)), outer.call([d.call(j.call(41_u8)), d.call(nil), d.call(j.call(42_u8))] of CrystalClick::BinaryValue)),
        w214_document(d.call(j.call(3_u8)), d.call(a.call([12_u8, 13_u8] of UInt8)), d.call(pair.call(27_u8, 28_u8)), outer.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
      [
        w214_document(d.call(j.call(4_u8)), d.call(a.call([14_u8] of UInt8)), d.call(pair.call(29_u8, 30_u8)), outer.call([d.call(j.call(43_u8)), d.call(j.call(44_u8)), d.call(nil), d.call(j.call(45_u8)), d.call(nil)] of CrystalClick::BinaryValue)),
        w214_document(d.call(j.call(5_u8)), d.call(a.call([] of UInt8)), d.call(pair.call(31_u8, 32_u8)), outer.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    @expected = [
      [
        ["D(J(1,11,N))", "D(A[])", "D(T(J(21,211,N),J(22,221,N)))", "A[]"],
        ["DNULL", "D(A[J(11,111,N)])", "D(T(J(23,231,N),J(24,241,N)))", "A[DNULL]"],
      ],
      [
        ["D(J(2,21,N))", "DNULL", "D(T(J(25,251,N),J(26,261,N)))", "A[D(J(41,411,N)),DNULL,D(J(42,421,N))]"],
        ["D(J(3,31,N))", "D(A[J(12,121,N),J(13,131,N)])", "D(T(J(27,271,N),J(28,281,N)))", "A[]"],
      ],
      [
        ["D(J(4,41,N))", "D(A[J(14,141,N)])", "D(T(J(29,291,N),J(30,301,N)))", "A[D(J(43,431,N)),D(J(44,441,N)),DNULL,D(J(45,451,N)),DNULL]"],
        ["D(J(5,51,N))", "D(A[])", "D(T(J(31,311,N),J(32,321,N)))", "A[]"],
      ],
    ] of Array(Array(String))
  end
end

private def w214_signature(value : CrystalClick::BinaryValue) : String
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    value.is_null? ? "DNULL" : "D(#{w214_signature(value.child_at(0))})"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    children = (0...value.element_count).map { |index| w214_signature(value.element_at(index)) }
    "A[#{children.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
    children = (0...value.child_count).map { |index| w214_signature(value.child_at(index)) }
    "T(#{children.join(",")})"
  when CrystalClick::BinaryDataType::TAG_JSON
    row = value.json_row
    id = row.value_for("id").not_nil!.byte_at(0)
    counter = row.value_for("counter").not_nil!.as_int64
    nullable = row.value_for("maybe").not_nil!.is_null? ? "N" : "V"
    "J(#{id},#{counter},#{nullable})"
  else
    raise "unexpected W214 value type: #{value.type.name}"
  end
end

private def w214_document_signatures(
  granules : Array(Array(CrystalClick::ObjectDocument)),
) : Array(Array(Array(String)))
  granules.map do |mark|
    mark.map do |document|
      ["p", "q", "t", "outer"].map { |path| w214_signature(document.value_for(path)) }
    end
  end
end

private def w214_mutate_typed_shared_envelope(
  streams : CrystalClick::ObjectDocumentStreams,
  mutation : Symbol,
) : CrystalClick::ObjectDocumentStreams
  typed = Hash(String, CrystalClick::BinaryBulkStreams).new
  streams.typed_paths.each { |path| typed[path] = streams.typed_for(path) }
  dynamic = Hash(String, CrystalClick::DynamicValueStreams).new
  streams.dynamic_paths.each { |path| dynamic[path] = streams.dynamic_for(path) }

  typed_dynamic = Hash(String, CrystalClick::BinaryDynamicBulkStreams).new
  root_offsets = Hash(String, Int32).new
  site_offsets = Hash(String, Hash(String, Int32)).new
  streams.typed_dynamic_paths.each do |path|
    lanes = streams.typed_dynamic_for(path)
    roles = Hash(String, CrystalClick::BinaryBulkStream).new
    lanes.data.roles.each do |role|
      source = lanes.data.stream(role)
      if path == "p" && role == "root.arm.0.data"
        bytes = source.bytes.to_a
        case mutation
        when :wrong_descriptor
          bytes[source.offset_at(0).to_i + 1] = 0xff_u8
          roles[role] = CrystalClick::BinaryBulkStream.new(
            Bytes.new(bytes.size) { |index| bytes[index] },
            source.offsets,
          )
        when :trailing_byte
          bytes << 0xff_u8
          offsets = source.offsets
          offsets[offsets.size - 1] += 1_u64
          roles[role] = CrystalClick::BinaryBulkStream.new(
            Bytes.new(bytes.size) { |index| bytes[index] },
            offsets,
          )
        else
          raise ArgumentError.new("unknown W214 envelope mutation: #{mutation}")
        end
      elsif path == "p" && role == "root.arm.0.string_sizes" && mutation == :trailing_byte
        bytes = source.bytes
        last_value = bytes.size - 8
        length = 0_u64
        8.times do |index|
          length |= bytes[last_value + index].to_u64 << (index * 8)
        end
        length += 1_u64
        8.times do |index|
          bytes[last_value + index] = ((length >> (index * 8)) & 0xff_u64).to_u8
        end
        roles[role] = CrystalClick::BinaryBulkStream.new(bytes, source.offsets)
      else
        roles[role] = source
      end
    end
    typed_dynamic[path] = CrystalClick::BinaryDynamicBulkStreams.new(
      lanes.structures,
      CrystalClick::BinaryBulkStreams.new(streams.mark_count, roles),
    )
    site_offsets[path] = Hash(String, Int32).new
    lanes.structures.site_paths.each do |site_path|
      if offset = streams.typed_dynamic_site_statistics_offset(path, site_path)
        site_offsets[path][site_path] = offset
        root_offsets[path] = offset if site_path == "root"
      end
    end
  end

  CrystalClick::ObjectDocumentStreams.new(
    streams.structures,
    streams.rows_per_mark,
    typed,
    dynamic,
    streams.shared,
    typed_dynamic,
    root_offsets,
    site_offsets,
    typed_dynamic_mode: streams.typed_dynamic_mode,
  )
end

describe "W214 declared Object Dynamic inline SharedVariant JSON matrix" do
  it "round-trips direct, Array(JSON), and Tuple(JSON, JSON) actuals with literal NULL and empty-value checks" do
    fixture = W214Fixture.new
    streams = CrystalClick::ObjectDocumentCodec.encode(fixture.plan, fixture.granules)
    decoded = CrystalClick::ObjectDocumentCodec.decode(fixture.schema.typed_paths, streams)
    w214_document_signatures(decoded).should eq(fixture.expected)

    first = decoded[0][0]
    first.value_for("p").child_at(0).json_row.value_for("id").not_nil!.byte_at(0).should eq(1_u8)
    first.value_for("p").child_at(0).json_row.value_for("counter").not_nil!.as_int64.should eq(11_i64)
    first.value_for("p").child_at(0).json_row.value_for("maybe").not_nil!.is_null?.should be_true
    first.value_for("q").child_at(0).element_count.should eq(0)
    decoded[0][1].value_for("p").is_null?.should be_true
  end

  it "keeps parent, Dynamic-occurrence, and selected-SharedVariant mark counts distinct across modes and String profiles" do
    fixture = W214Fixture.new
    modes = [
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    ] of UInt64
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    modes.each do |mode|
      profiles.each do |profile|
        streams = CrystalClick::ObjectDocumentCodec.encode(
          fixture.plan,
          fixture.granules,
          mode: mode,
          profile: profile,
        )
        streams.rows_per_mark.should eq([2_u64, 2_u64, 2_u64])
        lanes = streams.typed_dynamic_for("outer").data
        lanes.stream("root.elements.discriminators").offsets.should eq([0_u64, 1_u64, 4_u64, 9_u64])
        if profile.with_size_stream?
          lanes.stream("root.elements.arm.0.string_sizes").offsets.should eq([0_u64, 0_u64, 16_u64, 40_u64])
        end

        w214_document_signatures(
          CrystalClick::ObjectDocumentCodec.decode(fixture.schema.typed_paths, streams, profile: profile),
        ).should eq(fixture.expected)
        w214_document_signatures(
          CrystalClick::ObjectDocumentCodec.decode(
            fixture.schema.typed_paths, streams, first_mark: 0, mark_count: 1, profile: profile),
        ).should eq([fixture.expected[0]])
        w214_document_signatures(
          CrystalClick::ObjectDocumentCodec.decode(
            fixture.schema.typed_paths, streams, first_mark: 1, mark_count: 1, profile: profile),
        ).should eq([fixture.expected[1]])
        w214_document_signatures(
          CrystalClick::ObjectDocumentCodec.decode(
            fixture.schema.typed_paths, streams, first_mark: 2, mark_count: 1, profile: profile),
        ).should eq([fixture.expected[2]])
        CrystalClick::ObjectDocumentCodec.decode(
          fixture.schema.typed_paths, streams, first_mark: 3, mark_count: 0, profile: profile).should be_empty
      end
    end
  end

  it "charges runtime JSON descendants at the generic versus Object depth origin on encode and decode" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    runtime_array = CrystalClick::BinaryDataType.array(uint8)
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    nested_value = CrystalClick::BinaryValue.array(
      runtime_array,
      [CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8])] of CrystalClick::BinaryValue,
    )
    json_value = CrystalClick::BinaryValue.json(
      json,
      CrystalClick::BinaryJsonRow.new(
        json,
        [{"items", nested_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    depth_four = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )
    depth_five = CrystalClick::BinaryCodecLimits.new(
      max_depth: 5,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    generic_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => empty_roster} of String => CrystalClick::DynamicStructure,
      limits: depth_four,
    )
    generic_streams = CrystalClick::BinaryBulkEncoder.encode(
      dynamic,
      [[CrystalClick::BinaryValue.dynamic(dynamic, json_value)] of CrystalClick::BinaryValue],
      CrystalClick::BinaryCodecBudget.new(depth_four, true),
      CrystalClick::BinaryBulkProfile.single_stream,
      generic_plan,
    )
    generic_rows = CrystalClick::BinaryBulkDecoder.decode(
      dynamic,
      generic_streams,
      [1_u64],
      CrystalClick::BinaryCodecBudget.new(depth_four),
      0,
      nil,
      CrystalClick::BinaryBulkProfile.single_stream,
      generic_plan,
    )
    generic_rows[0][0].child_at(0).json_row.value_for("items").not_nil!.element_at(0).byte_at(0).should eq(9_u8)

    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic}, limits: depth_five)
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      {"p" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "p" => CrystalClick::BinaryValue.dynamic(dynamic, json_value),
    })] of CrystalClick::ObjectDocument]
    object_streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: depth_five)
    decoded_at_depth_five = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths, object_streams, limits: depth_five)
    decoded_at_depth_five[0][0].value_for("p").child_at(0).json_row.value_for("items").not_nil!.element_at(0).byte_at(0).should eq(9_u8)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: depth_four)
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, object_streams, limits: depth_four)
    end
  end

  it "composes inherited depth through an outer bound JSON Object and a typed Dynamic SharedVariant JSON" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    runtime_array = CrystalClick::BinaryDataType.array(uint8)
    selected_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    nested_value = CrystalClick::BinaryValue.array(
      runtime_array,
      [CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8])] of CrystalClick::BinaryValue,
    )
    selected_json_value = CrystalClick::BinaryValue.json(
      selected_json,
      CrystalClick::BinaryJsonRow.new(
        selected_json,
        [{"items", nested_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    typed_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 0,
      typed_paths: {"p" => typed_dynamic} of String => CrystalClick::BinaryDataType,
    )
    outer_structure = CrystalClick::DynamicStructure.new([outer_json] of CrystalClick::BinaryDataType)
    outer_structures = {"root" => outer_structure} of String => CrystalClick::DynamicStructure
    arm = outer_structure.canonical_index_for(outer_json)
    empty_roster = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      outer_json.json_type.not_nil!.typed_paths,
      {"p" => empty_roster} of String => CrystalClick::DynamicStructure,
    )
    leaf_plans = [{
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [] of Int32),
      child_plan,
    }] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    p_value = CrystalClick::BinaryValue.dynamic(typed_dynamic, selected_json_value)
    outer_json_value = CrystalClick::BinaryValue.json(
      outer_json,
      CrystalClick::BinaryJsonRow.new(
        outer_json,
        [{"p", p_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    granules = [[CrystalClick::BinaryValue.dynamic(dynamic, outer_json_value)] of CrystalClick::BinaryValue]
    at_depth = ->(max_depth : Int32) do
      CrystalClick::BinaryCodecLimits.new(
        max_depth: max_depth,
        max_nodes: 256,
        max_elements: 256,
        max_bytes: 4096,
      )
    end

    depth_six = at_depth.call(6_i32)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      outer_structures,
      granules,
      limits: depth_six,
      json_object_leaf_plans: leaf_plans,
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic,
      streams,
      [1_u64],
      limits: depth_six,
      json_object_leaf_plans: leaf_plans,
    )
    # outer Dynamic=1, bound Object JSON=2, typed Dynamic=3, selected JSON=4,
    # runtime Array=5, and its UInt8 leaf=6. The nominal descriptor and empty
    # actual roster fit at depth five; only the runtime value needs depth six.
    typed_dynamic_value = decoded[0][0].child_at(0).json_row.value_for("p").not_nil!
    nested_array = typed_dynamic_value.child_at(0).json_row.value_for("items").not_nil!
    nested_array.element_at(0).byte_at(0).should eq(9_u8)

    depth_five = at_depth.call(5_i32)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        dynamic,
        outer_structures,
        granules,
        limits: depth_five,
        json_object_leaf_plans: leaf_plans,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        dynamic,
        streams,
        [1_u64],
        limits: depth_five,
        json_object_leaf_plans: leaf_plans,
      )
    end
  end

  it "rejects invalid generic SharedVariant depth origins before encode or decode" do
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    json = w214_red_json_type
    value = CrystalClick::BinaryValue.dynamic(dynamic, w214_red_json_value(json, 1_u8))
    plan = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
      limits: limits,
    )
    values = [[value] of CrystalClick::BinaryValue]
    profile = CrystalClick::BinaryBulkProfile.single_stream
    streams = CrystalClick::BinaryBulkEncoder.encode(
      dynamic,
      values,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      profile,
      plan,
    )

    {0, Int32::MAX}.each do |origin|
      expect_raises(CrystalClick::UnsupportedFormatError, "depth limit") do
        CrystalClick::BinaryBulkEncoder.encode(
          dynamic,
          values,
          CrystalClick::BinaryCodecBudget.new(limits, true),
          profile,
          plan,
          shared_value_depth_origin: origin,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, "depth limit") do
        CrystalClick::BinaryBulkDecoder.decode(
          dynamic,
          streams,
          [1_u64],
          CrystalClick::BinaryCodecBudget.new(limits),
          0,
          nil,
          profile,
          plan,
          shared_value_depth_origin: origin,
        )
      end
    end
  end

  it "charges direct and nested JSON sites to one aggregate read/write operation budget" do
    fixture = W214Fixture.new
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS, true)
    streams = CrystalClick::ObjectDocumentCodec.encode_with_budget(fixture.plan, fixture.granules, write_budget)
    write_budget.node_count.should be > 0_i64
    write_budget.element_count.should be > 0_i64
    write_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: write_budget.limits.max_depth,
      max_nodes: write_budget.node_count - 1_i64,
      max_elements: write_budget.limits.max_elements,
      max_bytes: write_budget.limits.max_bytes,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(
        fixture.plan,
        fixture.granules,
        CrystalClick::BinaryCodecBudget.new(write_short, true),
      )
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS)
    CrystalClick::ObjectDocumentCodec.decode_with_budget(fixture.schema.typed_paths, streams, read_budget)
    read_budget.node_count.should be > 0_i64
    read_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: read_budget.limits.max_depth,
      max_nodes: read_budget.node_count - 1_i64,
      max_elements: read_budget.limits.max_elements,
      max_bytes: read_budget.limits.max_bytes,
    )
    expect_raises(CrystalClick::CorruptPartError, "node limit") do
      CrystalClick::ObjectDocumentCodec.decode_with_budget(
        fixture.schema.typed_paths,
        streams,
        CrystalClick::BinaryCodecBudget.new(read_short),
      )
    end
  end

  it "rejects a wrong descriptor and a trailing byte inside a selected Object SharedVariant envelope" do
    fixture = W214Fixture.new
    single = CrystalClick::ObjectDocumentCodec.encode(
      fixture.plan, fixture.granules, profile: CrystalClick::BinaryBulkProfile.single_stream)
    malformed = w214_mutate_typed_shared_envelope(single, :wrong_descriptor)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(
        fixture.schema.typed_paths, malformed, profile: CrystalClick::BinaryBulkProfile.single_stream)
    end

    sized_profile = CrystalClick::BinaryBulkProfile.with_size_stream
    sized = CrystalClick::ObjectDocumentCodec.encode(fixture.plan, fixture.granules, profile: sized_profile)
    trailing = w214_mutate_typed_shared_envelope(sized, :trailing_byte)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(fixture.schema.typed_paths, trailing, profile: sized_profile)
    end
  end

  it "keeps JSON out of default actual rosters and unbound root Object Dynamic" do
    json = w214_red_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    expect_raises(ArgumentError, "invalid typed Object Dynamic actual roster") do
      CrystalClick::ObjectDocumentPlan.new(
        empty,
        schema.typed_paths,
        {"p" => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)},
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
        json,
        CrystalClick::BinaryCodecLimits.default,
      )
    end
    selected = CrystalClick::BinaryValue.dynamic(dynamic, w214_red_json_value(json, 7_u8))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
        selected,
        dynamic,
        CrystalClick::BinaryCodecLimits.default,
        true,
      )
    end

    root = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["root"] of String),
      {"root" => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)},
    )
    expect_raises(ArgumentError, "JSON") do
      CrystalClick::ObjectDocumentPlan.new(root, {} of String => CrystalClick::BinaryDataType)
    end
  end

  it "keeps SharedVariant JSON permission closed to Variant, LowCardinality, and non-String Map siblings" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    json = w214_red_json_type
    json_value = w214_red_json_value(json, 8_u8)
    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    uint8_arm = (0...variant.child_count).find { |index| variant.child_at(index) == uint8 }.not_nil!
    variant_value = CrystalClick::BinaryValue.variant(
      variant, uint8_arm, CrystalClick::BinaryValue.fixed(uint8, Bytes[3_u8]),
    )
    variant_tuple = CrystalClick::BinaryDataType.tuple([json, variant] of CrystalClick::BinaryDataType)
    variant_tuple_value = CrystalClick::BinaryValue.tuple(
      variant_tuple, [json_value, variant_value] of CrystalClick::BinaryValue,
    )

    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
    low_cardinality_value = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality, CrystalClick::BinaryValue.string("sibling"),
    )
    low_cardinality_tuple = CrystalClick::BinaryDataType.tuple(
      [json, low_cardinality] of CrystalClick::BinaryDataType,
    )
    low_cardinality_tuple_value = CrystalClick::BinaryValue.tuple(
      low_cardinality_tuple, [json_value, low_cardinality_value] of CrystalClick::BinaryValue,
    )

    non_string_key_map = CrystalClick::BinaryDataType.map(uint8, json)
    non_string_key_map_value = CrystalClick::BinaryValue.map(
      non_string_key_map,
      [CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8]), json_value] of CrystalClick::BinaryValue,
    )

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    selected_values = [
      CrystalClick::BinaryValue.dynamic(dynamic, variant_tuple_value),
      CrystalClick::BinaryValue.dynamic(dynamic, low_cardinality_tuple_value),
      CrystalClick::BinaryValue.dynamic(dynamic, non_string_key_map_value),
    ] of CrystalClick::BinaryValue
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      {"p" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
    )

    selected_values.each do |selected|
      expect_raises(CrystalClick::UnsupportedFormatError, "selected child is outside") do
        document = CrystalClick::ObjectDocument.new({"p" => selected})
        CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
      end
      expect_raises(CrystalClick::UnsupportedFormatError, "selected child is outside") do
        CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
          selected,
          dynamic,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
          true,
          allow_shared_json: true,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, "selected child is outside") do
        CrystalClick::ObjectDeclaredDynamicDeclaration.validate_selected_values!(
          selected,
          dynamic,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
          false,
          allow_shared_json: true,
        )
      end
    end
  end
end

private def w214_red_json_value(type : CrystalClick::BinaryDataType, id : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"counter", CrystalClick::BinaryValue.int64(id.to_i64 * 10_i64 + 1_i64)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

describe "W214 declared Object Dynamic inline SharedVariant JSON" do
  it "encodes and decodes a direct JSON actual through existing Object APIs" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    empty_object = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty_object,
      schema.typed_paths,
      {"p" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
    )
    document = CrystalClick::ObjectDocument.new({
      "p" => CrystalClick::BinaryValue.dynamic(dynamic, w214_red_json_value(w214_red_json_type, 17_u8)),
    })

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    decoded.size.should eq(1)
    decoded[0].size.should eq(1)
    actual = decoded[0][0].value_for("p").child_at(0)
    actual.type.tag.should eq(CrystalClick::BinaryDataType::TAG_JSON)
    actual.json_row.value_for("id").not_nil!.byte_at(0).should eq(17_u8)
    actual.json_row.value_for("counter").not_nil!.as_int64.should eq(171_i64)
    actual.json_row.value_for("maybe").not_nil!.is_null?.should be_true
  end
end
