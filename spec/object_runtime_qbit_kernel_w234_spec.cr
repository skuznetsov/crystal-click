require "./spec_helper"

private def w234k_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 3_u64)
end

private def w234k_qbit_data_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.qbit(w234k_qbit_type)
end

private def w234k_qbit_value : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(
    CrystalClick::QBitValue.new(w234k_qbit_type, Bytes[0x11_u8, 0x22, 0x33]),
  )
end

private def w234k_copy_structure(paths : Array(String)) : CrystalClick::ObjectSharedChunkStructure
  CrystalClick::ObjectSharedChunkStructure.new(
    1_u64,
    paths,
    {0_u64, 0_u64},
    {0_u64, 0_u64},
    {0_u64, 0_u64},
  )
end

private def w234k_copy_row(path : String, value : CrystalClick::BinaryValue) : CrystalClick::ObjectSharedMapRow
  CrystalClick::ObjectSharedMapRow.new([
    CrystalClick::ObjectSharedMapEntry.new(path.to_slice, value),
  ] of CrystalClick::ObjectSharedMapEntry)
end

private def w234k_copy_descriptor_frame(type : CrystalClick::BinaryDataType) : Bytes
  descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
  Bytes.new(descriptor.size + 1) do |index|
    index == 0 ? descriptor.size.to_u8 : descriptor[index - 1]
  end
end

