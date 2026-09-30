require "./spec_helper"

describe CrystalClick::DecimalType do
  it "retains exact precision and scale while deriving the physical width" do
    {
      {1, 0, 4}, {9, 9, 4}, {10, 5, 8}, {18, 18, 8},
      {19, 4, 16}, {38, 38, 16}, {39, 20, 32}, {76, 76, 32},
    }.each do |precision, scale, storage_width|
      decimal = CrystalClick::DecimalType.new(precision, scale)
      decimal.precision.should eq(precision)
      decimal.scale.should eq(scale)
      decimal.storage_width.should eq(storage_width)
      decimal.width.should eq(storage_width)
      decimal.type_name.should eq("Decimal(#{precision}, #{scale})")
      CrystalClick::DecimalType.parse(decimal.type_name).should eq(decimal)
    end
  end

  it "rejects out-of-domain precision, scale, and noncanonical leaf spellings" do
    [{0, 0}, {77, 0}, {9, -1}, {9, 10}].each do |precision, scale|
      expect_raises(ArgumentError) { CrystalClick::DecimalType.new(precision, scale) }
    end

    [
      "Decimal(0, 0)", "Decimal(77, 0)", "Decimal(9, 10)",
      "Decimal(09, 2)", "Decimal(9, 02)", "Decimal(9,2)",
      "Decimal(9, 2 )", " Decimal(9, 2)", "Decimal(9,  2)",
      "Decimal(9, 2)trailing",
    ].each do |type_name|
      CrystalClick::DecimalType.parse(type_name).should be_nil
    end
  end

  it "uses exact P/S for equality and hash" do
    base = CrystalClick::DecimalType.new(21, 4)
    base.should eq(CrystalClick::DecimalType.new(21, 4))
    base.hash.should eq(CrystalClick::DecimalType.new(21, 4).hash)
    base.should_not eq(CrystalClick::DecimalType.new(21, 5))
    base.should_not eq(CrystalClick::DecimalType.new(22, 4))
  end

  it "fails closed for oversized and overflowing precision tokens" do
    [64, 65, 10_000].each do |size|
      type_name = "Decimal(" + "9" * (size - 12) + ", 0)"
      type_name.bytesize.should eq(size)
      CrystalClick::DecimalType.parse(type_name).should be_nil
    end
  end
end

describe CrystalClick::DecimalColumnType do
  it "round-trips exact metadata for all six admitted shapes" do
    [
      {"Decimal(37, 4)", CrystalClick::DecimalColumnShape::Scalar, false, 0},
      {"Nullable(Decimal(37, 4))", CrystalClick::DecimalColumnShape::NullableScalar, true, 0},
      {"Array(Decimal(37, 4))", CrystalClick::DecimalColumnShape::Array, false, 1},
      {"Array(Nullable(Decimal(37, 4)))", CrystalClick::DecimalColumnShape::ArrayNullable, true, 1},
      {"Array(Array(Decimal(37, 4)))", CrystalClick::DecimalColumnShape::ArrayArray, false, 2},
      {"Array(Array(Nullable(Decimal(37, 4))))", CrystalClick::DecimalColumnShape::ArrayArrayNullable, true, 2},
    ].each do |type_name, shape, nullable_leaf, array_depth|
      descriptor = CrystalClick::DecimalColumnType.parse(type_name).not_nil!
      descriptor.type_name.should eq(type_name)
      descriptor.shape.should eq(shape)
      descriptor.precision.should eq(37)
      descriptor.scale.should eq(4)
      descriptor.storage_width.should eq(16)
      descriptor.nullable_leaf?.should eq(nullable_leaf)
      descriptor.array_depth.should eq(array_depth)
      CrystalClick::DecimalColumnType.parse(descriptor.type_name).should eq(descriptor)
    end
  end

  it "separates strict persisted parsing from catalog shorthand normalization" do
    strict_alias = "Array(Decimal128(2))"
    CrystalClick::DecimalColumnType.parse(strict_alias).should be_nil
    CrystalClick::DecimalColumnType.catalog_type(strict_alias).should eq("Array(Decimal(38, 2))")
    CrystalClick::DecimalColumnType.catalog_type("Decimal(20)").should eq("Decimal(20, 0)")
    CrystalClick::DecimalColumnType.catalog_type("Decimal").should eq("Decimal(10, 0)")
    CrystalClick::DecimalColumnType.catalog_type("Nullable(Decimal)").should eq("Nullable(Decimal(10, 0))")
    CrystalClick::DecimalColumnType.catalog_type("Array(Decimal256(76))").should eq("Array(Decimal(76, 76))")
  end

  it "rejects malformed wrappers and forged shapes" do
    [
      "Nullable(Array(Decimal(37, 4)))",
      "Array(Array(Array(Decimal(37, 4))))",
      "Array(Array(Nullable(Decimal(37, 4)))",
      "Array(Nullable(Nullable(Decimal(37, 4))))",
      "Array(Decimal(37, 4)junk)",
      "Array(Decimal(037, 4))",
    ].each do |type_name|
      CrystalClick::DecimalColumnType.parse(type_name).should be_nil
    end

    invalid_shape = 99_i32.unsafe_as(CrystalClick::DecimalColumnShape)
    expect_raises(ArgumentError) do
      CrystalClick::DecimalColumnType.new(CrystalClick::DecimalType.new(20, 4), invalid_shape)
    end
  end

  it "includes both exact decimal metadata and shape in equality and hash" do
    base = CrystalClick::DecimalColumnType.parse("Array(Decimal(21, 4))").not_nil!
    base.should eq(CrystalClick::DecimalColumnType.parse("Array(Decimal(21, 4))").not_nil!)
    base.hash.should eq(CrystalClick::DecimalColumnType.parse("Array(Decimal(21, 4))").not_nil!.hash)
    base.should_not eq(CrystalClick::DecimalColumnType.parse("Array(Decimal(21, 5))").not_nil!)
    base.should_not eq(CrystalClick::DecimalColumnType.parse("Array(Array(Decimal(21, 4)))").not_nil!)
  end

  it "rejects bounded-edge and oversized declarations in both parser contexts" do
    [128, 129, 10_000].each do |size|
      type_name = "Array(Decimal(" + "9" * (size - 19) + ", 0))"
      type_name.bytesize.should eq(size)
      CrystalClick::DecimalColumnType.parse(type_name).should be_nil
      CrystalClick::DecimalColumnType.parse_catalog(type_name).should be_nil
    end
  end
end
