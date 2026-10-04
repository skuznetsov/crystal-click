require "./spec_helper"

private def w152_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

describe "W152 nominal Dynamic descriptor kernel" do
  it "round-trips all 255 admitted caps as one-byte nominal suffixes" do
    (0..254).each do |max_types|
      suffix = max_types.to_u8
      descriptor = Bytes[0x2b_u8, suffix]
      type = CrystalClick::BinaryDataType.dynamic(max_types: max_types)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      expected_name = max_types == 32 ? "Dynamic" : "Dynamic(max_types=#{max_types})"

      type.dynamic_max_types.should eq(suffix)
      type.name.should eq(expected_name)
      decoded.should eq(type)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
      CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(descriptor)
    end
  end

  it "keeps the default cap canonical and part of nominal equality and hashing" do
    default = CrystalClick::BinaryDataType.dynamic
    explicit_default = CrystalClick::BinaryDataType.dynamic(max_types: 32)
    other_cap = CrystalClick::BinaryDataType.dynamic(max_types: 33)

    default.name.should eq("Dynamic")
    explicit_default.name.should eq("Dynamic")
    other_cap.name.should eq("Dynamic(max_types=33)")
    default.should eq(explicit_default)
    default.hash.should eq(explicit_default.hash)
    default.should_not eq(other_cap)
    default.hash.should_not eq(other_cap.hash)

    types = Set(CrystalClick::BinaryDataType).new
    types.add(default)
    types.add(explicit_default)
    types.add(other_cap)
    types.size.should eq(2)
  end

  it "enforces the local cap range and exposes leaf metadata without fixed width" do
    [-1, 255, 256].each do |max_types|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.dynamic(max_types: max_types)
      end
    end

    dynamic = CrystalClick::BinaryDataType.dynamic
    integer = CrystalClick::BinaryDataType.primitive("UInt64")

    dynamic.tag.should eq(0x2b_u8)
    dynamic.dynamic_max_types.should eq(32_u8)
    dynamic.fixed_width.should be_nil
    dynamic.fixed_size.should be_nil
    dynamic.child_count.should eq(0)
    dynamic.children.should be_empty
    dynamic.contains_dynamic?.should be_true

    integer.dynamic_max_types.should be_nil
    integer.contains_dynamic?.should be_false
  end

  it "detaches descriptor bytes and child collections while retaining composition facts" do
    descriptor = Bytes[0x2b_u8, 0x20_u8]
    dynamic = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    descriptor[1] = 0x21_u8

    dynamic.dynamic_max_types.should eq(32_u8)
    CrystalClick::BinaryDataTypeCodec.encode(dynamic).should eq(Bytes[0x2b_u8, 0x20_u8])

    supplied_children = [dynamic] of CrystalClick::BinaryDataType
    tuple = CrystalClick::BinaryDataType.tuple(supplied_children)
    supplied_children.clear
    tuple.contains_dynamic?.should be_true
    tuple.child_count.should eq(1)

    returned_children = tuple.children
    returned_children.clear
    tuple.contains_dynamic?.should be_true
    tuple.child_at(0).should eq(dynamic)
    CrystalClick::BinaryDataType.primitive("String").contains_dynamic?.should be_false
  end

  it "composes Dynamic through legal Array, Tuple, Map, and Nullable-Tuple parents" do
    dynamic = CrystalClick::BinaryDataType.dynamic
    array = CrystalClick::BinaryDataType.array(dynamic)
    tuple = CrystalClick::BinaryDataType.tuple([dynamic] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    map = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("String"),
      dynamic
    )

    array.name.should eq("Array(Dynamic)")
    tuple.name.should eq("Tuple(Dynamic)")
    nullable_tuple.name.should eq("Nullable(Tuple(Dynamic))")
    map.name.should eq("Map(String, Dynamic)")

    [array, tuple, nullable_tuple, map].each do |parent|
      parent.contains_dynamic?.should be_true
      descriptor = CrystalClick::BinaryDataTypeCodec.encode(parent)
      CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(parent)
    end
  end

  it "refuses Dynamic as an immediate Nullable, Variant, or LowCardinality child" do
    dynamic = CrystalClick::BinaryDataType.dynamic

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(dynamic)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([dynamic] of CrystalClick::BinaryDataType)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.low_cardinality(dynamic)
    end
  end

  it "classifies direct Dynamic wrapper wire descriptors as corrupt input" do
    # These wire forms are invalid because Dynamic is the immediate child;
    # Nullable and Variant may still wrap a recursive Dynamic-containing parent.
    malformed = [
      Bytes[0x23_u8, 0x2b_u8, 0x20_u8],          # Nullable(Dynamic)
      Bytes[0x26_u8, 0x2b_u8, 0x20_u8],          # LowCardinality(Dynamic)
      Bytes[0x2a_u8, 0x01_u8, 0x2b_u8, 0x20_u8], # Variant(Dynamic)
    ] of Bytes

    malformed.each do |descriptor|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      end
    end
  end

  it "rejects the forbidden cap byte, truncation, and any suffix or descriptor trailer" do
    malformed = [
      Bytes[0x2b_u8],                   # missing cap byte
      Bytes[0x2b_u8, 0xff_u8],          # normal-type profile excludes cap 255
      Bytes[0x2b_u8, 0x20_u8, 0x00_u8], # descriptor trailer
      Bytes[0x2b_u8, 0x80_u8, 0x01_u8], # cap is one byte, not VarUInt(128)
    ] of Bytes

    malformed.each do |descriptor|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      end
    end

    cap_128 = Bytes[0x2b_u8, 0x80_u8]
    decoded = CrystalClick::BinaryDataTypeCodec.decode(cap_128)
    decoded.dynamic_max_types.should eq(128_u8)
    decoded.name.should eq("Dynamic(max_types=128)")
    CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(cap_128)
  end

  it "charges the Dynamic leaf and its container against exact aggregate descriptor budgets" do
    descriptor = Bytes[0x1e_u8, 0x2b_u8, 0x20_u8]
    type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic)
    exact = w152_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 3)

    CrystalClick::BinaryDataTypeCodec.decode(descriptor, exact).should eq(type)
    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(descriptor)

    one_short_limits = [
      w152_limits(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 3),
      w152_limits(max_depth: 2, max_nodes: 1, max_elements: 1, max_bytes: 3),
      w152_limits(max_depth: 2, max_nodes: 2, max_elements: 0, max_bytes: 3),
      w152_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 2),
    ] of CrystalClick::BinaryCodecLimits

    one_short_limits.each do |limits|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor, limits)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.encode(type, limits)
      end
    end
  end

  it "preflights the parameterized SQL name within the bounded name budget" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 254)
    probe = CrystalClick::BinaryCodecBudget.new(w152_limits, true)
    bounds = CrystalClick::BinaryTypeNameBudget.measure(type, probe)

    exact = CrystalClick::BinaryCodecBudget.new(
      w152_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: bounds[1].to_i),
      true
    )
    exact_bounds = CrystalClick::BinaryTypeNameBudget.measure(type, exact)
    name = CrystalClick::BinaryTypeNameBudget.materialize(type, exact, exact_bounds)
    name.should eq("Dynamic(max_types=254)")
    name.bytesize.to_u64.should be <= exact_bounds[0]
    exact.wire_byte_count.should eq(exact_bounds[1].to_i64)

    one_short = CrystalClick::BinaryCodecBudget.new(
      w152_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: exact_bounds[1].to_i - 1),
      true
    )
    one_short_bounds = CrystalClick::BinaryTypeNameBudget.measure(type, one_short)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, one_short, one_short_bounds)
    end
  end
end
