require "./spec_helper"

def w114_geo_array_data(
  type_name : String,
  level_sizes : Array(Array(UInt64)),
  points : Array(CrystalClick::WidePointValue),
) : CrystalClick::WideGeoArrayColumnData
  plan = CrystalClick::GeoArrayColumnType.for_type(type_name) ||
         raise ArgumentError.new("unknown W114 Geo Array fixture type")
  CrystalClick::WideGeoArrayColumnData.new(plan, level_sizes, points)
end

def w114_empty_geometry_geo_arrays : Hash(CrystalClick::WideGeometryArm, CrystalClick::WideGeoArrayColumnData)
  result = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  {
    {0_u8, "LineString"},
    {1_u8, "MultiLineString"},
    {2_u8, "MultiPolygon"},
    {4_u8, "Polygon"},
    {5_u8, "Ring"},
    {6_u8, "MultiPoint"},
  }.each do |tag, name|
    arm = CrystalClick::WideGeometryArm.for_tag(tag).not_nil!
    plan = CrystalClick::GeoArrayColumnType.for_type(name).not_nil!
    levels = Array(Array(UInt64)).new(plan.depth) { [] of UInt64 }
    result[arm] = CrystalClick::WideGeoArrayColumnData.new(
      plan,
      levels,
      [] of CrystalClick::WidePointValue
    )
  end
  result
end

def w114_zero_geometry_level_counts : Array(Array(UInt64))
  [
    [0_u64],
    [0_u64, 0_u64],
    [0_u64, 0_u64, 0_u64],
    [] of UInt64,
    [0_u64, 0_u64],
    [0_u64],
    [0_u64],
  ]
end

def w114_zero_geometry_point_counts : Array(UInt64)
  Array(UInt64).new(7, 0_u64)
end

describe CrystalClick::WideGeometryArm do
  it "maps the fixed persisted tags to exact nominal names and depths" do
    expected = [
      {0_u8, CrystalClick::WideGeometryArm::LineString, "LineString", 1},
      {1_u8, CrystalClick::WideGeometryArm::MultiLineString, "MultiLineString", 2},
      {2_u8, CrystalClick::WideGeometryArm::MultiPolygon, "MultiPolygon", 3},
      {3_u8, CrystalClick::WideGeometryArm::Point, "Point", 0},
      {4_u8, CrystalClick::WideGeometryArm::Polygon, "Polygon", 2},
      {5_u8, CrystalClick::WideGeometryArm::Ring, "Ring", 1},
      {6_u8, CrystalClick::WideGeometryArm::MultiPoint, "MultiPoint", 1},
    ]

    expected.each do |tag, arm, name, depth|
      resolved = CrystalClick::WideGeometryArm.for_tag(tag).not_nil!
      resolved.should eq(arm)
      resolved.type_name.should eq(name)
      resolved.depth.should eq(depth)
    end

    {7_u8, 254_u8, 255_u8}.each do |tag|
      CrystalClick::WideGeometryArm.for_tag(tag).should be_nil
    end
  end
end

