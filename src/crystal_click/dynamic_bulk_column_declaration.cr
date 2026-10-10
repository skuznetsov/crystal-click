module CrystalClick
  # Bounded schema admission for the generic Dynamic BinaryBulk table route.
  # ObjectRecursiveDeclaration remains the authority for its bounded recursive
  # grammar, with a DynamicBulk profile for nominal Nested and static Map keys.
  class DynamicBulkColumnDeclaration
    DEFAULT_LIMITS = ObjectRecursiveDeclaration::DEFAULT_LIMITS

    def self.parse(
      source : String,
      root_depth : Int = 1,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    ) : BinaryDataType?
      return nil if source == "Dynamic"

      bytes = source.to_slice
      preflight = ObjectRecursiveDeclaration.preflight_slice(
        bytes, 0, bytes.size, limits, root_depth,
        ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk,
      ) || return nil
      budget = BinaryCodecBudget.new(limits, true)
      # Preflight.account charges descendants and metadata, while this owner
      # owns and charges the complete descriptor root exactly once.
      budget.visit_node(root_depth)
      preflight.account(budget)
      type = preflight.materialize

      return nil unless type.contains_dynamic? && !type.contains_json?

      # A declaration that renders as the exact legacy scalar remains on its
      # specialized route even if it reached this owner through another source
      # spelling.
      canonical = canonical_name(type, root_depth, limits)
      return nil if canonical == "Dynamic"
      return nil unless canonical == source

      type
    end

    private def self.canonical_name(
      type : BinaryDataType,
      root_depth : Int,
      limits : BinaryCodecLimits,
    ) : String
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(type, budget, root_depth)
      BinaryTypeNameBudget.materialize(type, budget, bounds)
    end
  end
end
