module CrystalClick
  # Checked logical ownership shape for one selected mark of recursive
  # StorageColumnValue rows. Keeping units named prevents table materialization
  # preflight from mixing wrapper nodes, Tuple cells, child elements, and bytes.
  struct StorageValueShape
    getter nodes : UInt64
    getter tuple_cells : UInt64
    getter elements : UInt64
    getter bytes : UInt64

    def initialize(
      @nodes : UInt64,
      @tuple_cells : UInt64,
      @elements : UInt64,
      @bytes : UInt64,
    )
    end
  end
end
