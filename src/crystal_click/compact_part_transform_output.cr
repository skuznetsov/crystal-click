module CrystalClick
  # Detached typed output produced by a caller-run materialized-view transform.
  # Keys and Compact column-owner containers are copied from the caller.
  class CompactPartTransformOutput
    @keys : Array(UInt64)
    @columns : Array(CompactPartColumn)

    def initialize(keys : Slice(UInt64), columns : Array(CompactPartColumn))
      @keys = Array(UInt64).new(keys.size)
      keys.each { |key| @keys << key }
      @columns = columns.dup
    end

    def keys : Array(UInt64)
      @keys.dup
    end

    def empty? : Bool
      @keys.empty?
    end

    def columns : Array(CompactPartColumn)
      @columns.dup
    end
  end
end
