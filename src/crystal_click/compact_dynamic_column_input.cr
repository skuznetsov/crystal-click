module CrystalClick
  # Internal immutable value-column snapshot that binds one Dynamic structure
  # context to its detached per-mark BinaryValue containers.
  class CompactDynamicColumnInput
    getter name : String
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter granules : Array(Array(BinaryValue))
    getter dynamic_context : CompactDynamicWriteContext

    def initialize(
      name : String,
      @type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      @dynamic_context : CompactDynamicWriteContext,
    )
      if name.empty?
        raise ArgumentError.new("Compact Dynamic column name must be nonempty")
      end
      unless @type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic column input requires a Dynamic-bearing descriptor")
      end

      @name = String.new(name.to_slice)
      @profile = BinaryBulkProfile.single_stream
      @granules = Array(Array(BinaryValue)).new(granules.size)
      granules.each do |rows|
        @granules << rows.dup
      end
    end

    def map_basic? : Bool
      true
    end

    def granule_workspace_bytes : UInt64
      bytes = instance_sizeof(Array(Array(BinaryValue))).to_u64
      bytes = checked_add(bytes, checked_multiply(@granules.size.to_u64, sizeof(Pointer(Array(BinaryValue))).to_u64))
      @granules.each do |rows|
        bytes = checked_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
      end
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact Dynamic input workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact Dynamic input workspace overflows UInt64")
      end
      left * right
    end
  end
end
