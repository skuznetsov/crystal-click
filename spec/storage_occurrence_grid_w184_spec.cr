require "./spec_helper"

private def w184_grid_budget(
  writing : Bool = true,
  max_nodes : Int = 1_000,
  max_elements : Int = 2_000,
) : CrystalClick::BinaryCodecBudget
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: 64 * 1024
  )
  CrystalClick::BinaryCodecBudget.new(limits, writing)
end

describe CrystalClick::StorageOccurrenceGrid do
  it "detaches paired counts and keeps physical rows distinct from child occurrences" do
    physical = [2_u64, 2_u64, 2_u64, 2_u64]
    logical = [0_u64, 1_u64, 3_u64, 0_u64]
    budget = w184_grid_budget
    grid = CrystalClick::StorageOccurrenceGrid.new(physical, logical, budget)

    physical[0] = 99_u64
    logical[1] = 99_u64
    grid.mark_count.should eq(4)
    grid.physical_rows_at(0).should eq(2_u64)
    grid.logical_occurrences_at(0).should eq(0_u64)
    grid.logical_occurrences_at(1).should eq(1_u64)
    grid.logical_occurrences_at(2).should eq(3_u64)
    grid.physical_rows_at(3).should eq(2_u64)
    budget.node_count.should be >= 8_i64
    budget.element_count.should be >= 8_i64
  end

  it "preflights the whole copy before inspecting a late invalid count" do
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 3,
      max_elements: 4,
      max_bytes: 64
    )
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageOccurrenceGrid.new(
        [1_u64, 0_u64],
        [0_u64, UInt64::MAX],
        budget
      )
    end
    error.message.should eq("binary codec node limit exceeded")
  end

  it "rejects mismatched, empty-physical, and out-of-domain real grids" do
    expect_raises(ArgumentError) do
      CrystalClick::StorageOccurrenceGrid.new([1_u64], [] of UInt64, w184_grid_budget)
    end
    expect_raises(ArgumentError) do
      CrystalClick::StorageOccurrenceGrid.new([0_u64], [0_u64], w184_grid_budget)
    end
    expect_raises(ArgumentError) do
      CrystalClick::StorageOccurrenceGrid.new([1_u64], [Int32::MAX.to_u64 + 1_u64], w184_grid_budget)
    end
  end
end
