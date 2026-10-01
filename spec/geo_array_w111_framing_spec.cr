require "./spec_helper"

module CrystalClick::WidePartWriter
  def self.w111_framing_intervals(
    rows : UInt64,
    rpm : Int32,
    starts : Array(UInt64),
    counts : Array(UInt64),
    budget : UInt64 = 64_u64 * 1024 * 1024,
  ) : Array({Int32, Int32, Int32, Int32})
    schedule = TupleLeafMarkSchedule.from_intervals(rows, rpm, starts, counts, budget)
    Array({Int32, Int32, Int32, Int32}).new(schedule.mark_count) do |index|
      mark = schedule.mark(index)
      {mark.outer_start, mark.outer_rows, mark.leaf_start, mark.leaf_count}
    end
  end
end

describe "W111 logical stream framing adapter" do
  it "preserves the outer table rows when every Point interval is empty" do
    CrystalClick::WidePartWriter.w111_framing_intervals(
      5_u64, 2, [0_u64, 0_u64, 0_u64], [0_u64, 0_u64, 0_u64]
    ).should eq([{0, 2, 0, 0}, {2, 2, 0, 0}, {4, 1, 0, 0}])
  end

  it "preserves unequal outer and logical interval counts" do
    CrystalClick::WidePartWriter.w111_framing_intervals(
      5_u64, 2, [0_u64, 3_u64, 3_u64], [3_u64, 0_u64, 1_u64]
    ).should eq([{0, 2, 0, 3}, {2, 2, 3, 0}, {4, 1, 3, 1}])
  end

  it "rejects a shifted logical origin and gaps" do
    expect_raises(ArgumentError, /not contiguous/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(2_u64, 2, [1_u64], [1_u64])
    end
    expect_raises(ArgumentError, /not contiguous/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(3_u64, 2, [0_u64, 2_u64], [1_u64, 1_u64])
    end
  end

  it "rejects mismatched mark grids and a zero budget" do
    expect_raises(ArgumentError, /outer mark count/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(3_u64, 2, [0_u64], [1_u64])
    end
    expect_raises(ArgumentError, /materialization limit/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(3_u64, 2, [0_u64, 1_u64], [1_u64, 1_u64], 0_u64)
    end
  end

  it "rejects native logical overflow without wrapping" do
    expect_raises(ArgumentError, /native limit/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(
        3_u64, 2, [0_u64, Int32::MAX.to_u64], [Int32::MAX.to_u64, 1_u64]
      )
    end
    expect_raises(ArgumentError, /native limit/) do
      CrystalClick::WidePartWriter.w111_framing_intervals(1_u64, 1, [0_u64], [UInt64::MAX])
    end
  end
end
