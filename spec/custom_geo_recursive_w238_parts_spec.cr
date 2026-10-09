require "./spec_helper"
require "file_utils"

private def w238p_geo(type : CrystalClick::BinaryDataType, seed : Int32) : CrystalClick::BinaryValue
  body_type = type.child_at(0)
  body = if body_type.tag == CrystalClick::BinaryDataType::TAG_ARRAY
           children = Array(CrystalClick::BinaryValue).new(seed % 3) do |index|
             w238p_geo(body_type.child_at(0), seed + index + 1)
           end
           CrystalClick::BinaryValue.array(body_type, children)
         else
           CrystalClick::BinaryValue.tuple(body_type, [
             CrystalClick::BinaryValue.float64_bits(0x8000_0000_0000_0000_u64),
             CrystalClick::BinaryValue.float64_bits(0x7ff8_0000_0000_1234_u64),
           ] of CrystalClick::BinaryValue)
         end
  CrystalClick::BinaryValue.custom(type, body)
end

private def w238p_check_geo(actual : CrystalClick::WideGeoArrayRow, expected : CrystalClick::BinaryValue) : Nil
  body = expected.child_at(0)
  actual.size.should eq(body.child_count)
  body.child_count.times do |index|
    child = body.child_at(index)
    if child.type.name == "Point"
      point = actual.point_at(index)
      point.x_bits.should eq(child.child_at(0).child_at(0).as_float64_bits)
      point.y_bits.should eq(child.child_at(0).child_at(1).as_float64_bits)
    else
      w238p_check_geo(actual.array_at(index), child)
    end
  end
end

describe "W238 Custom Geo public part admission" do
  it "admits only plain static owner combinations and leaves bare Geo consumers on their legacy API" do
    names = ["Point", "MultiPoint", "LineString", "Ring", "MultiLineString", "Polygon", "MultiPolygon"]
    names.each do |name|
      type = CrystalClick::BinaryDataType.custom(name)
      declaration = CrystalClick::BinaryCustomGeoBulkColumnDeclaration.new(type)
      declaration.declaration.should eq(name)
      CrystalClick::BinaryCustomGeoBulkColumnDeclaration.parse(name).should eq(type)
      CrystalClick::WidePart.supports_custom_geo_bulk_type?(name).should be_false
      CrystalClick::WidePart.supports_custom_geo_bulk_type?("Array(#{name})").should be_true
    end
    [
      "String", "Geometry", "LowCardinality(Point)", "Nullable(LineString)",
      "Tuple(Point, LowCardinality(String))", "Tuple(Point, Dynamic)",
      "Tuple(Point, QBit(Float32, 3))", "Tuple(Point, AggregateFunction(count))",
      "Tuple(Point, SimpleAggregateFunction(sum, UInt64))", "Map(Point, String)",
    ].each do |name|
      CrystalClick::BinaryCustomGeoBulkColumnDeclaration.parse(name).should be_nil
    end
  end

  it "admits recursive Geo declarations through the public typed-type gate without widening mixed owners" do
    recursive_geo = [
      "Nullable(Point)",
      "Array(Point)",
      "Tuple(label String, point Point)",
      "Map(String, Point)",
      "Nested(point Point, line LineString)",
      "Variant(Point, String)",
    ]
    recursive_geo.each do |declaration|
      CrystalClick::WidePart.supports_typed_type?(declaration).should be_true
    end

    # These are valid owner compositions, but Custom Geo does not authorize
    # the distinct Dynamic, AggregateFunction, SAF, or QBit part profiles.
    [
      "Tuple(Point, Dynamic)",
      "Tuple(Point, AggregateFunction(sum, UInt8))",
      "Tuple(Point, SimpleAggregateFunction(sum, UInt64))",
      "Tuple(Point, QBit(Int8, 9))",
    ].each do |declaration|
      CrystalClick::WidePart.supports_typed_type?(declaration).should be_false
    end

    # Bare declarations remain supported by their existing typed consumers;
    # the recursive BinaryBulk selector intentionally does not take them.
    ["Point", "MultiPoint", "LineString", "Ring", "MultiLineString", "Polygon", "MultiPolygon"].each do |declaration|
      CrystalClick::WidePart.supports_typed_type?(declaration).should be_true
      CrystalClick::WidePart.supports_custom_geo_bulk_type?(declaration).should be_false
    end
  end

  it "writes each nominal alias through the generic publisher without changing legacy typed values" do
    root = File.tempname("crystal-click-w238-legacy-")
    Dir.mkdir(root)
    begin
      ["Point", "MultiPoint", "LineString", "Ring", "MultiLineString", "Polygon", "MultiPolygon"].each do |name|
        type = CrystalClick::BinaryDataType.custom(name)
        values = Array(CrystalClick::BinaryValue).new(5) { |index| w238p_geo(type, index) }
        granules = [values[0, 2], values[2, 2], values[4, 1]]
        keys = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
        profile_root = File.join(root, name.downcase)
        Dir.mkdir(profile_root)
        part_path = File.join(profile_root, "all_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
          part_path, "pk", keys.to_unsafe.to_slice(keys.size), "v", type, granules,
          rows_per_mark: 2,
        ).should eq(part_path)
        table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["v"])
        seen = 0
        table.scan_typed(batch_rows: 2) do |batch|
          if name == "Point"
            batch.point_values_for("v").each do |point|
              point.x_bits.should eq(0x8000_0000_0000_0000_u64)
              point.y_bits.should eq(0x7ff8_0000_0000_1234_u64)
              seen += 1
            end
          else
            batch.geo_array_rows_for("v").each do |row|
              row.type_name.should eq(name)
              w238p_check_geo(row, values[seen])
              seen += 1
            end
          end
        end
        seen.should eq(5)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
