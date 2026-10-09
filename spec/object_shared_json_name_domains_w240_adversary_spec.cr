require "./spec_helper"

describe "W240 nested shared JSON callback naming domains" do
  it "does not infer LowCardinality ownership from a String field named dict" do
    source = CrystalClick::BinaryBulkStream.new(Bytes[1_u8, 120_u8], [0_u64, 2_u64])
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    grid = CrystalClick::StorageOccurrenceGrid.new([1_u64], [1_u64], budget)
    lane = CrystalClick::ObjectDocumentColumnLane.new(
      ".child.dict",
      source.borrowed_slice(0, source.byte_size),
      nil,
      source,
    )

    callbacks = lane.inline_fragments_for_child_site(grid, budget)
    callbacks.map(&.[0]).should eq([".child.dict"])
    callbacks[0][1].should eq(Bytes[1_u8, 120_u8])
  end

  it "keeps raw Variant type names inside the child without unescaping Tuple separators" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_uint8 = CrystalClick::BinaryDataType.array(uint8)
    variant = CrystalClick::BinaryDataType.variant([array_uint8, string])
    tuple = CrystalClick::BinaryDataType.tuple([string], ["a"])
    dictionary = CrystalClick::BinaryDataType.low_cardinality(string)
    json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"typed" => variant, "tupled" => tuple, "lc" => dictionary},
    )
    array_json = CrystalClick::BinaryDataType.array(json)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    parent_structure = CrystalClick::DynamicStructure.new([array_json])
    structures = {"root" => parent_structure}
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["runtime"]),
        {"runtime" => CrystalClick::DynamicStructure.new([array_uint8])},
      ),
      json.json_type.not_nil!.typed_paths,
    )
    array_value = CrystalClick::BinaryValue.array(array_uint8, [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[7]),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[9]),
    ])
    row = CrystalClick::BinaryJsonRow.new(json, [
      {"lc", CrystalClick::BinaryValue.low_cardinality(dictionary, CrystalClick::BinaryValue.string("dictionary-value"))},
      {"typed", CrystalClick::BinaryValue.variant(variant, 0, array_value)},
      {"tupled", CrystalClick::BinaryValue.tuple(tuple, [CrystalClick::BinaryValue.string("kept")])},
      {"runtime", array_value},
    ])
    values = [CrystalClick::BinaryValue.dynamic(dynamic,
      CrystalClick::BinaryValue.array(array_json, [CrystalClick::BinaryValue.json(json, row)]))]
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", parent_structure.canonical_index_for(array_json), [0_i32],
    )
    profile = CrystalClick::BinaryBulkProfile.single_stream
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      dynamic, structures, values,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      [{key, child_plan}],
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 2_i32, profile),
      profile,
    )

    # SharedData.cpp:397 disables only VariantElement escaping. It does not
    # disable ISerialization.cpp:340-350's escaped Tuple separator. These
    # literals distinguish the two domains even if a paired codec agrees.
    # The outer shared-path callback uses an empty storage column name;
    # `root` belongs to internal plan coordinates, not to its wire names.
    callback_prefix = ".#{array_json.name}"
    names = encoded.events.map(&.name)
    names.should contain("#{callback_prefix}.typed.Array(UInt8).size1")
    names.should contain("#{callback_prefix}.runtime.Array(UInt8).size1")
    names.should contain("#{callback_prefix}.tupled%2Ea")
    names.should contain("#{callback_prefix}.lc.dict_prefix")
    names.should_not contain("#{callback_prefix}.typed.Array%28UInt8%29.size1")
    names.should_not contain("#{callback_prefix}.tupled.a")

    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data, encoded.events, values.size, dynamic,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    decoded.rows.size.should eq(1)
    decoded_row = decoded.rows[0].child_at(0).child_at(0).json_row
    typed = decoded_row.value_for("typed").not_nil!
    typed.variant_index?.should eq(0)
    typed.child_at(0).element_count.should eq(2)
    decoded_row.value_for("lc").not_nil!.child_at(0).as_string.should eq("dictionary-value")
    decoded_row.value_for("runtime").not_nil!.element_count.should eq(2)
    decoded_row.value_for("tupled").not_nil!.child_at(0).as_string.should eq("kept")
  end
end
