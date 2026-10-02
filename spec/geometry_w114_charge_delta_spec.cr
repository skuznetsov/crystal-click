require "./spec_helper"

private def w114_charge_delta_empty_lanes
  owners = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  {
    {0_u8, "LineString", 1}, {1_u8, "MultiLineString", 2},
    {2_u8, "MultiPolygon", 3}, {4_u8, "Polygon", 2},
    {5_u8, "Ring", 1}, {6_u8, "MultiPoint", 1},
  }.each do |tag, name, depth|
    owners[CrystalClick::WideGeometryArm.for_tag(tag).not_nil!] = CrystalClick::WideGeoArrayColumnData.new(
      CrystalClick::GeoArrayColumnType.for_type(name).not_nil!,
      Array(Array(UInt64)).new(depth) { [] of UInt64 },
      [] of CrystalClick::WidePointValue
    )
  end
  owners
end

describe "W114 Geometry retained-charge deltas" do
  it "counts independent tag/rank, topology and Point axes exactly once" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    # These are axis counts, not sizes: fixed global-tag order, Point has no
    # size levels, and each Geo Array owner retains both sizes and offsets.
    counts = [
      [0_u64], [0_u64, 0_u64], [0_u64, 0_u64, 0_u64],
      [] of UInt64, [0_u64, 0_u64], [0_u64], [0_u64],
    ]
    points = Array(UInt64).new(7, 0_u64)
    base = plan.materialization_charge(0_u64, counts, points).not_nil!
    row_slot = sizeof(UInt8).to_u64 + sizeof(Int32).to_u64
    point_slot = sizeof(CrystalClick::WidePointValue).to_u64

    plan.materialization_charge(3_u64, counts, points).should eq(base + 3_u64 * row_slot)
    points[3] = 3_u64
    plan.materialization_charge(3_u64, counts, points).should eq(base + 3_u64 * (row_slot + point_slot))

    points[3] = 0_u64
    counts[0] = [2_u64]
    points[0] = 5_u64
    plan.materialization_charge(2_u64, counts, points).should eq(
      base + 2_u64 * row_slot + 2_u64 * 2_u64 * sizeof(UInt64).to_u64 + 5_u64 * point_slot
    )

    counts[0] = [0_u64]
    points[0] = 0_u64
    counts[2] = [1_u64, 2_u64, 3_u64]
    points[2] = 7_u64
    plan.materialization_charge(1_u64, counts, points).should eq(
      base + row_slot + 2_u64 * 6_u64 * sizeof(UInt64).to_u64 + 7_u64 * point_slot
    )
  end

  it "applies one aggregate ceiling to concurrently supplied schedule and scratch" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    counts = [
      [1_u64], [0_u64, 0_u64], [0_u64, 0_u64, 0_u64],
      [] of UInt64, [0_u64, 0_u64], [0_u64], [1_u64],
    ]
    points = [1_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 2_u64]
    base = plan.materialization_charge(3_u64, counts, points).not_nil!
    limit = 64_u64 * 1024_u64 * 1024_u64
    schedule = 137_u64
    scratch = limit - base - schedule
    plan.materialization_charge(3_u64, counts, points, schedule, scratch).should eq(limit)
    plan.materialization_charge(3_u64, counts, points, schedule, scratch + 1_u64).should be_nil
    plan.materialization_charge(3_u64, counts, points, UInt64::MAX, 1_u64).should be_nil
    plan.materialization_charge(3_u64, counts, points, 1_u64, UInt64::MAX).should be_nil
  end
end

describe "W114 Geometry model hostile boundaries" do
  it "does not inherit Crystal negative-index wrapping or accept forged enum members" do
    point = CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64)
    data = CrystalClick::WideGeometryColumnData.new([3_u8, 255_u8], [point], w114_charge_delta_empty_lanes)
    {-1, 2}.each do |index|
      expect_raises(CrystalClick::BoundsError) { data.row(index) }
      expect_raises(CrystalClick::BoundsError) { data.arm_at(index) }
      expect_raises(CrystalClick::BoundsError) { data.arm_index_at(index) }
      expect_raises(CrystalClick::BoundsError) { CrystalClick::WideGeometryRow.new(data, index) }
    end
    {-1, 1}.each do |index|
      expect_raises(CrystalClick::BoundsError) { data.point_at(index) }
    end
    {7_u8, 255_u8}.each do |tag|
      forged = CrystalClick::WideGeometryArm.new(tag)
      expect_raises(ArgumentError) { forged.type_name }
      expect_raises(ArgumentError) { forged.depth }
      expect_raises(ArgumentError) { data.arm_count(forged) }
      expect_raises(ArgumentError) { data.geo_array_data(forged) }
    end
    data.row(0).point.same_bits?(point).should be_true
    data.row(1).null?.should be_true
  end

  it "admits exactly the outer-axis limit and rejects unmatched Point lanes" do
    owners = w114_charge_delta_empty_lanes
    no_points = [] of CrystalClick::WidePointValue
    tags = Array(UInt8).new(65_536, 255_u8)
    data = CrystalClick::WideGeometryColumnData.new(tags, no_points, owners)
    data.row_count.should eq(65_536)
    data.row(65_535).null?.should be_true
    tags[0] = 3_u8
    data.row(0).null?.should be_true
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new(Array(UInt8).new(65_537, 255_u8), no_points, owners)
    end
    expect_raises(ArgumentError) { CrystalClick::WideGeometryColumnData.new([3_u8], no_points, owners) }
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([255_u8], [CrystalClick::WidePointValue.new(0.0, 0.0)], owners)
    end
    # Six keys alone do not establish the required set of six nominal lanes.
    owners.delete(CrystalClick::WideGeometryArm::MultiPoint)
    owners[CrystalClick::WideGeometryArm.new(7_u8)] = w114_charge_delta_empty_lanes[CrystalClick::WideGeometryArm::MultiPoint]
    expect_raises(ArgumentError) { CrystalClick::WideGeometryColumnData.new([] of UInt8, no_points, owners) }
  end
end
