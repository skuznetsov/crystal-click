module CrystalClick
  # Metadata-only mark accounting for a public Compact JSON carrier.
  # `temporary_bytes` is the largest one-reader recursive result shell/tree
  # that coexists with already retained columns; `carrier_bytes` is the
  # public carrier owner for this selected mark.
  struct CompactJsonMarkPreflight
    getter shape : StorageValueShape
    getter temporary_bytes : UInt64
    getter carrier_bytes : UInt64
    getter carrier_nodes : UInt64
    getter carrier_elements : UInt64

    def initialize(
      @shape : StorageValueShape,
      @temporary_bytes : UInt64,
      @carrier_bytes : UInt64,
      @carrier_nodes : UInt64,
      @carrier_elements : UInt64,
    )
    end

    def total_bytes : UInt64
      checked_add(checked_add(@temporary_bytes, @carrier_bytes), @shape.bytes)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Compact JSON owner accounting overflows UInt64") if right > UInt64::MAX - left
      left + right
    end
  end
end
