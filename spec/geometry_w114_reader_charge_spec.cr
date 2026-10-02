require "./spec_helper"

private def w114_reader_charge_levels : Array(Array(UInt64))
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

private def w114_reader_charge_points : Array(UInt64)
  Array(UInt64).new(7, 0_u64)
end

describe "W114 Geometry shared reader materialization charge" do
  it "includes every live tag buffer and the outer-row vector in scratch charge" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    rows_by_mark = [2_u64, 1_u64]
    mark_count = rows_by_mark.size.to_u64
    outer_rows = 3_u64
    max_mark_rows = 2_u64

    expected = instance_sizeof(Array(UInt64)).to_u64 +
               mark_count * sizeof(UInt64).to_u64 +
               instance_sizeof(Array(Array(UInt8))).to_u64 +
               mark_count * sizeof(Pointer(Array(UInt8))).to_u64 +
               mark_count * instance_sizeof(Array(UInt8)).to_u64 +
               outer_rows +
               instance_sizeof(Array(UInt8)).to_u64 + outer_rows +
               instance_sizeof(Array(UInt8)).to_u64 + max_mark_rows +
               4_096_u64 +
               sizeof(Bytes).to_u64 + max_mark_rows + 19_u64

    plan.reader_tag_scratch_charge(rows_by_mark).should eq(expected)
  end

  it "covers full-window discovery beyond the retained result model" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    levels = w114_reader_charge_levels
    points = w114_reader_charge_points
    levels[0] = [1_u64]
    points[0] = 1_u64
    rows_by_mark = [1_u64]
    summary = plan.reader_summary_charge(rows_by_mark).not_nil!
    tag_scratch = plan.reader_tag_scratch_charge(rows_by_mark).not_nil!

    retained = plan.materialization_charge(1_u64, levels, points).not_nil!
    reader_peak = plan.reader_materialization_charge(
      rows_by_mark, levels, points, summary, tag_scratch
    ).not_nil!

    reader_peak.should be > retained
  end

  it "charges additional sparse all-null marks at a fixed per-mark cardinality" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    levels = w114_reader_charge_levels
    points = w114_reader_charge_points
    many_marks = Array(UInt64).new(8, 8_192_u64)
    # Keep the largest tag frame fixed: splitting a 65536-row mark into eight
    # smaller marks would reduce frame scratch, so total peak is not required
    # to grow monotonically with the mark count at a fixed outer-row total.
    one_mark = [8_192_u64]
    many_summary = plan.reader_summary_charge(many_marks).not_nil!
    one_summary = plan.reader_summary_charge(one_mark).not_nil!
    many_tag_scratch = plan.reader_tag_scratch_charge(many_marks).not_nil!
    one_tag_scratch = plan.reader_tag_scratch_charge(one_mark).not_nil!

    many_mark_charge = plan.reader_materialization_charge(
      many_marks, levels, points, many_summary, many_tag_scratch
    ).not_nil!
    one_mark_charge = plan.reader_materialization_charge(
      one_mark, levels, points, one_summary, one_tag_scratch
    ).not_nil!

    many_mark_charge.should be > one_mark_charge
  end

  it "rejects overflowing totals and every logical axis beyond 65536" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    levels = w114_reader_charge_levels
    points = w114_reader_charge_points

    plan.reader_materialization_charge([UInt64::MAX, 1_u64], levels, points).should be_nil
    plan.reader_materialization_charge([65_537_u64], levels, points).should be_nil
    plan.reader_summary_charge([UInt64::MAX, UInt64::MAX]).should_not be_nil
    plan.reader_tag_scratch_charge([UInt64::MAX, 1_u64]).should be_nil

    levels[0] = [65_537_u64]
    plan.reader_materialization_charge([65_536_u64], levels, points).should be_nil

    levels = w114_reader_charge_levels
    points[3] = 65_537_u64
    plan.reader_materialization_charge([65_536_u64], levels, points).should be_nil
  end

  it "adds caller-supplied per-mark summary and concurrent scratch to the shared ceiling" do
    plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
    levels = w114_reader_charge_levels
    points = w114_reader_charge_points
    rows_by_mark = [1_u64]
    summary = plan.reader_summary_charge(rows_by_mark).not_nil!
    tag_scratch = plan.reader_tag_scratch_charge(rows_by_mark).not_nil!
    base = plan.reader_materialization_charge(
      rows_by_mark, levels, points, summary, tag_scratch
    ).not_nil!
    limit = CrystalClick::GeometryColumnType::MAX_MATERIALIZED_BYTES

    plan.reader_materialization_charge(
      rows_by_mark, levels, points, summary + 17_u64, tag_scratch + limit - base - 17_u64
    ).should eq(limit)
    plan.reader_materialization_charge(
      rows_by_mark, levels, points, summary + 17_u64, tag_scratch + limit - base - 16_u64
    ).should be_nil
    plan.reader_materialization_charge(
      rows_by_mark, levels, points, UInt64::MAX, 1_u64
    ).should be_nil
  end
end
