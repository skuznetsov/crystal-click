require "./spec_helper"
require "../scripts/support/json_recursive_scalar_w181_cases"

private def w181_recursive_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w181_recursive_json_value(
  type : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"item", value}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w181_recursive_typed_schema_rejects(type : CrystalClick::BinaryDataType) : Nil
  expect_raises(ArgumentError) do
    CrystalClick::BinaryDataType.json(
      typed_paths: {"item" => type} of String => CrystalClick::BinaryDataType,
    )
  end
end

describe "W181 recursive scalar JSON RowBinary guards" do
  it "round-trips the finite native-confirmed roster without equating value objects" do
    profiles = W181JSONRecursiveScalarCases.build_profiles
    profiles.map(&.id).should eq(%w[
      lc_string variant_uint8 variant_null dynamic_array_nullable nested saf_sum
      array_lc_nullable map_string map_lc_string runtime_lc_string runtime_nested
      runtime_saf_sum runtime_interval runtime_bfloat16 runtime_numeric_map
    ])

    profiles.each do |profile|
      descriptor = CrystalClick::BinaryDataTypeCodec.encode(profile.type)
      row = CrystalClick::BinaryValueCodec.encode_value(profile.value)
      W181JSONRecursiveScalarCases.verify_profile_codecs!(profile, descriptor, row)
    end
    profiles.select(&.typed_path).size.should eq(9)
    profiles.reject(&.typed_path).size.should eq(6)
  end

  it "keeps the static JSON schema refusal roster narrow and rejects Nullable(Nothing)" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 2_u64))

    w181_recursive_typed_schema_rejects(qbit)
    w181_recursive_typed_schema_rejects(CrystalClick::BinaryDataType.nullable(qbit))
    w181_recursive_typed_schema_rejects(CrystalClick::BinaryDataType.aggregate_count(uint8))
    w181_recursive_typed_schema_rejects(CrystalClick::BinaryDataType.map(uint8, uint8))
    w181_recursive_typed_schema_rejects(
      CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Second),
    )
    w181_recursive_typed_schema_rejects(CrystalClick::BinaryDataType.primitive("BFloat16"))

    nullable_nothing = CrystalClick::BinaryDataType.nullable(nothing)
    w181_recursive_typed_schema_rejects(nullable_nothing)

    # These superficially similar schemas remain admitted. The native-confirmed
    # fixture verifier checks both maps, including nominal LC(String) keys.
    maps = W181JSONRecursiveScalarCases.build_profiles.select do |profile|
      profile.id == "map_string" || profile.id == "map_lc_string"
    end
    maps.map(&.child_type_name).should eq(["Map(String, UInt8)", "Map(LowCardinality(String), UInt8)"])
  end

  it "refuses runtime top Variant, Dynamic, and LowCardinality(Nullable) while keeping their typed uses separate" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json_type = CrystalClick::BinaryDataType.json

    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    variant_value = CrystalClick::BinaryValue.variant(
      variant,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    )
    dynamic = CrystalClick::BinaryDataType.dynamic
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]))
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_nullable_string = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    low_nullable_value = CrystalClick::BinaryValue.low_cardinality(
      low_nullable_string,
      CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("a")),
    )

    runtime_cases = [
      {"variant", variant_value, "2a021501012a"},
      {"dynamic", dynamic_value, "2b20012a"},
      {"lc_nullable", low_nullable_value, "262315000161"},
    ] of Tuple(String, CrystalClick::BinaryValue, String)
    runtime_cases.each do |name, value, child_wire_hex|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryJsonRow.new(
          json_type,
          [{"item", value}] of Tuple(String, CrystalClick::BinaryValue),
        )
      end
      row_wire = W181JSONRecursiveScalarCases.concat_bytes([
        W181JSONRecursiveScalarCases.path_prefix,
        W181JSONRecursiveScalarCases.bytes_from_hex(child_wire_hex),
      ] of Bytes)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
      end
      name.should_not be_empty
    end

    # Typed Variant and Dynamic plus Array(LC(Nullable(String))) remain in the
    # separate admitted roster, so this is a path-boundary guard, not a ban on
    # those nominal codecs.
    profiles = W181JSONRecursiveScalarCases.build_profiles
    %w[variant_uint8 variant_null dynamic_array_nullable array_lc_nullable].each do |id|
      profile = profiles.find! { |candidate| candidate.id == id }
      decoded = CrystalClick::BinaryValueCodec.decode_value(profile.type, profile.row)
      W181JSONRecursiveScalarCases.verify_value!(profile, decoded)
    end
  end

  it "rejects Variant, Dynamic, and LC(Nullable) selected as a nested Dynamic actual type" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic
    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    variant_value = CrystalClick::BinaryValue.variant(
      variant,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    )
    nested_dynamic_value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    )
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_nullable_string = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    low_nullable_value = CrystalClick::BinaryValue.low_cardinality(
      low_nullable_string,
      CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("a")),
    )

    selected_values = [variant_value, nested_dynamic_value, low_nullable_value] of CrystalClick::BinaryValue
    selected_values.each do |selected|
      json_type = CrystalClick::BinaryDataType.json(
        typed_paths: {"item" => dynamic} of String => CrystalClick::BinaryDataType,
      )
      value = CrystalClick::BinaryValue.dynamic(dynamic, selected)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryJsonRow.new(
          json_type,
          [{"item", value}] of Tuple(String, CrystalClick::BinaryValue),
        )
      end
    end
  end

  it "preserves nested runtime Nullable(Nothing) NULL values but refuses the static schema" do
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    nullable_nothing = CrystalClick::BinaryDataType.nullable(nothing)
    array = CrystalClick::BinaryDataType.array(nullable_nothing)
    json_type = CrystalClick::BinaryDataType.json
    value = w181_recursive_json_value(
      json_type,
      CrystalClick::BinaryValue.array(array, [
        CrystalClick::BinaryValue.null(nullable_nothing),
      ] of CrystalClick::BinaryValue),
    )
    descriptor_wire = Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00]
    row_wire = Bytes[
      0x01_u8, 0x04, 0x69, 0x74, 0x65, 0x6d,
      0x1e, 0x23, 0x00, # runtime Array(Nullable(Nothing)) descriptor
      0x01, 0x01,       # one NULL element
    ]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    array_value = decoded.json_row.value_at(0)
    array_value.type.name.should eq("Array(Nullable(Nothing))")
    array_value.element_count.should eq(1)
    array_value.element_at(0).type.name.should eq("Nullable(Nothing)")
    array_value.element_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(
        typed_paths: {"item" => nullable_nothing} of String => CrystalClick::BinaryDataType,
      )
    end
  end

  it "charges typed wrappers, selected Dynamic actuals, and sibling metadata to one budget" do
    profiles = W181JSONRecursiveScalarCases.build_profiles
    lc_profile = profiles.find! { |profile| profile.id == "lc_string" }
    lc_descriptor = lc_profile.descriptor
    lc_row = lc_profile.row

    # One JSON root, its path metadata, and LC(String)'s two type/value nodes
    # are charged on both descriptor and row visits. Exact limits pass; one
    # short in depth, nodes, elements, or bytes fails closed.
    CrystalClick::BinaryDataTypeCodec.encode(
      lc_profile.type,
      w181_recursive_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: lc_descriptor.size),
    ).should eq(lc_descriptor)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        lc_profile.type,
        w181_recursive_limits(max_depth: 2, max_nodes: 4, max_elements: 3, max_bytes: lc_descriptor.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        lc_profile.type,
        w181_recursive_limits(max_depth: 3, max_nodes: 3, max_elements: 3, max_bytes: lc_descriptor.size),
      )
    end
    CrystalClick::BinaryValueCodec.encode_value(
      lc_profile.value,
      w181_recursive_limits(max_depth: 3, max_nodes: 8, max_elements: 6, max_bytes: lc_row.size),
    ).should eq(lc_row)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        lc_profile.value,
        w181_recursive_limits(max_depth: 3, max_nodes: 7, max_elements: 6, max_bytes: lc_row.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        lc_profile.value,
        w181_recursive_limits(max_depth: 3, max_nodes: 8, max_elements: 5, max_bytes: lc_row.size),
      )
    end

    dynamic_profile = profiles.find! { |profile| profile.id == "dynamic_array_nullable" }
    dynamic_limits = w181_recursive_limits(max_depth: 5, max_nodes: 15, max_elements: 13,
      max_bytes: dynamic_profile.row.size)
    CrystalClick::BinaryValueCodec.encode_value(dynamic_profile.value, dynamic_limits).should eq(dynamic_profile.row)
    CrystalClick::BinaryValueCodec.decode_value(dynamic_profile.type, dynamic_profile.row, dynamic_limits)
      .json_row.value_at(0).child_at(0).element_count.should eq(3)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        dynamic_profile.value,
        w181_recursive_limits(max_depth: 4, max_nodes: 15, max_elements: 13,
          max_bytes: dynamic_profile.row.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        dynamic_profile.value,
        w181_recursive_limits(max_depth: 5, max_nodes: 14, max_elements: 13,
          max_bytes: dynamic_profile.row.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        dynamic_profile.value,
        w181_recursive_limits(max_depth: 5, max_nodes: 15, max_elements: 12,
          max_bytes: dynamic_profile.row.size),
      )
    end

    # Public row construction must account for the same wrapper and Dynamic
    # actual-descriptor visits before retaining path records, independently of
    # a subsequent encode. A skipped descriptor traversal falsifies this guard.
    lc_entries = [{"item", lc_profile.value.json_row.value_at(0)}] of Tuple(String, CrystalClick::BinaryValue)
    CrystalClick::BinaryJsonRow.new(lc_profile.type, lc_entries,
      w181_recursive_limits(max_depth: 3, max_nodes: 8, max_elements: 6)).path_count.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(lc_profile.type, lc_entries,
        w181_recursive_limits(max_depth: 3, max_nodes: 7, max_elements: 6))
    end

    dynamic_entries = [{"item", dynamic_profile.value.json_row.value_at(0)}] of Tuple(String, CrystalClick::BinaryValue)
    CrystalClick::BinaryJsonRow.new(dynamic_profile.type, dynamic_entries, dynamic_limits).path_count.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(dynamic_profile.type, dynamic_entries,
        w181_recursive_limits(max_depth: 5, max_nodes: 14, max_elements: 13))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(dynamic_profile.type, dynamic_entries,
        w181_recursive_limits(max_depth: 4, max_nodes: 15, max_elements: 13))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(dynamic_profile.type, dynamic_entries,
        w181_recursive_limits(max_depth: 5, max_nodes: 15, max_elements: 12))
    end

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable = CrystalClick::BinaryDataType.nullable(uint8)
    sibling_type = CrystalClick::BinaryDataType.json(typed_paths: {
      "left"  => CrystalClick::BinaryDataType.array(nullable),
      "right" => CrystalClick::BinaryDataType.array(nullable),
    } of String => CrystalClick::BinaryDataType)
    sibling_descriptor = CrystalClick::BinaryDataTypeCodec.encode(sibling_type)
    CrystalClick::BinaryDataTypeCodec.encode(
      sibling_type,
      w181_recursive_limits(max_depth: 4, max_nodes: 9, max_elements: 8, max_bytes: sibling_descriptor.size),
    ).should eq(sibling_descriptor)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        sibling_type,
        w181_recursive_limits(max_depth: 4, max_nodes: 8, max_elements: 8, max_bytes: sibling_descriptor.size),
      )
    end

    empty_array = CrystalClick::BinaryValue.array(CrystalClick::BinaryDataType.array(nullable),
      [] of CrystalClick::BinaryValue)
    sibling_entries = [{"left", empty_array}, {"right", empty_array}] of Tuple(String, CrystalClick::BinaryValue)
    CrystalClick::BinaryJsonRow.new(sibling_type, sibling_entries,
      w181_recursive_limits(max_depth: 4, max_nodes: 14, max_elements: 12)).path_count.should eq(2)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(sibling_type, sibling_entries,
        w181_recursive_limits(max_depth: 4, max_nodes: 13, max_elements: 12))
    end
  end

  it "bounds deep and shared Dynamic-selected value graphs before retaining row records" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic
    json_type = CrystalClick::BinaryDataType.json(typed_paths: {"item" => dynamic} of String => CrystalClick::BinaryDataType)
    deep_type = uint8
    deep_value = CrystalClick::BinaryValue.fixed(uint8, Bytes[0x01_u8])
    30.times do
      deep_type = CrystalClick::BinaryDataType.array(deep_type)
      deep_value = CrystalClick::BinaryValue.array(deep_type, [deep_value] of CrystalClick::BinaryValue)
    end
    entries = [{"item", CrystalClick::BinaryValue.dynamic(dynamic, deep_value)}] of Tuple(String, CrystalClick::BinaryValue)
    # JSON type/row each contribute three nodes; the inline actual descriptor
    # and value each contribute 31 nodes, at a maximum rebased depth of 33.
    CrystalClick::BinaryJsonRow.new(json_type, entries,
      w181_recursive_limits(max_depth: 33, max_nodes: 68, max_elements: 66)).path_count.should eq(1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(json_type, entries,
        w181_recursive_limits(max_depth: 32, max_nodes: 68, max_elements: 66))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(json_type, entries,
        w181_recursive_limits(max_depth: 33, max_nodes: 67, max_elements: 66))
    end

    shared_type = uint8
    shared_value = CrystalClick::BinaryValue.fixed(uint8, Bytes[0x01_u8])
    12.times do
      shared_type = CrystalClick::BinaryDataType.array(shared_type)
      shared_value = CrystalClick::BinaryValue.array(shared_type,
        [shared_value, shared_value] of CrystalClick::BinaryValue)
    end
    # A small caller-owned DAG represents thousands of wire occurrences. Do
    # not deduplicate visits or reset the enclosing budget at a wrapper edge.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(json_type,
        [{"item", CrystalClick::BinaryValue.dynamic(dynamic, shared_value)}] of Tuple(String, CrystalClick::BinaryValue),
        w181_recursive_limits(max_depth: 64, max_nodes: 128, max_elements: 2_000))
    end
  end

  it "rejects wrong Variant discriminators, truncation, and suffix bytes" do
    profile = W181JSONRecursiveScalarCases.build_profiles.find! { |item| item.id == "variant_uint8" }
    wrong_discriminator = W181JSONRecursiveScalarCases.concat_bytes([
      W181JSONRecursiveScalarCases.path_prefix,
      Bytes[0x02_u8, 0x2a_u8],
    ] of Bytes)
    truncated_child = W181JSONRecursiveScalarCases.concat_bytes([
      W181JSONRecursiveScalarCases.path_prefix,
      Bytes[0x01_u8],
    ] of Bytes)
    trailing_suffix = W181JSONRecursiveScalarCases.concat_bytes([
      profile.row,
      Bytes[0xff_u8],
    ] of Bytes)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(profile.type, wrong_discriminator)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(profile.type, truncated_child)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(profile.type, trailing_suffix)
    end
  end

  it "keeps recursive JSON fenced from Count, physical bulk, and borrowed envelopes" do
    profile = W181JSONRecursiveScalarCases.build_profiles.find! { |item| item.id == "lc_string" }
    json_type = profile.type
    value = profile.value
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(json_type) }

    # JSON remains a nominal scalar when ordinary RowBinary products compose
    # it. The separate Object/physical profiles below stay narrower.
    array_type = CrystalClick::BinaryDataType.array(json_type)
    nullable_type = CrystalClick::BinaryDataType.nullable(json_type)
    tuple_type = CrystalClick::BinaryDataType.tuple([json_type] of CrystalClick::BinaryDataType)
    array_type.child_at(0).should eq(json_type)
    nullable_type.child_at(0).should eq(json_type)
    tuple_type.child_at(0).should eq(json_type)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple_type)
    nullable_tuple.child_at(0).should eq(tuple_type)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(array_type) }

    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic_type, value)
    dynamic_row = CrystalClick::BinaryValueCodec.encode_value(dynamic_value)
    decoded_dynamic = CrystalClick::BinaryValueCodec.decode_value(dynamic_type, dynamic_row)
    decoded_dynamic.child_at(0).type.should eq(json_type)
    decoded_dynamic.child_at(0).json_row.path_at(0).should eq("item")
    decoded_dynamic.child_at(0).json_row.value_at(0).type.name.should eq("LowCardinality(String)")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(json_type, [] of Array(CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        CrystalClick::BinaryValue.array(array_type, [value] of CrystalClick::BinaryValue),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        CrystalClick::BinaryValueCodec.encode(
          CrystalClick::BinaryValue.array(array_type, [value] of CrystalClick::BinaryValue),
        ),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end
end
