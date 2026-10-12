module CrystalClick
  # Backwards-compatible name for existing MRK3 readback callers. The grid
  # formula is format-neutral; MRK4 callers pass the physical slot count.
  class CompactMRK3ReadbackGrid
    def self.preflight!(
      budget : CompressedStreamBudget,
      mark_count : Int,
      slot_count : Int,
      data_size : UInt64,
    ) : Nil
      CompactReadbackGrid.preflight!(budget, mark_count, slot_count, data_size)
    end
  end
end
