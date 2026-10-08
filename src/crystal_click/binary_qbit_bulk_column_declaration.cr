module CrystalClick
  # Exact static BinaryBulk declaration adapter for Array chains ending in a
  # QBit leaf or direct Nullable(QBit). Other QBit-bearing compositions keep
  # their independent Dynamic, Object and root-column contracts.
  class BinaryQBitBulkColumnDeclaration
    getter type : BinaryDataType
    getter declaration : String

    def initialize(
      type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      # Assign the required identity before the narrow conversion boundary.
      # A method-level rescue makes Crystal consider this ivar uninitialized
      # on a rescued constructor path.
      @type = type
      budget = BinaryCodecBudget.new(limits, true)
      canonical = begin
        bounds = BinaryTypeNameBudget.measure(type, budget)
        BinaryTypeNameBudget.materialize(type, budget, bounds)
      rescue ex : ArgumentError
        raise UnsupportedFormatError.new(ex.message || "QBit declaration is outside the static bulk profile")
      end
      unless @type.qbit_array_chain?
        raise UnsupportedFormatError.new("QBit bulk declaration requires an Array chain ending in QBit or Nullable(QBit)")
      end
      BinaryQBitRecursiveAdmission.validate_static_type!(@type)
      BinaryBulkTypePlan.new(
        @type,
        BinaryBulkProfile.single_stream,
        nil,
        limits,
        true
      ).role_count
      canonical_bytes = canonical.bytesize.to_u64
      budget.ensure_wire_bytes(canonical_bytes)
      budget.charge_wire_bytes(canonical_bytes)
      @declaration = String.new(canonical.to_slice)
    end

    def self.parse(
      source : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > limits.max_bytes
      parsed = BinaryRecursiveDataTypeNameReader.parse_canonical(source, limits) || return nil
      declaration = new(parsed, limits)
      return nil unless declaration.declaration == source
      parsed
    rescue ex : ArgumentError | BoundsError | CorruptPartError | UnsupportedFormatError
      nil
    end
  end
end
