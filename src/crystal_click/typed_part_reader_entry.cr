module CrystalClick
  # One validated physical-part backend retained by TypedPartTable. Kept in
  # its own file so the facade does not accumulate private record definitions.
  struct TypedPartReaderEntry
    getter name : String
    getter path : String
    getter info : MergeTreePartInfo
    getter reader : WidePartTable | CompactPartTable
    getter row_count : UInt64
    getter mark_row_counts : Array(UInt64)

    def initialize(
      @name : String,
      @path : String,
      @info : MergeTreePartInfo,
      @reader : WidePartTable | CompactPartTable,
      @row_count : UInt64,
      @mark_row_counts : Array(UInt64),
    )
    end
  end
end
