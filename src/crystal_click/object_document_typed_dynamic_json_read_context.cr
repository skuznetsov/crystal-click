module CrystalClick
  # Exact per-mark carrier for typed-Dynamic JSON child owners captured from
  # an Object callback tape. It retains only the parsed leaf plans and their
  # real keyed PrefixMaps; it never invents static Object leaf coordinates.
  class ObjectDocumentTypedDynamicJsonReadContext
    alias LeafPlan = Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)
    alias LeafPlans = Hash(String, Array(LeafPlan))
    alias PrefixMap = ObjectSharedPathJsonTapeCodec::PrefixMap
    alias SiteOwners = Tuple(Array(LeafPlan), PrefixMap)

    @sites : Hash(String, SiteOwners)
    @retained_workspace_bytes : UInt64

    private def initialize(@sites : Hash(String, SiteOwners), @retained_workspace_bytes : UInt64)
    end

    # The prefix must already be bound to its physical plan and all local and
    # descendant body callbacks must have completed their owner-local capture.
    # Returned child prefixes remain the exact parser-produced map values.
    def self.from_prefix(
      prefix : ObjectDocumentCallbackPrefix,
      budget : BinaryCodecBudget,
    ) : ObjectDocumentTypedDynamicJsonReadContext?
      unless !budget.writing? && !prefix.nested_context.writing?
        raise ArgumentError.new("typed-Dynamic JSON read context requires a read-direction owner")
      end
      physical = prefix.physical_plan
      prefix.validate_physical_owner!(physical)

      root_json = prefix.plan.root_dynamic_json_object_leaf_plans(budget)
      unless root_json.empty?
        raise UnsupportedFormatError.new("root-Dynamic JSON is outside the typed-Dynamic JSON read context")
      end
      leaf_plans = prefix.plan.typed_dynamic_json_object_leaf_plans(budget)
      return nil if leaf_plans.empty?

      record_count = leaf_plans.size.to_u64
      leaf_plans.each_value do |entries|
        record_count = checked_add(record_count, entries.size.to_u64)
      end
      budget.preflight_children(record_count) if record_count > 0_u64
      budget.ensure_future_elements(record_count)
      record_count.times { budget.charge_node }
      budget.charge_elements(record_count) if record_count > 0_u64

      sites = Hash(String, SiteOwners).new(initial_capacity: leaf_plans.size)
      retained = instance_sizeof(ObjectDocumentTypedDynamicJsonReadContext).to_u64
      retained = checked_add(retained, instance_sizeof(Hash(String, SiteOwners)).to_u64)
      retained = checked_add(retained,
        checked_multiply(record_count, sizeof(Pointer(SiteOwners)).to_u64))

      leaf_plans.each do |path, entries|
        declared_type = prefix.plan.typed_type_for(path)
        unless declared_type.tag == BinaryDataType::TAG_DYNAMIC &&
               prefix.plan.has_typed_dynamic?(path) &&
               prefix.typed_dynamic_plan_for(path).type == declared_type
          raise UnsupportedFormatError.new("typed-Dynamic JSON binding is not owned by a declared Dynamic root")
        end

        dynamic_plan = prefix.typed_dynamic_plan_for(path)
        dynamic_physical = physical.typed_dynamic(path)
        prefixes = prefix.typed_dynamic_json_prefixes_for(path)
        unless entries.size == dynamic_plan.json_object_binding_count &&
               entries.size == dynamic_physical.json_object_site_count &&
               entries.size == prefixes.size
          raise CorruptPartError.new("typed-Dynamic JSON leaf plans, physical sites, and captured prefixes differ")
        end

        if sites.has_key?(path)
          raise CorruptPartError.new("typed-Dynamic JSON field owner is duplicated")
        end
        budget.ensure_wire_bytes(path.bytesize.to_u64)
        budget.charge_wire_bytes(path.bytesize.to_u64)
        retained = checked_add(retained, instance_sizeof(Array(LeafPlan)).to_u64)
        retained = checked_add(retained,
          checked_multiply(entries.size.to_u64, sizeof(LeafPlan).to_u64))
        retained = checked_add(retained, string_owner_bytes(path))
        retained = checked_add(retained, instance_sizeof(Hash(BinaryDynamicJsonLeafKey, ObjectDocumentInlinePrefix)).to_u64)
        retained = checked_add(retained,
          checked_multiply(prefixes.size.to_u64,
            sizeof(BinaryDynamicJsonLeafKey).to_u64 + sizeof(Pointer(ObjectDocumentInlinePrefix)).to_u64))

        seen_keys = Set(BinaryDynamicJsonLeafKey).new
        entries.each do |entry|
          key = entry[0]
          child_plan = entry[1]
          unless key.dynamic_site == "root" && key.descriptor_path_size == 0
            raise UnsupportedFormatError.new("typed-Dynamic JSON read context admits only direct JSON actual leaves")
          end
          unless seen_keys.add?(key)
            raise CorruptPartError.new("typed-Dynamic JSON leaf key is duplicated in its exact field owner")
          end

          binding = dynamic_plan.json_object_binding(key)
          site = dynamic_physical.json_object_site(key)
          child_prefix = prefixes[key]? ||
                         raise(CorruptPartError.new("typed-Dynamic JSON child has no captured prefix for its exact leaf key"))
          unless binding.leaf_key == key && binding.json_type.tag == BinaryDataType::TAG_JSON &&
                 binding.plan.same?(child_plan) && site.leaf_key == key &&
                 site.binding.plan.same?(child_plan) && site.physical_plan.same?(child_prefix.physical_plan) &&
                 child_prefix.key == key && child_prefix.plan.same?(child_plan) &&
                 child_prefix.physical_prefix == site.escaped_prefix &&
                 site.json_depth == dynamic_plan.json_object_leaf_depth(key, prefix.typed_descriptor_root_depth) &&
                 child_prefix.json_descriptor_depth == site.json_depth &&
                 child_prefix.typed_descriptor_root_depth == site.json_depth + 1
            raise CorruptPartError.new("typed-Dynamic JSON child prefix differs from its exact binding or descriptor context")
          end
          child_prefix.validate_physical_owner!(site.physical_plan)
          unless child_prefix.nested_context.profile == prefix.nested_context.profile &&
                 child_prefix.plan.structures.object.shared_data_version ==
                   prefix.plan.structures.object.shared_data_version &&
                 site.physical_plan.shared_bucket_count == 1 &&
                 child_plan.structures.object.version == 4_u64 &&
                 child_plan.structures.object.shared_data_version == 0_u64 &&
                 child_plan.structures.object.bucket_count == 1_u64
            raise UnsupportedFormatError.new("typed-Dynamic JSON child Object changed its inherited MAP0 context")
          end
          unless child_prefix.body_callback_count == child_prefix.body_callback_slice_count
            raise CorruptPartError.new("typed-Dynamic JSON child body capture is incomplete")
          end
          unless child_plan.typed_dynamic_json_object_leaf_plans(budget).empty? &&
                 child_plan.root_dynamic_json_object_leaf_plans(budget).empty?
            raise UnsupportedFormatError.new("nested JSON below a typed-Dynamic JSON child is outside this read context")
          end
          retained = checked_add(retained, child_prefix.retained_callback_capture_workspace_bytes)
        end
        unless seen_keys.size == prefixes.size
          raise CorruptPartError.new("typed-Dynamic JSON prefix map contains an unbound leaf owner")
        end
        sites[String.new(path.to_slice)] = {entries, prefixes}
      end

      new(sites, retained)
    end

    def has_path?(path : String) : Bool
      @sites.has_key?(path)
    end

    # The returned binding roster is this context's exact prepared metadata;
    # codec validation charges and copies it before using it as an input plan.
    def leaf_plans_for(path : String) : Array(LeafPlan)
      (@sites[path]? || raise(KeyError.new("typed-Dynamic JSON read owner not found: #{path.inspect}")))[0]
    end

    # This is a real Dynamic-leaf PrefixMap from the callback parser. No keyless
    # static-root prefix is converted into a synthetic child key.
    def prefixes_for(path : String) : PrefixMap
      (@sites[path]? || raise(KeyError.new("typed-Dynamic JSON read owner not found: #{path.inspect}")))[1]
    end

    def leaf_plans(budget : BinaryCodecBudget) : LeafPlans
      count = @sites.size.to_u64
      @sites.each_value { |entry| count = checked_add(count, entry[0].size.to_u64) }
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(count)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      output = LeafPlans.new(initial_capacity: @sites.size)
      @sites.each do |path, entry|
        budget.charge_wire_bytes(path.bytesize.to_u64)
        output[String.new(path.to_slice)] = entry[0].dup
      end
      output
    end

    def retained_workspace_bytes : UInt64
      @retained_workspace_bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed-Dynamic JSON read context workspace overflows UInt64")
      end
      left + right
    end

    private def self.string_owner_bytes(value : String) : UInt64
      checked_add(sizeof(String).to_u64, value.bytesize.to_u64)
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed-Dynamic JSON read context workspace overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("typed-Dynamic JSON read context workspace overflows UInt64")
      end
      left * right
    end
  end
end
