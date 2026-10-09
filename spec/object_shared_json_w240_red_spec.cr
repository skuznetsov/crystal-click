require "./spec_helper"

private alias W240RJsonLeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w240r_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w240r_json_value(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w240r_empty_json_value : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.json
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(type, [] of Tuple(String, CrystalClick::BinaryValue)),
  )
end

private def w240r_assert_value_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

private def w240r_concat(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }
  output = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      output[offset] = byte
      offset += 1
    end
  end
  output
end

private def w240r_var_uint(value : UInt64) : Bytes
  output = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(output.size) { |index| output[index] }
end

private def w240r_frame(bytes : Bytes) : Bytes
  w240r_concat([w240r_var_uint(bytes.size.to_u64), bytes] of Bytes)
end

private def w240r_sizes(counts : Array(UInt64)) : Bytes
  output = Bytes.new(counts.size * 8)
  counts.each_with_index do |count, row|
    8.times do |byte|
      output[row * 8 + byte] = ((count >> (byte * 8)) & 0xff_u64).to_u8
    end
  end
  output
end

private def w240r_shared_row(path : String, value : CrystalClick::BinaryValue) : CrystalClick::ObjectSharedMapRow
  CrystalClick::ObjectSharedMapRow.new([
    CrystalClick::ObjectSharedMapEntry.new(path.to_slice, value),
  ] of CrystalClick::ObjectSharedMapEntry)
end

private def w240r_copy_structure(path : String) : CrystalClick::ObjectSharedChunkStructure
  CrystalClick::ObjectSharedChunkStructure.new(
    1_u64,
    [path] of String,
    {0_u64, 0_u64},
    {0_u64, 0_u64},
    {0_u64, 0_u64},
  )
end

private def w240r_document_plan(
  shared_data_version : UInt64 = 0_u64,
  bucket_count : UInt64 = 1_u64,
) : CrystalClick::ObjectDocumentPlan
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    shared_data_version: shared_data_version,
    bucket_count: bucket_count,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {} of String => CrystalClick::BinaryDataType,
  )
end

private def w240r_document_granules(value : CrystalClick::BinaryValue) : Array(Array(CrystalClick::ObjectDocument))
  document = CrystalClick::ObjectDocument.new({"x" => value} of String => CrystalClick::BinaryValue)
  [[document] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument)
end

