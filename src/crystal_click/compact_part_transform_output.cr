module CrystalClick
  # Detached typed output produced by a caller-run materialized-view transform.
  # Keys and Compact column-owner containers are copied from the caller.
  class CompactPartTransformOutput
    @keys : Array(UInt64)
    @columns : Array(CompactPartColumn)
    @projections : Array(WidePartProjection | CompactPartProjection)

    def initialize(
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      *,
      projections : Indexable(WidePartProjection | CompactPartProjection) = [] of WidePartProjection,
    )
      @keys = Array(UInt64).new(keys.size)
      keys.each { |key| @keys << key }
      @columns = columns.dup
      @projections = Array(WidePartProjection | CompactPartProjection).new(projections.size)
      projections.each { |projection| @projections << projection }
    end

    def keys : Array(UInt64)
      @keys.dup
    end

    def empty? : Bool
      @keys.empty?
    end

    # :nodoc:
    def row_count : UInt64
      @keys.size.to_u64
    end

    def columns : Array(CompactPartColumn)
      @columns.dup
    end

    def projections : Array(WidePartProjection | CompactPartProjection)
      @projections.dup
    end
  end
end
