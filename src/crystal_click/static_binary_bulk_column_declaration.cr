module CrystalClick
  # Canonical admission owner for static BinaryBulk declarations that do not
  # belong to an existing nominal or legacy typed table route. Specialized
  # SimpleAggregate, AggregateFunction, QBit, Geo, Dynamic and JSON layouts,
  # along with legacy flattened Nested storage aliases, retain separate owners.
  # Nominal static Nested nodes remain part of the recursive BinaryBulk tree.
  class StaticBinaryBulkColumnDeclaration
    getter type : BinaryDataType

    @declaration : String

    def initialize(
      @type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(@type, budget)
      canonical = BinaryTypeNameBudget.materialize(@type, budget, bounds)
      canonical_bytes = canonical.bytesize.to_u64
      budget.ensure_wire_bytes(canonical_bytes)
      budget.charge_wire_bytes(canonical_bytes)
      reject_context_owned_type!(@type)

      # String has two independently declared physical layouts. Admission is
      # descriptor-wide; the selected part's actual profile is checked again
      # by BinaryBulkColumnReader when it binds physical streams.
      {BinaryBulkProfile.single_stream, BinaryBulkProfile.with_size_stream}.each do |profile|
        plan = BinaryBulkTypePlan.new(@type, profile, nil, limits, false)
        raise UnsupportedFormatError.new("static BinaryBulk type has no physical roles") if plan.role_count == 0_u64
        BinaryBulkPhysicalPlan.new(@type, "static_binary_bulk_probe", profile, limits)
      end

      @declaration = String.new(canonical.to_slice)
    end

    def declaration : String
      String.new(@declaration.to_slice)
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

    private def reject_context_owned_type!(type : BinaryDataType) : Nil
      if type.contains_dynamic?
        raise UnsupportedFormatError.new("Dynamic requires its bound column-specific physical context")
      end
      if type.contains_json?
        raise UnsupportedFormatError.new("JSON requires its bound column-specific physical context")
      end
      if type.contains_aggregate_function?
        raise UnsupportedFormatError.new("AggregateFunction requires its nominal static owner")
      end
      if type.contains_qbit?
        raise UnsupportedFormatError.new("QBit requires its nominal static owner")
      end
      if type.contains_custom_geo?
        raise UnsupportedFormatError.new("Custom Geo requires its nominal static owner")
      end
      if contains_simple_aggregate?(type)
        raise UnsupportedFormatError.new("SimpleAggregateFunction requires its nominal static owner")
      end
      nil
    end

    private def contains_simple_aggregate?(type : BinaryDataType) : Bool
      pending = [type]
      until pending.empty?
        current = pending.pop
        return true if current.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE
        current.child_count.times do |index|
          pending << current.child_at(index)
        end
      end
      false
    end
  end
end
