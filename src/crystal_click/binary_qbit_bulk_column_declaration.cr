module CrystalClick
  # Exact static BinaryBulk declaration adapter for admitted recursive QBit
  # products. Root QBit and Nullable(QBit) retain their dedicated owners;
  # Dynamic, Object, Variant and other runtime layouts remain out of scope.
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
      root_qbit = @type.tag == BinaryDataType::TAG_QBIT ||
                  (@type.tag == BinaryDataType::TAG_NULLABLE &&
                   @type.child_at(0).tag == BinaryDataType::TAG_QBIT)
      unless @type.contains_qbit? && !root_qbit
        raise UnsupportedFormatError.new("QBit bulk declaration requires an admitted recursive static product")
      end
      BinaryQBitRecursiveAdmission.validate_static_type!(@type)
      plan = BinaryBulkTypePlan.new(
        @type,
        BinaryBulkProfile.single_stream,
        nil,
        limits,
        true
      )
      if plan.qbit_static_sites.empty?
        raise UnsupportedFormatError.new("QBit bulk declaration has no recursive static leaf sites")
      end
      plan.role_count
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
