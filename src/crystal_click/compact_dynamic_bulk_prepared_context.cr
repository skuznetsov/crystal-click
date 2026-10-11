module CrystalClick
  # Immutable part-wide Dynamic state learned from a complete parsed structure
  # prefix set. Compact granules may repeat the structure prefix and carry
  # different statistics, but their physical value roster must remain bound to
  # this single prepared Dynamic plan.
  class CompactDynamicBulkPreparedContext
    getter plan : BinaryDynamicBulkPlan
    getter physical : BinaryDynamicBulkPhysicalPlan
    getter column_name : String

    def initialize(
      type : BinaryDataType,
      column_name : String,
      profile : BinaryBulkProfile,
      structures : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
    )
      unless !budget.writing?
        raise ArgumentError.new("Compact Dynamic prepared context requires a read-direction budget")
      end
      unless type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic prepared context requires a Dynamic-bearing descriptor")
      end
      raise ArgumentError.new("Compact Dynamic selected column name must be nonempty") if column_name.empty?

      CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(type, budget.limits)
      structures.each_value do |structure|
        structure.type_count.times do |index|
          CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(
            structure.type_at(index), budget.limits
          )
        end
      end

      @column_name = String.new(column_name.to_slice)
      @plan = BinaryDynamicBulkPlan.decode_structure_prefixes_without_statistics_from_structures(
        type,
        structures,
        budget,
        profile,
      )
      @physical = BinaryDynamicBulkPhysicalPlan.new(@plan, column_name, budget.limits)
    end

    # Validate a repeated per-granule structure set against the part-wide
    # frozen plan. Statistics are intentionally excluded: they are local to a
    # granule. Version and ordinary descriptor order are wire identity and may
    # not drift while data lanes continue to use the original physical roster.
    def validate_granule_roster!(structures : Hash(String, DynamicStructure)) : Nil
      unless structures.size == @plan.site_count
        raise CorruptPartError.new("Compact Dynamic granule structure site set differs from its frozen plan")
      end

      @plan.each_site_path do |path|
        expected = @plan.structure_for(path)
        observed = structures[path]? ||
                   raise(CorruptPartError.new("Compact Dynamic granule is missing a frozen structure site"))
        unless same_roster?(expected, observed)
          raise CorruptPartError.new("Compact Dynamic granule structure roster differs from its frozen plan")
        end
      end
      structures.each_key do |path|
        unless @plan.has_site?(path)
          raise CorruptPartError.new("Compact Dynamic granule contains an unplanned structure site")
        end
      end
      nil
    end

    # Validate a site immediately while an online prefix traversal is still
    # inside that site's actual-arm subtree. A changed parent roster must not
    # redirect discovery into descriptors that differ from the frozen plan.
    def validate_site_roster!(path : String, observed : DynamicStructure) : Nil
      expected = @plan.structure_for(path)
      unless same_roster?(expected, observed)
        raise CorruptPartError.new("Compact Dynamic granule structure roster differs from its frozen plan")
      end
      nil
    end

    private def same_roster?(left : DynamicStructure, right : DynamicStructure) : Bool
      return false unless left.version == right.version
      return false unless left.legacy_max_dynamic_types == right.legacy_max_dynamic_types
      return false unless left.type_count == right.type_count
      return false unless left.shared_index == right.shared_index

      left.type_count.times do |index|
        return false unless left.type_at(index) == right.type_at(index)
      end
      true
    end
  end
end