describe CrystalClick::GeometryColumnType do
  it "admits exact Geometry and declares all 25 streams in persisted tag order" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    plan.type_name.should eq("Geometry")
    CrystalClick::GeometryColumnType.for_type("Point").should be_nil
    CrystalClick::GeometryColumnType.for_type("Variant").should be_nil
    CrystalClick::GeometryColumnType.for_type("geometry").should be_nil
    CrystalClick::WidePart.supports_typed_type?("Geometry").should be_false

    expected = [
      {"shape.variant_discr", 1},
      {"shape.LineString.size0", 8},
      {"shape.LineString%2E1", 8},
      {"shape.LineString%2E2", 8},
      {"shape.MultiLineString.size0", 8},
      {"shape.MultiLineString.size1", 8},
      {"shape.MultiLineString%2E1", 8},
      {"shape.MultiLineString%2E2", 8},
      {"shape.MultiPolygon.size0", 8},
      {"shape.MultiPolygon.size1", 8},
      {"shape.MultiPolygon.size2", 8},
      {"shape.MultiPolygon%2E1", 8},
      {"shape.MultiPolygon%2E2", 8},
      {"shape.Point%2E1", 8},
      {"shape.Point%2E2", 8},
      {"shape.Polygon.size0", 8},
      {"shape.Polygon.size1", 8},
      {"shape.Polygon%2E1", 8},
      {"shape.Polygon%2E2", 8},
      {"shape.Ring.size0", 8},
      {"shape.Ring%2E1", 8},
      {"shape.Ring%2E2", 8},
      {"shape.MultiPoint.size0", 8},
      {"shape.MultiPoint%2E1", 8},
      {"shape.MultiPoint%2E2", 8},
    ]
    plan.discriminator_stream("shape").should eq("shape.variant_discr")
    plan.physical_streams("shape").should eq(expected)
    plan.physical_streams("shape").size.should eq(25)
    expected.each do |stream, width|
      plan.stream_width("shape", stream).should eq(width)
    end
    plan.stream_width("shape", "shape.NotAnArm%2E1").should be_nil
  end

  it "charges every fixed arm, bounds each axis, checks arithmetic, and enforces the exact aggregate limit" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    zero_levels = w114_zero_geometry_level_counts
    zero_points = w114_zero_geometry_point_counts
    base = plan.materialization_charge(0_u64, zero_levels, zero_points).not_nil!
    plan.materialization_charge(0_u64, zero_levels, zero_points, 19_u64, 23_u64).should eq(base + 42_u64)

    plan.materialization_charge(65_536_u64, zero_levels, zero_points).should_not be_nil
    plan.materialization_charge(65_537_u64, zero_levels, zero_points).should be_nil

    7.times do |arm_index|
      levels = w114_zero_geometry_level_counts
      points = w114_zero_geometry_point_counts
      if arm_index == 3
        points[arm_index] = 65_536_u64
      else
        levels[arm_index][0] = 65_536_u64
      end
      plan.materialization_charge(65_536_u64, levels, points).should_not be_nil

      if arm_index == 3
        points[arm_index] = 65_537_u64
      else
        levels[arm_index][0] = 65_537_u64
      end
      plan.materialization_charge(65_536_u64, levels, points).should be_nil
    end

    {0, 1, 2, 4, 5, 6}.each do |arm_index|
      depth = CrystalClick::WideGeometryArm.for_tag(arm_index.to_u8).not_nil!.depth
      (1...depth).each do |axis|
        levels = w114_zero_geometry_level_counts
        levels[arm_index][0] = 1_u64
        (1...axis).each { |parent_axis| levels[arm_index][parent_axis] = 1_u64 }
        levels[arm_index][axis] = 65_536_u64
        plan.materialization_charge(1_u64, levels, zero_points).should_not be_nil
        levels[arm_index][axis] = 65_537_u64
        plan.materialization_charge(1_u64, levels, zero_points).should be_nil
      end

      levels = w114_zero_geometry_level_counts
      points = w114_zero_geometry_point_counts
      points[arm_index] = 65_536_u64
      depth.times { |axis| levels[arm_index][axis] = 1_u64 }
      plan.materialization_charge(1_u64, levels, points).should_not be_nil
      points[arm_index] = 65_537_u64
      plan.materialization_charge(1_u64, levels, points).should be_nil
    end

    mismatch = w114_zero_geometry_level_counts
    mismatch[0] = [] of UInt64
    plan.materialization_charge(0_u64, mismatch, zero_points).should be_nil
    mismatch = w114_zero_geometry_level_counts
    mismatch[3] = [0_u64]
    plan.materialization_charge(0_u64, mismatch, zero_points).should be_nil

    too_many_occurrences = w114_zero_geometry_level_counts
    too_many_occurrences[0][0] = 1_u64
    too_many_occurrences[1][0] = 1_u64
    plan.materialization_charge(1_u64, too_many_occurrences, zero_points).should be_nil
    wrong_axis_count = w114_zero_geometry_level_counts
    wrong_axis_count.pop
    plan.materialization_charge(0_u64, wrong_axis_count, zero_points).should be_nil
    plan.materialization_charge(0_u64, zero_levels, zero_points, UInt64::MAX, 1_u64).should be_nil
    plan.materialization_charge(0_u64, zero_levels, zero_points, UInt64::MAX, 0_u64).should be_nil

    exact = CrystalClick::GeometryColumnType::MAX_MATERIALIZED_BYTES - base
    plan.materialization_charge(0_u64, zero_levels, zero_points, exact, 0_u64).should eq(
      CrystalClick::GeometryColumnType::MAX_MATERIALIZED_BYTES
    )
    plan.materialization_charge(0_u64, zero_levels, zero_points, exact, 1_u64).should be_nil
  end
end

