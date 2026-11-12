module CrystalClick
  # Detached typed output produced by a caller-run materialized-view transform.
  # It carries no raw files or serializer; each column remains an existing
  # immutable WidePartColumn owner.
  class WidePartTransformOutput
    @keys : Array(UInt64)
    @columns : Array(WidePartColumn)

    def initialize(keys : Slice(UInt64), columns : Array(WidePartColumn))
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

    def columns : Array(WidePartColumn)
      @columns.dup
    end
  end
end
