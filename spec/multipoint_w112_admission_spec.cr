require "./spec_helper"

private def w112m_serialization(
  columns : String = %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":true}]),
  version : Int32 = 1,
  propagated : Bool = true,
  string_version : Int32 = 1,
  extra_root : String = "",
) : String
  %({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":#{propagated},"types_serialization_versions":{"string":#{string_version}},"version":#{version}#{extra_root}})
end

describe "W112 MultiPoint serialization admission" do
  it "admits exact-true Default accounting and keeps the W111 absent-flag profile readable" do
    ["MultiPoint", "MultiPolygon"].each do |type_name|
      columns = [{"pk", "UInt64"}, {"geo", type_name}]

      CrystalClick::GeoArraySerializationProfile.validate!(
        w112m_serialization,
        columns,
        "geo",
        4_u64
      ).should be_nil

      # W111's already-qualified serializer omitted exact_num_defaults. The
      # W112 extension must remain additive rather than invalidating that data.
      old_entry = %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4}])
      CrystalClick::GeoArraySerializationProfile.validate!(
        w112m_serialization(old_entry),
        columns,
        "geo",
        4_u64
      ).should be_nil
    end
  end

  it "accepts the exact all-empty columns profile without inferring PK values from it" do
    CrystalClick::GeoArraySerializationProfile.validate!(
      w112m_serialization(%([])),
      [{"pk", "UInt64"}, {"geo", "MultiPoint"}],
      "geo",
      4_u64
    ).should be_nil
  end

  it "rejects false, malformed, or extra Default flags and preserves row-count checks" do
    columns = [{"pk", "UInt64"}, {"geo", "MultiPoint"}]
    invalid = [
      %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":false}]),
      %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":"true"}]),
      %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":1}]),
      %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":null}]),
      %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"exact_num_defaults":true,"sampled":false}]),
    ]

    invalid.each do |records|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::GeoArraySerializationProfile.validate!(
          w112m_serialization(records),
          columns,
          "geo",
          4_u64
        )
      end
    end

    stale_rows = %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":3,"exact_num_defaults":true}])
    expect_raises(CrystalClick::CorruptPartError, "Geo Array primary-key serializer row count does not match part") do
      CrystalClick::GeoArraySerializationProfile.validate!(
        w112m_serialization(stale_rows),
        columns,
        "geo",
        4_u64
      )
    end

    invalid_default_count = %([{"kind":"Default","name":"pk","num_defaults":5,"num_rows":4,"exact_num_defaults":true}])
    expect_raises(CrystalClick::CorruptPartError, "Geo Array primary-key serializer default count is invalid") do
      CrystalClick::GeoArraySerializationProfile.validate!(
        w112m_serialization(invalid_default_count),
        columns,
        "geo",
        4_u64
      )
    end
  end

  it "keeps same-depth declarations distinct and rejects generic Array(Point) or Geometry aliases" do
    ["MultiPoint", "LineString", "Ring"].each do |type_name|
      plan = CrystalClick::GeoArrayColumnType.for_type(type_name).not_nil!
      plan.depth.should eq(1)
      plan.type_name.should eq(type_name)
      CrystalClick::GeoArraySerializationProfile.validate!(
        w112m_serialization,
        [{"pk", "UInt64"}, {"geo", type_name}],
        "geo",
        4_u64
      ).should be_nil
    end

    [
      [{"pk", "UInt64"}, {"geo", "Array(Point)"}],
      [{"pk", "UInt64"}, {"geo", "Geometry"}],
    ].each do |columns|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::GeoArraySerializationProfile.validate!(
          w112m_serialization,
          columns,
          "geo",
          4_u64
        )
      end
    end
  end
end
