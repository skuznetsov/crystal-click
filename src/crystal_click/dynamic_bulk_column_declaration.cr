module CrystalClick
  # Bounded schema admission for the generic Dynamic BinaryBulk table route.
  # ObjectRecursiveDeclaration remains the authority for its existing grammar;
  # this owner only adapts a root Nested through its implicit named Tuple.
  class DynamicBulkColumnDeclaration
    DEFAULT_LIMITS = ObjectRecursiveDeclaration::DEFAULT_LIMITS

    def self.parse(
      source : String,
      root_depth : Int = 1,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    ) : BinaryDataType?
      return nil if source == "Dynamic"

      bytes = source.to_slice
      type = if root_nested_source?(bytes)
               parse_root_nested(bytes, root_depth, limits) || return nil
             else
               preflight = ObjectRecursiveDeclaration.preflight_slice(
                 bytes, 0, bytes.size, limits, root_depth
               ) || return nil
               budget = BinaryCodecBudget.new(limits, true)
               preflight.account(budget)
               preflight.materialize
             end

      return nil unless type.contains_dynamic? && !type.contains_json?

      # A declaration that renders as the exact legacy scalar remains on its
      # specialized route even if it reached this owner through another source
      # spelling.
      canonical = canonical_name(type, root_depth, limits)
      return nil if canonical == "Dynamic"
      return nil unless canonical == source

      type
    end

    private def self.parse_root_nested(
      bytes : Bytes,
      root_depth : Int,
      limits : BinaryCodecLimits,
    ) : BinaryDataType?
      return nil unless root_nested_source?(bytes)
      return nil if root_depth <= 0 || root_depth >= Int32::MAX
      return nil if limits.max_nodes < 1 || limits.max_elements < 1 || limits.max_bytes < 1
      # Bound the borrowed declaration before allocating its adapted Tuple
      # spelling. Nested is exactly one byte longer than the implicit Tuple.
      return nil if bytes.size.to_i64 > limits.max_bytes

      body_first = "Nested(".bytesize
      body_after = bytes.size - 1
      return nil if body_first >= body_after

      # The existing parser sees the exact implicit Tuple tree one level below
      # Nested. Reserve the nominal root node, its Tuple edge, and the one-byte
      # Nested/Tuple prefix-width difference in the inherited limits.
      tuple_limits = BinaryCodecLimits.new(
        max_depth: limits.max_depth,
        max_nodes: limits.max_nodes - 1,
        max_elements: limits.max_elements - 1,
        max_bytes: limits.max_bytes - 1,
      )
      tuple_source_size = bytes.size - 1
      return nil if tuple_source_size.to_i64 > tuple_limits.max_bytes
      tuple_source = String.build(tuple_source_size) do |io|
        io << "Tuple("
        io.write(bytes[body_first, body_after - body_first])
        io << ')'
      end
      tuple_bytes = tuple_source.to_slice
      tuple_preflight = ObjectRecursiveDeclaration.preflight_slice(
        tuple_bytes, 0, tuple_bytes.size, tuple_limits, root_depth + 1
      ) || return nil

      # Account the nominal outer node and its implicit child before the
      # parser's preflight account/materialization sequence. The adapted tuple
      # adds one byte here so the budget receives the original Nested spelling
      # length plus all inherited metadata charges.
      budget = BinaryCodecBudget.new(limits, true)
      budget.visit_node(root_depth)
      budget.preflight_children(1_u64)
      tuple_preflight.account(budget)
      # account_admitted_slice's byte_size + 1 is the inherited parser
      # allowance; charge the distinct Nested-vs-Tuple spelling delta too.
      budget.charge_wire_bytes(1_u64)

      tuple_type = tuple_preflight.materialize
      return nil unless tuple_type.named_tuple? && tuple_type.child_count > 0

      BinaryDataType.nested(tuple_type)
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

    private def self.root_nested_source?(bytes : Bytes) : Bool
      bytes.size > "Nested()".bytesize &&
        bytes[0, "Nested(".bytesize] == "Nested(".to_slice &&
        bytes[bytes.size - 1] == ')'.ord.to_u8
    end
  end
end
