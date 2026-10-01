require "./spec_helper"

private def w101_enum_type(type_name : String, entries : Array(Tuple(String, Int32))) : String
  "#{type_name}(#{entries.map { |entry| "'#{entry[0]}' = #{entry[1]}" }.join(", ")})"
end

describe "W101 parameterized Tuple leaf type plan" do
  it "preserves existing Tuple controls and outer member whitespace behavior" do
    source = "Tuple( value UInt64 , label String  )"
    plan = CrystalClick::WideTupleTypePlan.for_type(source)
    plan.should_not be_nil

    if plan
      plan.type_name.should eq("Tuple(value UInt64, label String)")
      plan.fields.map(&.name).should eq(["value", "label"])
      plan.fields.map(&.type_name).should eq(["UInt64", "String"])
    end
  end

  it "admits every canonical Decimal(P, S) declaration and preserves both parameters" do
    checked = 0
    mismatch_count = 0
    mismatch_samples = [] of String

    (1..76).each do |precision|
      (0..precision).each do |scale|
        checked += 1
        leaf_type = "Decimal(#{precision}, #{scale})"
        source = "Tuple(value #{leaf_type})"
        plan = CrystalClick::WideTupleTypePlan.for_type(source)

        unless plan && plan.type_name == source && plan.fields.size == 1 && plan.fields[0].type_name == leaf_type
          mismatch_count += 1
          mismatch_samples << "P=#{precision},S=#{scale}: #{plan.try(&.type_name) || "rejected"}" if mismatch_samples.size < 8
        end
      end
    end

    checked.should eq(3_002)
    mismatch_count.should eq(0)
    mismatch_samples.should be_empty
  end

  it "normalizes every decimal width alias, Decimal(P), and bare Decimal" do
    width_aliases = [] of Tuple(String, String)
    [
      {"Decimal32", 9, 9},
      {"Decimal64", 18, 18},
      {"Decimal128", 38, 38},
      {"Decimal256", 76, 76},
    ].each do |alias_name, precision, maximum_scale|
      (0..maximum_scale).each do |scale|
        width_aliases << {
          "Tuple(value #{alias_name}(#{scale}))",
          "Tuple(value Decimal(#{precision}, #{scale}))",
        }
      end
    end

    width_aliases.size.should eq(145)
    width_alias_mismatches = [] of String
    width_aliases.each do |source, expected|
      plan = CrystalClick::WideTupleTypePlan.for_type(source)
      actual = plan.try(&.type_name)
      width_alias_mismatches << "#{source} -> #{actual || "rejected"}" if actual != expected
    end
    width_alias_mismatches.first(8).should be_empty
    width_alias_mismatches.size.should eq(0)

    precision_alias_mismatches = [] of String
    (1..76).each do |precision|
      source = "Tuple(value Decimal(#{precision}))"
      expected = "Tuple(value Decimal(#{precision}, 0))"
      actual = CrystalClick::WideTupleTypePlan.for_type(source).try(&.type_name)
      precision_alias_mismatches << "#{source} -> #{actual || "rejected"}" if actual != expected && precision_alias_mismatches.size < 8
    end
    precision_alias_mismatches.should be_empty

    bare = CrystalClick::WideTupleTypePlan.for_type("Tuple(value Decimal)")
    bare.try(&.type_name).should eq("Tuple(value Decimal(10, 0))")
  end

  it "selects Decimal storage widths at every precision-band boundary" do
    mismatches = [] of String
    [
      {1, 4},
      {9, 4},
      {10, 8},
      {18, 8},
      {19, 16},
      {38, 16},
      {39, 32},
      {76, 32},
    ].each do |precision, expected_width|
      [0, precision].uniq.each do |scale|
        source = "Tuple(value Decimal(#{precision}, #{scale}))"
        plan = CrystalClick::WideTupleTypePlan.for_type(source)
        actual_width = plan.try(&.stream_width("payload", "payload%2Evalue"))
        unless actual_width == expected_width
          mismatches << "P=#{precision},S=#{scale}: #{actual_width || "rejected"}" if mismatches.size < 8
        end
      end
    end

    mismatches.should be_empty
  end

  it "admits FixedString at both bounds as one exact-width raw stream" do
    mismatches = [] of String
    [1, 65_536].each do |width|
      source = "Tuple(value FixedString(#{width}))"
      plan = CrystalClick::WideTupleTypePlan.for_type(source)
      unless plan && plan.type_name == source && plan.fields.size == 1 &&
             plan.fields[0].type_name == "FixedString(#{width})" &&
             plan.physical_streams("payload") == ["payload%2Evalue"] &&
             plan.stream_width("payload", "payload%2Evalue") == width &&
             !plan.raw_string_stream?("payload", "payload%2Evalue")
        mismatches << source
      end
    end

    mismatches.should be_empty
  end

  it "canonicalizes escaped Enum labels without applying leaf guards inside quotes" do
    labels = [
      "",
      "quote\\'mark",
      "back\\\\slash",
      "backspace\\b",
      "formfeed\\f",
      "newline\\n",
      "return\\r",
      "tab\\t",
      "nul\\0",
      "punctuation, (parens) = equals",
      "unicode-λ",
      "UInt64()",
      "DateTime64 (3)",
    ]
    entries = [] of Tuple(String, Int32)
    labels.each_with_index do |label, index|
      entries << {label, (labels.size - index - 1).to_i32}
    end

    source_enum = w101_enum_type("Enum16", entries)
    source = "Tuple(value #{source_enum})"
    expected_enum = w101_enum_type("Enum16", entries.sort_by { |entry| entry[1] })
    expected = "Tuple(value #{expected_enum})"
    plan = CrystalClick::WideTupleTypePlan.for_type(source)
    plan.try(&.type_name).should eq(expected)

    if plan
      plan.fields[0].type_name.should eq(expected_enum)
      plan.physical_streams("payload").should eq(["payload%2Evalue"])
      plan.stream_width("payload", "payload%2Evalue").should eq(2)
    end
  end

  it "preserves Enum8 and Enum16 signed-code boundaries and a mixed three-family Tuple" do
    enum8_entries = [{"max", 127_i32}, {"min", -128_i32}] of Tuple(String, Int32)
    enum16_entries = [{"max", 32_767_i32}, {"min", -32_768_i32}] of Tuple(String, Int32)
    enum8 = w101_enum_type("Enum8", enum8_entries)
    enum16 = w101_enum_type("Enum16", enum16_entries)
    cases = [
      {"Tuple(value #{enum8})", "Tuple(value #{w101_enum_type("Enum8", enum8_entries.sort_by { |entry| entry[1] })})", 1},
      {"Tuple(value #{enum16})", "Tuple(value #{w101_enum_type("Enum16", enum16_entries.sort_by { |entry| entry[1] })})", 2},
    ]

    mismatches = [] of String
    cases.each do |source, expected, width|
      plan = CrystalClick::WideTupleTypePlan.for_type(source)
      unless plan && plan.type_name == expected && plan.stream_width("payload", "payload%2Evalue") == width
        mismatches << source if mismatches.size < 8
      end
    end

    mixed = "Tuple(code Enum8('active' = 3, 'inactive' = -1), id FixedString(16), amount Decimal(18, 4))"
    mixed_expected = "Tuple(code Enum8('inactive' = -1, 'active' = 3), id FixedString(16), amount Decimal(18, 4))"
    mixed_plan = CrystalClick::WideTupleTypePlan.for_type(mixed)
    unless mixed_plan && mixed_plan.type_name == mixed_expected &&
           mixed_plan.fields.map(&.type_name) == ["Enum8('inactive' = -1, 'active' = 3)", "FixedString(16)", "Decimal(18, 4)"] &&
           mixed_plan.physical_streams("payload") == ["payload%2Ecode", "payload%2Eid", "payload%2Eamount"] &&
           mixed_plan.stream_width("payload", "payload%2Ecode") == 1 &&
           mixed_plan.stream_width("payload", "payload%2Eid") == 16 &&
           mixed_plan.stream_width("payload", "payload%2Eamount") == 8
      mismatches << "mixed FixedString/Enum/Decimal Tuple" if mismatches.size < 8
    end

    mismatches.should be_empty
  end

  it "rejects malformed, noncanonical, out-of-range, duplicate, nested, and oversized candidates" do
    rejected = [
      "Tuple(value FixedString)",
      "Tuple(value FixedString(0))",
      "Tuple(value FixedString(01))",
      "Tuple(value FixedString(+1))",
      "Tuple(value FixedString( 1))",
      "Tuple(value FixedString(1 ))",
      "Tuple(value FixedString(65537))",
      "Tuple(value Decimal(0, 0))",
      "Tuple(value Decimal(1, 2))",
      "Tuple(value Decimal(1, 00))",
      "Tuple(value Decimal(01, 0))",
      "Tuple(value Decimal(1, +0))",
      "Tuple(value Decimal(1, 0 ))",
      "Tuple(value Decimal32(10))",
      "Tuple(value Decimal64(19))",
      "Tuple(value Decimal128(39))",
      "Tuple(value Decimal256(77))",
      "Tuple(value Enum8())",
      "Tuple(value Enum8('a' = -129))",
      "Tuple(value Enum8('a' = 128))",
      "Tuple(value Enum16('a' = -32769))",
      "Tuple(value Enum16('a' = 32768))",
      "Tuple(value Enum8('a' = 0, 'a' = 1))",
      "Tuple(value Enum8('' = 0, '' = 1))",
      "Tuple(value Enum8('a' = 0, 'b' = 0))",
      "Tuple(value Enum8('unknown\\q' = 0))",
      "Tuple(value Enum8('trailing\\' = 0))",
      "Tuple(value Enum8('a' = +0))",
      "Tuple(value Enum8('a' = 00))",
      "Tuple(value Enum8('a' = -0))",
      "Tuple(value Enum8('a' = 0, ))",
      "Tuple(value Enum8('raw\ncontrol' = 0))",
      "Tuple(value Tuple(inner Array(UInt64)))",
      "Tuple(UInt64, String)",
      "Tuple()",
      "Tuple(value Decimal(9, 2), value String)",
      "Tuple(value Decimal(9, 2)) trailing",
    ]

    rejected.each do |source|
      CrystalClick::WideTupleTypePlan.for_type(source).should be_nil
    end

    CrystalClick::WideTupleTypePlan.for_type("Tuple(value Tuple(inner UInt64))").should_not be_nil

    nested_leaf = "Array(" * 65 + "UInt64" + ")" * 65
    CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{nested_leaf})").should be_nil

    long_label = "x" * 4_100
    over_source_limit = "Tuple(value Enum8('#{long_label}' = 0))"
    over_source_limit.bytesize.should be > 4_096
    CrystalClick::WideTupleTypePlan.for_type(over_source_limit).should be_nil
  end

  it "keeps old Array(Tuple) physical admission unchanged and does not inherit W101 leaves" do
    old_type = "Array(Tuple(a UInt64, b String))"
    CrystalClick::WideTypePlan.admitted(old_type).should_not be_nil
    CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(old_type).should_not be_nil

    [
      "Array(Tuple(a FixedString(3), b String))",
      "Array(Tuple(a Decimal(9, 2), b String))",
      "Array(Tuple(a Enum8('x' = 0), b String))",
    ].each do |type|
      CrystalClick::WideTypePlan.admitted(type).should be_nil
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