describe CrystalClick::WideGeometryColumnData do
  it "retains fixed nominal owners and window-local interleaved ranks without changing raw Point bits" do
    nan_payload = CrystalClick::WidePointValue.from_bits(
      0x7ff8_0000_0000_0042_u64,
      0x8000_0000_0000_0000_u64
    )
    second_point = CrystalClick::WidePointValue.from_bits(
      0xfff8_0000_0000_0017_u64,
      0x3ff8_0000_0000_0000_u64
    )
    line_data = w114_geo_array_data("LineString", [[2_u64, 0_u64]], [nan_payload, second_point])
    multi_line_data = w114_geo_array_data("MultiLineString", [[2_u64], [0_u64, 1_u64]], [second_point])
    multi_polygon_data = w114_geo_array_data("MultiPolygon", [[1_u64], [2_u64], [0_u64, 1_u64]], [nan_payload])
    polygon_data = w114_geo_array_data("Polygon", [[1_u64], [0_u64]], [] of CrystalClick::WidePointValue)
    ring_data = w114_geo_array_data("Ring", [[0_u64]], [] of CrystalClick::WidePointValue)
    multi_point_data = w114_geo_array_data("MultiPoint", [[1_u64]], [second_point])
    owners = {
      CrystalClick::WideGeometryArm::LineString      => line_data,
      CrystalClick::WideGeometryArm::MultiLineString => multi_line_data,
      CrystalClick::WideGeometryArm::MultiPolygon    => multi_polygon_data,
      CrystalClick::WideGeometryArm::Polygon         => polygon_data,
      CrystalClick::WideGeometryArm::Ring            => ring_data,
      CrystalClick::WideGeometryArm::MultiPoint      => multi_point_data,
    }
    tags = [0_u8, 255_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 0_u8, 3_u8]
    point_values = [nan_payload, second_point]
    data = CrystalClick::WideGeometryColumnData.new(tags, point_values, owners)

    tags[0] = 6_u8
    point_values[0] = CrystalClick::WidePointValue.new(9.0, 10.0)
    owners[CrystalClick::WideGeometryArm::LineString] = ring_data

    data.type_name.should eq("Geometry")
    data.row_count.should eq(10)
    data.tags.should eq([0_u8, 255_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 0_u8, 3_u8])
    data.arm_indexes.should eq([0, -1, 0, 0, 0, 0, 0, 0, 1, 1])
    data.arm_count(CrystalClick::WideGeometryArm::LineString).should eq(2)
    data.arm_count(CrystalClick::WideGeometryArm::Point).should eq(2)
    data.arm_count(CrystalClick::WideGeometryArm::MultiPoint).should eq(1)
    data.point_at(0).same_bits?(nan_payload).should be_true
    data.point_at(1).same_bits?(second_point).should be_true
    data.points.map(&.x_bits).should eq([nan_payload.x_bits, second_point.x_bits])
    data.geo_array_data(CrystalClick::WideGeometryArm::LineString).same?(line_data).should be_true
    data.geo_array_data(CrystalClick::WideGeometryArm::MultiPolygon).same?(multi_polygon_data).should be_true
    exported_child_sizes = data.geo_array_data(CrystalClick::WideGeometryArm::LineString).topology.sizes(0)
    exported_child_points = data.geo_array_data(CrystalClick::WideGeometryArm::LineString).points
    exported_child_sizes[0] = 99_u64
    exported_child_points.clear
    line_data.topology.size_at(0, 0).should eq(2_u64)
    line_data.point_count.should eq(2)
    data.retained_logical_charge.should be <= CrystalClick::GeometryColumnType::MAX_MATERIALIZED_BYTES

    detached_tags = data.tags
    detached_indexes = data.arm_indexes
    detached_points = data.points
    detached_tags[0] = 6_u8
    detached_indexes[0] = 99
    detached_points.clear
    data.tags[0].should eq(0_u8)
    data.arm_index_at(0).should eq(0)
    data.points.size.should eq(2)

    rows = [
      {0_u8, CrystalClick::WideGeometryArm::LineString, "LineString"},
      {1_u8, CrystalClick::WideGeometryArm::MultiLineString, "MultiLineString"},
      {2_u8, CrystalClick::WideGeometryArm::MultiPolygon, "MultiPolygon"},
      {3_u8, CrystalClick::WideGeometryArm::Point, "Point"},
      {4_u8, CrystalClick::WideGeometryArm::Polygon, "Polygon"},
      {5_u8, CrystalClick::WideGeometryArm::Ring, "Ring"},
      {6_u8, CrystalClick::WideGeometryArm::MultiPoint, "MultiPoint"},
    ]
    row_indexes = [0, 2, 3, 4, 5, 6, 7]
    rows.each_with_index do |(tag, arm, name), arm_position|
      row = data.row(row_indexes[arm_position])
      row.data.same?(data).should be_true
      row.row_index.should eq(row_indexes[arm_position])
      row.tag.should eq(tag)
      row.arm.should eq(arm)
      row.arm_type_name.should eq(name)
      row.null?.should be_false
      row.arm_index.should eq(0)
    end

    null_row = data.row(1)
    null_row.tag.should eq(255_u8)
    null_row.arm.should be_nil
    null_row.arm_type_name.should be_nil
    null_row.arm_index.should be_nil
    null_row.null?.should be_true
    data.arm_at(1).should be_nil
    data.arm_index_at(1).should be_nil
    data.arm_index_at(8).should eq(1)
    data.row(8).arm_index.should eq(1)
    data.row(9).point.same_bits?(second_point).should be_true
    data.row(4).point.same_bits?(nan_payload).should be_true

    line_row = data.row(0).geo_array
    line_row.data.same?(line_data).should be_true
    line_row.type_name.should eq("LineString")
    line_row.size.should eq(2)
    line_row.point_at(0).same_bits?(nan_payload).should be_true
    data.row(8).geo_array.size.should eq(0)

    multi_line_row = data.row(2).geo_array
    multi_line_row.size.should eq(2)
    multi_line_row.array_at(0).size.should eq(0)
    multi_line_row.array_at(1).point_at(0).same_bits?(second_point).should be_true

    multi_polygon_row = data.row(3).geo_array
    multi_polygon_row.size.should eq(1)
    multi_polygon_row.array_at(0).size.should eq(2)
    multi_polygon_row.array_at(0).array_at(0).size.should eq(0)
    multi_polygon_row.array_at(0).array_at(1).point_at(0).same_bits?(nan_payload).should be_true

    polygon_row = data.row(5).geo_array
    polygon_row.size.should eq(1)
    polygon_row.array_at(0).size.should eq(0)
    data.row(6).geo_array.size.should eq(0)
    data.row(7).geo_array.point_at(0).same_bits?(second_point).should be_true

    expect_raises(CrystalClick::BoundsError) { data.row(10) }
    expect_raises(CrystalClick::BoundsError) { data.point_at(2) }
    expect_raises(ArgumentError) { data.row(4).geo_array }
    expect_raises(ArgumentError) { data.row(0).point }
    expect_raises(ArgumentError) { null_row.geo_array }
    expect_raises(ArgumentError) { null_row.point }
    expect_raises(ArgumentError) do
      data.geo_array_data(CrystalClick::WideGeometryArm::Point)
    end
    invalid_arm = CrystalClick::WideGeometryArm.new(7)
    expect_raises(ArgumentError) { data.arm_count(invalid_arm) }
    expect_raises(ArgumentError) { data.geo_array_data(invalid_arm) }
  end

  it "rejects invalid tags, invalid or incomplete keys, nominal mismatches, and lane-count mismatches" do
    empty = w114_empty_geometry_geo_arrays
    {7_u8, 254_u8}.each do |tag|
      expect_raises(ArgumentError) do
        CrystalClick::WideGeometryColumnData.new([tag], [] of CrystalClick::WidePointValue, empty)
      end
    end

    missing = w114_empty_geometry_geo_arrays
    missing.delete(CrystalClick::WideGeometryArm::MultiPoint)
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([] of UInt8, [] of CrystalClick::WidePointValue, missing)
    end

    with_point_key = w114_empty_geometry_geo_arrays
    with_point_key[CrystalClick::WideGeometryArm::Point] =
      w114_geo_array_data("LineString", [[] of UInt64], [] of CrystalClick::WidePointValue)
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([] of UInt8, [] of CrystalClick::WidePointValue, with_point_key)
    end

    with_invalid_key = w114_empty_geometry_geo_arrays
    with_invalid_key[CrystalClick::WideGeometryArm.new(7)] =
      w114_geo_array_data("LineString", [[] of UInt64], [] of CrystalClick::WidePointValue)
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([] of UInt8, [] of CrystalClick::WidePointValue, with_invalid_key)
    end

    wrong_nominal = w114_empty_geometry_geo_arrays
    wrong_nominal[CrystalClick::WideGeometryArm::Ring] =
      w114_geo_array_data("LineString", [[] of UInt64], [] of CrystalClick::WidePointValue)
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([] of UInt8, [] of CrystalClick::WidePointValue, wrong_nominal)
    end

    count_mismatch = w114_empty_geometry_geo_arrays
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryColumnData.new([0_u8], [] of CrystalClick::WidePointValue, count_mismatch)
    end
  end
end
