module CrystalClick
  # Detached immutable input description for one fixed-profile Compact value
  # column. The public factory snapshots the caller's granule containers; the
  # values and descriptor are already immutable owners.
  class CompactPartColumn
    getter name : String
    getter type : BinaryDataType

    @granules : Array(Array(BinaryValue))
    @dynamic_context : CompactDynamicWriteContext?

    private def initialize(
      @name : String,
      @type : BinaryDataType,
      @granules : Array(Array(BinaryValue)),
      @dynamic_context : CompactDynamicWriteContext?,
    )
    end

    def self.binary_bulk(
      name : String,
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
    ) : CompactPartColumn
      owned_name = String.new(name.to_slice)
      owned_granules = Array(Array(BinaryValue)).new(granules.size)
      granules.each { |rows| owned_granules << rows.dup }
      new(owned_name, type, owned_granules, nil)
    end

    # Explicitly binds the detached Dynamic site roster required to serialize
    # first-prefix statistics and freeze later callback structure.
    def self.dynamic_bulk(
      name : String,
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      dynamic_context : CompactDynamicWriteContext,
    ) : CompactPartColumn
      unless type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic column requires a Dynamic-bearing descriptor")
      end
      owned_name = String.new(name.to_slice)
      owned_granules = Array(Array(BinaryValue)).new(granules.size)
      granules.each { |rows| owned_granules << rows.dup }
      new(owned_name, type, owned_granules, dynamic_context)
    end

    # Internal bridge to the Compact-only physical backend. This intentionally
    # does not accept a Wide profile, map mode, or other ignored writer option.
    def static_input : CompactStaticColumnInput
      if @dynamic_context
        raise UnsupportedFormatError.new("Compact Dynamic input requires an explicit Dynamic write context")
      end
      detached_granules = Array(Array(BinaryValue)).new(@granules.size)
      @granules.each do |rows|
        detached_rows = Array(BinaryValue).new(rows.size)
        rows.each { |value| detached_rows << value }
        detached_granules << detached_rows
      end
      CompactStaticColumnInput.new(@name, @type, detached_granules)
    end

    def dynamic_input : CompactDynamicColumnInput
      context = @dynamic_context ||
                raise UnsupportedFormatError.new("unbound Compact binary_bulk Dynamic input is not admitted")
      CompactDynamicColumnInput.new(@name, @type, @granules, context)
    end

    def dynamic_context? : Bool
      !@dynamic_context.nil?
    end

    def input_workspace_bytes : UInt64
      if context = @dynamic_context
        checked_workspace_add(dynamic_granule_workspace_bytes, context.retained_workspace_bytes)
      else
        static_input_workspace_bytes
      end
    end

    # Logical allocation estimate for the detached array containers created by
    # #static_input. The contained BinaryValue nodes are immutable owners.
    def static_input_workspace_bytes : UInt64
      bytes = instance_sizeof(Array(Array(BinaryValue))).to_u64
      bytes = checked_workspace_add(
        bytes,
        checked_workspace_multiply(@granules.size.to_u64, sizeof(Pointer(Array(BinaryValue))).to_u64),
      )
      @granules.each do |rows|
        bytes = checked_workspace_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
        bytes = checked_workspace_add(
          bytes,
          checked_workspace_multiply(rows.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64),
        )
      end
      bytes
    end

    private def dynamic_granule_workspace_bytes : UInt64
      bytes = instance_sizeof(Array(Array(BinaryValue))).to_u64
      bytes = checked_workspace_add(
        bytes,
        checked_workspace_multiply(@granules.size.to_u64, sizeof(Pointer(Array(BinaryValue))).to_u64),
      )
      @granules.each do |rows|
        bytes = checked_workspace_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
        bytes = checked_workspace_add(
          bytes,
          checked_workspace_multiply(rows.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64),
        )
      end
      bytes
    end

    private def checked_workspace_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact static-input workspace overflows UInt64")
      end
      left + right
    end

    private def checked_workspace_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact static-input workspace overflows UInt64")
      end
      left * right
    end
  end
end