describe "W234 Object runtime QBit kernel" do
  it "admits source-valid non-Variant static QBit actuals with exact descriptor depth" do
    qbit = w234k_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_qbit = CrystalClick::BinaryDataType.array(qbit)
    tuple_qbit = CrystalClick::BinaryDataType.tuple([qbit, uint8] of CrystalClick::BinaryDataType)
    map_qbit = CrystalClick::BinaryDataType.map(string, qbit)
    nested_qbit = CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["q"] of String)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType),
    )
    array_nullable_tuple = CrystalClick::BinaryDataType.array(nullable_tuple)
    actual_types = [qbit, array_qbit, tuple_qbit, map_qbit, nested_qbit, array_nullable_tuple] of CrystalClick::BinaryDataType

    qbit.name.should eq("QBit(Int8, 3)")
    qbit.qbit_type.should eq(w234k_qbit_type)
    w234k_qbit_type.raw_row_bytes.should eq(3)
    actual_types.map(&.name).should eq([
      "QBit(Int8, 3)",
      "Array(QBit(Int8, 3))",
      "Tuple(QBit(Int8, 3), UInt8)",
      "Map(String, QBit(Int8, 3))",
      "Nested(q QBit(Int8, 3))",
      "Array(Nullable(Tuple(QBit(Int8, 3))))",
    ])

    # QBit's carrier descriptor is budgeted below the type itself. With the
    # actual rooted at depth 3, Array -> QBit -> UInt8 needs exactly depth 5.
    exact_depth = CrystalClick::BinaryCodecLimits.new(5, 64, 64, 4096)
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(array_qbit, exact_depth)
    one_level_short = CrystalClick::BinaryCodecLimits.new(4, 64, 64, 4096)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(array_qbit, one_level_short)
    end

    actual_types.each do |type|
      CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
        type,
        CrystalClick::BinaryCodecLimits.default,
      )
    end

    # A wide named Tuple is part of the Object owner grammar. Keep QBit away
    # from the first field so admission must validate the full name/child
    # roster without repeatedly rescanning it for every child.
    wide_children = Array(CrystalClick::BinaryDataType).new(24, uint8)
    wide_children[12] = qbit
    wide_names = Array(String).new(24) { |index| "field_#{index}" }
    named_wide_tuple = CrystalClick::BinaryDataType.tuple(wide_children, wide_names)
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
      named_wide_tuple,
      CrystalClick::BinaryCodecLimits.default,
    )

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: actual_types.size)
    schema = CrystalClick::ObjectDocumentSchema.new({"value" => dynamic})
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      {"value" => CrystalClick::DynamicStructure.new(actual_types)},
    )
    plan.typed_dynamic_for("value").types.map(&.name).should eq(actual_types.map(&.name))
  end

  it "retains root laws and excludes mixed runtime-owned or aggregate siblings" do
    qbit = w234k_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    variant = CrystalClick::BinaryDataType.variant([qbit, uint8] of CrystalClick::BinaryDataType)
    nullable = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType),
    )
    embedded_variant = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.variant([qbit, uint8] of CrystalClick::BinaryDataType),
    )
    mixed_dynamic = CrystalClick::BinaryDataType.tuple([qbit, dynamic] of CrystalClick::BinaryDataType)
    non_string_map_key = CrystalClick::BinaryDataType.map(uint8, qbit)
    low = CrystalClick::BinaryDataType.low_cardinality(uint8)
    mixed_low = CrystalClick::BinaryDataType.tuple([qbit, low] of CrystalClick::BinaryDataType)
    json = CrystalClick::BinaryDataType.json
    mixed_json = CrystalClick::BinaryDataType.tuple([qbit, json] of CrystalClick::BinaryDataType)
    aggregate = CrystalClick::BinaryDataType.aggregate_function("sum", uint64)
    mixed_aggregate = CrystalClick::BinaryDataType.tuple([qbit, aggregate] of CrystalClick::BinaryDataType)
    simple_aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      uint64,
    )
    mixed_simple_aggregate = CrystalClick::BinaryDataType.tuple(
      [qbit, simple_aggregate] of CrystalClick::BinaryDataType,
    )

    rejected = [variant, nullable, embedded_variant, dynamic, mixed_dynamic, non_string_map_key, mixed_low, mixed_json, mixed_aggregate, mixed_simple_aggregate] of CrystalClick::BinaryDataType
    rejected.each do |type|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
          type,
          CrystalClick::BinaryCodecLimits.default,
        )
      end
    end
  end

  it "keeps direct QBit Copy as a positive control and opts only Copy's recursive children in" do
    qbit = w234k_qbit_data_type
    qbit_value = w234k_qbit_value
    direct_path = "direct"
    direct_structure = w234k_copy_structure([direct_path] of String)
    direct_row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new(direct_path.to_slice, qbit_value),
    ] of CrystalClick::ObjectSharedMapEntry)
    direct_streams = CrystalClick::ObjectSharedCopyCodec.encode(
      [direct_row] of CrystalClick::ObjectSharedMapRow,
      [direct_structure] of CrystalClick::ObjectSharedChunkStructure,
    )
    direct_decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      direct_streams.sizes,
      direct_streams.indexes,
      direct_streams.values,
      [direct_structure] of CrystalClick::ObjectSharedChunkStructure,
    )
    direct_decoded[0].entry_at(0).value.type.should eq(qbit)
    direct_decoded[0].entry_at(0).value.qbit_value.raw_bytes.should eq(Bytes[0x11_u8, 0x22, 0x33])

    array_type = CrystalClick::BinaryDataType.array(qbit)
    tuple_type = CrystalClick::BinaryDataType.tuple([
      qbit,
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    map_type = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), qbit)
    nested_type = CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["q"] of String)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    array_value = CrystalClick::BinaryValue.array(array_type, [qbit_value] of CrystalClick::BinaryValue)
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [qbit_value, CrystalClick::BinaryValue.fixed(tuple_type.child_at(1), Bytes[0x07_u8])] of CrystalClick::BinaryValue,
    )
    map_value = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.string("k"), qbit_value] of CrystalClick::BinaryValue,
    )
    nested_row = CrystalClick::BinaryValue.tuple(
      CrystalClick::BinaryNestedType.tuple_for(nested_type),
      [qbit_value] of CrystalClick::BinaryValue,
    )
    nested_value = CrystalClick::BinaryValue.nested(nested_type, [nested_row] of CrystalClick::BinaryValue)

    paths = ["a_array", "b_empty", "c_map", "d_nested", "e_tuple"] of String
    values = [array_value, empty_array, map_value, nested_value, tuple_value] of CrystalClick::BinaryValue
    entries = Array(CrystalClick::ObjectSharedMapEntry).new(paths.size)
    paths.each_with_index do |path, index|
      entries << CrystalClick::ObjectSharedMapEntry.new(path.to_slice, values[index])
    end
    row = CrystalClick::ObjectSharedMapRow.new(entries)
    structure = w234k_copy_structure(paths)

    # The helper default remains closed (including for the Copy caller's
    # borrowed sibling policy); only ObjectSharedCopyCodec's qualified owner
    # is expected to pass the recursive-QBit profile.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        array_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        array_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        Bytes[0x1e_u8, 0x36, 0x07, 0x03, 0x01, 0x03, 0x11, 0x22, 0x33],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        1,
      )
    end

    encoded = CrystalClick::ObjectSharedCopyCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      [structure] of CrystalClick::ObjectSharedChunkStructure,
    )
    wire_bytes = (encoded.sizes.size + encoded.indexes.size + encoded.values.size).to_i
    exact_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, wire_bytes)
    exact_encoded = CrystalClick::ObjectSharedCopyCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      [structure] of CrystalClick::ObjectSharedChunkStructure,
      exact_limits,
    )
    exact_encoded.sizes.should eq(encoded.sizes)
    exact_encoded.indexes.should eq(encoded.indexes)
    exact_encoded.values.should eq(encoded.values)

    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      [structure] of CrystalClick::ObjectSharedChunkStructure,
      exact_limits,
    )
    decoded[0].entry_count.should eq(values.size)
    decoded[0].entry_count.times do |index|
      actual = decoded[0].entry_at(index).value
      actual.type.should eq(values[index].type)
      CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(values[index]))
    end

    short_limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, wire_bytes - 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedCopyCodec.encode(
        [row] of CrystalClick::ObjectSharedMapRow,
        [structure] of CrystalClick::ObjectSharedChunkStructure,
        short_limits,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedCopyCodec.decode(
        encoded.sizes,
        encoded.indexes,
        encoded.values,
        [structure] of CrystalClick::ObjectSharedChunkStructure,
        short_limits,
      )
    end
  end

  it "keeps Copy's non-Variant QBit profile closed to wrapped Variant and runtime-owned siblings" do
    qbit = w234k_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    qbit_value = w234k_qbit_value

    variant = CrystalClick::BinaryDataType.variant([qbit, uint8] of CrystalClick::BinaryDataType)
    qbit_arm = variant.children.index(qbit).not_nil!
    selected_qbit = CrystalClick::BinaryValue.variant(variant, qbit_arm, qbit_value)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    array_variant_value = CrystalClick::BinaryValue.array(
      array_variant,
      [selected_qbit] of CrystalClick::BinaryValue,
    )

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    mixed_dynamic = CrystalClick::BinaryDataType.tuple([qbit, dynamic] of CrystalClick::BinaryDataType)
    mixed_dynamic_value = CrystalClick::BinaryValue.tuple(
      mixed_dynamic,
      [qbit_value, CrystalClick::BinaryValue.dynamic(dynamic)] of CrystalClick::BinaryValue,
    )

    low = CrystalClick::BinaryDataType.low_cardinality(uint8)
    mixed_low = CrystalClick::BinaryDataType.tuple([qbit, low] of CrystalClick::BinaryDataType)
    mixed_low_value = CrystalClick::BinaryValue.tuple(
      mixed_low,
      [
        qbit_value,
        CrystalClick::BinaryValue.low_cardinality(
          low,
          CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
        ),
      ] of CrystalClick::BinaryValue,
    )

    # The opt-in recursive admission walk must be behind the normal bounded
    # descriptor preflight, using this same write budget rather than creating
    # a private allowance. The invalid runtime-owned sibling ensures each
    # limit is observed before semantic admission can reject the product.
    depth_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(1, 4096, 4096, 4096),
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "depth limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        mixed_low_value,
        depth_budget,
        1,
        allow_recursive_qbit: true,
        allow_qbit_variants: false,
      )
    end
    depth_budget.node_count.should eq(1_i64)

    node_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(64, 1, 4096, 4096),
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        mixed_low_value,
        node_budget,
        1,
        allow_recursive_qbit: true,
        allow_qbit_variants: false,
      )
    end
    node_budget.node_count.should eq(1_i64)
    node_budget.element_count.should eq(2_i64)

    edge_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(64, 4096, 1, 4096),
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "element limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        mixed_low_value,
        edge_budget,
        1,
        allow_recursive_qbit: true,
        allow_qbit_variants: false,
      )
    end
    edge_budget.node_count.should eq(1_i64)
    edge_budget.element_count.should eq(0_i64)

    json = CrystalClick::BinaryDataType.json
    mixed_json = CrystalClick::BinaryDataType.tuple([qbit, json] of CrystalClick::BinaryDataType)
    mixed_json_value = CrystalClick::BinaryValue.tuple(
      mixed_json,
      [
        qbit_value,
        CrystalClick::BinaryValue.json(
          json,
          CrystalClick::BinaryJsonRow.new(json, [] of Tuple(String, CrystalClick::BinaryValue)),
        ),
      ] of CrystalClick::BinaryValue,
    )

    aggregate = CrystalClick::BinaryDataType.aggregate_function("sum", uint64)
    mixed_aggregate = CrystalClick::BinaryDataType.tuple(
      [qbit, aggregate] of CrystalClick::BinaryDataType,
    )
    mixed_aggregate_value = CrystalClick::BinaryValue.tuple(
      mixed_aggregate,
      [
        qbit_value,
        CrystalClick::BinaryValue.aggregate_function_state(
          aggregate,
          Bytes[0x07_u8, 0, 0, 0, 0, 0, 0, 0],
        ),
      ] of CrystalClick::BinaryValue,
    )

    simple_aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      uint64,
    )
    mixed_simple_aggregate = CrystalClick::BinaryDataType.tuple(
      [qbit, simple_aggregate] of CrystalClick::BinaryDataType,
    )
    mixed_simple_aggregate_value = CrystalClick::BinaryValue.tuple(
      mixed_simple_aggregate,
      [
        qbit_value,
        CrystalClick::BinaryValue.simple_aggregate(
          simple_aggregate,
          CrystalClick::BinaryValue.fixed(uint64, Bytes[0x07_u8, 0, 0, 0, 0, 0, 0, 0]),
        ),
      ] of CrystalClick::BinaryValue,
    )

    excluded = [
      array_variant_value,
      mixed_dynamic_value,
      mixed_low_value,
      mixed_json_value,
      mixed_aggregate_value,
      mixed_simple_aggregate_value,
    ] of CrystalClick::BinaryValue

    excluded.each_with_index do |value, index|
      path = "blocked_#{index}"
      row = w234k_copy_row(path, value)
      structure = w234k_copy_structure([path] of String)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectSharedCopyCodec.encode(
          [row] of CrystalClick::ObjectSharedMapRow,
          [structure] of CrystalClick::ObjectSharedChunkStructure,
        )
      end

      # A descriptor-only child frame is enough to exercise the decode-side
      # admission gate: if it admits the type, the following value read would
      # fail as truncation instead of producing the expected type rejection.
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectSharedCopyCodec.decode(
          Bytes[0x01_u8, 0, 0, 0, 0, 0, 0, 0],
          Bytes[0x00_u8],
          w234k_copy_descriptor_frame(value.type),
          [structure] of CrystalClick::ObjectSharedChunkStructure,
        )
      end
    end
  end

  it "retains Dynamic V3 support for wrapped Variant QBit actuals" do
    qbit = w234k_qbit_data_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    variant = CrystalClick::BinaryDataType.variant([qbit, uint8] of CrystalClick::BinaryDataType)
    qbit_arm = variant.children.index(qbit).not_nil!
    selected_qbit = CrystalClick::BinaryValue.variant(variant, qbit_arm, w234k_qbit_value)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    actual = CrystalClick::BinaryValue.array(array_variant, [selected_qbit] of CrystalClick::BinaryValue)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structures = {
      "root" => CrystalClick::DynamicStructure.new([array_variant] of CrystalClick::BinaryDataType),
    }
    wrapped = CrystalClick::BinaryValue.dynamic(dynamic, actual)
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      dynamic,
      structures,
      [[wrapped]] of Array(CrystalClick::BinaryValue),
    )
    restored = CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, streams, [1_u64])
    CrystalClick::BinaryValueCodec.encode(restored[0][0]).should eq(CrystalClick::BinaryValueCodec.encode(wrapped))
  end

  it "encodes one recursive-QBit Copy child to an independent exact lane literal" do
    qbit = w234k_qbit_data_type
    array_type = CrystalClick::BinaryDataType.array(qbit)
    array_value = CrystalClick::BinaryValue.array(array_type, [w234k_qbit_value] of CrystalClick::BinaryValue)
    path = "array"
    row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new(path.to_slice, array_value),
    ] of CrystalClick::ObjectSharedMapEntry)
    structure = w234k_copy_structure([path] of String)

    encoded = CrystalClick::ObjectSharedCopyCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      [structure] of CrystalClick::ObjectSharedChunkStructure,
    )
    encoded.sizes.should eq(Bytes[0x01_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.indexes.should eq(Bytes[0x00_u8])
    encoded.values.should eq(Bytes[
      0x09_u8, 0x1e, 0x36, 0x07, 0x03, 0x01, 0x03, 0x11, 0x22, 0x33,
    ])
  end

  it "decodes an independently authored recursive-QBit Copy child literal" do
    path = "array"
    structure = w234k_copy_structure([path] of String)
    # One value frame containing Array(QBit(Int8, 3)), one populated element.
    # Descriptor, count, QBit dimension and payload are literal bytes, not
    # generated by ObjectSharedCopyCodec or its value-envelope writer.
    sizes = Bytes[0x01_u8, 0, 0, 0, 0, 0, 0, 0]
    indexes = Bytes[0x00_u8]
    values = Bytes[0x09_u8, 0x1e, 0x36, 0x07, 0x03, 0x01, 0x03, 0x11, 0x22, 0x33]

    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      sizes,
      indexes,
      values,
      [structure] of CrystalClick::ObjectSharedChunkStructure,
    )
    decoded.size.should eq(1)
    decoded[0].entry_count.should eq(1)
    decoded[0].entry_at(0).path.should eq(path.to_slice)
    decoded[0].entry_at(0).value.type.name.should eq("Array(QBit(Int8, 3))")
    decoded[0].entry_at(0).value.element_at(0).qbit_value.raw_bytes.should eq(Bytes[0x11_u8, 0x22, 0x33])
  end
end
