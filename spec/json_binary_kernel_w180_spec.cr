require "./spec_helper"

private def w180_json_concat(left : Bytes, right : Bytes) : Bytes
  Bytes.new(left.size + right.size) do |index|
    index < left.size ? left[index] : right[index - left.size]
  end
end

private def w180_json_spec_limits(
  max_depth : Int,
  max_nodes : Int,
  max_elements : Int,
  max_bytes : Int,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W180 nominal JSON descriptor and scalar RowBinary values" do
  it "keeps JSON v0 nominal and preserves default, zero, maximum, and sorted typed metadata" do
    default_json = CrystalClick::BinaryDataType.json
    default_json.tag.should eq(CrystalClick::BinaryDataType::TAG_JSON)
    default_json.child_count.should eq(0)
    default_json.name.should eq("JSON")

    # tag, v0, VarUInt(1024), UInt8(32), typed-path count, SKIP count,
    # SKIP REGEXP count. This vector is independent of the encoder.
    default_wire = Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00]
    CrystalClick::BinaryDataTypeCodec.encode(default_json).should eq(default_wire)
    CrystalClick::BinaryDataTypeCodec.decode(default_wire).should eq(default_json)

    zero_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    zero_wire = Bytes[0x30_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    CrystalClick::BinaryDataTypeCodec.encode(zero_json).should eq(zero_wire)
    CrystalClick::BinaryDataTypeCodec.decode(zero_wire).should eq(zero_json)

    one_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    one_wire = Bytes[0x30_u8, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00]
    CrystalClick::BinaryDataTypeCodec.encode(one_json).should eq(one_wire)
    CrystalClick::BinaryDataTypeCodec.decode(one_wire).should eq(one_json)

    maximum_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 10_000, max_dynamic_types: 254)
    maximum_wire = Bytes[0x30_u8, 0x00, 0x90, 0x4e, 0xfe, 0x00, 0x00, 0x00]
    CrystalClick::BinaryDataTypeCodec.encode(maximum_json).should eq(maximum_wire)
    CrystalClick::BinaryDataTypeCodec.decode(maximum_wire).should eq(maximum_json)
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 10_000_i64,
      max_dynamic_types: 254_i64,
    ).should eq(maximum_json)
    CrystalClick::BinaryDataType.json(max_dynamic_paths: 10_000_i64, max_dynamic_types: 254_i64)
      .should eq(maximum_json)

    caller_paths = {
      "z" => CrystalClick::BinaryDataType.primitive("UInt8"),
      "a" => CrystalClick::BinaryDataType.primitive("String"),
    } of String => CrystalClick::BinaryDataType
    sorted_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: caller_paths,
    )
    other_order = {
      "a" => CrystalClick::BinaryDataType.primitive("String"),
      "z" => CrystalClick::BinaryDataType.primitive("UInt8"),
    } of String => CrystalClick::BinaryDataType
    sorted_json.should eq(CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
      typed_paths: other_order,
    ))
    sorted_json.name.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=2, a String, z UInt8)")

    # Typed-path declarations are descriptor metadata, not generic child
    # types that recursive container/bulk walkers may silently traverse.
    sorted_json.child_count.should eq(0)
    metadata = sorted_json.json_type.not_nil!
    metadata.typed_path_count.should eq(2)
    metadata.typed_path_at(0).should eq("a")
    metadata.typed_path_at(1).should eq("z")
    metadata.typed_type_for("a").not_nil!.name.should eq("String")
    metadata.typed_type_for("z").not_nil!.name.should eq("UInt8")

    caller_paths.clear
    returned_paths = metadata.typed_paths
    returned_paths.clear
    metadata.typed_path_count.should eq(2)
    metadata.typed_path_at(0).should eq("a")
    returned_path = metadata.typed_path_at(0)
    returned_path.to_unsafe[0] = 0x78_u8
    metadata.typed_path_at(0).should eq("a")

    mutable_source_path = String.new(Bytes[0x6d_u8])
    source_paths = Hash(String, CrystalClick::BinaryDataType).new
    source_paths[mutable_source_path] = CrystalClick::BinaryDataType.primitive("UInt8")
    copied_source_type = CrystalClick::BinaryDataType.json(typed_paths: source_paths)
    mutable_source_path.to_unsafe[0] = 0x78_u8
    copied_source_type.json_type.not_nil!.typed_path_at(0).should eq("m")

    sorted_wire = Bytes[
      0x30_u8, 0x00, 0x02, 0x01, 0x02,
      0x01, 0x61, 0x15, # a String
      0x01, 0x7a, 0x01, # z UInt8
      0x00, 0x00,       # no SKIP paths or regexps
    ]
    CrystalClick::BinaryDataTypeCodec.encode(sorted_json).should eq(sorted_wire)
    CrystalClick::BinaryDataTypeCodec.decode(sorted_wire).should eq(sorted_json)
  end

  it "uses the independently authored structured RowBinary body for empty and typed UInt8 rows" do
    empty_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    empty_row = CrystalClick::BinaryJsonRow.new(
      empty_type,
      [] of Tuple(String, CrystalClick::BinaryValue),
    )
    empty_value = CrystalClick::BinaryValue.json(empty_type, empty_row)
    empty_row_wire = Bytes[0x00_u8]
    CrystalClick::BinaryValueCodec.encode_value(empty_value).should eq(empty_row_wire)
    decoded_empty = CrystalClick::BinaryValueCodec.decode_value(empty_type, empty_row_wire)
    decoded_empty.json_row.empty?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded_empty).should eq(empty_row_wire)

    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    typed_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"n" => uint8_type} of String => CrystalClick::BinaryDataType,
    )
    typed_values = Array(Tuple(String, CrystalClick::BinaryValue)).new
    typed_values << {"n", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8])}
    constructor_exact = CrystalClick::BinaryJsonRow.new(
      typed_type,
      typed_values,
      w180_json_spec_limits(2, 6, 4, 128),
    )
    constructor_exact.path_at(0).should eq("n")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(
        typed_type,
        typed_values,
        w180_json_spec_limits(1, 6, 4, 128),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(
        typed_type,
        typed_values,
        w180_json_spec_limits(2, 5, 4, 128),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(
        typed_type,
        typed_values,
        w180_json_spec_limits(2, 6, 3, 128),
      )
    end

    typed_row = CrystalClick::BinaryJsonRow.new(typed_type, typed_values)
    typed_value = CrystalClick::BinaryValue.json(typed_type, typed_row)

    # RowBinary scalar: path count, length-prefixed path, then declared value.
    # No descriptor tag is written for a declared typed path.
    typed_row_wire = Bytes[0x01_u8, 0x01, 0x6e, 0x2a]
    CrystalClick::BinaryValueCodec.encode_value(typed_value).should eq(typed_row_wire)
    decoded_typed = CrystalClick::BinaryValueCodec.decode_value(typed_type, typed_row_wire)
    decoded_typed.json_row.path_count.should eq(1)
    decoded_typed.json_row.path_at(0).should eq("n")
    decoded_typed.json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded_typed).should eq(typed_row_wire)

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x01, 0x6e, 0x01, 0x00, 0x00,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(typed_type).should eq(descriptor_wire)
    descriptor_exact = w180_json_spec_limits(2, 3, 2, descriptor_wire.size)
    CrystalClick::BinaryDataTypeCodec.encode(typed_type, descriptor_exact).should eq(descriptor_wire)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        typed_type,
        w180_json_spec_limits(1, 3, 2, descriptor_wire.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        typed_type,
        w180_json_spec_limits(2, 2, 2, descriptor_wire.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        typed_type,
        w180_json_spec_limits(2, 3, 1, descriptor_wire.size),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        typed_type,
        w180_json_spec_limits(2, 3, 2, descriptor_wire.size - 1),
      )
    end
    full_wire = w180_json_concat(descriptor_wire, typed_row_wire)
    full_wire.size.should eq(15)
    CrystalClick::BinaryValueCodec.encode(typed_value).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire).json_row.path_at(0).should eq("n")

    # One typed declaration accounts for the JSON descriptor root, its path
    # metadata record, and its child descriptor; the structured row accounts
    # for its root, path record, and scalar value. The descriptor and row each
    # consume two edges per typed path. Both independent wires must fit one
    # full-envelope operation together.
    full_exact = w180_json_spec_limits(2, 6, 4, full_wire.size)
    CrystalClick::BinaryValueCodec.encode(typed_value, full_exact).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire, full_exact).json_row.path_at(0).should eq("n")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(typed_value, w180_json_spec_limits(1, 6, 4, full_wire.size))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(typed_value, w180_json_spec_limits(2, 5, 4, full_wire.size))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(typed_value, w180_json_spec_limits(2, 6, 3, full_wire.size))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(typed_value, w180_json_spec_limits(2, 6, 4, full_wire.size - 1))
    end

    value_exact = w180_json_spec_limits(2, 6, 4, typed_row_wire.size)
    CrystalClick::BinaryValueCodec.encode_value(typed_value, value_exact).should eq(typed_row_wire)
    CrystalClick::BinaryValueCodec.decode_value(typed_type, typed_row_wire, value_exact)
      .json_row.path_at(0).should eq("n")
  end

  it "retains typed Nullable NULL and uses the literal Array(Nullable(UInt8)) row" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable_type = CrystalClick::BinaryDataType.nullable(uint8_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_type)
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"item" => array_type} of String => CrystalClick::BinaryDataType,
    )
    array_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_type),
      CrystalClick::BinaryValue.nullable(
        nullable_type,
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x00_u8]),
      ),
      CrystalClick::BinaryValue.nullable(
        nullable_type,
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0xff_u8]),
      ),
    ] of CrystalClick::BinaryValue)
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"item", array_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    # One typed path "item", array length 3, then Nullable flags and payloads.
    # In particular, the first flag is a present typed NULL, not a missing key.
    literal = Bytes[0x01_u8, 0x04, 0x69, 0x74, 0x65, 0x6d, 0x03, 0x01, 0x00, 0x00, 0x00, 0xff]
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(literal)
    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, literal)
    decoded.json_row.path_count.should eq(1)
    decoded.json_row.path_at(0).should eq("item")
    decoded_array = decoded.json_row.value_at(0)
    decoded_array.element_count.should eq(3)
    decoded_array.element_at(0).is_null?.should be_true
    decoded_array.element_at(1).is_null?.should be_false
    decoded_array.element_at(1).child_at(0).bytes.should eq(Bytes[0x00_u8])
    decoded_array.element_at(2).child_at(0).bytes.should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(literal)
  end

  it "canonicalizes runtime paths while omitting Nothing NULL, independently of storage caps" do
    json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    row = CrystalClick::BinaryJsonRow.new(json_type, [
      {"z", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8])},
      {"gone", CrystalClick::BinaryValue.null},
      {"a", CrystalClick::BinaryValue.string("x")},
    ] of Tuple(String, CrystalClick::BinaryValue))

    row.path_count.should eq(2)
    row.path_at(0).should eq("a")
    row.path_at(1).should eq("z")
    detached_entries = row.entries
    detached_entries.clear
    row.path_count.should eq(2)

    value = CrystalClick::BinaryValue.json(json_type, row)
    # The cap parameters are persisted-storage policy, not a row-size/type cap.
    # Runtime paths are sorted and carry their actual descriptor plus scalar.
    literal = Bytes[
      0x02_u8,
      0x01, 0x61, 0x15, 0x01, 0x78, # a: String("x")
      0x01, 0x7a, 0x01, 0x2a,       # z: UInt8(42)
    ]
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(literal)
    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, literal)
    decoded.json_row.path_at(0).should eq("a")
    decoded.json_row.path_at(1).should eq("z")
    decoded.json_row.value_at(0).as_string.should eq("x")
    decoded.json_row.value_at(1).bytes.should eq(Bytes[0x2a_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(literal)

    # A runtime Nothing NULL is not a present dynamic path; an empty object is
    # therefore encoded with a zero path count even if that path was supplied.
    nothing_only = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"gone", CrystalClick::BinaryValue.null}] of Tuple(String, CrystalClick::BinaryValue),
    )
    nothing_only.path_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode_value(
      CrystalClick::BinaryValue.json(json_type, nothing_only),
    ).should eq(Bytes[0x00_u8])
  end
end
