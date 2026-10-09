module CrystalClick
  # Closed owner for the implicit fixed-order Variant body of Custom(Geometry).
  # The descriptor wire contains only the nominal Custom name; this owner
  # preflights its complete hidden graph under the caller's shared budget.
  class BinaryGeometryStorageType
    HIDDEN_NODE_COUNT = 49_u64
    MAX_HIDDEN_DEPTH  =     10

    # Relative depths below the nominal Custom(Geometry) root. The fixed tree
    # comprises the Variant body and its seven recursively nested Geo arms.
    def self.storage_type : BinaryDataType
      # This no-argument factory alone constructs the source-fixed discriminator
      # order. Never accept a caller roster or pass it through normal sorting.
      BinaryDataType.custom("Geometry").child_at(0)
    end

    def self.preflight_expansion(budget : BinaryCodecBudget, root_depth : Int) : Nil
      budget.ensure_depth(root_depth + MAX_HIDDEN_DEPTH)
      budget.preflight_children(HIDDEN_NODE_COUNT)

      offset = 1
      while offset <= MAX_HIDDEN_DEPTH
        nodes_at_hidden_depth(offset).times { budget.visit_node(root_depth + offset) }
        offset += 1
      end
      nil
    end

    private def self.nodes_at_hidden_depth(offset : Int32) : Int32
      case offset
      when  1 then 1
      when  2 then 7
      when  3 then 7
      when  4 then 8
      when  5 then 6
      when  6 then 9
      when  7 then 3
      when  8 then 5
      when  9 then 1
      when 10 then 2
      else
        0
      end
    end
  end
end
