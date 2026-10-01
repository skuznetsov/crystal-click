require "./spec_helper"

private def w111_geo_serialization(columns : String = %([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4}]), version : Int32 = 1, propagated : Bool = true, string_version : Int32 = 1, extra_root : String = "") : String
  %({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":#{propagated},"types_serialization_versions":{"string":#{string_version}},"version":#{version}#{extra_root}})
end

describe CrystalClick::GeoArraySerializationProfile do
  it "admits the exact version-one envelope with only a PK Default record or empty records" do
    columns = [{"pk", "UInt64"}, {"shape", "MultiPolygon"}]

    CrystalClick::GeoArraySerializationProfile.validate!(
      w111_geo_serialization,
      columns,
      "shape",
      4_u64
    ).should be_nil

    CrystalClick::GeoArraySerializationProfile.validate!(
      w111_geo_serialization(%([])),
      columns,
      "shape",
      4_u64
    ).should be_nil
  end

  it "rejects unsupported root envelopes and non-Default or recursive Geo statistics" do
    columns = [{"pk", "UInt64"}, {"shape", "LineString"}]
    invalid = [
      w111_geo_serialization(version: 2),
      w111_geo_serialization(propagated: false),
      w111_geo_serialization(string_version: 0),
      w111_geo_serialization(extra_root: %[,"unknown":true]),
      w111_geo_serialization(%([{"kind":"Sparse","name":"pk","num_defaults":1,"num_rows":4}])),
      w111_geo_serialization(%([{"kind":"Default","name":"shape","num_defaults":1,"num_rows":4}])),
      w111_geo_serialization(%([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4,"subcolumns":[]}])),
      w111_geo_serialization(%([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":4},{"kind":"Default","name":"shape","num_defaults":1,"num_rows":4}])),
    ]

    invalid.each do |text|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::GeoArraySerializationProfile.validate!(text, columns, "shape", 4_u64)
      end
    end

    stale_count = w111_geo_serialization(%([{"kind":"Default","name":"pk","num_defaults":1,"num_rows":3}]))
    expect_raises(CrystalClick::CorruptPartError, "Geo Array primary-key serializer row count does not match part") do
      CrystalClick::GeoArraySerializationProfile.validate!(stale_count, columns, "shape", 4_u64)
    end

    missing_columns = %({"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
    expect_raises(CrystalClick::UnsupportedFormatError, "unsupported Geo Array serialization.json fields") do
      CrystalClick::GeoArraySerializationProfile.validate!(missing_columns, columns, "shape", 4_u64)
    end
  end

  it "requires exactly one nominal Geo column paired with a UInt64 primary key" do
    valid_serialization = w111_geo_serialization
    invalid_columns = [
      [{"pk", "UInt64"}],
      [{"pk", "UInt64"}, {"shape", "Geometry"}],
      [{"pk", "UInt64"}, {"shape", "MultiPoint"}],
      [{"pk", "UInt32"}, {"shape", "MultiPolygon"}],
      [{"pk", "UInt64"}, {"shape", "MultiPolygon"}, {"extra", "String"}],
    ]

    invalid_columns.each do |columns|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::GeoArraySerializationProfile.validate!(
          valid_serialization,
          columns,
          "shape",
          4_u64
        )
      end
    end
  end
end
