require "./spec_helper"

describe "W122 scalar Dynamic schedule consumers" do
  it "exposes mark-local ranks and counts without weakening detached snapshots" do
    tags = [255_u8, 0_u8, 0_u8]
    ranks = [nil, 0, 1] of Int32?
    counts = [2_u64, 0_u64]
    owner = CrystalClick::DynamicMarkSchedule.new(3, 6_u64, tags, ranks, counts, [7_u64, 1_u64])
    tags[1] = 1_u8
    ranks[1] = 99
    counts[0] = 99_u64
    owner.row_count.should eq(3)
    owner.rank_count.should eq(3)
    owner.variant_count.should eq(2)
    owner.tag_at(0).should eq(255_u8)
    owner.tag_at(1).should eq(0_u8)
    owner.rank_at(0).should be_nil
    owner.rank_at(1).should eq(0)
    owner.rank_at(2).should eq(1)
    owner.arm_count_at(0).should eq(2_u64)
    owner.arm_count_at(1).should eq(0_u64)
    owner.tags[1] = 1_u8
    owner.ranks[1] = 99
    owner.arm_counts[0] = 99_u64
    owner.tag_at(1).should eq(0_u8)
    owner.rank_at(1).should eq(0)
    owner.arm_count_at(0).should eq(2_u64)
    expect_raises(IndexError) { owner.tag_at(3) }
    expect_raises(IndexError) { owner.arm_count_at(2) }
  end
end
