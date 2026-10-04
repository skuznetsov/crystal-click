require "./spec_helper"

private def w153_dynamic_limits(
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

describe "W153 paired Dynamic logical values" do
  it "keeps every admitted cap nominal while actual UInt64 selection remains independent" do
    body = Bytes[
      0x04_u8, # UInt64 descriptor
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, # little-endian 42
    ]

    (0..254).each do |max_types|
      type = CrystalClick::BinaryDataType.dynamic(max_types: max_types)
      cap = max_types.to_u8
      complete = Bytes[
        0x2b_u8, cap, 0x04_u8, 0x2a_u8,
        0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x00_u8, 0x00_u8,
      ]

      decoded = CrystalClick::BinaryValueCodec.decode_value(type, body)
      decoded.type.should eq(type)
      decoded.type.dynamic_max_types.should eq(cap)
      decoded.is_null?.should be_false
      decoded.child_at(0).type.name.should eq("UInt64")
      decoded.child_at(0).as_uint64.should eq(42_u64)
      CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(body)

      complete_value = CrystalClick::BinaryValueCodec.decode(complete)
      complete_value.type.should eq(type)
      complete_value.child_at(0).as_uint64.should eq(42_u64)
      CrystalClick::BinaryValueCodec.encode(complete_value).should eq(complete)
    end
  end

  it "distinguishes Dynamic NULL from selected Nullable, Variant, and nested Dynamic NULL" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 0)

    dynamic_null = CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x00_u8])
    dynamic_null.type.should eq(type)
    dynamic_null.is_null?.should be_true
    dynamic_null.child_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode_value(dynamic_null).should eq(Bytes[0x00_u8])

    # A Nothing NULL child is the same outer Dynamic NULL sentinel.
    normalized_null = CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.null)
    normalized_null.is_null?.should be_true
    normalized_null.child_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode_value(normalized_null).should eq(Bytes[0x00_u8])

    # Nullable(UInt64) NULL: descriptor 23 04, then its NULL flag 01.
    nullable_wire = Bytes[0x23_u8, 0x04_u8, 0x01_u8]
    nullable_value = CrystalClick::BinaryValueCodec.decode_value(type, nullable_wire)
    nullable_value.is_null?.should be_false
    nullable_value.child_at(0).type.name.should eq("Nullable(UInt64)")
    nullable_value.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(nullable_value).should eq(nullable_wire)

    # Canonical Variant(String, UInt64), with the selected Variant NULL tag ff.
    variant_wire = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0xff_u8]
    variant_value = CrystalClick::BinaryValueCodec.decode_value(type, variant_wire)
    variant_value.is_null?.should be_false
    variant_value.child_at(0).type.name.should eq("Variant(String, UInt64)")
    variant_value.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(variant_value).should eq(variant_wire)

    # The selected value is itself Dynamic(max_types=0), whose body is NULL.
    nested_dynamic_wire = Bytes[0x2b_u8, 0x00_u8, 0x00_u8]
    nested_dynamic = CrystalClick::BinaryValueCodec.decode_value(type, nested_dynamic_wire)
    nested_dynamic.is_null?.should be_false
    nested_dynamic.child_at(0).type.should eq(CrystalClick::BinaryDataType.dynamic(max_types: 0))
    nested_dynamic.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(nested_dynamic).should eq(nested_dynamic_wire)
  end

  it "requires a nominal Dynamic wrapper and keeps child snapshots detached" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.dynamic(uint64, CrystalClick::BinaryValue.uint64(42_u64))
    end

    type = CrystalClick::BinaryDataType.dynamic(max_types: 17)
    wire = Bytes[0x04_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    value = CrystalClick::BinaryValueCodec.decode_value(type, wire)
    wire[1] = 0x99_u8
    value.child_at(0).as_uint64.should eq(42_u64)

    returned_children = value.elements
    returned_children.clear
    value.child_count.should eq(1)
    value.child_at(0).as_uint64.should eq(42_u64)
  end

  it "uses the ordinary recursive payload grammar for selected composites" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 254)

    # Array(UInt64), one element 42: descriptor 1e 04, count 01, UInt64 body.
    array_wire = Bytes[
      0x1e_u8, 0x04_u8, 0x01_u8,
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    array_value = CrystalClick::BinaryValueCodec.decode_value(type, array_wire)
    array_value.is_null?.should be_false
    array_value.child_at(0).type.name.should eq("Array(UInt64)")
    array_value.child_at(0).element_count.should eq(1)
    array_value.child_at(0).element_at(0).as_uint64.should eq(42_u64)
    CrystalClick::BinaryValueCodec.encode_value(array_value).should eq(array_wire)

    # Nothing has no ordinary scalar body. Empty Array(Nothing) has no such
    # scalar visit and remains valid under Dynamic.
    empty_array_nothing_wire = Bytes[0x1e_u8, 0x00_u8, 0x00_u8]
    empty_array_nothing = CrystalClick::BinaryValueCodec.decode_value(type, empty_array_nothing_wire)
    empty_array_nothing.child_at(0).type.name.should eq("Array(Nothing)")
    empty_array_nothing.child_at(0).element_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode_value(empty_array_nothing).should eq(empty_array_nothing_wire)

    # Nullable(Nothing) still permits NULL flag 01, including when selected.
    nullable_nothing_wire = Bytes[0x23_u8, 0x00_u8, 0x01_u8]
    nullable_nothing = CrystalClick::BinaryValueCodec.decode_value(type, nullable_nothing_wire)
    nullable_nothing.child_at(0).type.name.should eq("Nullable(Nothing)")
    nullable_nothing.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(nullable_nothing).should eq(nullable_nothing_wire)
    CrystalClick::BinaryValueCodec.decode_value(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Nothing")),
      Bytes[0x01_u8],
    ).is_null?.should be_true

    # Do not synthesize a zero-byte Nothing value inside a nonempty composite.
    rejected_nothing_bodies = [
      Bytes[0x1e_u8, 0x00_u8, 0x01_u8], # Array(Nothing), one element
      Bytes[0x1f_u8, 0x01_u8, 0x00_u8], # Tuple(Nothing), one field
    ] of Bytes
    rejected_nothing_bodies.each do |wire|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_value(type, wire)
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x23_u8, 0x00_u8, 0x00_u8])
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(
        CrystalClick::BinaryDataType.primitive("Nothing"),
        Bytes.empty,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(
        CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("Nothing")),
        Bytes[0x01_u8],
      )
    end

    array_nothing = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("Nothing"))
    array_with_nothing = CrystalClick::BinaryValue.array(array_nothing, [CrystalClick::BinaryValue.null] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(CrystalClick::BinaryValue.dynamic(type, array_with_nothing))
    end

    tuple_nothing = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.primitive("Nothing")] of CrystalClick::BinaryDataType)
    tuple_with_nothing = CrystalClick::BinaryValue.tuple(tuple_nothing, [CrystalClick::BinaryValue.null] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(CrystalClick::BinaryValue.dynamic(type, tuple_with_nothing))
    end
  end

  it "charges Dynamic NULL and complete-envelope bytes once at exact limits" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    value = CrystalClick::BinaryValue.dynamic(type)
    body = Bytes[0x00_u8]
    full_wire = Bytes[0x2b_u8, 0x00_u8, 0x00_u8]
    known_exact = w153_dynamic_limits(max_depth: 2, max_nodes: 3, max_elements: 1, max_bytes: 1)

    CrystalClick::BinaryValueCodec.encode_value(value, known_exact).should eq(body)
    CrystalClick::BinaryValueCodec.decode_value(type, body, known_exact).is_null?.should be_true

    full_exact = w153_dynamic_limits(max_depth: 2, max_nodes: 3, max_elements: 1, max_bytes: 3)
    CrystalClick::BinaryValueCodec.encode(value, full_exact).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire, full_exact).is_null?.should be_true

    [
      w153_dynamic_limits(max_depth: 1, max_nodes: 3, max_elements: 1, max_bytes: 1),
      w153_dynamic_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 1),
      w153_dynamic_limits(max_depth: 2, max_nodes: 3, max_elements: 0, max_bytes: 1),
      w153_dynamic_limits(max_depth: 2, max_nodes: 3, max_elements: 1, max_bytes: 0),
    ].each do |too_small|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, body, too_small)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, too_small)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(full_wire, w153_dynamic_limits(max_bytes: 2))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w153_dynamic_limits(max_bytes: 2))
    end
  end

  it "shares recursive descriptor and payload limits in known and complete envelopes" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    uint64_value = CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.uint64(42_u64))
    uint64_body = Bytes[0x04_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    uint64_full = Bytes[0x2b_u8, 0x00_u8, 0x04_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    uint64_known_exact = w153_dynamic_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 9)
    uint64_full_exact = w153_dynamic_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 11)
    CrystalClick::BinaryValueCodec.encode_value(uint64_value, uint64_known_exact).should eq(uint64_body)
    CrystalClick::BinaryValueCodec.decode_value(type, uint64_body, uint64_known_exact).child_at(0).as_uint64.should eq(42_u64)
    CrystalClick::BinaryValueCodec.encode(uint64_value, uint64_full_exact).should eq(uint64_full)
    CrystalClick::BinaryValueCodec.decode(uint64_full, uint64_full_exact).child_at(0).as_uint64.should eq(42_u64)

    inner_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested_value = CrystalClick::BinaryValue.dynamic(
      type,
      CrystalClick::BinaryValue.dynamic(inner_type, CrystalClick::BinaryValue.uint64(42_u64)),
    )
    nested_body = Bytes[
      0x2b_u8, 0x01_u8, 0x04_u8, 0x2a_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8,
    ]
    nested_exact = w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 11)
    CrystalClick::BinaryValueCodec.encode_value(nested_value, nested_exact).should eq(nested_body)
    nested_decoded = CrystalClick::BinaryValueCodec.decode_value(type, nested_body, nested_exact)
    nested_decoded.child_at(0).type.should eq(inner_type)
    nested_decoded.child_at(0).child_at(0).as_uint64.should eq(42_u64)

    [
      w153_dynamic_limits(max_depth: 2, max_nodes: 6, max_elements: 4, max_bytes: 11),
      w153_dynamic_limits(max_depth: 3, max_nodes: 5, max_elements: 4, max_bytes: 11),
      w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 3, max_bytes: 11),
    ].each do |too_small|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, nested_body, too_small)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(nested_value, too_small)
      end
    end

    value = CrystalClick::BinaryValue.dynamic(
      type,
      CrystalClick::BinaryValue.array(
        CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64")),
        [CrystalClick::BinaryValue.uint64(42_u64)] of CrystalClick::BinaryValue,
      ),
    )
    body = Bytes[
      0x1e_u8, 0x04_u8, 0x01_u8,
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    full_wire = Bytes[
      0x2b_u8, 0x00_u8,
      0x1e_u8, 0x04_u8, 0x01_u8,
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    known_exact = w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 11)

    CrystalClick::BinaryValueCodec.encode_value(value, known_exact).should eq(body)
    decoded = CrystalClick::BinaryValueCodec.decode_value(type, body, known_exact)
    decoded.child_at(0).element_at(0).as_uint64.should eq(42_u64)

    full_exact = w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 13)
    CrystalClick::BinaryValueCodec.encode(value, full_exact).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire, full_exact).child_at(0).element_at(0).as_uint64.should eq(42_u64)

    [
      w153_dynamic_limits(max_depth: 2, max_nodes: 6, max_elements: 4, max_bytes: 11),
      w153_dynamic_limits(max_depth: 3, max_nodes: 5, max_elements: 4, max_bytes: 11),
      w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 3, max_bytes: 11),
      w153_dynamic_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 10),
    ].each do |too_small|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, body, too_small)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, too_small)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(full_wire, w153_dynamic_limits(max_bytes: 12))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w153_dynamic_limits(max_bytes: 12))
    end
  end

  it "keeps borrowed Dynamic refusals even for NULL and empty wrappers" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    null_value = CrystalClick::BinaryValue.dynamic(type)
    write_budget = CrystalClick::BinaryCodecBudget.new(w153_dynamic_limits(max_bytes: 16), true)
    write_budget.charge_wire_bytes(3_u64)

    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryValueCodec.encode_borrowed(null_value, write_budget)
    end
    write_budget.wire_byte_count.should eq(3_i64)

    read_budget = CrystalClick::BinaryCodecBudget.new(w153_dynamic_limits(max_bytes: 16))
    read_budget.charge_wire_bytes(3_u64)
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryValueCodec.decode_borrowed(Bytes[0x2b_u8, 0x00_u8, 0x00_u8], read_budget)
    end
    read_budget.wire_byte_count.should eq(3_i64)

    array_dynamic = CrystalClick::BinaryDataType.array(type)
    empty_value = CrystalClick::BinaryValue.array(array_dynamic, [] of CrystalClick::BinaryValue)
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        empty_value,
        CrystalClick::BinaryCodecBudget.new(w153_dynamic_limits, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        Bytes[0x1e_u8, 0x2b_u8, 0x00_u8, 0x00_u8],
        CrystalClick::BinaryCodecBudget.new(w153_dynamic_limits),
      )
    end

    # Ordinary neighboring public envelopes remain usable.
    ordinary = CrystalClick::BinaryValue.uint64(42_u64)
    ordinary_wire = Bytes[0x04_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    CrystalClick::BinaryValueCodec.encode(ordinary).should eq(ordinary_wire)
    CrystalClick::BinaryValueCodec.decode(ordinary_wire).as_uint64.should eq(42_u64)
  end

  it "rejects malformed Dynamic actual descriptors, payloads, and trailing bytes" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 254)
    malformed_bodies = [
      Bytes.empty,                      # no actual descriptor
      Bytes[0x04_u8, 0x2a_u8],          # truncated UInt64 body
      Bytes[0x00_u8, 0x00_u8],          # trailing byte after Dynamic NULL
      Bytes[0xff_u8],                   # unknown actual descriptor
      Bytes[0x23_u8, 0x00_u8, 0x00_u8], # Nullable(Nothing) non-NULL
    ] of Bytes

    malformed_bodies.each do |body|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, body)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(Bytes[0x2b_u8, 0xff_u8, 0x00_u8])
    end
  end
end
