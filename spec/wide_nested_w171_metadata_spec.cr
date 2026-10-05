require "./spec_helper"

private def w171m_metadata(
  column_records : String = %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":5,"exact_num_defaults":true}]),
  version : Int32 = 1,
  propagated : Bool = true,
  string_version : Int32 = 1,
  extra_root : String = "",
) : String
  %({"columns":#{column_records},"propagate_types_serialization_versions_to_nested_types":#{propagated},"types_serialization_versions":{"string":#{string_version}},"version":#{version}#{extra_root}})
end

private def w171m_nested_columns : Array({String, String})
  [{"pk", "UInt64"}, {"payload", "Nested(a UInt64, b String)"}]
end

describe "W171 Nested serialization metadata admission" do
  it "accepts the exact observed Nested and UInt64-key envelope" do
    observed = %({"columns":[{"kind":"Default","name":"pk","num_defaults":1,"num_rows":5,"exact_num_defaults":true}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})

    CrystalClick::NestedSerializationProfile.validate!(
      observed, w171m_nested_columns, "payload", "Nested(a UInt64, b String)", 5_u64
    ).should be_nil
  end

  it "rejects unsupported versions, propagation, String versions, and extra records or fields" do
    invalid = [
      w171m_metadata(version: 2),
      w171m_metadata(propagated: false),
      w171m_metadata(string_version: 2),
      w171m_metadata(extra_root: ",\"sampled\":true"),
      w171m_metadata(column_records: %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":5,"exact_num_defaults":true},{"kind":"Default","name":"payload","num_defaults":0,"num_rows":5,"exact_num_defaults":true}])),
      w171m_metadata(column_records: %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":5}])),
    ]

    invalid.each do |text|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::NestedSerializationProfile.validate!(
          text, w171m_nested_columns, "payload", "Nested(a UInt64, b String)", 5_u64
        )
      end
    end
  end

  it "classifies malformed JSON and inconsistent key statistics as corrupt" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::NestedSerializationProfile.validate!(
        "{malformed", w171m_nested_columns, "payload", "Nested(a UInt64, b String)", 5_u64
      )
    end

    wrong_rows = w171m_metadata(
      column_records: %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":true}])
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::NestedSerializationProfile.validate!(
        wrong_rows, w171m_nested_columns, "payload", "Nested(a UInt64, b String)", 5_u64
      )
    end

    invalid_defaults = w171m_metadata(
      column_records: %([{"kind":"Default","name":"pk","num_defaults":6,"num_rows":5,"exact_num_defaults":true}])
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::NestedSerializationProfile.validate!(
        invalid_defaults, w171m_nested_columns, "payload", "Nested(a UInt64, b String)", 5_u64
      )
    end
  end

  it "rejects a non-Nested selected type and any third part column" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::NestedSerializationProfile.validate!(
        w171m_metadata,
        [{"pk", "UInt64"}, {"payload", "Array(Tuple(a UInt64, b String))"}],
        "payload",
        "Array(Tuple(a UInt64, b String))",
        5_u64
      )
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::NestedSerializationProfile.validate!(
        w171m_metadata,
        [{"pk", "UInt64"}, {"payload", "Nested(a UInt64, b String)"}, {"extra", "UInt64"}],
        "payload",
        "Nested(a UInt64, b String)",
        5_u64
      )
    end
  end
end
