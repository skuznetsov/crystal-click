module CrystalClick
  # Detached recursive storage-value grid bound to explicit per-site Object
  # structure/statistics authority. Values and schemas are immutable owners;
  # only mark and child-reference containers are copied here.
  class CompactJsonColumnInput
    getter name : String
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter schema : StorageColumnSchema
    getter granules : Array(Array(StorageColumnValue))
    getter json_context : CompactJsonWriteContext

    def initialize(
      name : String,
      @schema : StorageColumnSchema,
      granules : Array(Array(StorageColumnValue)),
      @json_context : CompactJsonWriteContext,
      canonical_type : BinaryDataType? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    )
      if name.empty?
        raise ArgumentError.new("Compact JSON column name must be nonempty")
      end
      unless CompactRecursiveJsonSchemaPlan.admitted_schema?(@schema)
        raise UnsupportedFormatError.new("Compact JSON schema is outside the admitted static-site subset")
      end
      if @schema.object?
        parsed = CompactJsonColumnAdapter.schema_for_json_declaration(
          @schema.source_declaration,
          BinaryBulkCodec::DEFAULT_LIMITS,
        ) || raise(UnsupportedFormatError.new("Compact JSON root schema declaration is not admitted"))
        unless @schema.same_tree?(parsed)
          raise UnsupportedFormatError.new("Compact JSON root schema differs from its source declaration")
        end
      else
        @schema.validate_source_tree!(BinaryBulkCodec::DEFAULT_LIMITS)
      end
      @type = if type = canonical_type
                type_budget = BinaryCodecBudget.new(BinaryBulkCodec::DEFAULT_LIMITS, true)
                bounds = BinaryTypeNameBudget.measure(type, type_budget)
                rendered = BinaryTypeNameBudget.materialize(type, type_budget, bounds)
                unless rendered == @schema.declaration
                  raise UnsupportedFormatError.new("Compact JSON descriptor differs from its canonical storage schema")
                end
                type
              else
                BinaryRecursiveDataTypeNameReader.parse_canonical(@schema.declaration) ||
                  raise(UnsupportedFormatError.new("Compact JSON schema has no canonical BinaryDataType"))
              end
      unless @type.contains_json? && !@type.contains_dynamic?
        raise UnsupportedFormatError.new("Compact JSON input requires static JSON sites without Dynamic-owned JSON")
      end

      @name = String.new(name.to_slice)
      @profile = profile
      @granules = Array(Array(StorageColumnValue)).new(granules.size)
      granules.each { |rows| @granules << rows.dup }
    end

    def map_basic? : Bool
      true
    end

    def granule_workspace_bytes : UInt64
      bytes = instance_sizeof(Array(Array(StorageColumnValue))).to_u64
      bytes = checked_add(
        bytes,
        checked_multiply(@granules.size.to_u64, sizeof(Pointer(Array(StorageColumnValue))).to_u64),
      )
      @granules.each do |rows|
        bytes = checked_add(bytes, instance_sizeof(Array(StorageColumnValue)).to_u64)
        bytes = checked_add(
          bytes,
          checked_multiply(rows.size.to_u64, sizeof(Pointer(StorageColumnValue)).to_u64),
        )
      end
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact JSON input workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact JSON input workspace overflows UInt64")
      end
      left * right
    end
  end
end
