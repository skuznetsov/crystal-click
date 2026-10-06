require "./spec_helper"

private def w193a_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (8 * index)) & 255_u64).to_u8 }
end

private def w193a_join(*parts : Bytes) : Bytes
  result = Bytes.new(parts.sum(&.size))
  offset = 0
  parts.each do |part|
    result[offset, part.size].copy_from(part)
    offset += part.size
  end
  result
end

private def w193a_events(entries : Array(Tuple(String, UInt64)))
  entries.map { |entry| CrystalClick::ObjectSharedPathSubstreamEvent.new(entry[0], entry[1]) }
end

private def w193a_empty_structure
  {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
end

describe "W193 independently authored per-path framing falsifiers" do
  it "matches the retained uniform COMPACT path, not just the PLAIN path" do
    # Actual retained root ADVANCED-v2 Data bytes [277,333), independently
    # read from the decompressor output: beta in rows seven and eight.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    data = w193a_join(
      w193a_u64(4_u64), Bytes[0], w193a_u64(1_u64), Bytes[2, 1, 0],
      w193a_u64(10_u64), w193a_u64(10_u64),
      Bytes[0x15, 8], "r-beta-7".to_slice,
      Bytes[0x15, 8], "r-beta-8".to_slice,
    )
    events = w193a_events([
      {".dynamic_structure", 0_u64}, {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64}, {".SharedVariant.size", 20_u64},
      {".SharedVariant", 36_u64},
    ])
    rows = CrystalClick::ObjectSharedPathCodec.decode(data, events, 2, dynamic)
    rows.map { |row| row.child_at(0).as_string }.should eq(["r-beta-7", "r-beta-8"])
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, rows)
    encoded.data.should eq(data)
    encoded.events.map { |event| {event.name, event.relative_offset} }.should eq(
      events.map { |event| {event.name, event.relative_offset} }
    )
  end

  it "lays canonical Array bytes before SharedVariant irrespective of logical preparation order" do
    # Source-derived literal, not a stock witness of ordinary actual types.
    # Variant emits all child bodies in canonical global-discriminator order.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    array = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("Int64"))
    rows = [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("s")),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array, [CrystalClick::BinaryValue.int64(7_i64)])),
      CrystalClick::BinaryValue.dynamic(dynamic),
    ]
    structures = {"root" => CrystalClick::DynamicStructure.new([array])}
    expected = w193a_join(
      w193a_u64(4_u64), Bytes[1, 0x1e, 0x0a], w193a_u64(1_u64),
      Bytes[4, 0, 0, 1, 0, 255],
      w193a_u64(0_u64), w193a_u64(1_u64), w193a_u64(7_u64),
      w193a_u64(3_u64), Bytes[0x15, 1, 0x73],
    )
    events = [
      {".dynamic_structure", 0_u64}, {".variant_discr_prefix", 11_u64},
      {".variant_discr", 19_u64}, {".Array(Int64).size0", 25_u64},
      {".Array(Int64)", 41_u64}, {".SharedVariant.size", 49_u64},
      {".SharedVariant", 57_u64},
    ]
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    encoded.data.should eq(expected)
    encoded.events.map { |event| {event.name, event.relative_offset} }.should eq(events)
    decoded = CrystalClick::ObjectSharedPathCodec.decode(expected, w193a_events(events), 4, dynamic)
    decoded.map(&.type).should eq([dynamic, dynamic, dynamic, dynamic])
    decoded[0].child_at(0).type.should eq(array)
    decoded[0].child_at(0).child_count.should eq(0)
    decoded[1].child_at(0).as_string.should eq("s")
    decoded[2].child_at(0).type.should eq(array)
    decoded[2].child_at(0).child_count.should eq(1)
    decoded[2].child_at(0).child_at(0).as_int64.should eq(7_i64)
    decoded[3].is_null?.should be_true
  end

  it "retains zero-byte callbacks for zero rows and distinguishes them from a NULL row" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, [] of CrystalClick::BinaryValue)
    empty.data.should eq(w193a_join(w193a_u64(4_u64), Bytes[0], w193a_u64(1_u64)))
    empty.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64}, {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64}, {".SharedVariant.size", 17_u64},
      {".SharedVariant", 17_u64},
    ])
    CrystalClick::ObjectSharedPathCodec.decode(empty.data, empty.events, 0, dynamic).should be_empty
    one_null = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, [CrystalClick::BinaryValue.dynamic(dynamic)])
    one_null.data.should eq(w193a_join(empty.data, Bytes[1, 1, 255]))
    CrystalClick::ObjectSharedPathCodec.decode(one_null.data, one_null.events, 1, dynamic)[0].is_null?.should be_true
  end

  it "finishes all nested prefixes before the outer discriminator body" do
    # Source-derived phase-order falsifier: Variant prefix recursively visits
    # every arm before any bulk body runs. A paired implementation can otherwise
    # agree with itself while storing the nested roster at the wrong position.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    array = CrystalClick::BinaryDataType.array(dynamic)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.int64(11_i64)),
    ]))]
    structures = {
      "root"                => CrystalClick::DynamicStructure.new([array]),
      "root.arm.0.elements" => CrystalClick::DynamicStructure.new([int64]),
    }
    arm = ".#{array.name}"
    expected_names = [
      ".dynamic_structure", ".variant_discr_prefix",
      "#{arm}.dynamic_structure", "#{arm}.variant_discr_prefix",
      ".variant_discr", "#{arm}.size0", "#{arm}.variant_discr",
      "#{arm}.Int64", "#{arm}.SharedVariant.size", "#{arm}.SharedVariant",
      ".SharedVariant.size", ".SharedVariant",
    ]
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    encoded.events.map(&.name).should eq(expected_names)
    decoded = CrystalClick::ObjectSharedPathCodec.decode(encoded.data, encoded.events, 1, dynamic)
    decoded.size.should eq(1)
    decoded[0].type.should eq(dynamic)
    decoded_array = decoded[0].child_at(0)
    decoded_array.type.should eq(array)
    decoded_array.child_count.should eq(1)
    decoded_array.child_at(0).type.should eq(dynamic)
    decoded_array.child_at(0).child_at(0).as_int64.should eq(11_i64)
  end

  it "escapes the Tuple field separator without aliasing literal escape-looking field names" do
    # ISerialization::getFileNameForStream escapes the leading Tuple field
    # dot together with the raw field, unlike a structural stream component.
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    tuple = CrystalClick::BinaryDataType.tuple([int64, int64], ["a.b", "a%2Eb"])
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.int64(1_i64), CrystalClick::BinaryValue.int64(2_i64),
    ]))]
    encoded = CrystalClick::ObjectSharedPathCodec.encode(
      dynamic, {"root" => CrystalClick::DynamicStructure.new([tuple])}, rows,
    )
    arm = ".#{tuple.name}"
    names = encoded.events.map(&.name)
    names.should contain("#{arm}%2Ea%2Eb")
    names.should contain("#{arm}%2Ea%252Eb")
    names.should_not contain("#{arm}.a%2Eb")
    decoded = CrystalClick::ObjectSharedPathCodec.decode(encoded.data, encoded.events, 1, dynamic)
    decoded.size.should eq(1)
    decoded[0].type.should eq(dynamic)
    decoded[0].child_at(0).type.should eq(tuple)
    decoded[0].child_at(0).elements.map(&.as_int64).should eq([1_i64, 2_i64])
  end

  it "rejects cumulative descriptor depth before looking for the next prefix or body" do
    # Two independent V3 prefixes advertise Array(Dynamic(max_types=1)).
    # At the second site, the descriptor's nested Dynamic is at depth five.
    # No later mode/body callbacks exist: a late depth check instead fails on
    # that missing tape entry, so the diagnostic distinguishes the ordering.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array = CrystalClick::BinaryDataType.array(dynamic)
    prefix = w193a_join(w193a_u64(4_u64), Bytes[1, 0x1e, 0x2b, 1])
    data = w193a_join(prefix, w193a_u64(1_u64), prefix)
    events = w193a_events([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 12_u64},
      {".#{array.name}.dynamic_structure", 20_u64},
    ])
    limits = CrystalClick::BinaryCodecLimits.new(4, 4_096, 100_000, 1_048_576)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError, "binary codec depth limit exceeded") do
      CrystalClick::ObjectSharedPathCodec.decode_with_budget(data, events, 1, dynamic, budget)
    end
  end

  it "uses escaped TupleElement names for BASIC Map keys and values" do
    # DataTypeMap builds Array(Tuple(keys, values)) with SerializationNamed
    # TupleElement children. Their leading dots use the Tuple escape rule,
    # including recursively emitted Dynamic prefixes in a Map value.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    map = CrystalClick::BinaryDataType.map(int64, dynamic)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.map(map, [
      CrystalClick::BinaryValue.int64(7_i64),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.int64(11_i64)),
    ]))]
    structures = {
      "root"                        => CrystalClick::DynamicStructure.new([map]),
      "root.arm.0.elements.field.1" => CrystalClick::DynamicStructure.new([int64]),
    }
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    arm = ".#{map.name}"
    names = encoded.events.map(&.name)
    names.should contain("#{arm}%2Ekeys")
    names.should contain("#{arm}%2Evalues.dynamic_structure")
    names.should contain("#{arm}%2Evalues.variant_discr")
    names.should_not contain("#{arm}.keys")
    names.should_not contain("#{arm}.values.dynamic_structure")
    decoded = CrystalClick::ObjectSharedPathCodec.decode(encoded.data, encoded.events, 1, dynamic)
    decoded[0].child_at(0).type.should eq(map)
    decoded[0].child_at(0).elements[0].as_int64.should eq(7_i64)
    decoded[0].child_at(0).elements[1].child_at(0).as_int64.should eq(11_i64)
  end

  it "preserves ArrayElements levels across Dynamic arm boundaries" do
    # getFileNameForStream counts ArrayElements over the entire substream
    # path; neither Dynamic nor VariantElements resets that level.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    inner_array = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("Int64"))
    outer_array = CrystalClick::BinaryDataType.array(dynamic)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(outer_array, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(inner_array, [
        CrystalClick::BinaryValue.int64(7_i64),
      ])),
    ]))]
    structures = {
      "root"                => CrystalClick::DynamicStructure.new([outer_array]),
      "root.arm.0.elements" => CrystalClick::DynamicStructure.new([inner_array]),
    }
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    nested_arm = ".#{outer_array.name}.#{inner_array.name}"
    names = encoded.events.map(&.name)
    names.should contain("#{nested_arm}.size1")
    names.should_not contain("#{nested_arm}.size0")
    decoded = CrystalClick::ObjectSharedPathCodec.decode(encoded.data, encoded.events, 1, dynamic)
    decoded[0].child_at(0).child_at(0).child_at(0).child_at(0).as_int64.should eq(7_i64)
  end

  it "keeps empty and embedded-NUL Strings as values, not missing Dynamic rows" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    rows = ["", "a\u0000b"].map do |text|
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string(text))
    end
    expected = w193a_join(
      w193a_u64(4_u64), Bytes[0], w193a_u64(1_u64), Bytes[2, 1, 0],
      w193a_u64(2_u64), w193a_u64(5_u64), Bytes[0x15, 0, 0x15, 3, 0x61, 0, 0x62],
    )
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, rows)
    encoded.data.should eq(expected)
    decoded = CrystalClick::ObjectSharedPathCodec.decode(expected, encoded.events, 2, dynamic)
    decoded.map(&.type).should eq([dynamic, dynamic])
    decoded.map { |row| row.child_at(0).as_string }.should eq(["", "a\u0000b"])
    decoded.each { |row| row.is_null?.should be_false }
  end

  it "rejects framing and getter mutations even when lengths and row domain look plausible" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("s"))]
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, rows)
    data = encoded.data
    bad_mode = data.dup
    bad_mode[9] = 0_u8
    bad_count = data.dup
    bad_count[17] = 2_u8
    bad_tag = data.dup
    bad_tag[19] = 7_u8
    [bad_mode, bad_count, bad_tag, data[0, data.size - 1], w193a_join(data, Bytes[0])].each do |bad|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPathCodec.decode(bad, encoded.events, 1, dynamic)
      end
    end
    original = encoded.events.map { |event| {event.name, event.relative_offset} }
    changed_name = original.dup
    changed_name[4] = {".SharedVariant.bad", changed_name[4][1]}
    changed_offset = original.dup
    changed_offset[3] = {changed_offset[3][0], changed_offset[3][1] + 1_u64}
    overflowing_offset = original.dup
    overflowing_offset[3] = {overflowing_offset[3][0], UInt64::MAX}
    wrong_order = original.dup
    wrong_order[3], wrong_order[4] = wrong_order[4], wrong_order[3]
    [changed_name, changed_offset, overflowing_offset, wrong_order, original[0, 4], original + [{".extra", data.size.to_u64}]].each do |events|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectSharedPathCodec.decode(data, w193a_events(events), 1, dynamic)
      end
    end
  end

  it "bounds compact NULL expansion by the caller's element budget rather than the tiny physical slice" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prefix = w193a_join(w193a_u64(4_u64), Bytes[0], w193a_u64(1_u64))
    # VarUInt 1024 rows, uniform COMPACT format, NULL discriminator. All
    # children have zero bytes even though the logical domain is nonempty.
    data = w193a_join(prefix, Bytes[0x80, 0x08, 1, 255])
    events = w193a_events([
      {".dynamic_structure", 0_u64}, {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64}, {".SharedVariant.size", 21_u64},
      {".SharedVariant", 21_u64},
    ])
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
      max_elements: 8,
      max_bytes: 1024,
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode_with_budget(data, events, 1024, dynamic, budget)
    end
  end

  it "does not reset a caller budget between exact slices in either direction" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    rows = [CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("s"))]
    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, w193a_empty_structure, rows)
    write_measure = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    CrystalClick::ObjectSharedPathCodec.encode_with_budget(dynamic, w193a_empty_structure, rows, write_measure)
    read_measure = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    CrystalClick::ObjectSharedPathCodec.decode_with_budget(encoded.data, encoded.events, 1, dynamic, read_measure)
    [true, false].each do |writing|
      measured = writing ? write_measure : read_measure
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        max_nodes: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
        max_elements: CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
        max_bytes: measured.wire_byte_count.to_i,
      )
      budget = CrystalClick::BinaryCodecBudget.new(limits, writing)
      if writing
        CrystalClick::ObjectSharedPathCodec.encode_with_budget(dynamic, w193a_empty_structure, rows, budget)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::ObjectSharedPathCodec.encode_with_budget(dynamic, w193a_empty_structure, rows, budget)
        end
      else
        CrystalClick::ObjectSharedPathCodec.decode_with_budget(encoded.data, encoded.events, 1, dynamic, budget)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::ObjectSharedPathCodec.decode_with_budget(encoded.data, encoded.events, 1, dynamic, budget)
        end
      end
    end
  end
end
