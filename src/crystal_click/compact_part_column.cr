module CrystalClick
  # Detached immutable input description for one fixed-profile Compact value
  # column. The public factory snapshots the caller's granule containers; the
  # values and descriptor are already immutable owners.
  class CompactPartColumn
    getter name : String
    getter type : BinaryDataType

    @granules : Array(Array(BinaryValue))
    @dynamic_context : CompactDynamicWriteContext?
    @json_schema : StorageColumnSchema?
    @json_granules : Array(Array(StorageColumnValue))?
    @json_context : CompactJsonWriteContext?
    @recursive_dynamic_context : CompactRecursiveDynamicWriteContext?

    private def initialize(
      @name : String,
      @type : BinaryDataType,
      @granules : Array(Array(BinaryValue)),
      @dynamic_context : CompactDynamicWriteContext?,
      @json_schema : StorageColumnSchema? = nil,
      @json_granules : Array(Array(StorageColumnValue))? = nil,
      @json_context : CompactJsonWriteContext? = nil,
      @recursive_dynamic_context : CompactRecursiveDynamicWriteContext? = nil,
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

    # Static Object sites retain their schema/value carriers and an explicit
    # first-block serialization context, rather than flattening JSON into an
    # ordinary BinaryValue byte lane.
    def self.json(
      name : String,
      schema : StorageColumnSchema,
      granules : Array(Array(StorageColumnValue)),
      json_context : CompactJsonWriteContext,
      dynamic_contexts : Hash(String, CompactDynamicWriteContext) = {} of String => CompactDynamicWriteContext,
    ) : CompactPartColumn
      unless CompactRecursiveJsonSchemaPlan.admitted_schema?(schema)
        raise UnsupportedFormatError.new("Compact JSON column schema is outside the admitted static-site subset")
      end
      type = BinaryRecursiveDataTypeNameReader.parse_canonical(schema.declaration) ||
             raise UnsupportedFormatError.new("Compact JSON column requires a canonical JSON-bearing descriptor")
      recursive_dynamic_context = CompactRecursiveDynamicWriteContext.new(schema, dynamic_contexts)
      owned_granules = Array(Array(StorageColumnValue)).new(granules.size)
      granules.each { |rows| owned_granules << rows.dup }
      new(
        String.new(name.to_slice), type, [] of Array(BinaryValue), nil,
        schema, owned_granules, json_context, recursive_dynamic_context,
      )
    end

    # Internal bridge to the Compact-only physical backend. The shared
    # BinaryBulkProfile selects String layout; unrelated Wide-only storage
    # options and map modes are not accepted here.
    def static_input(profile : BinaryBulkProfile = BinaryBulkProfile.single_stream) : CompactStaticColumnInput
      if @dynamic_context || @json_context
        raise UnsupportedFormatError.new("context-owned Compact input cannot use the static input bridge")
      end
      detached_granules = Array(Array(BinaryValue)).new(@granules.size)
      @granules.each do |rows|
        detached_rows = Array(BinaryValue).new(rows.size)
        rows.each { |value| detached_rows << value }
        detached_granules << detached_rows
      end
      CompactStaticColumnInput.new(@name, @type, detached_granules, profile)
    end

    def dynamic_input(
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : CompactDynamicColumnInput
      context = @dynamic_context ||
                raise UnsupportedFormatError.new("unbound Compact binary_bulk Dynamic input is not admitted")
      CompactDynamicColumnInput.new(@name, @type, @granules, context, profile)
    end

    def dynamic_context? : Bool
      !@dynamic_context.nil?
    end

    def json_input(
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : CompactJsonColumnInput
      context = @json_context || raise UnsupportedFormatError.new("unbound Compact JSON input is not admitted")
      dynamic_context = @recursive_dynamic_context ||
                        raise UnsupportedFormatError.new("Compact JSON input has no recursive Dynamic context")
      schema = @json_schema || raise UnsupportedFormatError.new("Compact JSON input has no schema")
      granules = @json_granules || raise UnsupportedFormatError.new("Compact JSON input has no storage values")
      CompactJsonColumnInput.new(
        @name, schema, granules, context, @type, profile,
        recursive_dynamic_context: dynamic_context,
      )
    end

    def json_context? : Bool
      !@json_context.nil?
    end

    def input_workspace_bytes : UInt64
      if context = @json_context
        bytes = checked_workspace_add(json_granule_workspace_bytes, context.retained_workspace_bytes)
        if dynamic_context = @recursive_dynamic_context
          checked_workspace_add(bytes, dynamic_context.retained_workspace_bytes)
        else
          bytes
        end
      elsif context = @dynamic_context
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

    private def json_granule_workspace_bytes : UInt64
      granules = @json_granules || raise UnsupportedFormatError.new("Compact JSON input has no storage values")
      bytes = instance_sizeof(Array(Array(StorageColumnValue))).to_u64
      bytes = checked_workspace_add(
        bytes,
        checked_workspace_multiply(granules.size.to_u64, sizeof(Pointer(Array(StorageColumnValue))).to_u64),
      )
      granules.each do |rows|
        bytes = checked_workspace_add(bytes, instance_sizeof(Array(StorageColumnValue)).to_u64)
        bytes = checked_workspace_add(bytes, checked_workspace_multiply(rows.size.to_u64, sizeof(Pointer(StorageColumnValue)).to_u64))
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
