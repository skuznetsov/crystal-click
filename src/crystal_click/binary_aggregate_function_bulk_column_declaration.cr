module CrystalClick
  # Exact root-only physical admission for Sum-family AggregateFunction
  # states. Logical type parsing remains recursive, but bulk storage consumes
  # only one opaque state lane and never reinterprets the argument as a value.
  class BinaryAggregateFunctionBulkColumnDeclaration
    getter type : BinaryDataType
    getter declaration : String
    getter state_plan : BinaryAggregateFunctionStatePlan

    def initialize(type : BinaryDataType, limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS)
      @type = type
      built = build(type, limits)
      @state_plan = built[0]
      @declaration = built[1]
    end

    private def build(type : BinaryDataType, limits : BinaryCodecLimits) : Tuple(BinaryAggregateFunctionStatePlan, String)
      unless type.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION && !type.aggregate_count_type
        raise UnsupportedFormatError.new("static AggregateFunction bulk requires a root Sum-family state")
      end

      state_plan = BinaryAggregateFunctionStatePlan.for_type(type)
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      declaration = BinaryTypeNameBudget.materialize(type, budget, bounds)
      {state_plan, declaration}
    rescue ex : ArgumentError
      raise UnsupportedFormatError.new(ex.message || "AggregateFunction declaration is outside the static bulk profile")
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