private def w240r_manual_object_document_streams(value : CrystalClick::BinaryValue) : CrystalClick::ObjectDocumentStreams
  structure_set = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structure_set)

  string = CrystalClick::BinaryDataType.primitive("String")
  tuple = CrystalClick::BinaryDataType.tuple(
    [string, string] of CrystalClick::BinaryDataType,
    ["paths", "values"] of String,
  )
  array = CrystalClick::BinaryDataType.array(tuple)
  envelope = CrystalClick::BinaryValueCodec.encode(value)
  entry = CrystalClick::BinaryValue.tuple(tuple, [
    CrystalClick::BinaryValue.string("x"),
    CrystalClick::BinaryValue.string(String.new(envelope)),
  ] of CrystalClick::BinaryValue)
  row = CrystalClick::BinaryValue.array(array, [entry] of CrystalClick::BinaryValue)
  shared = CrystalClick::BinaryBulkCodec.encode(
    array,
    [[row] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
  )
  CrystalClick::ObjectDocumentStreams.new(
    metadata,
    [1_u64] of UInt64,
    {} of String => CrystalClick::BinaryBulkStreams,
    {} of String => CrystalClick::DynamicValueStreams,
    shared,
  )
end

private def w240r_json_child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  empty_structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(empty_structures, type.json_type.not_nil!.typed_paths)
end

describe "W240 compositional Object shared JSON RED" do
  it "retains the existing scalar JSON and Array(JSON) leaf envelopes" do
    json = w240r_json_type
    direct = w240r_json_value(json, 41_u8)
    array_type = CrystalClick::BinaryDataType.array(json)
    array_value = CrystalClick::BinaryValue.array(array_type, [direct] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    empty_json = w240r_empty_json_value

    [direct, array_value, empty_array, empty_json].each do |expected|
      wire = CrystalClick::BinaryValueCodec.encode(expected)
      decoded = CrystalClick::BinaryValueCodec.decode(wire)
      w240r_assert_value_equal!(decoded, expected)
    end

    [direct, array_value].each do |value|
      write_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_borrowed(
          value,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        )
      end
      write_error.message.to_s.should contain("JSON")
      read_error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_borrowed(
          CrystalClick::BinaryValueCodec.encode(value),
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end
      read_error.message.to_s.should contain("JSON")
    end
  end

  it "preserves an empty pathless shared row independently of JSON admission" do
    empty_row = CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)
    encoded = CrystalClick::ObjectSharedMapCodec.encode([empty_row] of CrystalClick::ObjectSharedMapRow)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(encoded.sizes, encoded.paths, encoded.values, 1)
    decoded.size.should eq(1)
    decoded[0].entry_count.should eq(0)

    documents = [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
    streams = CrystalClick::ObjectDocumentCodec.encode(w240r_document_plan, documents)
    pathless = CrystalClick::ObjectDocumentCodec.decode(
      {} of String => CrystalClick::BinaryDataType,
      streams,
    )
    pathless[0][0].path_count.should eq(0)
  end

  it "round-trips a JSON value through standalone shared MAP envelopes" do
    value = w240r_json_value(w240r_json_type, 42_u8)
    rows = [w240r_shared_row("x", value)] of CrystalClick::ObjectSharedMapRow
    encoded = CrystalClick::ObjectSharedMapCodec.encode(rows)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(encoded.sizes, encoded.paths, encoded.values, rows.size)
    decoded[0].entry_at(0).path.should eq(Bytes[0x78_u8])
    w240r_assert_value_equal!(decoded[0].entry_at(0).value, value)
  end

  it "decodes an independently framed JSON envelope from standalone shared MAP" do
    value = w240r_json_value(w240r_json_type, 46_u8)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(
      w240r_sizes([1_u64] of UInt64),
      Bytes[0x01_u8, 0x78_u8],
      w240r_frame(CrystalClick::BinaryValueCodec.encode(value)),
      1,
    )
    w240r_assert_value_equal!(decoded[0].entry_at(0).value, value)
  end

  it "round-trips a JSON value through Object MAP" do
    value = w240r_json_value(w240r_json_type, 43_u8)
    documents = w240r_document_granules(value)
    typed_schema = {} of String => CrystalClick::BinaryDataType

    map_streams = CrystalClick::ObjectDocumentCodec.encode(w240r_document_plan, documents)
    map_decoded = CrystalClick::ObjectDocumentCodec.decode(typed_schema, map_streams)
    w240r_assert_value_equal!(map_decoded[0][0].value_for("x"), value)
  end

  it "round-trips a JSON value through Object MAP_WITH_BUCKETS" do
    value = w240r_json_value(w240r_json_type, 47_u8)
    documents = w240r_document_granules(value)
    typed_schema = {} of String => CrystalClick::BinaryDataType

    bucket_streams = CrystalClick::ObjectDocumentCodec.encode(
      w240r_document_plan(1_u64, 2_u64),
      documents,
    )
    bucket_decoded = CrystalClick::ObjectDocumentCodec.decode(typed_schema, bucket_streams)
    w240r_assert_value_equal!(bucket_decoded[0][0].value_for("x"), value)
  end

  it "decodes an independently authored JSON scalar envelope from Object MAP" do
    value = w240r_json_value(w240r_json_type, 48_u8)
    streams = w240r_manual_object_document_streams(value)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      {} of String => CrystalClick::BinaryDataType,
      streams,
    )
    w240r_assert_value_equal!(decoded[0][0].value_for("x"), value)
  end

  it "round-trips a JSON value through Object shared Copy envelopes" do
    value = w240r_json_value(w240r_json_type, 44_u8)
    rows = [w240r_shared_row("x", value)] of CrystalClick::ObjectSharedMapRow
    structures = [w240r_copy_structure("x")] of CrystalClick::ObjectSharedChunkStructure
    encoded = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      structures,
    )
    w240r_assert_value_equal!(decoded[0].entry_at(0).value, value)
  end

  it "decodes an independently framed JSON envelope from Object shared Copy" do
    value = w240r_json_value(w240r_json_type, 49_u8)
    structures = [w240r_copy_structure("x")] of CrystalClick::ObjectSharedChunkStructure
    ordinary = CrystalClick::ObjectSharedCopyCodec.encode(
      [w240r_shared_row("x", CrystalClick::BinaryValue.bool(true))] of CrystalClick::ObjectSharedMapRow,
      structures,
    )
    streams = CrystalClick::ObjectSharedCopyStreams.new(
      ordinary.sizes,
      ordinary.indexes,
      w240r_frame(CrystalClick::BinaryValueCodec.encode(value)),
    )
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      streams.sizes,
      streams.indexes,
      streams.values,
      structures,
    )
    w240r_assert_value_equal!(decoded[0].entry_at(0).value, value)
  end

  it "integrates an ordinary Array(JSON) Dynamic arm into per-path Data" do
    json = w240r_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    structures = {"root" => structure} of String => CrystalClick::DynamicStructure
    array_value = CrystalClick::BinaryValue.array(
      array_json,
      [w240r_json_value(json, 45_u8)] of CrystalClick::BinaryValue,
    )
    value = CrystalClick::BinaryValue.dynamic(dynamic, array_value)
    granules = [[value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new(
        "root",
        structure.canonical_index_for(array_json),
        [0_i32] of Int32,
      ),
      w240r_json_child_plan(json),
    }
    leaf_bindings = [binding] of W240RJsonLeafPlan

    # This direct Dynamic lane demonstrates that Array(JSON) is already a
    # legal ordinary arm when its exact JSON child Object plan is bound.
    bulk = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      structures,
      granules,
      json_object_leaf_plans: leaf_bindings,
    )
    bulk.json_object_count.should eq(1)
    decoded_bulk = CrystalClick::BinaryDynamicBulkCodec.decode(
      dynamic,
      bulk,
      [1_u64] of UInt64,
      json_object_leaf_plans: leaf_bindings,
    )
    w240r_assert_value_equal!(decoded_bulk[0][0], value)

    # The legacy unbound entry point stays guarded. The named paired path
    # supplies exact child ownership on write and discovers it from the inline
    # prefix on read; it is not a relaxation of the borrowed default.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, [value] of CrystalClick::BinaryValue)
    end
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    path = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      dynamic,
      structures,
      [value] of CrystalClick::BinaryValue,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedPathCodec.decode(path.data, path.events, 1, dynamic)
    end
    decoded_path = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      path.data,
      path.events,
      1,
      dynamic,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    w240r_assert_value_equal!(decoded_path.rows[0], value)
  end
end
