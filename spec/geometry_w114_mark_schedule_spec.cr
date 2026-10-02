require "./spec_helper"

describe CrystalClick::WideGeometryMarkSchedule do
  it "keeps absolute mark origins separate from sparse window-local arm counts" do
    rows_by_mark = [2_u64, 2_u64, 1_u64]
    tags_by_mark = [
      [3_u8, 255_u8],
      [6_u8, 6_u8],
      [6_u8],
    ]
    schedule = CrystalClick::WideGeometryMarkSchedule.new(
      11_i32,
      rows_by_mark,
      tags_by_mark
    )

    rows_by_mark[0] = 0_u64
    tags_by_mark[0][0] = 7_u8
    schedule.first_mark.should eq(11)
    schedule.mark_count.should eq(3)
    schedule.arm_count_at(0, 0).should eq(0_u64)
    schedule.arm_count_at(0, 3).should eq(1_u64)
    schedule.arm_count_at(0, 6).should eq(0_u64)
    schedule.arm_count_at(1, 6).should eq(2_u64)
    schedule.arm_count_at(2, 6).should eq(1_u64)
    schedule.arm_range_count(11, 3, 6).should eq(3_u64)
    schedule.arm_range_count(12, 2, 6).should eq(3_u64)
    schedule.tag_at(0, 0).should eq(3_u8)
    schedule.tag_at(1, 0).should eq(6_u8)
    schedule.tags_for_mark(1).should eq([6_u8, 6_u8])
    schedule.flattened_tags.should eq([3_u8, 255_u8, 6_u8, 6_u8, 6_u8])

    detached_mark_tags = schedule.tags_for_mark(1)
    detached_mark_tags[0] = 7_u8
    schedule.tag_at(1, 0).should eq(6_u8)
  end

  it "rejects mismatched table rows and invalid global tags" do
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryMarkSchedule.new(4, [2_u64], [[0_u8]])
    end
    {7_u8, 254_u8}.each do |tag|
      expect_raises(ArgumentError) do
        CrystalClick::WideGeometryMarkSchedule.new(4_i32, [1_u64], [[tag]])
      end
    end
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryMarkSchedule.new(-1_i32, [0_u64], [[] of UInt8])
    end
  end

  it "matches its checked class reservation and returns detached tag copies" do
    schedule = CrystalClick::WideGeometryMarkSchedule.new(23_i32, [1_u64], [[6_u8]])
    reservation = CrystalClick::WideGeometryMarkSchedule.logical_charge_for_shape([1_u64])
    tags = schedule.flattened_tags
    tags[0] = 0_u8

    schedule.flattened_tags.should eq([6_u8])
    schedule.logical_charge.should eq(reservation)
    schedule.logical_charge.should be > 0_u64
    schedule.logical_charge.should be <= CrystalClick::GeometryColumnType::MAX_MATERIALIZED_BYTES
    CrystalClick::WideGeometryMarkSchedule.logical_charge_for_shape([65_537_u64]).should be_nil
    CrystalClick::WideGeometryMarkSchedule.logical_charge_for_shape([65_536_u64, 1_u64]).should be_nil
    expect_raises(CrystalClick::BoundsError) { schedule.tag_at(1, 0) }
    expect_raises(CrystalClick::BoundsError) { schedule.tag_at(0, 1) }
    expect_raises(CrystalClick::BoundsError) { schedule.arm_count_at(0, 7) }
    expect_raises(CrystalClick::BoundsError) { schedule.arm_range_count(22, 1, 6) }
  end
end
