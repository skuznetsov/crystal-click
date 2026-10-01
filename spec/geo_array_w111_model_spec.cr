require "./spec_helper"

describe CrystalClick::GeoArrayColumnType do
  it "admits only the five exact nominal Geo names and maps their physical lanes" do
    expected = {
      "LineString"      => {1, ["shape.size0"]},
      "Ring"            => {1, ["shape.size0"]},
      "Polygon"         => {2, ["shape.size0", "shape.size1"]},
      "MultiLineString" => {2, ["shape.size0", "shape.size1"]},
      "MultiPolygon"    => {3, ["shape.size0", "shape.size1", "shape.size2"]},
    }

    expected.each do |name, pair|
      plan = CrystalClick::GeoArrayColumnType.for_type(name).not_nil!
      plan.type_name.should eq(name)
      plan.depth.should eq(pair[0])
      plan.size_streams("shape").should eq(pair[1])
      plan.coordinate_streams("shape").should eq({"shape%2E1", "shape%2E2"})
      plan.physical_streams("shape").should eq(
        pair[1].map { |stream| {stream, 8} } + [{"shape%2E1", 8}, {"shape%2E2", 8}]
      )
      plan.size_stream("shape", 0).should eq("shape.size0")
      expect_raises(CrystalClick::BoundsError) { plan.size_stream("shape", plan.depth) }
    end

    {"MultiPoint", "Geometry", "Array(Point)", "linestring"}.each do |name|
      CrystalClick::GeoArrayColumnType.for_type(name).should be_nil
    end
  end
end

describe CrystalClick::WideGeoArrayTopology do
  it "owns detached ragged sizes and offsets while rows retain exact nominal identity" do
    plan = CrystalClick::GeoArrayColumnType.for_type("MultiPolygon").not_nil!
    levels = [
      [2_u64, 0_u64],
      [1_u64, 2_u64],
      [1_u64, 0_u64, 1_u64],
    ]
    points = [
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
      CrystalClick::WidePointValue.new(3.5, -8.25),
    ]
    data = CrystalClick::WideGeoArrayColumnData.new(plan, levels, points)

    levels[0][0] = 99_u64
    levels[2].clear
    points[0] = CrystalClick::WidePointValue.new(9.0, 9.0)
    data.type_name.should eq("MultiPolygon")
    data.topology.sizes(0).should eq([2_u64, 0_u64])
    data.topology.offsets(0).should eq([0_u64, 2_u64, 2_u64])
    data.topology.sizes(2).should eq([1_u64, 0_u64, 1_u64])
    data.point_at(0).x_bits.should eq(0x8000_0000_0000_0000_u64)

    exported_sizes = data.topology.sizes(1)
    exported_offsets = data.topology.offsets(1)
    exported_points = data.points
    exported_sizes[0] = 77_u64
    exported_offsets.clear
    exported_points.clear
    data.topology.size_at(1, 0).should eq(1_u64)
    data.topology.offset_at(1, 2).should eq(3_u64)
    data.point_count.should eq(2)

    first_row = data.row(0)
    first_row.data.same?(data).should be_true
    first_row.type_name.should eq("MultiPolygon")
    first_row.size.should eq(2)
    first_row.terminal?.should be_false
    polygon0 = first_row.array_at(0)
    polygon0.level.should eq(1)
    polygon0.size.should eq(1)
    line0 = polygon0.array_at(0)
    line0.terminal?.should be_true
    line0.size.should eq(1)
    line0.point_at(0).same_bits?(CrystalClick::WidePointValue.from_bits(
      0x8000_0000_0000_0000_u64,
      0x7ff8_0000_0000_0042_u64
    )).should be_true
    polygon1 = first_row.array_at(1)
    polygon1.size.should eq(2)
    polygon1.array_at(0).size.should eq(0)
    polygon1.array_at(1).point_at(0).y.should eq(-8.25)
    data.row(1).size.should eq(0)

    expect_raises(CrystalClick::BoundsError) { data.row(2) }
    expect_raises(CrystalClick::BoundsError) { first_row.array_at(2) }
    expect_raises(ArgumentError) { first_row.point_at(0) }
  end

  it "rejects wrong depth, child cardinalities, UInt64 overflow and per-level native limits before ownership copies" do
    polygon = CrystalClick::GeoArrayColumnType.for_type("Polygon").not_nil!
    expect_raises(ArgumentError) do
      CrystalClick::WideGeoArrayTopology.new(polygon, [[1_u64]])
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideGeoArrayTopology.new(polygon, [[1_u64], [] of UInt64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideGeoArrayColumnData.new(
        CrystalClick::GeoArrayColumnType.for_type("LineString").not_nil!,
        [[1_u64]],
        [] of CrystalClick::WidePointValue
      )
    end

    line = CrystalClick::GeoArrayColumnType.for_type("LineString").not_nil!
    overflowing = [[UInt64::MAX, 1_u64]]
    expect_raises(ArgumentError) { CrystalClick::WideGeoArrayTopology.validate!(line, overflowing) }

    too_many_rows = Array(UInt64).new((CrystalClick::GeoArrayColumnType::MAX_LOGICAL_ELEMENTS + 1_u64).to_i, 0_u64)
    expect_raises(ArgumentError) { CrystalClick::WideGeoArrayTopology.validate!(line, [too_many_rows]) }
    expect_raises(ArgumentError) { CrystalClick::WideGeoArrayTopology.validate!(line, [[65_537_u64]]) }

    exact_rows = [[1_u64]]
    expect_raises(ArgumentError) { CrystalClick::WideGeoArrayTopology.validate!(line, exact_rows, 0) }
  end

  it "keeps charge arithmetic bounded and does not charge lazily created row handles" do
    plan = CrystalClick::GeoArrayColumnType.for_type("Ring").not_nil!
    base = plan.materialization_charge([0_u64], 0_u64).not_nil!
    plan.materialization_charge([0_u64], 0_u64, 1_u64).should eq(base + 1_u64)
    plan.materialization_charge([UInt64::MAX], 0_u64).should be_nil
    plan.materialization_charge([0_u64], UInt64::MAX).should be_nil
    plan.reader_materialization_charge([0_u64], 0_u64, Int32::MAX).should be_nil
  end
end
