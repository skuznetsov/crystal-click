require "./spec_helper"

private class JsonTypedPathBoolOverrideSpecWidePart < CrystalClick::WidePart
  def self.supports_numeric_type?(type : String) : Bool
    type == "Bool" || CrystalClick::WidePart.supports_numeric_type?(type)
  end
end

private class JsonTypedPathCustomListSpecWidePart < CrystalClick::WidePart
  def self.json_typed_paths(_type : String) : Array({String, String})
    [{"custom.path", "UInt64"}]
  end
end

describe "WidePart JSON typed-path declaration characterization" do
  it "preserves declaration order, spacing, and every admitted primitive type" do
    type = "JSON( u8 UInt8 , u16 UInt16, u32 UInt32, u64 UInt64, i8 Int8, i16 Int16, i32 Int32, i64 Int64, f32 Float32, f64 Float64, label String )"

    CrystalClick::WidePart.json_typed_paths(type).should eq([
      {"u8", "UInt8"},
      {"u16", "UInt16"},
      {"u32", "UInt32"},
      {"u64", "UInt64"},
      {"i8", "Int8"},
      {"i16", "Int16"},
      {"i32", "Int32"},
      {"i64", "Int64"},
      {"f32", "Float32"},
      {"f64", "Float64"},
      {"label", "String"},
    ])
  end

  it "looks up only an exact declared path and returns nil for missing paths" do
    type = "JSON(a UInt64, ab String)"

    CrystalClick::WidePart.json_typed_path_type(type, "a").should eq("UInt64")
    CrystalClick::WidePart.json_typed_path_type(type, "ab").should eq("String")
    CrystalClick::WidePart.json_typed_path_type(type, "a.b").should be_nil
    CrystalClick::WidePart.json_typed_path_type(type, "missing").should be_nil
  end

  it "reports a duplicate before validating the duplicate declaration's scalar type" do
    invalid_type = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.json_typed_paths("JSON(a Bool)")
    end
    invalid_type.message.not_nil!.should eq("unsupported JSON typed-path scalar type")

    duplicate = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.json_typed_paths("JSON(a UInt64, a Bool)")
    end
    duplicate.message.not_nil!.should eq("duplicate JSON typed path")
  end

  it "preserves current bare, empty, malformed, unterminated, and trailing-entry errors" do
    cases = [
      {"JSON", "JSON column has no explicit typed paths"},
      {"JSON()", "empty JSON typed-path declaration"},
      {"JSON(a UInt64))", "malformed JSON typed-path declaration"},
      {"JSON(a Tuple(UInt64)", "malformed JSON typed-path declaration"},
      {"JSON(a UInt64", "JSON column has no explicit typed paths"},
      {"JSON(a UInt64, )", "unsupported JSON typed-path declaration"},
    ]

    cases.each do |type, message|
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.json_typed_paths(type)
      end
      error.message.not_nil!.should eq(message)
    end
  end

  it "continues to refuse Bool, wrappers, containers, and non-simple paths" do
    cases = [
      {"JSON(flag Bool)", "unsupported JSON typed-path scalar type"},
      {"JSON(value Nullable(UInt64))", "unsupported JSON typed-path declaration"},
      {"JSON(value Array(UInt64))", "unsupported JSON typed-path declaration"},
      {"JSON(a.b UInt64)", "unsupported JSON typed-path declaration"},
      {"JSON(`a` UInt64)", "unsupported JSON typed-path declaration"},
    ]

    cases.each do |type, message|
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.json_typed_paths(type)
      end
      error.message.not_nil!.should eq(message)
    end
  end

  it "returns a fresh declaration list after callers mutate an earlier result" do
    type = "JSON(a UInt64, b String)"
    expected = [{"a", "UInt64"}, {"b", "String"}]

    first = CrystalClick::WidePart.json_typed_paths(type)
    first.clear

    CrystalClick::WidePart.json_typed_paths(type).should eq(expected)
  end

  it "honors a subclass numeric-type override through inherited declaration APIs" do
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.json_typed_paths("JSON(flag Bool)")
    end
    error.message.not_nil!.should eq("unsupported JSON typed-path scalar type")

    JsonTypedPathBoolOverrideSpecWidePart.json_typed_paths("JSON(flag Bool)").should eq([
      {"flag", "Bool"},
    ])
    JsonTypedPathBoolOverrideSpecWidePart.json_typed_path_type("JSON(flag Bool)", "flag").should eq("Bool")
  end

  it "honors an overridden public declaration list through inherited path lookup" do
    type = "JSON(base UInt64)"

    JsonTypedPathCustomListSpecWidePart.json_typed_path_type(type, "custom.path").should eq("UInt64")
    JsonTypedPathCustomListSpecWidePart.json_typed_path_type(type, "missing").should be_nil
  end
end
