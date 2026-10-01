require "./spec_helper"

describe "QBit independent hostile controls" do
  it "distinguishes carrier byte width from plane bit count for every element type" do
    [{"Int8", 1, 8}, {"BFloat16", 2, 16}, {"Float32", 4, 32}, {"Float64", 8, 64}].each do |element, width, bits|
      type = CrystalClick::QBitType.new(element, 10_u64)
      type.element_width.should eq(width)
      type.element_bits.should eq(bits)
      type.raw_row_bytes.should eq(10 * width)
      type.plane_count.should eq(bits)
      type.plane_width.should eq(2)
      raw = Bytes.new(10 * width, 0_u8)
      raw[9 * width] = 1_u8
      plane = Bytes.new(2, 0_u8)
      CrystalClick::QBitPlaneCodec.encode_plane_row(CrystalClick::QBitValue.new(type, raw), bits - 1, plane)
      plane.should eq(Bytes[2_u8, 0_u8])
    end
  end

  it "keeps reverse byte-block order and MSB-first element planes" do
    type = CrystalClick::QBitType.new("Int8", 10_u64)
    raw = Bytes.new(10, 0_u8)
    raw[0] = 1_u8
    raw[8] = 1_u8
    raw[9] = 2_u8
    value = CrystalClick::QBitValue.new(type, raw)

    # Independent one-hot expectation: dimensions 0 and 8 occupy bit zero
    # in opposite bytes. Element bit zero is the eighth (index 7) plane.
    low_plane = Bytes.new(2, 0_u8)
    CrystalClick::QBitPlaneCodec.encode_plane_row(value, 7, low_plane, 0)
    low_plane.should eq(Bytes[1_u8, 1_u8])
    next_plane = Bytes.new(2, 0_u8)
    CrystalClick::QBitPlaneCodec.encode_plane_row(value, 6, next_plane, 0)
    next_plane.should eq(Bytes[2_u8, 0_u8])
    sign_plane = Bytes.new(2, 0_u8)
    CrystalClick::QBitPlaneCodec.encode_plane_row(value, 0, sign_plane, 0)
    sign_plane.should eq(Bytes[0_u8, 0_u8])
  end

  it "keeps stride groups distinct instead of treating all dimensions as one plane" do
    type = CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)
    raw = Bytes.new(16, 0_u8)
    raw[0] = 1_u8
    raw[9] = 1_u8
    value = CrystalClick::QBitValue.new(type, raw)
    first = Bytes.new(1, 0_u8)
    second = Bytes.new(1, 0_u8)
    CrystalClick::QBitPlaneCodec.encode_plane_row(value, 7, first, 0)
    CrystalClick::QBitPlaneCodec.encode_plane_row(value, 15, second, 0)
    first.should eq(Bytes[1_u8])
    second.should eq(Bytes[2_u8])
  end

  it "ignores unused plane padding like ClickHouse untranspose" do
    type = CrystalClick::QBitType.new("Int8", 1_u64)
    decoded = CrystalClick::QBitPlaneCodec.decode_row(type) do |plane, byte|
      # Bit zero belongs to dimension zero; bit seven is padding. Both are
      # deliberately set in the least-significant element-bit plane.
      plane == 7 && byte == 0 ? 129_u8 : 0_u8
    end
    decoded.raw_bytes.should eq(Bytes[1_u8])
  end

  it "compares raw float bits rather than numerical equality" do
    type = CrystalClick::QBitType.new("Float32", 1_u64)
    positive_zero = CrystalClick::QBitValue.new(type, Bytes[0_u8, 0_u8, 0_u8, 0_u8])
    negative_zero = CrystalClick::QBitValue.new(type, Bytes[0_u8, 0_u8, 0_u8, 128_u8])
    nan = CrystalClick::QBitValue.new(type, Bytes[1_u8, 0_u8, 192_u8, 127_u8])
    nan_copy = CrystalClick::QBitValue.new(type, Bytes[1_u8, 0_u8, 192_u8, 127_u8])
    positive_zero.should_not eq(negative_zero)
    nan.should eq(nan_copy)
    nan.hash.should eq(nan_copy.hash)
  end

  it "owns descriptor and row inputs and never exposes its raw storage" do
    element = String.new("Int8".to_slice)
    type = CrystalClick::QBitType.new(element, 1_u64)
    input = Bytes[3_u8]
    value = CrystalClick::QBitValue.new(type, input)
    element.to_unsafe[0] = 'X'.ord.to_u8
    input[0] = 9_u8
    exported = value.raw_bytes
    exported[0] = 12_u8
    type.element_type.should eq("Int8")
    type.type_name.should eq("QBit(Int8, 1)")
    value.raw_bytes.should eq(Bytes[3_u8])
  end

  it "rejects unsigned overflow dimensions and wrong raw row widths" do
    expect_raises(ArgumentError) { CrystalClick::QBitType.new("Float64", UInt64::MAX) }
    type = CrystalClick::QBitType.new("Float32", 2_u64)
    expect_raises(ArgumentError) { CrystalClick::QBitValue.new(type, Bytes.new(7, 0_u8)) }
    expect_raises(ArgumentError) { CrystalClick::QBitValue.new(type, Bytes.new(9, 0_u8)) }
  end

  it "canonicalizes equal stride only at construction, not persisted admission" do
    CrystalClick::QBitType.new("Float32", 16_u64, 16_u64).type_name.should eq("QBit(Float32, 16)")
    CrystalClick::QBitColumnType.for_type("QBit(Float32, 16, 16)").should be_nil
    CrystalClick::QBitColumnType.for_type("Nullable(QBit(Float32, 16, 16))").should be_nil
    CrystalClick::QBitColumnType.for_type("QBit(Float32, 18446744073709551616)").should be_nil
  end

  it "keeps legal source parameters separate from bounded part-stream admission" do
    # The source permits 1024 stride groups. Float64 then has 65536 planes;
    # paired bin/mark checksum records exceed this library's bounded profile.
    type = CrystalClick::QBitType.new("Float64", 8192_u64, 8_u64)
    type.stride_groups.should eq(1024)
    type.plane_count.should eq(65536)
    CrystalClick::QBitColumnType.for_type(type.type_name).should be_nil
    CrystalClick::QBitColumnType.for_type("QBit(Int8, 8192, 8)").should_not be_nil
    expect_raises(ArgumentError) { CrystalClick::QBitType.new("Int8", 8200_u64, 8_u64) }
  end

  it "bounds the whole logical range without UInt64 multiplication overflow" do
    plan = CrystalClick::QBitColumnType.for_type("QBit(Float64, 10)").not_nil!
    plan.materialization_charge(5_u64).should be < 64_u64 * 1024_u64 * 1024_u64
    expect_raises(ArgumentError) { plan.materialization_charge(UInt64::MAX) }
    expect_raises(ArgumentError) { plan.materialization_charge(1_000_000_u64) }
  end
end
