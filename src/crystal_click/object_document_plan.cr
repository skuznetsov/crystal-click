module CrystalClick
  # Exact encoder-side association between paired Object metadata and the
  # separately declared typed field schema. Dynamic-bearing typed fields keep
  # an explicit, exact map from generic site path to DynamicStructure.
  class ObjectDocumentPlan
    MAX_TYPED_PATHS = 1_000
    DEFAULT_LIMITS  = BinaryBulkCodec::DEFAULT_LIMITS

    private struct TypedDynamicSite
      getter path : String
      getter type : BinaryDataType
      getter object_depth : Int32
      getter structure : DynamicStructure

      def initialize(@path : String, @type : BinaryDataType, @object_depth : Int32, @structure : DynamicStructure)
      end
    end

    @structures : ObjectDynamicStructureSet
    @typed_types : Hash(String, BinaryDataType)
    @typed_paths : Array(String)
    @typed_dynamic_sites : Hash(String, Hash(String, TypedDynamicSite))
    @typed_dynamic_site_paths : Hash(String, Array(String))
    @typed_dynamic_paths : Array(String)
    @typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)))
    @root_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)))
    @inferred_actual_root_depth : Int32

    def initialize(
      structures : ObjectDynamicStructureSet,
      typed_paths : Hash(String, BinaryDataType),
      typed_dynamics : Hash(String, DynamicStructure) = Hash(String, DynamicStructure).new,
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)) = Hash(String, Hash(String, DynamicStructure)).new,
      typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
      root_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
      root_dynamic_json_budget : BinaryCodecBudget? = nil,
      inferred_actual_root_depth : Int32 = 1_i32,
    )
      object = structures.object

      @structures = structures
      @inferred_actual_root_depth = inferred_actual_root_depth
      limits = DEFAULT_LIMITS
      raise ArgumentError.new("typed Object paths exceed the admitted count") if typed_paths.size > MAX_TYPED_PATHS

      # Preflight the whole explicit roster before copying a path, site key, or
      # per-field Hash. Ordinary descriptors retain the old constructor
      # behavior; only Dynamic-bearing descriptors are validated here.
      budget = BinaryCodecBudget.new(limits, true)
      budget.visit_node(1)
      budget.preflight_children(typed_paths.size.to_u64) if typed_paths.size > 0
      root_json_budget = root_dynamic_json_budget || budget
      root_json_budget.ensure_depth(inferred_actual_root_depth)
      if root_dynamic_json_object_leaf_plans.size > object.dynamic_path_count
        root_plan_error!("root Object Dynamic JSON binding roster has an unknown path", root_json_budget)
      end
      root_binding_count = 0_u64
      root_binding_bytes = 0_u64
      root_dynamic_json_object_leaf_plans.each do |path, leaf_plans|
        unless object.has_dynamic_path?(path)
          root_plan_error!("root Object Dynamic JSON binding has no declared Object path", root_json_budget)
        end
        if leaf_plans.empty?
          root_plan_error!("root Object Dynamic JSON binding roster cannot be empty", root_json_budget)
        end
        root_binding_count = checked_add(root_binding_count, leaf_plans.size.to_u64)
        root_binding_bytes = checked_add(root_binding_bytes, path.bytesize.to_u64)
        leaf_plans.each do |entry|
          key = entry[0]
          root_binding_bytes = checked_add(root_binding_bytes, key.dynamic_site_bytesize.to_u64)
          root_binding_bytes = checked_add(root_binding_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
        end
      end
      if root_binding_count > limits.max_nodes.to_u64 ||
         root_binding_count > limits.max_elements.to_u64 ||
         root_binding_bytes > limits.max_bytes.to_u64
        root_plan_error!("root Object Dynamic JSON bindings exceed codec limits", root_json_budget)
      end
      root_json_budget.preflight_children(root_binding_count) if root_binding_count > 0_u64
      root_json_budget.charge_wire_bytes(root_binding_bytes) if root_binding_bytes > 0_u64
      root_binding_count.times { root_json_budget.charge_node }
      root_json_budget.charge_elements(root_binding_count) if root_binding_count > 0_u64

      @root_dynamic_json_object_leaf_plans = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new(
        initial_capacity: root_dynamic_json_object_leaf_plans.size,
      )
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = structures.dynamic_for(path)
        supplied = root_dynamic_json_object_leaf_plans[path]?
        leaf_plans = supplied || [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)
        roster = nil.as(DynamicJsonObjectBindingRoster?)
        begin
          roster = DynamicJsonObjectBindingRoster.for_root_if_json(
            structure,
            leaf_plans,
            root_json_budget,
            inferred_actual_root_depth,
          )
        rescue ex : CorruptPartError | UnsupportedFormatError
          if root_json_budget.writing?
            raise ArgumentError.new("invalid root Object Dynamic JSON binding: #{ex.message}")
          else
            raise ex
          end
        rescue ex : ArgumentError
          if root_json_budget.writing?
            raise ArgumentError.new("invalid root Object Dynamic JSON binding: #{ex.message}")
          else
            raise CorruptPartError.new("invalid root Object Dynamic JSON binding: #{ex.message}")
          end
        end
        unless selected_roster = roster
          if supplied
            root_plan_error!("root Object Dynamic JSON binding has no JSON actual leaf", root_json_budget)
          end
          next
        end
        unless selected_roster.has_json_object_bindings?
          if supplied
            root_plan_error!("root Object Dynamic JSON binding has no JSON actual leaf", root_json_budget)
          end
          next
        end
        unless supplied
          root_plan_error!("root Object Dynamic JSON bindings must cover every JSON actual leaf", root_json_budget)
        end
        detached_path = String.new(path.to_slice)
        detached_plans = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(leaf_plans.size)
        leaf_plans.each { |entry| detached_plans << entry }
        @root_dynamic_json_object_leaf_plans[detached_path] = detached_plans
      end

      schema_context = BinaryCodecContext.new(limits, nil, true, budget, false, false)
      path_copy_bytes = 0_u64
      site_count = 0_u64
      dynamic_field_count = 0_u64
      generated_path_bytes = 0_u64
      typed_paths.each do |path, type|
        budget.visit_node(2)
        # Bound the complete raw descriptor before recursive summary
        # predicates inspect it.
        schema_context.validate_type_tree(type, 2)
        if type.contains_json?
          raise ArgumentError.new("root JSON is outside the persisted Object declaration grammar")
        end
        if type.contains_qbit?
          raise ArgumentError.new("typed Object QBit descriptor is outside the persisted Object declaration grammar")
        end
        if structures.object.has_dynamic_path?(path)
          raise ArgumentError.new("typed and Dynamic Object paths must be disjoint")
        end
        path_copy_bytes = checked_add(path_copy_bytes, path.bytesize.to_u64)
        next unless type.contains_dynamic?

        ObjectRecursiveDeclaration.account_descriptor(type, budget, limits, 2) ||
          raise ArgumentError.new("typed Object Dynamic descriptor is outside the Object recursive declaration grammar")
        shape = ObjectDeclaredDynamicSites.shape_for(type, limits, 2)
        dynamic_field_count = checked_add(dynamic_field_count, 1_u64)
        site_count = checked_add(site_count, shape.count)
        generated_path_bytes = checked_add(generated_path_bytes, shape.path_bytes)
        # A separate field key is retained by the nested site map.
        path_copy_bytes = checked_add(path_copy_bytes, path.bytesize.to_u64)
      end
      unless typed_dynamics.size + typed_dynamic_sites.size <= dynamic_field_count
        raise ArgumentError.new("typed Object Dynamic roster has an unknown or duplicate field")
      end
      unless typed_dynamic_json_object_leaf_plans.size <= dynamic_field_count
        raise ArgumentError.new("typed Object Dynamic JSON binding roster has an unknown or duplicate field")
      end
      if site_count > limits.max_nodes.to_u64 || site_count > limits.max_elements.to_u64
        raise ArgumentError.new("typed Object Dynamic site count exceeds codec limits")
      end

      json_binding_count = 0_u64
      json_binding_path_elements = 0_u64
      json_binding_bytes = 0_u64
      typed_dynamic_json_object_leaf_plans.each do |_path, leaf_plans|
        json_binding_count = checked_add(json_binding_count, leaf_plans.size.to_u64)
      end
      if json_binding_count > limits.max_nodes.to_u64 || json_binding_count > limits.max_elements.to_u64
        raise ArgumentError.new("typed Object Dynamic JSON bindings exceed codec limits")
      end
      budget.preflight_children(json_binding_count) if json_binding_count > 0_u64
      typed_dynamic_json_object_leaf_plans.each do |path, leaf_plans|
        type = typed_paths[path]?
        unless type && type.contains_dynamic?
          raise ArgumentError.new("typed Object Dynamic JSON bindings have no Dynamic-bearing declaration")
        end
        if leaf_plans.empty?
          raise ArgumentError.new("typed Object Dynamic JSON binding roster cannot be empty")
        end
        json_binding_bytes = checked_add(json_binding_bytes, path.bytesize.to_u64)
        leaf_plans.each do |entry|
          key = entry[0]
          json_binding_path_elements = checked_add(json_binding_path_elements, key.descriptor_path_size.to_u64)
          json_binding_bytes = checked_add(json_binding_bytes, key.dynamic_site_bytesize.to_u64)
          json_binding_bytes = checked_add(json_binding_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
        end
      end
      if json_binding_count > limits.max_nodes.to_u64 ||
         json_binding_count > limits.max_elements.to_u64 ||
         json_binding_path_elements > limits.max_elements.to_u64 ||
         json_binding_bytes > limits.max_bytes.to_u64
        raise ArgumentError.new("typed Object Dynamic JSON bindings exceed codec limits")
      end
      budget.ensure_future_elements(json_binding_path_elements)
      budget.charge_wire_bytes(json_binding_bytes) if json_binding_bytes > 0_u64
      json_binding_count.times { budget.charge_node }
      budget.charge_elements(json_binding_path_elements) if json_binding_path_elements > 0_u64

      supplied_site_count = typed_dynamics.size.to_u64
      supplied_key_bytes = 0_u64
      typed_dynamics.each_key do |path|
        supplied_key_bytes = checked_add(supplied_key_bytes, path.bytesize.to_u64)
      end
      typed_dynamic_sites.each do |path, roster|
        supplied_key_bytes = checked_add(supplied_key_bytes, path.bytesize.to_u64)
        supplied_site_count = checked_add(supplied_site_count, roster.size.to_u64)
        roster.each_key do |site_path|
          supplied_key_bytes = checked_add(supplied_key_bytes, site_path.bytesize.to_u64)
        end
      end
      if supplied_site_count > limits.max_nodes.to_u64 || supplied_key_bytes > limits.max_bytes.to_u64
        raise ArgumentError.new("typed Object Dynamic supplied roster exceeds codec limits")
      end

      # Generated path prefixes are temporary during canonical path building;
      # use depth as a conservative multiplier before any site-key allocation.
      path_work_bytes = checked_multiply(
        generated_path_bytes,
        checked_add(limits.max_depth.to_u64, 1_u64)
      )
      copied_bytes = checked_add(path_copy_bytes, path_work_bytes)
      budget.charge_wire_bytes(copied_bytes)
      budget.preflight_children(site_count) if site_count > 0_u64
      budget.preflight_children(dynamic_field_count) if dynamic_field_count > 0_u64

      # Reject source maps that cannot correspond to a declared Dynamic field
      # before materializing any per-field site maps.
      typed_dynamics.each do |path, _structure|
        type = typed_paths[path]?
        unless type && type.tag == BinaryDataType::TAG_DYNAMIC
          raise ArgumentError.new("legacy typed Object Dynamic rosters require a direct Dynamic declaration")
        end
        if typed_dynamic_sites.has_key?(path)
          raise ArgumentError.new("typed Object Dynamic field has both legacy and site rosters")
        end
      end
      typed_dynamic_sites.each do |path, _roster|
        type = typed_paths[path]?
        unless type && type.contains_dynamic?
          raise ArgumentError.new("typed Object Dynamic site roster has no Dynamic-bearing declaration")
        end
      end

      @typed_types = Hash(String, BinaryDataType).new(initial_capacity: typed_paths.size)
      @typed_paths = Array(String).new(typed_paths.size)
      typed_paths.each do |path, type|
        detached_path = String.new(path.to_slice)
        @typed_types[detached_path] = type
        @typed_paths << detached_path
      end
      @typed_paths.sort! { |left, right| compare_paths(left, right) }

      @typed_dynamic_sites = Hash(String, Hash(String, TypedDynamicSite)).new(initial_capacity: dynamic_field_count.to_i)
      @typed_dynamic_json_object_leaf_plans = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new(initial_capacity: typed_dynamic_json_object_leaf_plans.size)
      typed_dynamic_json_object_leaf_plans.each do |path, leaf_plans|
        detached_path = String.new(path.to_slice)
        detached_plans = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(leaf_plans.size)
        leaf_plans.each { |entry| detached_plans << entry }
        @typed_dynamic_json_object_leaf_plans[detached_path] = detached_plans
      end
      @typed_dynamic_site_paths = Hash(String, Array(String)).new(initial_capacity: dynamic_field_count.to_i)
      typed_paths.each do |path, type|
        next unless type.contains_dynamic?

        legacy_structure = typed_dynamics[path]?
        supplied_roster = typed_dynamic_sites[path]?
        if legacy_structure && supplied_roster
          raise ArgumentError.new("typed Object Dynamic field has both legacy and site rosters")
        end
        unless legacy_structure || supplied_roster
          raise ArgumentError.new("typed Object Dynamic structure is missing declared field: #{path.inspect}")
        end

        site_entries = Hash(String, TypedDynamicSite).new
        if structure = legacy_structure
          maximum = ObjectDeclaredDynamicDeclaration.max_types_for(type) ||
                    raise ArgumentError.new("legacy typed Object Dynamic roster requires a direct canonical descriptor")
          if structure.type_count > maximum
            raise ArgumentError.new("typed Object Dynamic roster exceeds its declared max_types cap")
          end
          begin
            ObjectDeclaredDynamicDeclaration.validate_actual_structure!(
              structure,
              limits,
              3,
              budget,
              typed_dynamic_json_object_leaf_plans.has_key?(path),
            )
          rescue ex : UnsupportedFormatError
            raise ArgumentError.new("invalid typed Object Dynamic actual roster: #{ex.message}")
          end
          spec = ObjectDeclaredDynamicSites::SiteSpec.new("root", type, 2)
          site_entries[spec.path] = TypedDynamicSite.new(spec.path, spec.type, spec.object_depth, structure)
        else
          roster = supplied_roster.not_nil!
          specs = begin
            ObjectDeclaredDynamicSites.validate_roster!(
              type,
              roster,
              limits,
              2,
              budget,
              typed_dynamic_json_object_leaf_plans.has_key?(path),
            )
          rescue ex : UnsupportedFormatError
            raise ArgumentError.new("invalid typed Object Dynamic site roster: #{ex.message}")
          end
          specs.each do |spec|
            structure = roster[spec.path]? || raise(ArgumentError.new("typed Object Dynamic structure is missing site: #{spec.path.inspect}"))
            site_entries[spec.path] = TypedDynamicSite.new(spec.path, spec.type, spec.object_depth, structure)
          end
        end
        if json_leaf_plans = typed_dynamic_json_object_leaf_plans[path]?
          site_structures = Hash(String, DynamicStructure).new(initial_capacity: site_entries.size)
          site_entries.each do |site_path, site|
            site_structures[site_path] = site.structure
          end
          begin
            # Reuse the generic Dynamic planner as the admission authority for
            # exact leaf identities, duplicate/excess keys, and child-schema
            # compatibility. `allow_bound_json` above is shape-only; it does
            # not make this Object plan value-ready by itself.
            ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
              type,
              site_structures,
              budget,
              BinaryBulkProfile.single_stream,
              2,
              json_leaf_plans,
            )
          rescue ex : UnsupportedFormatError
            raise ArgumentError.new("invalid typed Object Dynamic JSON binding: #{ex.message}")
          end
        end
        detached_path = String.new(path.to_slice)
        @typed_dynamic_sites[detached_path] = site_entries
        # Keep one stable index per field. Rebuilding and sorting the full key
        # table from typed_dynamic_site_path_at would make an indexed walk
        # quadratic in the explicit site roster.
        site_paths = site_entries.keys
        site_paths.sort! { |left, right| compare_paths(left, right) }
        @typed_dynamic_site_paths[detached_path] = site_paths
      end

      # A site roster with no corresponding typed field is never ignored.
      typed_dynamic_sites.each_key do |path|
        unless @typed_dynamic_sites.has_key?(path)
          raise ArgumentError.new("typed Object Dynamic site roster has no declared field: #{path.inspect}")
        end
      end
      @typed_dynamic_paths = Array(String).new(@typed_dynamic_sites.size)
      @typed_dynamic_sites.each_key { |path| @typed_dynamic_paths << path }
      @typed_dynamic_paths.sort! { |left, right| compare_paths(left, right) }
    end

    def structures : ObjectDynamicStructureSet
      @structures
    end

    def typed_paths : Hash(String, BinaryDataType)
      detached = Hash(String, BinaryDataType).new(initial_capacity: @typed_types.size)
      @typed_types.each do |path, type|
        detached[String.new(path.to_slice)] = type
      end
      detached
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def inferred_actual_root_depth : Int32
      @inferred_actual_root_depth
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_paths[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_paths[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_paths[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_types.has_key?(path)
    end

    def typed_type_for(path : String) : BinaryDataType
      @typed_types[path]? || raise(KeyError.new("typed Object path not found: #{path.inspect}"))
    end

    # Backward-compatible direct-root accessor. Recursive declarations must
    # use typed_dynamic_sites_for rather than selecting an arbitrary site.
    def typed_dynamics : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new
      @typed_dynamic_paths.each do |path|
        next unless @typed_types[path]?.try(&.tag) == BinaryDataType::TAG_DYNAMIC
        detached[String.new(path.to_slice)] = typed_dynamic_for(path)
      end
      detached
    end

    # Number of typed fields containing at least one declared Dynamic site.
    def typed_dynamic_count : Int32
      @typed_dynamic_paths.size
    end

    def typed_dynamic_path_at(index : Int) : String
      String.new(@typed_dynamic_paths[index].to_slice)
    end

    def typed_dynamic_path_byte_size_at(index : Int) : Int32
      @typed_dynamic_paths[index].bytesize
    end

    def typed_dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_dynamic_paths[index].to_slice[byte_index]
    end

    def has_typed_dynamic?(path : String) : Bool
      @typed_dynamic_sites.has_key?(path)
    end

    def typed_dynamic_for(path : String) : DynamicStructure
      type = @typed_types[path]?
      unless type && type.tag == BinaryDataType::TAG_DYNAMIC
        raise KeyError.new("typed Object Dynamic root structure not found: #{path.inspect}")
      end
      typed_dynamic_site_structure_for(path, "root")
    end

    def typed_dynamic_site_count_for(path : String) : Int32
      typed_dynamic_site_map(path).size
    end

    def typed_dynamic_site_path_at(path : String, index : Int) : String
      paths = @typed_dynamic_site_paths[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
      site_path = paths[index]
      String.new(site_path.to_slice)
    end

    def typed_dynamic_site_path_byte_size_at(path : String, index : Int) : Int32
      paths = @typed_dynamic_site_paths[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
      paths[index].bytesize
    end

    def typed_dynamic_site_structure_for(path : String, site_path : String) : DynamicStructure
      typed_site = typed_dynamic_site_map(path)[site_path]? || raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
      typed_site.structure
    end

    def typed_dynamic_site_type_for(path : String, site_path : String) : BinaryDataType
      typed_dynamic_site_map(path)[site_path]?.try(&.type) ||
        raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
    end

    def typed_dynamic_site_object_depth_for(path : String, site_path : String) : Int32
      typed_dynamic_site_map(path)[site_path]?.try(&.object_depth) ||
        raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
    end

    def typed_dynamic_sites_for(path : String) : Hash(String, DynamicStructure)
      budget = BinaryCodecBudget.new(DEFAULT_LIMITS, true)
      typed_dynamic_sites_for(path, budget)
    end

    # Borrowed-budget snapshot for an in-flight Object operation. This keeps
    # site-key and map-copy work in the caller's aggregate limits.
    def typed_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      unless budget.writing?
        raise ArgumentError.new("typed Object Dynamic roster copy requires a writing budget")
      end
      entries = typed_dynamic_site_map(path)
      copied_bytes = 0_u64
      entries.each_key { |site_path| copied_bytes = checked_add(copied_bytes, site_path.bytesize.to_u64) }
      count = entries.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(copied_bytes)
      detached = Hash(String, DynamicStructure).new(initial_capacity: entries.size)
      entries.each do |site_path, site|
        detached[String.new(site_path.to_slice)] = site.structure
      end
      detached
    end

    # Borrowed-budget snapshot of the exact JSON leaf bindings for one declared
    # typed Dynamic field. Binding keys and child plans are immutable owners;
    # only the containing roster is detached.
    def typed_dynamic_json_object_leaf_plans_for(
      path : String,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))
      entries = @typed_dynamic_json_object_leaf_plans[path]?
      return [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan) unless entries
      count = entries.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(count)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      copied = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(entries.size)
      entries.each { |entry| copied << entry }
      copied
    end

    # Detached full snapshot for normalized child decoding, where the Object
    # codec must hand each declared Dynamic field its own exact leaf roster.
    def typed_dynamic_json_object_leaf_plans(
      budget : BinaryCodecBudget,
    ) : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)))
      count = @typed_dynamic_json_object_leaf_plans.size.to_u64
      binding_count = 0_u64
      copied_bytes = 0_u64
      @typed_dynamic_json_object_leaf_plans.each do |path, entries|
        copied_bytes = checked_add(copied_bytes, path.bytesize.to_u64)
        binding_count = checked_add(binding_count, entries.size.to_u64)
      end
      records = checked_add(count, binding_count)
      budget.preflight_children(records) if records > 0_u64
      budget.ensure_future_elements(records)
      budget.charge_wire_bytes(copied_bytes) if copied_bytes > 0_u64
      records.times { budget.charge_node }
      budget.charge_elements(records) if records > 0_u64
      detached = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new(initial_capacity: @typed_dynamic_json_object_leaf_plans.size)
      @typed_dynamic_json_object_leaf_plans.each do |path, entries|
        detached[String.new(path.to_slice)] = entries.dup
      end
      detached
    end

    # Borrowed-budget snapshot of the exact JSON child bindings for one
    # inferred root Object Dynamic path. This is separate from declared typed
    # Dynamic fields, which retain their own structural root and depth.
    def root_dynamic_json_object_leaf_plans_for(
      path : String,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))
      entries = @root_dynamic_json_object_leaf_plans[path]?
      return [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan) unless entries
      count = entries.size.to_u64
      path_elements = 0_u64
      key_bytes = 0_u64
      entries.each do |entry|
        key = entry[0]
        path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64)
        key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64)
        key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      copied = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(entries.size)
      entries.each do |entry|
        copied << {
          BinaryDynamicJsonLeafKey.new(entry[0].dynamic_site, entry[0].canonical_arm_index, entry[0].descriptor_child_path),
          entry[1],
        }
      end
      copied
    end

    # Full detached root binding snapshot used by normalized decode. Each
    # path and leaf key is copied under the caller's aggregate operation
    # budget; child plans remain immutable shared owners.
    def root_dynamic_json_object_leaf_plans(
      budget : BinaryCodecBudget,
    ) : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)))
      path_count = @root_dynamic_json_object_leaf_plans.size.to_u64
      leaf_count = 0_u64
      path_bytes = 0_u64
      key_bytes = 0_u64
      path_elements = 0_u64
      @root_dynamic_json_object_leaf_plans.each do |path, entries|
        path_bytes = checked_add(path_bytes, path.bytesize.to_u64)
        leaf_count = checked_add(leaf_count, entries.size.to_u64)
        entries.each do |entry|
          key = entry[0]
          key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64)
          key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
          path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64)
        end
      end
      records = checked_add(path_count, leaf_count)
      budget.preflight_children(records) if records > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(checked_add(path_bytes, key_bytes)) if path_bytes > 0_u64 || key_bytes > 0_u64
      records.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      detached = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new(
        initial_capacity: @root_dynamic_json_object_leaf_plans.size,
      )
      @root_dynamic_json_object_leaf_plans.each do |path, entries|
        copied_entries = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(entries.size)
        entries.each do |entry|
          copied_entries << {
            BinaryDynamicJsonLeafKey.new(entry[0].dynamic_site, entry[0].canonical_arm_index, entry[0].descriptor_child_path),
            entry[1],
          }
        end
        detached[String.new(path.to_slice)] = copied_entries
      end
      detached
    end

    private def typed_dynamic_site_map(path : String) : Hash(String, TypedDynamicSite)
      @typed_dynamic_sites[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
    end

    private def compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise ArgumentError.new("typed Object Dynamic plan size overflows UInt64")
      end
      left + right
    end

    private def root_plan_error!(message : String, budget : BinaryCodecBudget) : NoReturn
      if budget.writing?
        raise ArgumentError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise ArgumentError.new("typed Object Dynamic plan size overflows UInt64")
      end
      left * right
    end
  end
end
