require "./spec_helper"

W102_DECIMAL_SHAPES   = [:scalar, :nullable_scalar, :array, :array_nullable, :array_array, :array_array_nullable]
W102_DECIMAL_FAMILIES = [{9, 4}, {18, 8}, {38, 16}, {76, 32}]

private def w102_decimal_shapes : Array(Symbol)
  W102_DECIMAL_SHAPES
end

private def w102_shape_type(leaf_type : String, shape : Symbol) : String
  case shape
  when :scalar
    leaf_type
  when :nullable_scalar
    "Nullable(#{leaf_type})"
  when :array
    "Array(#{leaf_type})"
  when :array_nullable
    "Array(Nullable(#{leaf_type}))"
  when :array_array
    "Array(Array(#{leaf_type}))"
  when :array_array_nullable
    "Array(Array(Nullable(#{leaf_type})))"
  else
    raise ArgumentError.new("unknown W102 Decimal shape: #{shape}")
  end
end

private def w102_family_scale(type : String, shape : Symbol, family_precision : Int32) : Int32?
  case shape
  when :scalar
    case family_precision
    when  9 then CrystalClick::WidePart.decimal32_scale(type)
    when 18 then CrystalClick::WidePart.decimal64_scale(type)
    when 38 then CrystalClick::WidePart.decimal128_scale(type)
    when 76 then CrystalClick::WidePart.decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  when :nullable_scalar
    case family_precision
    when  9 then CrystalClick::WidePart.nullable_decimal32_scale(type)
    when 18 then CrystalClick::WidePart.nullable_decimal64_scale(type)
    when 38 then CrystalClick::WidePart.nullable_decimal128_scale(type)
    when 76 then CrystalClick::WidePart.nullable_decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  when :array
    case family_precision
    when  9 then CrystalClick::WidePart.array_decimal32_scale(type)
    when 18 then CrystalClick::WidePart.array_decimal64_scale(type)
    when 38 then CrystalClick::WidePart.array_decimal128_scale(type)
    when 76 then CrystalClick::WidePart.array_decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  when :array_nullable
    case family_precision
    when  9 then CrystalClick::WidePart.array_nullable_decimal32_scale(type)
    when 18 then CrystalClick::WidePart.array_nullable_decimal64_scale(type)
    when 38 then CrystalClick::WidePart.array_nullable_decimal128_scale(type)
    when 76 then CrystalClick::WidePart.array_nullable_decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  when :array_array
    case family_precision
    when  9 then CrystalClick::WidePart.array_array_decimal32_scale(type)
    when 18 then CrystalClick::WidePart.array_array_decimal64_scale(type)
    when 38 then CrystalClick::WidePart.array_array_decimal128_scale(type)
    when 76 then CrystalClick::WidePart.array_array_decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  when :array_array_nullable
    case family_precision
    when  9 then CrystalClick::WidePart.array_array_nullable_decimal32_scale(type)
    when 18 then CrystalClick::WidePart.array_array_nullable_decimal64_scale(type)
    when 38 then CrystalClick::WidePart.array_array_nullable_decimal128_scale(type)
    when 76 then CrystalClick::WidePart.array_array_nullable_decimal256_scale(type)
    else         raise ArgumentError.new("unknown W102 Decimal family: #{family_precision}")
    end
  else
    raise ArgumentError.new("unknown W102 Decimal shape: #{shape}")
  end
end

private def w102_expected_family(precision : Int32) : Tuple(Int32, Int32)
  if precision <= 9
    {9, 4}
  elsif precision <= 18
    {18, 8}
  elsif precision <= 38
    {38, 16}
  else
    {76, 32}
  end
end

