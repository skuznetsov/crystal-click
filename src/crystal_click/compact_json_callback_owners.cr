module CrystalClick
  # Exact JSON owners admitted by the bounded Compact typed-Dynamic slice:
  # direct JSON and bounded Array chains ending at JSON. The root Object
  # already belongs to the caller; returned tuples are its JSON Object
  # children in the callback-owner representation.
  class CompactJsonCallbackOwners
    alias CallbackOwner = ObjectDocumentInlineCallbackOrder::CallbackOwner

    private def initialize
    end

    # Admit only direct JSON or bounded Array-chain JSON actuals at a declared
    # typed Dynamic root. Its child Object can contain ordinary Object/Dynamic
    # lanes, but no further typed- or inferred-Dynamic JSON owner is admitted.
    def self.for_owner(
      physical_plan : ObjectDocumentPhysicalPlan,
      object_plan : ObjectDocumentPlan,
      raw_callback_root : String,
      budget : BinaryCodecBudget,
    ) : Array(CallbackOwner)
      unless raw_callback_root.bytesize > 0
        raise UnsupportedFormatError.new("Compact JSON callback owner root must be nonempty")
      end

      # Discover both JSON rosters before applying the new child-profile gate.
      # Existing Compact Objects without JSON children (including MAP1/MAP2
      # owners) have no callback descendants and retain their old admission.
      # ObjectDocumentPlan construction requires every JSON actual to have an
      # exact binding; cross-check the physical counts as well so a mismatched
      # or unbound physical JSON site cannot be mistaken for a child-free plan.
      root_dynamic_bindings = object_plan.root_dynamic_json_object_leaf_plans(budget)
      typed_bindings = object_plan.typed_dynamic_json_object_leaf_plans(budget)
      validate_parent_json_site_roster!(physical_plan, object_plan, root_dynamic_bindings, typed_bindings)
      if root_dynamic_bindings.empty? && typed_bindings.empty?
        return [] of CallbackOwner
      end
      unless root_dynamic_bindings.empty?
        raise UnsupportedFormatError.new("Compact typed-Dynamic JSON owner does not admit root-Dynamic JSON children")
      end

      unless object_plan.structures.object.version == 4_u64 &&
             object_plan.structures.object.shared_data_version == 0_u64 &&
             object_plan.structures.object.bucket_count == 1_u64 &&
             physical_plan.shared_bucket_count == 1 &&
             physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("Compact typed-Dynamic JSON owner requires Object V3 MAP0/bucket1 single-stream layout")
      end
      output = Array(CallbackOwner).new
      seen_roots = Set(String).new
      seen_roots << ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)

      typed_bindings.each do |path, bindings|
        unless object_plan.has_typed_dynamic?(path) &&
               object_plan.typed_type_for(path).tag == BinaryDataType::TAG_DYNAMIC &&
               object_plan.typed_dynamic_site_count_for(path) == 1 &&
               object_plan.typed_dynamic_site_path_at(path, 0) == "root"
          raise UnsupportedFormatError.new("Compact JSON binding is not attached to a declared direct typed Dynamic")
        end
        dynamic = object_plan.typed_dynamic_for(path)
        dynamic_physical = physical_plan.typed_dynamic(path)
        unless bindings.size == dynamic_physical.json_object_site_count
          raise UnsupportedFormatError.new("Compact typed-Dynamic JSON bindings and physical child sites differ")
        end

        bindings.each do |entry|
          key = entry[0]
          child_plan = entry[1]
          unless key.dynamic_site == "root"
            raise UnsupportedFormatError.new("Compact typed-Dynamic JSON binding names a non-root Dynamic site")
          end
          actual_type = nil.as(BinaryDataType?)
          dynamic.type_count.times do |type_index|
            candidate = dynamic.type_at(type_index)
            next unless dynamic.canonical_index_for(candidate) == key.canonical_arm_index
            actual_type = candidate
            break
          end
          resolved_type = actual_type ||
                          raise(UnsupportedFormatError.new("Compact typed-Dynamic JSON binding names no canonical actual arm"))
          unless admitted_typed_dynamic_json_leaf_key?(resolved_type, key, budget.limits.max_depth)
            raise UnsupportedFormatError.new("Compact typed-Dynamic JSON binding is not a direct JSON or bounded Array-chain actual arm")
          end

          site = dynamic_physical.json_object_site(key)
          unless site.leaf_key == key && site.binding.leaf_key == key &&
                 site.binding.plan.same?(child_plan) &&
                 site.binding.json_type.tag == BinaryDataType::TAG_JSON
            raise UnsupportedFormatError.new("Compact typed-Dynamic JSON child differs from its exact physical binding")
          end
          depth = dynamic_physical.json_object_leaf_depth(key)
          unless site.json_depth == depth
            raise UnsupportedFormatError.new("Compact typed-Dynamic JSON child depth differs from its physical descriptor")
          end
          begin
            site.binding.validate_for!(key, dynamic, budget, depth)
          rescue ex : ArgumentError
            raise UnsupportedFormatError.new(ex.message || "Compact typed-Dynamic JSON binding changed")
          end

          child_physical = site.physical_plan
          child_canonical_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(child_physical)
          unless child_canonical_root == site.escaped_prefix &&
                 child_physical.initial_array_level == site.array_level
            raise UnsupportedFormatError.new("Compact JSON child physical root differs from its exact bound site coordinates")
          end
          validate_child_owner!(
            object_plan,
            physical_plan,
            child_plan,
            child_physical,
            budget,
          )
          if seen_roots.includes?(child_canonical_root)
            raise UnsupportedFormatError.new("Compact JSON callback owner root is duplicated or cyclic")
          end

          raw_child_root = ObjectDocumentInlineCallbackOrder.callback_prefix_for_exact_site(
            physical_plan,
            object_plan,
            raw_callback_root,
            site.escaped_prefix,
            budget,
          )
          unless raw_child_root.bytesize > 0
            raise UnsupportedFormatError.new("Compact JSON child callback root is empty")
          end
          account_owner!(child_canonical_root, raw_child_root, budget)
          output << {
            String.new(child_canonical_root.to_slice),
            String.new(raw_child_root.to_slice),
            child_physical,
            child_plan,
          }
          seen_roots << child_canonical_root
        end
      end

      output
    end

    # Exact leaf-key shape shared by the writer and all Compact read gates.
    # The selected actual must be JSON or a bounded chain of one-child Arrays
    # ending at JSON; every other descriptor wrapper remains refused.
    def self.admitted_typed_dynamic_json_leaf_key?(
      actual_type : BinaryDataType,
      key : BinaryDynamicJsonLeafKey,
      max_path_depth : Int32,
    ) : Bool
      return false unless key.dynamic_site == "root"
      !BinaryArrayJsonLeafShape.wrapper_count?(actual_type, key, max_path_depth).nil?
    end

    def self.admitted_typed_dynamic_json_leaf_key?(
      structure : DynamicStructure,
      key : BinaryDynamicJsonLeafKey,
      max_path_depth : Int32,
    ) : Bool
      return false unless key.dynamic_site == "root"
      actual_type = nil.as(BinaryDataType?)
      structure.type_count.times do |type_index|
        candidate = structure.type_at(type_index)
        next unless structure.canonical_index_for(candidate) == key.canonical_arm_index
        actual_type = candidate
        break
      end
      actual_type ? admitted_typed_dynamic_json_leaf_key?(actual_type.not_nil!, key, max_path_depth) : false
    end

    private def self.validate_parent_json_site_roster!(
      physical_plan : ObjectDocumentPhysicalPlan,
      object_plan : ObjectDocumentPlan,
      root_bindings : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))),
      typed_bindings : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))),
    ) : Nil
      object = object_plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        expected_count = root_bindings[path]?.try(&.size) || 0
        actual_count = if physical_plan.has_root_dynamic_json?(path)
                         physical_plan.root_dynamic_json(path).json_object_site_count
                       else
                         0
                       end
        unless expected_count == actual_count
          raise UnsupportedFormatError.new("Compact JSON root-Dynamic bindings and physical child sites differ")
        end
      end

      object_plan.typed_dynamic_count.times do |index|
        path = object_plan.typed_dynamic_path_at(index)
        expected_count = typed_bindings[path]?.try(&.size) || 0
        actual_count = physical_plan.typed_dynamic(path).json_object_site_count
        unless expected_count == actual_count
          raise UnsupportedFormatError.new("Compact typed-Dynamic bindings and physical child sites differ")
        end
      end
      nil
    end

    private def self.validate_child_owner!(
      parent_plan : ObjectDocumentPlan,
      parent_physical : ObjectDocumentPhysicalPlan,
      child_plan : ObjectDocumentPlan,
      child_physical : ObjectDocumentPhysicalPlan,
      budget : BinaryCodecBudget,
    ) : Nil
      object = child_plan.structures.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("Compact JSON child Object must use Object V3 MAP0/bucket1")
      end
      unless object.shared_data_version == parent_plan.structures.object.shared_data_version &&
             child_physical.shared_profile == parent_physical.shared_profile
        raise UnsupportedFormatError.new("Compact JSON child Object changed its inherited shared layout or profile")
      end

      # This transition admits one Object-child level only. Ordinary root
      # Dynamic lanes such as Int64 remain valid; any JSON binding below the
      # child would create another callback owner and needs its own qualification.
      typed_json = child_plan.typed_dynamic_json_object_leaf_plans(budget)
      root_json = child_plan.root_dynamic_json_object_leaf_plans(budget)
      unless typed_json.empty? && root_json.empty? && child_physical.shared_bucket_count == 1
        raise UnsupportedFormatError.new("Compact JSON child Object contains an unqualified nested JSON owner")
      end
      descriptor_root_depth = child_physical.typed_descriptor_root_depth
      inferred_root_depth = child_physical.inferred_actual_root_depth
      unless descriptor_root_depth > 0 && inferred_root_depth > 0 &&
             descriptor_root_depth <= budget.limits.max_depth &&
             inferred_root_depth <= budget.limits.max_depth
        raise UnsupportedFormatError.new("Compact JSON child Object lost its inherited descriptor depths")
      end
      nil
    end

    private def self.account_owner!(canonical_root : String, raw_root : String, budget : BinaryCodecBudget) : Nil
      copied_bytes = canonical_root.bytesize.to_u64 + raw_root.bytesize.to_u64
      budget.ensure_wire_bytes(copied_bytes)
      budget.preflight_children(1_u64)
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(1_u64)
      budget.charge_node
      budget.charge_elements(1_u64)
      budget.charge_wire_bytes(copied_bytes) if copied_bytes > 0_u64
      nil
    end
  end
end
