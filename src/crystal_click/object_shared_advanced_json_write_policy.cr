module CrystalClick
  # Opt-in writer roster policy for ordinary Dynamic JSON actuals in advanced
  # shared per-path Data. Nil policy leaves the existing all-spill behavior.
  class ObjectSharedAdvancedJsonWritePolicy
    getter max_ordinary_types : Int32

    @actuals : Array(ObjectSharedAdvancedJsonActualPlan)

    def initialize(
      actuals : Array(ObjectSharedAdvancedJsonActualPlan),
      @max_ordinary_types : Int32 = 16,
    )
      unless 1 <= @max_ordinary_types <= DynamicStructure::MAX_ORDINARY_TYPES
        raise ArgumentError.new("ordinary JSON actual cap must be between one and 254")
      end
      if actuals.empty?
        raise ArgumentError.new("shared JSON write policy requires at least one prepared actual")
      end

      retained = Array(ObjectSharedAdvancedJsonActualPlan).new(actuals.size)
      actuals.each_with_index do |candidate, index|
        index.times do |previous|
          if actuals[previous].actual_type == candidate.actual_type
            raise ArgumentError.new("shared JSON actual plans must be unique by exact descriptor")
          end
        end
        retained << candidate
      end
      @actuals = retained
    end

    def actual_count : Int32
      @actuals.size
    end

    def actual_at(index : Int) : ObjectSharedAdvancedJsonActualPlan
      @actuals[index]
    end

    # Select only prepared JSON-bearing types observed in this chunk. Other
    # actuals remain SharedVariant values; a JSON-bearing but unprepared type
    # is a hard refusal, never an implicit spill that hides a missing binding.
    def ordinary_types_for(
      observed_types : Array(BinaryDataType),
      budget : BinaryCodecBudget,
    ) : Array(BinaryDataType)
      unless budget.writing?
        raise ArgumentError.new("shared JSON roster preparation requires a write-direction budget")
      end
      budget.preflight_children(observed_types.size.to_u64) unless observed_types.empty?
      selected = Array(BinaryDataType).new(observed_types.size)
      observed_types.each do |observed|
        budget.visit_node(1)
        next unless observed.contains_json?
        unless actual_plan_for(observed)
          raise UnsupportedFormatError.new("observed JSON-bearing Dynamic actual has no prepared child plan")
        end
        next if selected.any? { |existing| existing == observed }
        selected << observed
      end
      if selected.size > @max_ordinary_types
        raise UnsupportedFormatError.new("prepared JSON actual roster exceeds the configured ordinary-type cap")
      end
      selected.sort_by!(&.name)
      selected
    end

    # A nested Dynamic descriptor owns its own ordinary-arm cap. Prepared JSON
    # actuals are mandatory ordinary arms; non-JSON types fill only the
    # remaining local slots and overflow through that site's SharedVariant.
    def ordinary_types_for_dynamic_site(
      observed_types : Array(BinaryDataType),
      local_cap : Int32,
      budget : BinaryCodecBudget,
    ) : Array(BinaryDataType)
      unless budget.writing?
        raise ArgumentError.new("nested Dynamic roster preparation requires a write-direction budget")
      end
      unless 0 <= local_cap <= DynamicStructure::MAX_ORDINARY_TYPES
        raise UnsupportedFormatError.new("nested Dynamic ordinary-type cap is outside its supported range")
      end

      scratch_count = observed_types.size.to_u64
      if scratch_count > UInt64::MAX // 2_u64
        raise UnsupportedFormatError.new("nested Dynamic roster work overflows UInt64")
      end
      budget.preflight_children(scratch_count * 2_u64) if scratch_count > 0_u64
      required_json = Array(BinaryDataType).new(observed_types.size)
      other_candidates = Array(BinaryDataType).new(observed_types.size)
      observed_types.each do |observed|
        budget.visit_node(1)
        target = observed.contains_json? ? required_json : other_candidates
        next if target.any? { |existing| existing == observed }
        if observed.contains_json?
          unless actual_plan_for(observed)
            raise UnsupportedFormatError.new("nested JSON-bearing Dynamic actual has no prepared child plan")
          end
          unless dynamic_ordinary_type_admitted?(observed)
            raise UnsupportedFormatError.new("prepared nested JSON actual is not an admitted Dynamic ordinary type")
          end
        elsif !dynamic_ordinary_type_admitted?(observed)
          # This value can still use the exact Dynamic SharedVariant scalar
          # envelope; it is not silently promoted to an ordinary lane.
          next
        end
        target << observed
      end

      if required_json.size > local_cap
        raise UnsupportedFormatError.new("prepared JSON actual roster exceeds its Dynamic descriptor cap")
      end
      required_json.sort_by!(&.name)
      other_candidates.sort_by!(&.name)
      selected = required_json
      remaining = local_cap - selected.size
      other_candidates.each do |type|
        break if remaining == 0
        selected << type
        remaining -= 1
      end
      selected.sort_by!(&.name)
      selected
    end

    # Rebind complete prepared paths to the exact site and canonical arm
    # indices selected by this chunk's DynamicStructure.
    def leaf_bindings_for(
      site : String,
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))
      count = 0_u64
      structure.type_count.times do |index|
        type = structure.type_at(index)
        next unless type.contains_json?
        plan = actual_plan_for(type) || raise(UnsupportedFormatError.new("Dynamic structure contains an unprepared JSON actual"))
        count = checked_add(count, plan.child_plan_count.to_u64, budget)
      end
      budget.preflight_children(count) if count > 0_u64
      bindings = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(count.to_i)
      structure.type_count.times do |index|
        type = structure.type_at(index)
        next unless type.contains_json?
        plan = actual_plan_for(type) || raise(UnsupportedFormatError.new("Dynamic structure contains an unprepared JSON actual"))
        canonical_index = structure.canonical_index_for(type)
        plan.child_plan_count.times do |child_index|
          path = plan.child_descriptor_path_at(child_index)
          key = BinaryDynamicJsonLeafKey.new(site, canonical_index, path)
          bindings << {key, plan.child_plan_at(child_index)}
          budget.charge_node
        end
      end
      unless bindings.size.to_u64 == count
        raise UnsupportedFormatError.new("prepared Dynamic JSON leaf binding roster changed after admission")
      end
      bindings
    end

    private def actual_plan_for(type : BinaryDataType) : ObjectSharedAdvancedJsonActualPlan?
      @actuals.find { |candidate| candidate.actual_type == type }
    end

    private def dynamic_ordinary_type_admitted?(type : BinaryDataType) : Bool
      return false if type.tag == BinaryDataType::TAG_DYNAMIC ||
                      type.tag == BinaryDataType::TAG_VARIANT ||
                      type.tag == BinaryDataType::TAG_NOTHING ||
                      type.tag == BinaryDataType::TAG_NULLABLE
      return false if type.contains_aggregate_function? &&
                      !BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(type)
      return false if type.tag == BinaryDataType::TAG_LOW_CARDINALITY &&
                      type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
      true
    end

    private def checked_add(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if left > UInt64::MAX - right
        message = "shared JSON binding count overflows UInt64"
        raise budget.writing? ? UnsupportedFormatError.new(message) : CorruptPartError.new(message)
      end
      left + right
    end
  end
end
