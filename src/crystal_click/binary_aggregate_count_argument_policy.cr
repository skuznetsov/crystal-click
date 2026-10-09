module CrystalClick
  # Admission law for Count's nominal argument metadata. The argument is
  # parsed and rendered under independent limits; it never enters generic
  # value-child traversal.
  class BinaryAggregateCountArgumentPolicy
    DEFAULT_LIMITS               = BinaryCodecLimits.default
    NO_ARGUMENT_COUNT_NAME_BOUND = 24_u64

    def self.admitted?(argument_type : BinaryDataType?, limits : BinaryCodecLimits = DEFAULT_LIMITS) : Bool
      budget = BinaryCodecBudget.new(limits, true)
      budget.visit_node(1)

      unless argument_type
        # The no-argument Count shell has a 24-byte output bound and holds
        # the builder/final pair while materializing its name.
        budget.ensure_wire_bytes(BinaryTypeNameBudget.multiply(NO_ARGUMENT_COUNT_NAME_BOUND, 2_u64))
        return true
      end

      argument = argument_type.not_nil!
      return false if argument.contains_qbit?
      return false if argument.contains_aggregate_function?
      return false if argument.contains_custom_geo?
      return false if nullable_nothing?(argument)

      # Count is the root descriptor, and its argument is a metadata edge.
      # Charge both before recursively budgeting the argument so admission
      # uses the same depth, node, and edge context as the full type tree.
      budget.preflight_children(1_u64)
      bounds = BinaryTypeNameBudget.measure(argument, budget, 2)

      # Admission materializes the argument name before validating its
      # canonical parse. Preflight the whole Count name/allocation bound first,
      # including the argument's bounded temporary formatting work.
      count_output_bound = BinaryTypeNameBudget.add(26_u64, bounds[0])
      count_name_work_bound = BinaryTypeNameBudget.add(
        BinaryTypeNameBudget.multiply(count_output_bound, 2_u64),
        bounds[1],
      )
      budget.ensure_wire_bytes(count_name_work_bound)

      name = BinaryTypeNameBudget.materialize(argument, budget, bounds)
      canonical = BinaryAggregateCountArgumentNameParser.parse_canonical(name, limits) || return false
      canonical == argument
    rescue ex : ArgumentError | CorruptPartError | UnsupportedFormatError
      false
    end

    # Recursive descriptor call graphs must retain this method's exception edge.
    @[Raises]
    def self.require!(argument_type : BinaryDataType?, limits : BinaryCodecLimits = DEFAULT_LIMITS) : Nil
      unless admitted?(argument_type, limits)
        raise ArgumentError.new("AggregateFunction(count) argument is outside the bounded canonical profile")
      end
      nil
    end

    private def self.nullable_nothing?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NULLABLE &&
        type.child_count == 1 && type.child_at(0).tag == BinaryDataType::TAG_NOTHING
    end
  end
end