describe "W102 non-Tuple Decimal precision admission" do
  it "admits all 3,002 canonical P/S declarations in all six shapes with the matching width" do
    declaration_count = 0
    shape_count = 0
    family_check_count = 0
    admission_mismatches = 0
    width_mismatches = 0
    metadata_mismatches = 0
    admission_samples = [] of String
    width_samples = [] of String
    metadata_samples = [] of String

    (1..76).each do |precision|
      (0..precision).each do |scale|
        declaration_count += 1
        leaf_type = "Decimal(#{precision}, #{scale})"
        expected_family, expected_width = w102_expected_family(precision.to_i32)

        w102_decimal_shapes.each do |shape|
          shape_count += 1
          type = w102_shape_type(leaf_type, shape)

          unless CrystalClick::WidePart.supports_typed_type?(type)
            admission_mismatches += 1
            admission_samples << type if admission_samples.size < 8
          end

          if CrystalClick::WidePart.catalog_type(type) != type
            metadata_mismatches += 1
            metadata_samples << "#{type} -> #{CrystalClick::WidePart.catalog_type(type) || "rejected"}" if metadata_samples.size < 8
          end

          family_widths = [] of Int32
          W102_DECIMAL_FAMILIES.each do |family, width|
            family_check_count += 1
            actual_scale = w102_family_scale(type, shape, family)
            expected_scale = family == expected_family ? scale.to_i32 : nil
            if actual_scale != expected_scale
              width_mismatches += 1
              width_samples << "#{type}, family P=#{family}: #{actual_scale || "rejected"}" if width_samples.size < 8
            end
            family_widths << width if actual_scale
          end

          if family_widths != [expected_width]
            width_mismatches += 1
            width_samples << "#{type}: widths #{family_widths}, expected [#{expected_width}]" if width_samples.size < 8
          end
        end
      end
    end

    declaration_count.should eq(3_002)
    shape_count.should eq(18_012)
    family_check_count.should eq(72_048)
    admission_mismatches.should eq(0), "#{admission_mismatches} admission mismatches; samples: #{admission_samples}"
    width_mismatches.should eq(0), "#{width_mismatches} family/width mismatches; samples: #{width_samples}"
    metadata_mismatches.should eq(0), "#{metadata_mismatches} exact catalog metadata mismatches; samples: #{metadata_samples}"
  end

  it "retains all existing max-precision positives as controls" do
    checks = 0
    mismatches = [] of String

    {9, 18, 38, 76}.each do |precision|
      [0, precision // 2, precision].uniq.each do |scale|
        leaf_type = "Decimal(#{precision}, #{scale})"
        w102_decimal_shapes.each do |shape|
          checks += 1
          type = w102_shape_type(leaf_type, shape)
          actual = w102_family_scale(type, shape, precision)
          unless CrystalClick::WidePart.supports_typed_type?(type) && actual == scale && CrystalClick::WidePart.catalog_type(type) == type
            mismatches << type if mismatches.size < 8
          end
        end
      end
    end

    checks.should eq(72)
    mismatches.should be_empty, "#{mismatches.size} max-precision controls failed; samples: #{mismatches}"
  end

  it "normalizes width aliases, Decimal(P), and bare Decimal only at the catalog boundary" do
    alias_checks = 0
    alias_mismatches = [] of String
    [
      {"Decimal32", 9, 9},
      {"Decimal64", 18, 18},
      {"Decimal128", 38, 38},
      {"Decimal256", 76, 76},
    ].each do |alias_name, precision, max_scale|
      (0..max_scale).each do |scale|
        source_leaf = "#{alias_name}(#{scale})"
        canonical_leaf = "Decimal(#{precision}, #{scale})"
        w102_decimal_shapes.each do |shape|
          alias_checks += 1
          source = w102_shape_type(source_leaf, shape)
          expected = w102_shape_type(canonical_leaf, shape)
          actual = CrystalClick::WidePart.catalog_type(source)
          alias_mismatches << "#{source} -> #{actual || "rejected"}" if actual != expected && alias_mismatches.size < 8
        end
      end
    end

    precision_checks = 0
    precision_mismatches = [] of String
    (1..76).each do |precision|
      source_leaf = "Decimal(#{precision})"
      canonical_leaf = "Decimal(#{precision}, 0)"
      w102_decimal_shapes.each do |shape|
        precision_checks += 1
        source = w102_shape_type(source_leaf, shape)
        expected = w102_shape_type(canonical_leaf, shape)
        actual = CrystalClick::WidePart.catalog_type(source)
        precision_mismatches << "#{source} -> #{actual || "rejected"}" if actual != expected && precision_mismatches.size < 8
      end
    end

    bare_checks = 0
    bare_mismatches = [] of String
    w102_decimal_shapes.each do |shape|
      bare_checks += 1
      source = w102_shape_type("Decimal", shape)
      expected = w102_shape_type("Decimal(10, 0)", shape)
      actual = CrystalClick::WidePart.catalog_type(source)
      bare_mismatches << "#{source} -> #{actual || "rejected"}" if actual != expected && bare_mismatches.size < 8
    end

    alias_checks.should eq(870)
    precision_checks.should eq(456)
    bare_checks.should eq(6)
    alias_mismatches.should be_empty, "#{alias_mismatches.size} width-alias mismatches; samples: #{alias_mismatches}"
    precision_mismatches.should be_empty, "#{precision_mismatches.size} Decimal(P) mismatches; samples: #{precision_mismatches}"
    bare_mismatches.should be_empty, "#{bare_mismatches.size} bare Decimal mismatches; samples: #{bare_mismatches}"
  end

  it "rejects malformed and noncanonical declarations in every supported shape" do
    malformed_leaves = [
      "Decimal(0, 0)",
      "Decimal(77, 0)",
      "Decimal(9, 10)",
      "Decimal(09, 2)",
      "Decimal(9, 02)",
      "Decimal(9,2)",
      "Decimal(9, 2 )",
      "Decimal( 9, 2)",
      "Decimal(9,  2)",
      "Decimal(-1, 0)",
    ]
    checks = 0
    failures = [] of String

    malformed_leaves.each do |leaf_type|
      w102_decimal_shapes.each do |shape|
        checks += 1
        type = w102_shape_type(leaf_type, shape)
        failures << type if CrystalClick::WidePart.supports_typed_type?(type) && failures.size < 8
      end
    end

    [
      "Nullable(Array(Decimal(9, 2)))",
      "Nullable(Array(Nullable(Decimal(9, 2))))",
      "Array(Array(Array(Decimal(9, 2))))",
      "Array(Array(Array(Nullable(Decimal(9, 2)))))",
    ].each do |type|
      checks += 1
      failures << type if CrystalClick::WidePart.supports_typed_type?(type) && failures.size < 8
    end

    checks.should eq(64)
    failures.should be_empty, "#{failures.size} malformed/unsupported shapes admitted; samples: #{failures}"
  end
end
