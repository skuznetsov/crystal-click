require "./spec_helper"

private def w239g_geometry_descriptor : Bytes
  Bytes[0x2c_u8, 0x08_u8, 0x47_u8, 0x65_u8, 0x6f_u8, 0x6d_u8, 0x65_u8, 0x74_u8, 0x72_u8, 0x79_u8]
end

private def w239g_join(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| bytes.concat(part.to_a) }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W239 nominal Geometry type-owner guards" do
  it "does not expose the hidden Variant TypeId as a direct Nullable child" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(geometry)
    end

    # The restriction is immediate-TypeId based, not a ban on recursive
    # composition: Tuple itself is Nullable-eligible upstream.
    tuple = CrystalClick::BinaryDataType.tuple([geometry] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    nullable_tuple.name.should eq("Nullable(Tuple(Geometry))")

    # Outer Nullable absence and Geometry's intrinsic Variant null are two
    # different persisted markers, even when the nested Tuple is present.
    descriptor = w239g_join([
      Bytes[0x23_u8, 0x1f_u8, 0x01_u8],
      w239g_geometry_descriptor,
    ] of Bytes)
    outer_null_wire = w239g_join([descriptor, Bytes[0x01_u8]] of Bytes)
    outer_null = CrystalClick::BinaryValueCodec.decode(outer_null_wire)
    outer_null.is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode(outer_null).should eq(outer_null_wire)

    inner_null_wire = w239g_join([descriptor, Bytes[0x00_u8, 0xff_u8]] of Bytes)
    inner_null = CrystalClick::BinaryValueCodec.decode(inner_null_wire)
    inner_null.is_null?.should be_false
    inner_null.child_at(0).child_at(0).child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode(inner_null).should eq(inner_null_wire)
  end

  it "does not expose the hidden Variant TypeId as a direct ordinary Variant arm" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    string = CrystalClick::BinaryDataType.primitive("String")

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([geometry, string] of CrystalClick::BinaryDataType)
    end

    # An intervening Array changes the direct TypeId, so this remains a
    # source-lawful static arm even though its child tree contains Geometry.
    array = CrystalClick::BinaryDataType.array(geometry)
    wrapped = CrystalClick::BinaryDataType.variant([string, array] of CrystalClick::BinaryDataType)
    wrapped.children.map(&.name).should eq(["Array(Geometry)", "String"] of String)
  end

  it "does not admit an extracted Geometry storage Variant as an ordinary child" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    hidden_body.geometry_storage_variant?.should be_true
    string = CrystalClick::BinaryDataType.primitive("String")

    # The nominal Geometry wrapper is legal below these recursive owners, but
    # extracting its source-fixed body must not turn that body into a public,
    # ordinary Variant whose declaration would be reparsed with sorted arms.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.array(hidden_body)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.tuple([hidden_body] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.map(string, hidden_body)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested([hidden_body] of CrystalClick::BinaryDataType, ["body"] of String)
    end

    array = CrystalClick::BinaryDataType.array(geometry)
    tuple = CrystalClick::BinaryDataType.tuple([geometry] of CrystalClick::BinaryDataType)
    map = CrystalClick::BinaryDataType.map(string, geometry)
    nested = CrystalClick::BinaryDataType.nested([geometry] of CrystalClick::BinaryDataType, ["body"] of String)
    array.name.should eq("Array(Geometry)")
    tuple.name.should eq("Tuple(Geometry)")
    map.name.should eq("Map(String, Geometry)")
    nested.name.should eq("Nested(body Geometry)")
  end

  it "refuses a direct bulk declaration of the extracted Geometry storage Variant" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)

    # Callers can pass the extracted hidden body without going through any
    # ordinary constructor, so the physical declaration boundary must guard it.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryCustomGeoBulkColumnDeclaration.new(hidden_body)
    end
  end

  it "refuses scalar encoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    hidden_null = CrystalClick::BinaryValue.variant_null(hidden_body)
    nominal_value = CrystalClick::BinaryValue.custom(geometry, hidden_null)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(hidden_null)
    end

    # The same visitor remains available beneath the nominal Custom owner.
    CrystalClick::BinaryValueCodec.encode_value(nominal_value).should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.encode(nominal_value).should eq(
      w239g_join([w239g_geometry_descriptor, Bytes[0xff_u8]] of Bytes),
    )
  end

  it "refuses scalar decoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(hidden_body, Bytes[0xff_u8])
    end

    # A legal Geometry scalar has the same intrinsic null byte, but retains its
    # nominal Custom type at the public boundary.
    decoded = CrystalClick::BinaryValueCodec.decode_value(geometry, Bytes[0xff_u8])
    decoded.type.should eq(geometry)
    decoded.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(Bytes[0xff_u8])
  end

  it "refuses bulk encoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    hidden_null = CrystalClick::BinaryValue.variant_null(hidden_body)
    nominal_value = CrystalClick::BinaryValue.custom(geometry, hidden_null)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        hidden_body,
        [[hidden_null] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode_with_budget(
        hidden_body,
        [[hidden_null] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end

    nominal_streams = CrystalClick::BinaryBulkCodec.encode(
      geometry,
      [[nominal_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
    )
    nominal_streams.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8])
  end

  it "refuses bulk decoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    nominal_value = CrystalClick::BinaryValue.custom(
      geometry,
      CrystalClick::BinaryValue.variant_null(hidden_body),
    )
    # Build an independently legal nominal stream to avoid deriving the
    # decoder input from the direct-root encoder being challenged.
    nominal_streams = CrystalClick::BinaryBulkCodec.encode(
      geometry,
      [[nominal_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
    )
    nominal_rows = CrystalClick::BinaryBulkCodec.decode(geometry, nominal_streams, [1_u64])
    nominal_rows.first.first.type.should eq(geometry)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.decode(hidden_body, nominal_streams, [1_u64])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.decode_with_budget(
        hidden_body,
        nominal_streams,
        [1_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
    end
  end

  it "refuses direct raw bulk encoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    hidden_null = CrystalClick::BinaryValue.variant_null(hidden_body)
    nominal_value = CrystalClick::BinaryValue.custom(geometry, hidden_null)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkEncoder.encode(
        hidden_body,
        [[hidden_null] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        CrystalClick::BinaryBulkProfile.single_stream,
      )
    end

    nominal_streams = CrystalClick::BinaryBulkEncoder.encode(
      geometry,
      [[nominal_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    nominal_streams.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8])
  end

  it "refuses direct raw bulk decoding of the extracted Geometry storage Variant root" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239g_geometry_descriptor)
    hidden_body = geometry.child_at(0)
    nominal_value = CrystalClick::BinaryValue.custom(
      geometry,
      CrystalClick::BinaryValue.variant_null(hidden_body),
    )
    nominal_streams = CrystalClick::BinaryBulkCodec.encode(
      geometry,
      [[nominal_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
    )

    nominal_rows = CrystalClick::BinaryBulkDecoder.decode(
      geometry,
      nominal_streams,
      [1_u64],
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      0,
      nil,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    nominal_rows.first.first.type.should eq(geometry)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDecoder.decode(
        hidden_body,
        nominal_streams,
        [1_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        0,
        nil,
        CrystalClick::BinaryBulkProfile.single_stream,
      )
    end
  end

  it "retains the ordinary sorted Variant wire and discriminator control" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    ordinary = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
    descriptor = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8]

    ordinary.children.map(&.name).should eq(["String", "UInt64"] of String)
    CrystalClick::BinaryDataTypeCodec.encode(ordinary).should eq(descriptor)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(ordinary)

    string_value = CrystalClick::BinaryValue.variant(ordinary, 0, CrystalClick::BinaryValue.string("x"))
    CrystalClick::BinaryValueCodec.encode_value(string_value).should eq(Bytes[0x00_u8, 0x01_u8, 0x78_u8])
  end
end
