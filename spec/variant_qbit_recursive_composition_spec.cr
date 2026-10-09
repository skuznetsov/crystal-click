require "./spec_helper"

private def w232k_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 3_u64)
end

private def w232k_qbit_value(type : CrystalClick::QBitType, bytes : Bytes) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, bytes))
end

describe "W232 recursive QBit composition in Variant" do
  it "normalizes QBit arms and preserves literal descriptor and RowBinary bytes" do
    qbit_type = w232k_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    descriptor = Bytes[0x2a_u8, 0x02, 0x36, 0x07, 0x03, 0x01]
    candidate = begin
      CrystalClick::BinaryDataType.variant([uint8, qbit] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    candidate.should_not be_nil
    type = candidate.not_nil!

    type.children.map(&.name).should eq(["QBit(Int8, 3)", "UInt8"] of String)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)

    qbit_value = w232k_qbit_value(qbit_type, Bytes[0x01_u8, 0x02, 0x03])
    selected_qbit = CrystalClick::BinaryValue.variant(type, 0, qbit_value)
    selected_uint8 = CrystalClick::BinaryValue.variant(
      type,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
    )
    null_value = CrystalClick::BinaryValue.variant_null(type)

    # Independent RowBinary literals: discriminator followed by the existing
    # QBit scalar codec, an ordinary UInt8 arm, or the Variant NULL sentinel.
    CrystalClick::BinaryValueCodec.encode_value(selected_qbit).should eq(Bytes[0x00_u8, 0x03, 0x01, 0x02, 0x03])
    CrystalClick::BinaryValueCodec.encode_value(selected_uint8).should eq(Bytes[0x01_u8, 0x07])
    CrystalClick::BinaryValueCodec.encode_value(null_value).should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.decode_value(
      type,
      Bytes[0x00_u8, 0x03, 0x01, 0x02, 0x03],
    ).should eq(selected_qbit)

    envelope = Bytes[0x2a_u8, 0x02, 0x36, 0x07, 0x03, 0x01, 0x00, 0x03, 0x01, 0x02, 0x03]
    CrystalClick::BinaryValueCodec.encode(selected_qbit).should eq(envelope)
    CrystalClick::BinaryValueCodec.decode(envelope).should eq(selected_qbit)

    # The paired wire decoder remains strict about the normal form. The
    # opposite arm order is parseable but not the canonical roster order.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x2a_u8, 0x02, 0x01, 0x36, 0x07, 0x03])
    end
  end

  it "rejects nominally different QBit dimensions and strides as selected Variant values" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    dimension_type = CrystalClick::QBitType.new("Int8", 3_u64)
    dimension_variant_candidate = begin
      CrystalClick::BinaryDataType.variant([
        CrystalClick::BinaryDataType.qbit(dimension_type), uint8,
      ] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    dimension_variant_candidate.should_not be_nil
    dimension_variant = dimension_variant_candidate.not_nil!
    wrong_dimension = w232k_qbit_value(
      CrystalClick::QBitType.new("Int8", 4_u64), Bytes[0x01_u8, 0x02, 0x03, 0x04],
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(dimension_variant, 0, wrong_dimension)
    end

    stride_type = CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)
    stride_variant_candidate = begin
      CrystalClick::BinaryDataType.variant([
        CrystalClick::BinaryDataType.qbit(stride_type), uint8,
      ] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    stride_variant_candidate.should_not be_nil
    stride_variant = stride_variant_candidate.not_nil!
    wrong_stride = w232k_qbit_value(
      CrystalClick::QBitType.new("Int8", 16_u64), Bytes.new(16, 0x05_u8),
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(stride_variant, 0, wrong_stride)
    end
  end

  it "composes existing QBit leaves through Variant arms and an ordinary Array wrapper" do
    qbit_type = w232k_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple([qbit, uint64] of CrystalClick::BinaryDataType)
    array = CrystalClick::BinaryDataType.array(tuple)
    candidate = begin
      CrystalClick::BinaryDataType.variant([uint8, array] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    candidate.should_not be_nil
    type = candidate.not_nil!

    type.children.map(&.name).should eq([
      "Array(Tuple(QBit(Int8, 3), UInt64))",
      "UInt8",
    ] of String)

    qbit_value = w232k_qbit_value(qbit_type, Bytes[0x11_u8, 0x22, 0x33])
    tuple_value = CrystalClick::BinaryValue.tuple(tuple, [
      qbit_value,
      CrystalClick::BinaryValue.uint64(42_u64),
    ] of CrystalClick::BinaryValue)
    one = CrystalClick::BinaryValue.array(array, [tuple_value] of CrystalClick::BinaryValue)
    empty = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
    selected_array = CrystalClick::BinaryValue.variant(type, 0, one)
    selected_empty = CrystalClick::BinaryValue.variant(type, 0, empty)
    selected_uint8 = CrystalClick::BinaryValue.variant(
      type,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
    )
    null_value = CrystalClick::BinaryValue.variant_null(type)
    rows = [[selected_array, selected_uint8, null_value], [selected_empty]] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(type, rows)
    streams.has_role?("root.discriminators").should be_true
    streams.has_role?("root.arm.0.sizes").should be_true
    streams.has_role?("root.arm.0.elements.field.0.qbit_plane.0").should be_true
    streams.has_role?("root.arm.0.elements.field.1.data").should be_true
    streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01, 0xff, 0x00])
    CrystalClick::BinaryBulkCodec.decode(type, streams, [3_u64, 1_u64]).should eq(rows)

    # The same selected value tree must continue to work below a standard
    # Array node; role prefixes are generated by the existing generic visitor.
    outer = CrystalClick::BinaryDataType.array(type)
    wrapped = CrystalClick::BinaryValue.array(
      outer,
      [selected_array, selected_uint8, null_value] of CrystalClick::BinaryValue,
    )
    wrapped_rows = [[wrapped]] of Array(CrystalClick::BinaryValue)
    wrapped_streams = CrystalClick::BinaryBulkCodec.encode(outer, wrapped_rows)
    wrapped_streams.has_role?("root.sizes").should be_true
    wrapped_streams.has_role?("root.elements.discriminators").should be_true
    wrapped_streams.has_role?("root.elements.arm.0.elements.field.0.qbit_plane.0").should be_true
    CrystalClick::BinaryBulkCodec.decode(outer, wrapped_streams, [1_u64]).should eq(wrapped_rows)
  end

  it "keeps two sparse Variant discriminator axes around an ordinary Array" do
    qbit_type = w232k_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")

    inner_candidate = begin
      CrystalClick::BinaryDataType.variant([qbit, uint64] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    inner_candidate.should_not be_nil
    inner = inner_candidate.not_nil!
    array = CrystalClick::BinaryDataType.array(inner)
    outer_candidate = begin
      CrystalClick::BinaryDataType.variant([string, array] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    outer_candidate.should_not be_nil
    outer = outer_candidate.not_nil!

    # A direct nested Variant remains outside the static roster law; the
    # supported composition crosses the first discriminator through Array.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([inner, string] of CrystalClick::BinaryDataType)
    end

    inner_qbit = CrystalClick::BinaryValue.variant(
      inner,
      0,
      w232k_qbit_value(qbit_type, Bytes[0x31_u8, 0x32, 0x33]),
    )
    inner_null = CrystalClick::BinaryValue.variant_null(inner)
    inner_uint64 = CrystalClick::BinaryValue.variant(inner, 1, CrystalClick::BinaryValue.uint64(73_u64))
    selected_array = CrystalClick::BinaryValue.variant(
      outer,
      0,
      CrystalClick::BinaryValue.array(array, [inner_qbit, inner_null, inner_uint64] of CrystalClick::BinaryValue),
    )
    selected_empty = CrystalClick::BinaryValue.variant(
      outer,
      0,
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
    )
    selected_string = CrystalClick::BinaryValue.variant(outer, 1, CrystalClick::BinaryValue.string("s"))
    null_value = CrystalClick::BinaryValue.variant_null(outer)
    rows = [[selected_array, selected_string, null_value, selected_empty]] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(outer, rows)
    streams.has_role?("root.discriminators").should be_true
    streams.has_role?("root.arm.0.sizes").should be_true
    streams.has_role?("root.arm.0.elements.discriminators").should be_true
    streams.has_role?("root.arm.0.elements.arm.0.qbit_plane.0").should be_true
    streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01, 0xff, 0x00])
    streams.stream("root.arm.0.elements.discriminators").bytes.should eq(Bytes[0x00_u8, 0xff, 0x01])
    CrystalClick::BinaryBulkCodec.decode(outer, streams, [4_u64]).should eq(rows)
  end

  it "composes Count and QBit sibling arms through scalar and bulk codecs" do
    count = CrystalClick::BinaryDataType.aggregate_count
    qbit_type = w232k_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    type = CrystalClick::BinaryDataType.variant([qbit, count] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq(["AggregateFunction(count)", "QBit(Int8, 3)"] of String)

    descriptor = Bytes[
      0x2a_u8, 0x02,
      0x25, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x00,
      0x36, 0x07, 0x03,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)

    count_value = CrystalClick::BinaryValue.variant(
      type,
      0,
      CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64),
    )
    qbit_value = CrystalClick::BinaryValue.variant(
      type,
      1,
      w232k_qbit_value(qbit_type, Bytes[0x41_u8, 0x42, 0x43]),
    )
    null_value = CrystalClick::BinaryValue.variant_null(type)
    CrystalClick::BinaryValueCodec.encode_value(count_value).should eq(Bytes[0x00_u8, 0x80, 0x01])
    CrystalClick::BinaryValueCodec.encode_value(qbit_value).should eq(Bytes[0x01_u8, 0x03, 0x41, 0x42, 0x43])
    CrystalClick::BinaryValueCodec.encode_value(null_value).should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x00_u8, 0x80, 0x01]).should eq(count_value)
    CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x03, 0x41, 0x42, 0x43]).should eq(qbit_value)

    rows = [[count_value, qbit_value, null_value]] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryBulkCodec.encode(type, rows)
    streams.has_role?("root.arm.0.data").should be_true
    streams.has_role?("root.arm.1.qbit_plane.0").should be_true
    streams.has_role?("root.discriminators").should be_true
    streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01, 0xff])
    CrystalClick::BinaryBulkCodec.decode(type, streams, [3_u64]).should eq(rows)
  end

  it "keeps Dynamic, Object, LowCardinality, and invalid Nullable admission closed" do
    qbit_type = w232k_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    candidate = begin
      CrystalClick::BinaryDataType.variant([qbit, uint8] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    candidate.should_not be_nil
    type = candidate.not_nil!
    qbit_value = w232k_qbit_value(qbit_type, Bytes[0x01_u8, 0x02, 0x03])
    selected_qbit = CrystalClick::BinaryValue.variant(type, 0, qbit_value)

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([dynamic, uint8] of CrystalClick::BinaryDataType)
    end
    CrystalClick::BinaryValue.dynamic(dynamic, qbit_value).child_count.should eq(1)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.dynamic(dynamic, selected_qbit)
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"payload" => type})
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.low_cardinality(qbit)
    end

    nullable_qbit = CrystalClick::BinaryDataType.nullable(qbit)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([nullable_qbit, uint8] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(type)
    end

    encoded = CrystalClick::BinaryValueCodec.encode(selected_qbit)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        selected_qbit,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        encoded,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end

  it "bounds cumulative Variant QBit roles, role names, and scratch" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    small_a = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 3_u64))
    small_b = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 4_u64))
    small_candidate = begin
      CrystalClick::BinaryDataType.variant([small_a, small_b, uint8] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    small_candidate.should_not be_nil
    small = small_candidate.not_nil!

    # Type-tree edges fit (five); both eight-plane QBit sites do not fit the
    # shared role/entry budget of fifteen.
    role_limited = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64, max_nodes: 128, max_elements: 15, max_bytes: 64 * 1024,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitRecursiveAdmission.static_sites(small, role_limited, true)
    end

    name_limited = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64, max_nodes: 128, max_elements: 1024, max_bytes: 64,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitRecursiveAdmission.static_sites(small, name_limited, true)
    end

    wide_a = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 100_000_u64))
    wide_b = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 120_000_u64))
    wide_candidate = begin
      CrystalClick::BinaryDataType.variant([wide_a, wide_b, uint8] of CrystalClick::BinaryDataType)
    rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
      nil
    end
    wide_candidate.should_not be_nil
    wide = wide_candidate.not_nil!
    # Each site uses at most 15,000 scratch bytes; their cumulative 27,500
    # bytes exceed this cap while generated role names remain far below it.
    scratch_limited = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64, max_nodes: 128, max_elements: 1024, max_bytes: 25_000,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitRecursiveAdmission.static_sites(wide, scratch_limited, true)
    end
  end
end
