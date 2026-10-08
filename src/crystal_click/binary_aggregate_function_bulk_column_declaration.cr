module CrystalClick
  # Exact physical admission for AggregateFunction state leaves in the static
  # recursive BinaryBulk profile. Arguments remain descriptor metadata and
  # are never reinterpreted as values.
  class BinaryAggregateFunctionBulkColumnDeclaration
    getter type : BinaryDataType
    getter declaration : String

    @state_plan : BinaryAggregateFunctionStatePlan?

    def initialize(type : BinaryDataType, limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS)
      @type = type
      built = build(type, limits)
      @state_plan = built[0]
      @declaration = built[1]
    end

    # Preserve the root-Sum accessor for existing callers. Recursive
    # declarations have multiple opaque state leaves and therefore do not
    # expose a singular root state plan.
    def state_plan : BinaryAggregateFunctionStatePlan
      @state_plan || raise UnsupportedFormatError.new("recursive AggregateFunction bulk has no singular root state plan")
    end

    private def build(type : BinaryDataType, limits : BinaryCodecLimits) : Tuple(BinaryAggregateFunctionStatePlan?, String)
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      declaration = BinaryTypeNameBudget.materialize(type, budget, bounds)
      unless type.contains_aggregate_function? &&
             BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(type)
        raise UnsupportedFormatError.new("type is outside the recursive AggregateFunction static bulk profile")
      end
      if type.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION && type.aggregate_count_type
        raise UnsupportedFormatError.new("root AggregateFunction(count) retains its specialized bulk profile")
      end

      state_plan = if type.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION
                     BinaryAggregateFunctionStatePlan.for_type(type)
                   else
                     nil
                   end
      validate_descendant_state_plans!(type)
      {state_plan, declaration}
    rescue ex : ArgumentError
      raise UnsupportedFormatError.new(ex.message || "AggregateFunction declaration is outside the static bulk profile")
    end

    private def validate_descendant_state_plans!(type : BinaryDataType) : Nil
      type.child_count.times do |index|
        child = type.child_at(index)
        if child.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION && !child.aggregate_count_type
          BinaryAggregateFunctionStatePlan.for_type(child)
        end
        validate_descendant_state_plans!(child)
      end
      nil
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
