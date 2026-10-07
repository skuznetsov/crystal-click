require "./spec_helper"

private def w201_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w201_u64s(values : Array(UInt64)) : Bytes
  bytes = [] of UInt8
  values.each { |value| w201_u64(value).each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w201_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  bytes = Bytes.new(size)
  offset = 0
  parts.each do |part|
    bytes[offset, part.size].copy_from(part)
    offset += part.size
  end
  bytes
end

private def w201_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w201_lc_nullable_string(
  low_cardinality : CrystalClick::BinaryDataType,
  nullable : CrystalClick::BinaryDataType,
  value : String?,
) : CrystalClick::BinaryValue
  payload = if value
              CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(value))
            else
              CrystalClick::BinaryValue.nullable(nullable)
            end
  CrystalClick::BinaryValue.low_cardinality(low_cardinality, payload)
end

private def w201_nested_value(
  type : CrystalClick::BinaryDataType,
  elements : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.nested(type, elements)
end

private def w201_nested_record(
  type : CrystalClick::BinaryDataType,
  fields : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(type.child_at(0), fields)
end

private def w201_replace_lane(
  source : CrystalClick::BinaryBulkStreams,
  changed_role : String,
  changed_bytes : Bytes,
) : CrystalClick::BinaryBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  source.roles.each do |role|
    lane = source.stream(role)
    bytes = role == changed_role ? changed_bytes : lane.bytes
    lanes[role] = CrystalClick::BinaryBulkStream.new(bytes, lane.offsets)
  end
  CrystalClick::BinaryBulkStreams.new(source.mark_count, lanes)
end

describe "W201 recursive specialized Nested bulk composition" do
  it "encodes Nested with LowCardinality(Nullable(String))" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested(
      [low_cardinality] of CrystalClick::BinaryDataType,
      ["label"] of String,
    )
    low_value = w201_lc_nullable_string(low_cardinality, nullable, "x")
    record = w201_nested_record(nested, [low_value] of CrystalClick::BinaryValue)
    value = w201_nested_value(nested, [record] of CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(
      nested,
      [[value]] of Array(CrystalClick::BinaryValue),
    )

    streams.roles.should eq([
      "root.elements.field.0.dictionary",
      "root.elements.field.0.indexes",
      "root.sizes",
    ] of String)
  end

  it "accounts LC elements by Nested shape across ragged, empty, and zero-row marks" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested([low] of CrystalClick::BinaryDataType, ["label"] of String)
    rec = ->(value : String?) { w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, value)] of CrystalClick::BinaryValue) }
    populated = w201_nested_value(nested, [rec.call("red"), rec.call("red"), rec.call(nil)] of CrystalClick::BinaryValue)
    empty_elements = w201_nested_value(nested, [] of CrystalClick::BinaryValue)
    later = w201_nested_value(nested, [rec.call("blue")] of CrystalClick::BinaryValue)
    final = w201_nested_value(nested, [rec.call(nil), rec.call("red")] of CrystalClick::BinaryValue)
    granules = [
      [populated] of CrystalClick::BinaryValue,
      [empty_elements] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [later] of CrystalClick::BinaryValue,
      [final] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 0_u64, 1_u64, 1_u64]

    streams = CrystalClick::BinaryBulkCodec.encode(nested, granules)
    streams.stream("root.sizes").bytes.should eq(w201_u64s([3_u64, 0_u64, 1_u64, 2_u64]))
    streams.stream("root.sizes").offsets.should eq([0_u64, 8_u64, 16_u64, 16_u64, 24_u64, 32_u64])

    # The independent size lane says the nested LC site has 3, 0, 0, 1,
    # and 2 occurrences. Empty nested arrays and the empty mark add no keys.
    indexes = streams.stream("root.elements.field.0.indexes")
    indexes.offsets.should eq([0_u64, 19_u64, 19_u64, 19_u64, 36_u64, 54_u64])
    w201_read_u64(indexes.bytes, 8).should eq(3_u64)
    w201_read_u64(indexes.bytes, 27).should eq(1_u64)
    w201_read_u64(indexes.bytes, 44).should eq(2_u64)

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(nested, "events")
    physical.stream_names.should eq({
      "root.sizes"                       => "events.size0",
      "root.elements.field.0.dictionary" => "events%2Elabel.dict",
      "root.elements.field.0.indexes"    => "events%2Elabel",
    } of String => String)

    restored = CrystalClick::BinaryBulkCodec.decode(nested, streams, rows_per_mark)
    restored[0][0].type.should eq(nested)
    restored[0][0].element_count.should eq(3)
    restored[0][0].element_at(2).child_at(0).child_at(0).is_null?.should be_true
    restored[1][0].element_count.should eq(0)
    restored[2].should be_empty
    restored[3][0].element_at(0).child_at(0).child_at(0).child_at(0).as_string.should eq("blue")
    restored[4][0].element_at(1).child_at(0).child_at(0).child_at(0).as_string.should eq("red")

    # A zero-length selection is still a legal window at the end of the grid.
    CrystalClick::BinaryBulkCodec.decode(
      nested, streams, rows_per_mark, first_mark: 5, mark_count: 0
    ).should be_empty
    selected = CrystalClick::BinaryBulkCodec.decode(
      nested, streams, rows_per_mark, first_mark: 3, mark_count: 2
    )
    selected[0][0].element_count.should eq(1)
    selected[1][0].element_count.should eq(2)
  end

  it "composes Variant arms inside nominal Nested under both String profiles" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    variant = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
    nested = CrystalClick::BinaryDataType.nested([variant] of CrystalClick::BinaryDataType, ["choice"] of String)
    string_index = variant.children.index(string).not_nil!
    uint64_index = variant.children.index(uint64).not_nil!
    choice = ->(index : Int32, value : CrystalClick::BinaryValue) { CrystalClick::BinaryValue.variant(variant, index, value) }
    first = w201_nested_value(nested, [
      w201_nested_record(nested, [choice.call(string_index, CrystalClick::BinaryValue.string("a"))] of CrystalClick::BinaryValue),
      w201_nested_record(nested, [CrystalClick::BinaryValue.variant_null(variant)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)
    empty = w201_nested_value(nested, [] of CrystalClick::BinaryValue)
    last = w201_nested_value(nested, [
      w201_nested_record(nested, [choice.call(uint64_index, CrystalClick::BinaryValue.uint64(42_u64))] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)
    granules = [
      [first] of CrystalClick::BinaryValue,
      [empty] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [last] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 0_u64, 1_u64]

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      streams = CrystalClick::BinaryBulkCodec.encode(nested, granules, profile: profile)
      streams.roles.should contain("root.elements.field.0.discriminators")
      streams.stream("root.sizes").bytes.should eq(w201_u64s([2_u64, 0_u64, 1_u64]))
      streams.stream("root.sizes").offsets.should eq([0_u64, 8_u64, 16_u64, 16_u64, 24_u64])
      streams.stream("root.elements.field.0.discriminators").bytes.should eq(Bytes[
        string_index.to_u8, 0xff_u8, uint64_index.to_u8,
      ])
      streams.stream("root.elements.field.0.discriminators").offsets.should eq([0_u64, 2_u64, 2_u64, 2_u64, 3_u64])

      physical = CrystalClick::BinaryBulkPhysicalPlan.new(nested, "events", profile: profile)
      physical.stream_names.keys.sort.should eq(streams.roles)
      physical.prefix_size_for("root.elements.field.0.discriminators").should eq(8)

      restored = CrystalClick::BinaryBulkCodec.decode(nested, streams, rows_per_mark, profile: profile)
      restored[0][0].type.should eq(nested)
      restored[0][0].element_at(0).child_at(0).variant_child?.not_nil!.as_string.should eq("a")
      restored[0][0].element_at(1).child_at(0).variant_child?.should be_nil
      restored[3][0].element_at(0).child_at(0).variant_child?.not_nil!.as_uint64.should eq(42_u64)
    end
  end

  it "keeps Nested identity beneath Array(Tuple) beside an unrelated LC sibling" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    nested_lc = CrystalClick::BinaryDataType.low_cardinality(nullable)
    sibling_lc = CrystalClick::BinaryDataType.low_cardinality(string)
    nested = CrystalClick::BinaryDataType.nested([nested_lc] of CrystalClick::BinaryDataType, ["label"] of String)
    pair = CrystalClick::BinaryDataType.tuple(
      [nested, sibling_lc] of CrystalClick::BinaryDataType,
      ["records", "lookup"] of String,
    )
    array = CrystalClick::BinaryDataType.array(pair)
    make_pair = ->(labels : Array(String?), lookup : String) {
      records = labels.map { |label| w201_nested_record(nested, [w201_lc_nullable_string(nested_lc, nullable, label)] of CrystalClick::BinaryValue) }
      nested_value = w201_nested_value(nested, records)
      CrystalClick::BinaryValue.tuple(pair, [
        nested_value,
        CrystalClick::BinaryValue.low_cardinality(sibling_lc, CrystalClick::BinaryValue.string(lookup)),
      ] of CrystalClick::BinaryValue)
    }
    first_array = CrystalClick::BinaryValue.array(array, [
      make_pair.call(["red", "blue"] of String?, "lookup-a"),
      make_pair.call([] of String?, "lookup-b"),
    ] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
    later_array = CrystalClick::BinaryValue.array(array, [
      make_pair.call([nil] of String?, "lookup-c"),
    ] of CrystalClick::BinaryValue)
    granules = [
      [first_array] of CrystalClick::BinaryValue,
      [empty_array] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [later_array] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 0_u64, 1_u64]

    streams = CrystalClick::BinaryBulkCodec.encode(array, granules)
    streams.roles.should eq([
      "root.elements.field.0.elements.field.0.dictionary",
      "root.elements.field.0.elements.field.0.indexes",
      "root.elements.field.0.sizes",
      "root.elements.field.1.dictionary",
      "root.elements.field.1.indexes",
      "root.sizes",
    ] of String)
    # The two outer pairs each contain a nominal Nested; their shared size
    # stream remains independent from the flattened LC sibling site.
    streams.stream("root.sizes").bytes.should eq(w201_u64s([2_u64, 0_u64, 1_u64]))
    streams.stream("root.elements.field.0.sizes").bytes.should eq(w201_u64s([2_u64, 0_u64, 1_u64]))
    physical = CrystalClick::BinaryBulkPhysicalPlan.new(array, "events")
    physical.stream_names.keys.sort.should eq(streams.roles)

    restored = CrystalClick::BinaryBulkCodec.decode(array, streams, rows_per_mark)
    restored[0][0].type.should eq(array)
    restored[0][0].element_at(0).child_at(0).type.should eq(nested)
    restored[0][0].element_at(0).child_at(0).element_count.should eq(2)
    restored[0][0].element_at(1).child_at(0).element_count.should eq(0)
    restored[3][0].element_at(0).child_at(0).element_at(0).child_at(0).child_at(0).is_null?.should be_true
    restored[3][0].element_at(0).child_at(1).child_at(0).as_string.should eq("lookup-c")
    restored[1][0].element_count.should eq(0)
    restored[2].should be_empty
  end

  it "composes LC, Variant, and Dynamic fields together in one Nested" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    variant = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested = CrystalClick::BinaryDataType.nested(
      [low, variant, dynamic] of CrystalClick::BinaryDataType,
      ["label", "choice", "payload"] of String,
    )
    string_index = variant.children.index(string).not_nil!
    uint64_index = variant.children.index(uint64).not_nil!
    structures = {"root.elements.field.2" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)}
    make_record = ->(label : String?, choice_index : Int32, choice : CrystalClick::BinaryValue, payload : CrystalClick::BinaryValue) {
      w201_nested_record(nested, [
        w201_lc_nullable_string(low, nullable, label),
        CrystalClick::BinaryValue.variant(variant, choice_index, choice),
        CrystalClick::BinaryValue.dynamic(dynamic, payload),
      ] of CrystalClick::BinaryValue)
    }
    first = w201_nested_value(nested, [
      make_record.call("red", string_index, CrystalClick::BinaryValue.string("v"), CrystalClick::BinaryValue.uint64(7_u64)),
      make_record.call(nil, uint64_index, CrystalClick::BinaryValue.uint64(8_u64), CrystalClick::BinaryValue.string("shared")),
    ] of CrystalClick::BinaryValue)
    empty = w201_nested_value(nested, [] of CrystalClick::BinaryValue)
    last = w201_nested_value(nested, [
      make_record.call("blue", string_index, CrystalClick::BinaryValue.string("z"), CrystalClick::BinaryValue.uint64(9_u64)),
    ] of CrystalClick::BinaryValue)
    granules = [
      [first] of CrystalClick::BinaryValue,
      [empty] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [last] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 0_u64, 1_u64]

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      encoded = CrystalClick::BinaryDynamicBulkCodec.encode(nested, structures, granules, profile: profile)
      encoded.structures.site_paths.should eq(["root.elements.field.2"] of String)
      encoded.data.stream("root.sizes").bytes.should eq(w201_u64s([2_u64, 0_u64, 1_u64]))
      encoded.data.stream("root.elements.field.0.indexes").offsets.size.should eq(5)
      encoded.data.roles.should contain("root.elements.field.1.discriminators")
      encoded.data.roles.should contain("root.elements.field.2.discriminators")

      prepared = CrystalClick::BinaryDynamicBulkPlan.new(nested, structures, profile)
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "events")
      physical.data_stream_names.keys.sort.should eq(encoded.data.roles)
      physical.structure_stream_names.should eq({
        "root.elements.field.2.dynamic_structure" => "events%2Epayload.dynamic_structure",
      } of String => String)

      restored = CrystalClick::BinaryDynamicBulkCodec.decode(nested, encoded, rows_per_mark, profile: profile)
      restored[0][0].type.should eq(nested)
      restored[0][0].element_at(0).child_at(0).child_at(0).child_at(0).as_string.should eq("red")
      restored[0][0].element_at(1).child_at(0).child_at(0).is_null?.should be_true
      restored[0][0].element_at(0).child_at(2).child_at(0).as_uint64.should eq(7_u64)
      restored[0][0].element_at(1).child_at(2).child_at(0).as_string.should eq("shared")
      restored[1][0].element_count.should eq(0)
      restored[2].should be_empty
      restored[3][0].element_at(0).child_at(2).child_at(0).as_uint64.should eq(9_u64)
    end
  end

  it "routes a Nested-with-LC actual through an ordinary Dynamic roster" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested([low] of CrystalClick::BinaryDataType, ["label"] of String)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structures = {"root" => CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)}
    make_nested = ->(labels : Array(String?)) {
      records = labels.map { |label| w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, label)] of CrystalClick::BinaryValue) }
      w201_nested_value(nested, records)
    }
    actual = CrystalClick::BinaryValue.dynamic(dynamic, make_nested.call(["one", "two"] of String?))
    empty_actual = CrystalClick::BinaryValue.dynamic(dynamic, make_nested.call([] of String?))
    null_actual = CrystalClick::BinaryValue.dynamic(dynamic)
    shared_actual = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("fallback"))
    later_actual = CrystalClick::BinaryValue.dynamic(dynamic, make_nested.call(["later"] of String?))
    granules = [
      [actual, empty_actual, null_actual, shared_actual] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [later_actual] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [4_u64, 0_u64, 1_u64]

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      encoded = CrystalClick::BinaryDynamicBulkCodec.encode(dynamic, structures, granules, profile: profile)
      encoded.data.roles.should contain("root.arm.0.sizes")
      encoded.data.roles.should contain("root.arm.0.elements.field.0.dictionary")
      prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, structures, profile)
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "events")
      physical.data_stream_names["root.arm.0.sizes"].should eq("events.Nested%28label%20LowCardinality%28Nullable%28String%29%29%29.size0")
      physical.data_stream_names.keys.sort.should eq(encoded.data.roles)

      restored = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, encoded, rows_per_mark, profile: profile)
      restored[0][0].child_at(0).type.should eq(nested)
      restored[0][0].child_at(0).element_count.should eq(2)
      restored[0][1].child_at(0).element_count.should eq(0)
      restored[0][2].is_null?.should be_true
      restored[0][3].child_at(0).as_string.should eq("fallback")
      restored[1].should be_empty
      restored[2][0].child_at(0).element_at(0).child_at(0).child_at(0).child_at(0).as_string.should eq("later")
    end
  end

  it "preserves per-path LC prefix and additional-key order for Nested actuals" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested([low] of CrystalClick::BinaryDataType, ["label"] of String)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structures = {"root" => CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)}
    make_nested = ->(labels : Array(String?)) {
      records = labels.map { |label| w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, label)] of CrystalClick::BinaryValue) }
      CrystalClick::BinaryValue.nested(nested, records)
    }
    rows = [
      CrystalClick::BinaryValue.dynamic(dynamic, make_nested.call(["red", "blue"] of String?)),
      CrystalClick::BinaryValue.dynamic(dynamic, make_nested.call([] of String?)),
      CrystalClick::BinaryValue.dynamic(dynamic),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("shared")),
    ] of CrystalClick::BinaryValue
    nested_prefix = ".#{nested.name}"
    dictionary_prefix = "#{nested_prefix}%2Elabel.dict_prefix"
    dictionary_body = "#{nested_prefix}%2Elabel.dict"
    indexes_body = "#{nested_prefix}%2Elabel"

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows, profile: profile)
      names = encoded.events.map(&.name)
      names.first(3).should eq([
        ".dynamic_structure",
        ".variant_discr_prefix",
        dictionary_prefix,
      ] of String)
      names.index(".variant_discr").not_nil!.should be < names.index("#{nested_prefix}.size0").not_nil!
      names.index("#{nested_prefix}.size0").not_nil!.should be < names.index(dictionary_body).not_nil!
      names.index(dictionary_body).not_nil!.should be < names.index(indexes_body).not_nil!
      encoded.events.map(&.relative_offset).should eq(encoded.events.map(&.relative_offset).sort)

      # Object shared paths own an additional-keys-only LC tape: every new
      # nested label remains ordered in the index stream after its prefix/body.
      index_event = names.index(indexes_body).not_nil!
      index_start = encoded.events[index_event].relative_offset.to_i
      index_end = if following = encoded.events[index_event + 1]?
                    following.relative_offset.to_i
                  else
                    encoded.data.size
                  end
      index_lane = encoded.data[index_start, index_end - index_start]
      expected_index_lane = w201_concat([
        w201_u64(0x600_u64),
        w201_u64(4_u64),
        Bytes[0_u8, 0_u8, 3_u8, 'r'.ord.to_u8, 'e'.ord.to_u8, 'd'.ord.to_u8,
          4_u8, 'b'.ord.to_u8, 'l'.ord.to_u8, 'u'.ord.to_u8, 'e'.ord.to_u8],
        w201_u64(2_u64),
        Bytes[2_u8, 3_u8],
      ] of Bytes)
      index_lane.should eq(expected_index_lane)
      w201_read_u64(index_lane, 27).should eq(2_u64)

      restored = CrystalClick::ObjectSharedPathCodec.decode(
        encoded.data, encoded.events, rows.size, dynamic, profile: profile
      )
      restored[0].child_at(0).type.should eq(nested)
      restored[0].child_at(0).element_at(0).child_at(0).child_at(0).child_at(0).as_string.should eq("red")
      restored[0].child_at(0).element_at(1).child_at(0).child_at(0).child_at(0).as_string.should eq("blue")
      restored[1].child_at(0).element_count.should eq(0)
      restored[2].is_null?.should be_true
      restored[3].child_at(0).as_string.should eq("shared")
    end
  end

  it "rejects independently corrupted Nested sizes and LC occurrence counts" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested([low] of CrystalClick::BinaryDataType, ["label"] of String)
    first = w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, "a")] of CrystalClick::BinaryValue)
    second = w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, "b")] of CrystalClick::BinaryValue)
    value = w201_nested_value(nested, [first, second] of CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryBulkCodec.encode(nested, [[value]] of Array(CrystalClick::BinaryValue))

    wrong_size = w201_u64(1_u64)
    bad_shape = w201_replace_lane(streams, "root.sizes", wrong_size)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nested, bad_shape, [1_u64])
    end
    # Even an empty end-window must authenticate the full shape schedule,
    # rather than hiding an inconsistent LC ancestor outside the selection.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nested, bad_shape, [1_u64], first_mark: 1, mark_count: 0)
    end

    wrong_count = streams.stream("root.elements.field.0.indexes").bytes
    w201_u64(1_u64).each_with_index { |byte, index| wrong_count[index + 8] = byte }
    bad_indexes = w201_replace_lane(streams, "root.elements.field.0.indexes", wrong_count)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nested, bad_indexes, [1_u64])
    end
  end

  it "retains byte-budget, JSON, QBit, and Nullable(Nested) boundaries" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(string)
    low = CrystalClick::BinaryDataType.low_cardinality(nullable)
    nested = CrystalClick::BinaryDataType.nested([low] of CrystalClick::BinaryDataType, ["label"] of String)
    record = w201_nested_record(nested, [w201_lc_nullable_string(low, nullable, "bounded")] of CrystalClick::BinaryValue)
    value = w201_nested_value(nested, [record] of CrystalClick::BinaryValue)
    rows = [[value]] of Array(CrystalClick::BinaryValue)
    valid = CrystalClick::BinaryBulkCodec.encode(nested, rows)

    tiny_write = CrystalClick::BinaryCodecLimits.new(64, 100_000, 100_000, 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(nested, rows, limits: tiny_write)
    end
    tiny_read = CrystalClick::BinaryCodecLimits.new(64, 100_000, 100_000, 1)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nested, valid, [1_u64], limits: tiny_read)
    end

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(nested) }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[
        0x23_u8, 0x2f_u8, 0x01_u8, 0x01_u8, 0x78_u8, 0x15_u8,
      ])
    end

    json_nested = CrystalClick::BinaryDataType.nested(
      [CrystalClick::BinaryDataType.json] of CrystalClick::BinaryDataType,
      ["document"] of String,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(json_nested, [] of Array(CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(json_nested, "document")
    end

    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 8_u64))
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["embedding"] of String)
    end
  end
end
