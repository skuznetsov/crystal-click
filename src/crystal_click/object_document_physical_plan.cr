module CrystalClick
  # Binds the W125 Object metadata, typed paths, Dynamic alternatives, and
  # shared MAP lanes into one collision-checked physical filename roster.
  class ObjectDocumentPhysicalPlan
    private struct EscapedPrefix
      getter value : String

      private def initialize(value : String)
        PhysicalStreamName.validate_canonical_escaped_prefix(value)
        @value = String.new(value.to_slice)
      end

      def self.validated(value : String) : EscapedPrefix
        new(value)
      end
    end

    private struct TypedDynamicNameShape
      getter count : UInt64
      getter path_bytes : UInt64
      getter physical_name_bytes : UInt64
      getter sql_name_work_bytes : UInt64

      def initialize(@count : UInt64, @path_bytes : UInt64, @physical_name_bytes : UInt64, @sql_name_work_bytes : UInt64)
      end
    end

    private struct PlanState
      getter object_structure_stream : String
      getter dynamic_structure_streams : Hash(String, String)
      getter discriminator_streams : Hash(String, String)
      getter typed_plans : Hash(String, BinaryBulkPhysicalPlan)
      getter typed_dynamic_plans : Hash(String, BinaryDynamicBulkPhysicalPlan)
      getter dynamic_arm_plans : Hash(String, Hash(String, BinaryBulkPhysicalPlan))
      getter root_dynamic_json_plans : Hash(String, ObjectDocumentRootDynamicJsonPhysicalPlan)
      getter shared_plans : Array(BinaryBulkPhysicalPlan)
      getter shared_bucket_count : Int32
      getter advanced_copy_stream_names : Hash(String, String)
      getter advanced_bucket_stream_names : Array(Hash(String, String))
      getter stream_count : Int32

      def initialize(
        @object_structure_stream : String,
        @dynamic_structure_streams : Hash(String, String),
        @discriminator_streams : Hash(String, String),
        @typed_plans : Hash(String, BinaryBulkPhysicalPlan),
        @typed_dynamic_plans : Hash(String, BinaryDynamicBulkPhysicalPlan),
        @dynamic_arm_plans : Hash(String, Hash(String, BinaryBulkPhysicalPlan)),
        @root_dynamic_json_plans : Hash(String, ObjectDocumentRootDynamicJsonPhysicalPlan),
        @shared_plans : Array(BinaryBulkPhysicalPlan),
        @shared_bucket_count : Int32,
        @advanced_copy_stream_names : Hash(String, String),
        @advanced_bucket_stream_names : Array(Hash(String, String)),
        @stream_count : Int32,
      )
      end
    end

    @object_structure_stream : String
    @dynamic_structure_streams : Hash(String, String)
    @discriminator_streams : Hash(String, String)
    @typed_plans : Hash(String, BinaryBulkPhysicalPlan)
    @typed_dynamic_plans : Hash(String, BinaryDynamicBulkPhysicalPlan)
    @dynamic_arm_plans : Hash(String, Hash(String, BinaryBulkPhysicalPlan))
    @root_dynamic_json_plans : Hash(String, ObjectDocumentRootDynamicJsonPhysicalPlan)
    @shared_plans : Array(BinaryBulkPhysicalPlan)
    @shared_bucket_count : Int32
    @advanced_copy_stream_names : Hash(String, String)
    @advanced_bucket_stream_names : Array(Hash(String, String))
    @advanced_stream_names : Array(String)
    @stream_count : Int32
    @shared_data_version : UInt64
    @initial_array_level : UInt64
    @typed_descriptor_root_depth : Int32
    @inferred_actual_root_depth : Int32
    @shared_profile : BinaryBulkProfile

    # Discover only declared Dynamic structure basenames, without constructing
    # a dummy BinaryDynamicBulkPlan. This is used before metadata is available;
    # the completed physical plan remains the authority and callers compare
    # every discovered name against structure_name_for(site).
    def self.typed_dynamic_structure_names(
      column_name : String,
      typed_path : String,
      type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Hash(String, String)
      budget = BinaryCodecBudget.new(limits, false)
      typed_dynamic_structure_names(column_name, typed_path, type, budget)
    end

    # Borrowed-budget form for a whole FileReader prepare operation. All
    # descriptor/site/name work accumulates in the same read budget as the
    # other metadata and lanes rather than restarting per field.
    def self.typed_dynamic_structure_names(
      column_name : String,
      typed_path : String,
      type : BinaryDataType,
      budget : BinaryCodecBudget,
    ) : Hash(String, String)
      limits = budget.limits
      unless ObjectRecursiveDeclaration.account_descriptor(type, budget, limits, 2)
        raise UnsupportedFormatError.new("typed Object Dynamic descriptor is outside the Object recursive declaration grammar")
      end
      unless type.contains_dynamic?
        raise UnsupportedFormatError.new("typed Dynamic structure-name discovery requires a declared Dynamic site")
      end
      site_shape = ObjectDeclaredDynamicSites.shape_for(type, limits, 2)
      if site_shape.count == 0_u64
        raise UnsupportedFormatError.new("typed Dynamic descriptor has no canonical sites")
      end
      if site_shape.count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("typed Dynamic structure-name roster exceeds the in-memory domain")
      end
      budget.ensure_future_nodes(site_shape.count)
      budget.preflight_children(site_shape.count)

      raw_input_bytes = typed_dynamic_checked_add(column_name.bytesize.to_u64, typed_path.bytesize.to_u64)
      budget.ensure_wire_bytes(raw_input_bytes)
      column_prefix_bytes = PhysicalStreamName.escaped_size(column_name)
      typed_component_bytes = PhysicalStreamName.escaped_size(typed_path)
      root_prefix_bytes = typed_dynamic_checked_add(
        column_prefix_bytes,
        typed_dynamic_checked_add(1_u64, typed_component_bytes)
      )
      measured = measure_typed_dynamic_names(type, "root".bytesize.to_u64, root_prefix_bytes, 2, budget)
      unless measured.count == site_shape.count && measured.path_bytes == site_shape.path_bytes
        raise UnsupportedFormatError.new("typed Dynamic structure-name preflight disagrees with the declared site roster")
      end

      path_work_bound = typed_dynamic_checked_multiply(
        site_shape.path_bytes,
        typed_dynamic_checked_add(limits.max_depth.to_u64, 1_u64)
      )
      # Every tuple/map/variant edge creates a new physical prefix string.
      # Summing only final basenames misses repeated prefix copies along a
      # deep path, especially when the column name is long. Bound the sum of
      # those intermediate prefixes by each final basename times the maximum
      # descriptor depth, plus a small allowance for root/interpolation
      # temporaries. Variant SQL-name rendering has its own recursive bound.
      prefix_copy_factor = typed_dynamic_checked_add(limits.max_depth.to_u64, 2_u64)
      physical_prefix_copies = typed_dynamic_checked_multiply(measured.physical_name_bytes, prefix_copy_factor)
      physical_work_bound = typed_dynamic_checked_add(physical_prefix_copies, measured.sql_name_work_bytes)
      allocation_bound = typed_dynamic_checked_add(path_work_bound, physical_work_bound)
      allocation_bound = typed_dynamic_checked_add(allocation_bound, raw_input_bytes)
      budget.ensure_wire_bytes(allocation_bound)
      budget.ensure_future_nodes(site_shape.count)
      # Charge the conservative complete bound before allocating any generated
      # path, prefix, SQL arm name, or output Hash entry.
      budget.charge_wire_bytes(allocation_bound)
      site_shape.count.times { budget.charge_node }

      prefix = PhysicalStreamName.escape(column_name)
      prefix = PhysicalStreamName.append_escaped_component(prefix, typed_path)
      names = Hash(String, String).new(initial_capacity: measured.count.to_i)
      physical_seen = Hash(String, Bool).new(initial_capacity: measured.count.to_i)
      collect_typed_dynamic_names(type, "root", prefix, names, physical_seen)
      unless names.size.to_u64 == measured.count
        raise UnsupportedFormatError.new("typed Dynamic structure-name roster changed after preflight")
      end
      names
    end

    # Site-aware counterpart to root-column name discovery. The prefix is an
    # already escaped structural path (for example `pair%2Eleft`); only the
    # typed Object path is appended as a new escaped component.
    def self.typed_dynamic_structure_names_at_site(
      escaped_prefix : String,
      typed_path : String,
      type : BinaryDataType,
      budget : BinaryCodecBudget,
    ) : Hash(String, String)
      limits = budget.limits
      unless type.contains_dynamic?
        raise UnsupportedFormatError.new("typed Dynamic structure-name discovery requires a declared Dynamic site")
      end
      unless ObjectRecursiveDeclaration.account_descriptor(type, budget, limits, 2)
        raise UnsupportedFormatError.new("typed Object Dynamic descriptor is outside the Object recursive declaration grammar")
      end
      site_shape = ObjectDeclaredDynamicSites.shape_for(type, limits, 2)
      if site_shape.count == 0_u64
        raise UnsupportedFormatError.new("typed Dynamic descriptor has no canonical sites")
      end
      if site_shape.count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("typed Dynamic structure-name roster exceeds the in-memory domain")
      end
      budget.ensure_future_nodes(site_shape.count)
      budget.preflight_children(site_shape.count)

      PhysicalStreamName.validate_canonical_escaped_prefix(escaped_prefix)
      raw_input_bytes = typed_dynamic_checked_add(escaped_prefix.bytesize.to_u64, typed_path.bytesize.to_u64)
      budget.ensure_wire_bytes(raw_input_bytes)
      typed_component_bytes = PhysicalStreamName.escaped_size(typed_path)
      root_prefix_bytes = typed_dynamic_checked_add(
        escaped_prefix.bytesize.to_u64,
        typed_dynamic_checked_add(1_u64, typed_component_bytes)
      )
      measured = measure_typed_dynamic_names(type, "root".bytesize.to_u64, root_prefix_bytes, 2, budget)
      unless measured.count == site_shape.count && measured.path_bytes == site_shape.path_bytes
        raise UnsupportedFormatError.new("typed Dynamic structure-name preflight disagrees with the declared site roster")
      end

      path_work_bound = typed_dynamic_checked_multiply(
        site_shape.path_bytes,
        typed_dynamic_checked_add(limits.max_depth.to_u64, 1_u64)
      )
      prefix_copy_factor = typed_dynamic_checked_add(limits.max_depth.to_u64, 2_u64)
      physical_prefix_copies = typed_dynamic_checked_multiply(measured.physical_name_bytes, prefix_copy_factor)
      physical_work_bound = typed_dynamic_checked_add(physical_prefix_copies, measured.sql_name_work_bytes)
      allocation_bound = typed_dynamic_checked_add(path_work_bound, physical_work_bound)
      allocation_bound = typed_dynamic_checked_add(allocation_bound, raw_input_bytes)
      budget.ensure_wire_bytes(allocation_bound)
      budget.ensure_future_nodes(site_shape.count)
      budget.charge_wire_bytes(allocation_bound)
      site_shape.count.times { budget.charge_node }

      prefix = PhysicalStreamName.append_escaped_component(escaped_prefix, typed_path)
      names = Hash(String, String).new(initial_capacity: measured.count.to_i)
      physical_seen = Hash(String, Bool).new(initial_capacity: measured.count.to_i)
      collect_typed_dynamic_names(type, "root", prefix, names, physical_seen)
      unless names.size.to_u64 == measured.count
        raise UnsupportedFormatError.new("typed Dynamic structure-name roster changed after preflight")
      end
      names
    end

    # Construct a physical plan below a previously escaped structural site.
    # A shared context lets all sibling sites consume one name-work budget.
    def self.from_escaped_prefix(
      escaped_prefix : String,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      initial_array_level : UInt64 = 0_u64,
      context : PhysicalStreamPlanContext? = nil,
      typed_descriptor_root_depth : Int32 = 2,
      inferred_actual_root_depth : Int32? = nil,
      root_dynamic_json_budget : BinaryCodecBudget? = nil,
    ) : ObjectDocumentPhysicalPlan
      PhysicalStreamName.validate_canonical_escaped_prefix(escaped_prefix)
      unless escaped_prefix.bytesize.to_u64 <= limits.max_bytes.to_u64 &&
             escaped_prefix.bytesize <= Int32::MAX
        raise UnsupportedFormatError.new("physical Object site prefix exceeds configured name bound")
      end
      if selected = context
        unless same_limits?(selected.limits, limits)
          raise ArgumentError.new("Object physical name context limits differ from the site limits")
        end
      end
      new(
        EscapedPrefix.validated(escaped_prefix), plan, profile, shared_profile, limits,
        initial_array_level, context, typed_descriptor_root_depth,
        inferred_actual_root_depth || plan.inferred_actual_root_depth,
        root_dynamic_json_budget,
      )
    end

    def initialize(
      column_name : String,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      initial_array_level : UInt64 = 0_u64,
      typed_descriptor_root_depth : Int32 = 2,
      inferred_actual_root_depth : Int32? = nil,
      root_dynamic_json_budget : BinaryCodecBudget? = nil,
    )
      inferred_depth = inferred_actual_root_depth || plan.inferred_actual_root_depth
      selected_root_budget = root_dynamic_json_budget || BinaryCodecBudget.new(limits, false)
      state = build_plan(
        column_name, nil, plan, profile, shared_profile, limits, initial_array_level, nil,
        typed_descriptor_root_depth, inferred_depth, selected_root_budget
      )
      @profile = profile
      @shared_profile = shared_profile
      @initial_array_level = initial_array_level
      @typed_descriptor_root_depth = typed_descriptor_root_depth
      @inferred_actual_root_depth = inferred_depth
      @object_structure_stream = state.object_structure_stream
      @dynamic_structure_streams = state.dynamic_structure_streams
      @discriminator_streams = state.discriminator_streams
      @typed_plans = state.typed_plans
      @typed_dynamic_plans = state.typed_dynamic_plans
      @dynamic_arm_plans = state.dynamic_arm_plans
      @root_dynamic_json_plans = state.root_dynamic_json_plans
      @shared_plans = state.shared_plans
      @shared_bucket_count = state.shared_bucket_count
      @advanced_copy_stream_names = state.advanced_copy_stream_names
      @advanced_bucket_stream_names = state.advanced_bucket_stream_names
      @advanced_stream_names = collect_advanced_names(state.advanced_copy_stream_names, state.advanced_bucket_stream_names)
      @stream_count = state.stream_count
      @shared_data_version = plan.structures.object.shared_data_version
    end

    private def initialize(
      escaped_prefix : EscapedPrefix,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      initial_array_level : UInt64,
      context : PhysicalStreamPlanContext?,
      typed_descriptor_root_depth : Int32,
      inferred_actual_root_depth : Int32,
      root_dynamic_json_budget : BinaryCodecBudget?,
    )
      selected_budget = root_dynamic_json_budget || BinaryCodecBudget.new(limits, false)
      state = build_plan(
        nil, escaped_prefix.value, plan, profile, shared_profile, limits, initial_array_level,
        context, typed_descriptor_root_depth, inferred_actual_root_depth, selected_budget
      )
      @profile = profile
      @shared_profile = shared_profile
      @initial_array_level = initial_array_level
      @typed_descriptor_root_depth = typed_descriptor_root_depth
      @inferred_actual_root_depth = inferred_actual_root_depth
      @object_structure_stream = state.object_structure_stream
      @dynamic_structure_streams = state.dynamic_structure_streams
      @discriminator_streams = state.discriminator_streams
      @typed_plans = state.typed_plans
      @typed_dynamic_plans = state.typed_dynamic_plans
      @dynamic_arm_plans = state.dynamic_arm_plans
      @root_dynamic_json_plans = state.root_dynamic_json_plans
      @shared_plans = state.shared_plans
      @shared_bucket_count = state.shared_bucket_count
      @advanced_copy_stream_names = state.advanced_copy_stream_names
      @advanced_bucket_stream_names = state.advanced_bucket_stream_names
      @advanced_stream_names = collect_advanced_names(state.advanced_copy_stream_names, state.advanced_bucket_stream_names)
      @stream_count = state.stream_count
      @shared_data_version = plan.structures.object.shared_data_version
    end

    private def build_plan(
      column_name : String?,
      escaped_prefix : String?,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      initial_array_level : UInt64,
      provided_context : PhysicalStreamPlanContext?,
      typed_descriptor_root_depth : Int32,
      inferred_actual_root_depth : Int32,
      root_dynamic_json_budget : BinaryCodecBudget,
    ) : PlanState
      if initial_array_level > UInt64::MAX - limits.max_depth.to_u64
        raise UnsupportedFormatError.new("physical Object initial Array level overflows the name coordinate")
      end
      if typed_descriptor_root_depth <= 0 ||
         (plan.typed_path_count > 0 && typed_descriptor_root_depth > limits.max_depth)
        raise UnsupportedFormatError.new("physical Object typed descriptor root depth exceeds the configured limit")
      end
      if plan.typed_dynamic_count > 0 && typed_descriptor_root_depth < 2
        raise UnsupportedFormatError.new("physical Object typed Dynamic descriptor root depth must be at least 2")
      end
      if inferred_actual_root_depth <= 0 || inferred_actual_root_depth > limits.max_depth
        raise UnsupportedFormatError.new("physical Object inferred Dynamic actual root depth exceeds the configured limit")
      end
      unless same_limits?(root_dynamic_json_budget.limits, limits)
        raise ArgumentError.new("physical Object root JSON budget limits differ from the site limits")
      end
      object = plan.structures.object
      unless ObjectSharedBucketLayout.supported?(object)
        raise UnsupportedFormatError.new("physical Object planning admits V1/V2 MAP or V3 MAP, MAP_WITH_BUCKETS, ADVANCED, or CHUNKED layouts")
      end

      context = provided_context || PhysicalStreamPlanContext.new(limits)
      typed_dynamic_budget = BinaryCodecBudget.new(limits, true)
      typed_dynamic_write_plans = Hash(String, BinaryDynamicBulkPlan).new
      total_records = add_size(plan.typed_path_count.to_u64, object.dynamic_path_count.to_u64)
      context.record_elements(total_records)
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        if plan.has_typed_dynamic?(path)
          unless ObjectRecursiveDeclaration.account_descriptor(type, typed_dynamic_budget, limits, typed_descriptor_root_depth)
            raise UnsupportedFormatError.new("physical typed Object Dynamic descriptor is outside the recursive declaration grammar")
          end
          structures = plan.typed_dynamic_sites_for(path, typed_dynamic_budget)
          json_leaf_plans = plan.typed_dynamic_json_object_leaf_plans_for(path, typed_dynamic_budget)
          typed_dynamic_write_plans[path] = ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
            type,
            structures,
            typed_dynamic_budget,
            profile,
            typed_descriptor_root_depth,
            json_leaf_plans.empty? ? nil : json_leaf_plans,
          )
        elsif type.contains_dynamic?
          raise UnsupportedFormatError.new("physical Object typed Dynamic fields are not admitted")
        end
      end

      column_prefix = if escaped_prefix
                        context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
                        escaped_prefix
                      else
                        raw_column_name = column_name.not_nil!
                        context.preflight_name_bytes(PhysicalStreamName.escaped_size(raw_column_name))
                        PhysicalStreamName.escape(raw_column_name)
                      end
      seen_names = Hash(String, Bool).new

      object_structure_stream = PhysicalStreamName.append_literal(column_prefix, ".object_structure", context)
      context.charge_name_bytes(object_structure_stream.bytesize.to_u64)
      reject_collision!(object_structure_stream, seen_names)

      dynamic_structure_streams = Hash(String, String).new
      discriminator_streams = Hash(String, String).new
      dynamic_arm_plans = Hash(String, Hash(String, BinaryBulkPhysicalPlan)).new
      root_dynamic_json_plans = Hash(String, ObjectDocumentRootDynamicJsonPhysicalPlan).new
      object.dynamic_path_count.times do |index|
        preflight_object_path(object, index, column_prefix.bytesize.to_u64, context)
        raw_path = object.dynamic_path_at(index)
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path, context)
        structure_name = PhysicalStreamName.append_literal(path_prefix, ".dynamic_structure", context)
        discriminator_name = PhysicalStreamName.append_literal(path_prefix, ".variant_discr", context)
        context.charge_name_bytes(add_size(structure_name.bytesize.to_u64, discriminator_name.bytesize.to_u64))
        reject_collision!(structure_name, seen_names)
        reject_collision!(discriminator_name, seen_names)
        dynamic_structure_streams[String.new(raw_path.to_slice)] = structure_name
        discriminator_streams[String.new(raw_path.to_slice)] = discriminator_name

        dynamic = plan.structures.dynamic_for(raw_path)
        context.record_elements(dynamic.canonical_variant_count.to_u64)
        arm_plans = Hash(String, BinaryBulkPhysicalPlan).new
        shared_string = BinaryDataType.primitive("String")
        shared_prefix = PhysicalStreamName.append_escaped_component(path_prefix, DynamicStructure::SHARED_VARIANT_NAME, context)
        shared_arm = BinaryBulkPhysicalPlan.from_escaped_prefix(
          shared_string, shared_prefix, profile, limits, context, initial_array_level
        )
        arm_plans[String.new(DynamicStructure::SHARED_VARIANT_NAME.to_slice)] = shared_arm
        collect_plan_names!(shared_arm, seen_names)

        # Bound every actual descriptor before asking any cached recursive
        # summary whether the arm contains JSON. Root JSON discovery reuses
        # these already bounded actuals and returns a complete arm roster.
        dynamic.type_count.times do |type_index|
          preflight_dynamic_type(dynamic.type_at(type_index), limits.max_depth, 0, context, 0_u64, 0_u64)
        end
        leaf_plans = plan.root_dynamic_json_object_leaf_plans_for(raw_path, root_dynamic_json_budget)
        roster = DynamicJsonObjectBindingRoster.for_root_if_json(
          dynamic,
          leaf_plans,
          root_dynamic_json_budget,
          inferred_actual_root_depth,
        )

        dynamic.type_count.times do |type_index|
          type = dynamic.type_at(type_index)
          if type.contains_variant?
            raise UnsupportedFormatError.new("physical Object Dynamic Variant alternatives are not admitted")
          end
          has_json_name = type.contains_json?
          name_bounds = if has_json_name
                          BinaryTypeNameBudget.measure(type, root_dynamic_json_budget, inferred_actual_root_depth)
                        else
                          {display_name_bound(type, limits.max_depth, 0), 0_u64}
                        end
          name_bound = name_bounds[0]
          escaped_name_bound = multiply_size(name_bound, 3_u64)
          context.preflight_name_bytes(escaped_name_bound)
          context.preflight_name_bytes(add_size(path_prefix.bytesize.to_u64, add_size(1_u64, escaped_name_bound)))

          arm_name = if has_json_name
                       BinaryTypeNameBudget.materialize(type, root_dynamic_json_budget, name_bounds)
                     else
                       type.name
                     end
          unless arm_name.bytesize.to_u64 <= name_bound
            raise UnsupportedFormatError.new("Dynamic SQL display name exceeded its metadata preflight bound")
          end
          context.charge_name_bytes(arm_name.bytesize.to_u64)
          if arm_plans.has_key?(arm_name)
            raise UnsupportedFormatError.new("Dynamic alternatives collide on SQL display name")
          end
          arm_prefix = PhysicalStreamName.append_escaped_component(path_prefix, arm_name, context)
          arm_plan = if has_json_name
                       root_roster = roster || raise UnsupportedFormatError.new("root Dynamic JSON arm is missing its complete binding roster")
                       BinaryBulkPhysicalPlan.for_root_json_arm(
                         type,
                         dynamic.canonical_index_for(type),
                         root_roster,
                         root_dynamic_json_budget,
                         arm_prefix,
                         profile,
                         limits,
                         context,
                         initial_array_level,
                       )
                     else
                       BinaryBulkPhysicalPlan.from_escaped_prefix(
                         type, arm_prefix, profile, limits, context, initial_array_level
                       )
                     end
          arm_plans[String.new(arm_name.to_slice)] = arm_plan
          collect_plan_names!(arm_plan, seen_names)
        end
        dynamic_arm_plans[String.new(raw_path.to_slice)] = arm_plans

        # The legacy Object Dynamic actuals are bare root values. Reuse the
        # complete root JSON roster and the same path-coordinate resolver as
        # the reader; no nominal Dynamic physical plan or extra envelope is
        # introduced here.
        if root_roster = roster
          sites = Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectPhysicalSite).new(initial_capacity: leaf_plans.size)
          resolver = if root_dynamic_json_budget.writing?
                       ObjectRootDynamicJsonSiteResolver.for_write(
                         path_prefix,
                         dynamic,
                         root_dynamic_json_budget,
                         context,
                         initial_array_level,
                         inferred_actual_root_depth,
                       )
                     else
                       ObjectRootDynamicJsonSiteResolver.new(
                         path_prefix,
                         dynamic,
                         root_dynamic_json_budget,
                         context,
                         initial_array_level,
                         inferred_actual_root_depth,
                       )
                     end
          leaf_plans.each do |entry|
            key = entry[0]
            child_plan = entry[1]
            binding = root_roster.json_object_binding(key)
            coordinates = resolver.resolve_json_leaf(key)
            unless coordinates.json_type == binding.json_type &&
                   coordinates.json_depth == root_roster.json_object_leaf_depth(key)
              raise UnsupportedFormatError.new("root Dynamic JSON physical coordinates differ from the bound descriptor")
            end
            child_depth64 = coordinates.json_depth.to_i64 + 1_i64
            unless child_depth64 <= Int32::MAX.to_i64 && child_depth64 <= limits.max_depth.to_i64
              raise UnsupportedFormatError.new("root Dynamic JSON child descriptor depth exceeds the configured limit")
            end
            child_depth = child_depth64.to_i32
            child_physical = ObjectDocumentPhysicalPlan.from_escaped_prefix(
              coordinates.escaped_prefix,
              child_plan,
              profile,
              shared_profile,
              limits,
              coordinates.array_level,
              context,
              child_depth,
              child_depth,
              root_dynamic_json_budget,
            )
            site = DynamicJsonObjectPhysicalSite.new(
              key,
              coordinates.escaped_prefix,
              coordinates.array_level,
              binding,
              child_physical,
              coordinates.json_depth,
            )
            if sites.has_key?(key)
              raise UnsupportedFormatError.new("root Dynamic JSON physical leaf is duplicated")
            end
            sites[key] = site
            child_physical.stream_names.each do |name|
              reject_collision!(name, seen_names)
            end
          end
          unless sites.size == leaf_plans.size
            raise UnsupportedFormatError.new("root Dynamic JSON physical roster differs from its complete binding map")
          end
          root_dynamic_json_plans[String.new(raw_path.to_slice)] = ObjectDocumentRootDynamicJsonPhysicalPlan.new(sites)
        end
      end

      typed_plans = Hash(String, BinaryBulkPhysicalPlan).new
      typed_dynamic_plans = Hash(String, BinaryDynamicBulkPhysicalPlan).new
      plan.typed_path_count.times do |index|
        preflight_typed_path(plan, index, column_prefix.bytesize.to_u64, context)
        raw_path = plan.typed_path_at(index)
        type = plan.typed_type_for(raw_path)
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path, context)
        if plan.has_typed_dynamic?(raw_path)
          prepared = typed_dynamic_write_plans[raw_path]
          typed_dynamic_plan = BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(
            prepared,
            path_prefix,
            limits,
            context,
            initial_array_level,
            typed_descriptor_root_depth,
            root_dynamic_json_budget,
          )
          typed_dynamic_plans[String.new(raw_path.to_slice)] = typed_dynamic_plan
          collect_plan_names!(typed_dynamic_plan, seen_names)
          next
        end

        if type.contains_variant?
          preflight_variant_typed_type(type, limits.max_depth, 0, context, 0_u64, 0_u64)
          if ObjectRecursiveDeclaration.measure_descriptor(type, limits, typed_descriptor_root_depth).nil?
            raise UnsupportedFormatError.new("physical Object typed Variant descriptor is outside the admitted declaration grammar")
          end
        end
        if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type) &&
           ObjectRecursiveDeclaration.measure_descriptor(type, limits, typed_descriptor_root_depth).nil?
          raise UnsupportedFormatError.new("physical Object typed LowCardinality fields are not admitted")
        end
        typed_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(
          type, path_prefix, profile, limits, context, initial_array_level
        )
        typed_plans[String.new(raw_path.to_slice)] = typed_plan
        collect_plan_names!(typed_plan, seen_names)
      end

      shared_bucket_count = ObjectSharedBucketLayout.bucket_count(object)
      shared_plans = Array(BinaryBulkPhysicalPlan).new(shared_bucket_count)
      advanced_copy_stream_names = Hash(String, String).new
      advanced_bucket_stream_names = Array(Hash(String, String)).new(shared_bucket_count)
      if object.shared_data_version >= 2_u64
        {"sizes" => "sizes", "indexes" => "paths_indexes", "values" => "values"}.each do |lane, physical_lane|
          name = PhysicalStreamName.append_literal(
            column_prefix,
            ".object_shared_data.copy.#{physical_lane}",
            context
          )
          context.charge_name_bytes(name.bytesize.to_u64)
          reject_collision!(name, seen_names)
          advanced_copy_stream_names[String.new(lane.to_slice)] = name
        end
        shared_bucket_count.times do |bucket_index|
          names = Hash(String, String).new
          ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
            name = PhysicalStreamName.append_literal(
              column_prefix,
              ".object_shared_data.#{bucket_index}.#{lane}",
              context
            )
            context.charge_name_bytes(name.bytesize.to_u64)
            reject_collision!(name, seen_names)
            names[String.new(lane.to_slice)] = name
          end
          advanced_bucket_stream_names << names
        end
      else
        shared_type = BinaryDataType.array(
          BinaryDataType.tuple(
            [BinaryDataType.primitive("String"), BinaryDataType.primitive("String")],
            ["paths", "values"]
          )
        )
        # MAP-0 keeps its historical planning-budget behavior; MAP_WITH_BUCKETS
        # owns one BinaryBulk plan per configured bucket.
        if object.shared_data_version == 1_u64
          context.record_elements(shared_bucket_count.to_u64)
        end
        shared_bucket_count.times do |bucket_index|
          shared_component = if object.shared_data_version == 0_u64
                               ".object_shared_data"
                             else
                               ".object_shared_data.#{bucket_index}"
                             end
          shared_prefix = PhysicalStreamName.append_literal(column_prefix, shared_component, context)
          shared_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(
            shared_type, shared_prefix, shared_profile, limits, context, initial_array_level
          )
          collect_plan_names!(shared_plan, seen_names)
          shared_plans << shared_plan
        end
      end
      PlanState.new(
        object_structure_stream,
        dynamic_structure_streams,
        discriminator_streams,
        typed_plans,
        typed_dynamic_plans,
        dynamic_arm_plans,
        root_dynamic_json_plans,
        shared_plans,
        shared_bucket_count,
        advanced_copy_stream_names,
        advanced_bucket_stream_names,
        seen_names.size.to_i32
      )
    end

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    def object_structure_stream : String
      String.new(@object_structure_stream.to_slice)
    end

    def dynamic_structure_stream(path : String) : String
      name = @dynamic_structure_streams[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      String.new(name.to_slice)
    end

    def discriminator_stream(path : String) : String
      name = @discriminator_streams[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      String.new(name.to_slice)
    end

    def typed(path : String) : BinaryBulkPhysicalPlan
      @typed_plans[path]? || raise(KeyError.new("typed Object path not found: #{path.inspect}"))
    end

    def typed_dynamic(path : String) : BinaryDynamicBulkPhysicalPlan
      @typed_dynamic_plans[path]? || raise(KeyError.new("typed Dynamic Object path not found: #{path.inspect}"))
    end

    def dynamic_arm(path : String, arm_name : String) : BinaryBulkPhysicalPlan
      arms = @dynamic_arm_plans[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      arms[arm_name]? || raise(KeyError.new("Dynamic alternative not found: #{arm_name.inspect}"))
    end

    def shared : BinaryBulkPhysicalPlan
      unless @shared_plans.size == 1
        raise ArgumentError.new("Object shared plan is ambiguous for a multi-bucket layout")
      end
      @shared_plans[0]
    end

    def shared_bucket_count : Int32
      @shared_bucket_count
    end

    def shared_bucket(index : Int) : BinaryBulkPhysicalPlan
      @shared_plans[index]? || raise(IndexError.new("Object shared bucket index is outside the physical roster"))
    end

    def advanced_copy_stream_name(lane : String) : String
      name = @advanced_copy_stream_names[lane]? || raise(KeyError.new("advanced shared Object Copy lane not found: #{lane.inspect}"))
      String.new(name.to_slice)
    end

    def advanced_bucket_stream_name(bucket_index : Int, lane : String) : String
      bucket = @advanced_bucket_stream_names[bucket_index]? || raise(IndexError.new("advanced shared Object bucket index is outside the physical roster"))
      name = bucket[lane]? || raise(KeyError.new("advanced shared Object lane not found: #{lane.inspect}"))
      String.new(name.to_slice)
    end

    def advanced_stream_names : Array(String)
      @advanced_stream_names.map { |name| String.new(name.to_slice) }
    end

    def advanced_stream_name?(name : String) : Bool
      @advanced_stream_names.any? { |candidate| candidate == name }
    end

    # Account the additional shared-lane binding records before the reader
    # materializes per-bucket role/name snapshots. MAP-0 retains its historical
    # budget behavior. All buckets are measured without detached name hashes;
    # role records/edges use the borrowed codec budget while copied names use
    # the existing physical-name context, never the wire-byte counter.
    def preflight_shared_bucket_bindings!(hashed : Bool, budget : BinaryCodecBudget) : Nil
      return nil unless @shared_data_version == 1_u64

      binding_count = 0_u64
      name_copy_work_bytes = 0_u64
      @shared_plans.each do |physical|
        binding_count = add_size(binding_count, physical.stream_count.to_u64)
        name_copy_work_bytes = add_size(
          name_copy_work_bytes,
          physical.binding_name_copy_work_bytes(hashed)
        )
      end

      budget.ensure_future_nodes(binding_count)
      budget.ensure_future_elements(binding_count)
      shared_names = @shared_plans[0]
      shared_names.preflight_binding_name_copy_work(name_copy_work_bytes)

      # These are all preflighted above before any owner is charged.
      budget.charge_elements(binding_count)
      binding_count.times { budget.charge_node }
      shared_names.charge_binding_name_copy_work(name_copy_work_bytes)
      nil
    end

    def initial_array_level : UInt64
      @initial_array_level
    end

    def typed_descriptor_root_depth : Int32
      @typed_descriptor_root_depth
    end

    def inferred_actual_root_depth : Int32
      @inferred_actual_root_depth
    end

    def shared_profile : BinaryBulkProfile
      @shared_profile
    end

    def root_dynamic_json(path : String) : ObjectDocumentRootDynamicJsonPhysicalPlan
      @root_dynamic_json_plans[path]? ||
        raise(KeyError.new("root Dynamic JSON Object physical plan not found: #{path.inspect}"))
    end

    def has_root_dynamic_json?(path : String) : Bool
      @root_dynamic_json_plans.has_key?(path)
    end

    # Scalar count from the collision-checked construction roster. This lets
    # callers enforce entry caps before materializing the detached name list.
    def stream_count : Int32
      @stream_count
    end

    # The roster is detached and sorted; Object plans deliberately expose
    # basenames only, not guessed hashed aliases or extensions.
    def stream_names : Array(String)
      names = [] of String
      names << String.new(@object_structure_stream.to_slice)
      @dynamic_structure_streams.each_value { |name| names << String.new(name.to_slice) }
      @discriminator_streams.each_value { |name| names << String.new(name.to_slice) }
      @typed_plans.each_value do |physical|
        physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
      end
      @typed_dynamic_plans.each_value do |physical|
        physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
      end
      @dynamic_arm_plans.each_value do |arms|
        arms.each_value do |physical|
          physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
        end
      end
      @root_dynamic_json_plans.each_value do |root_plan|
        # The root plan stores child Object names rather than a synthetic
        # Dynamic stream map, preserving independent physical domains.
        # Child names are already collision-checked during construction.
        root_plan.each_site do |site|
          site.physical_plan.stream_names.each { |name| names << String.new(name.to_slice) }
        end
      end
      @shared_plans.each do |physical|
        physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
      end
      @advanced_stream_names.each { |name| names << String.new(name.to_slice) }
      names.sort!
      names
    end

    private def collect_advanced_names(
      copy_names : Hash(String, String),
      bucket_names : Array(Hash(String, String)),
    ) : Array(String)
      names = Array(String).new(copy_names.size + bucket_names.size * ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.size)
      copy_names.each_value { |name| names << String.new(name.to_slice) }
      bucket_names.each do |bucket|
        bucket.each_value { |name| names << String.new(name.to_slice) }
      end
      names.sort!
      names
    end

    private def collect_plan_names!(plan : BinaryBulkPhysicalPlan, seen : Hash(String, Bool)) : Nil
      plan.stream_names.each_value do |name|
        reject_collision!(name, seen)
      end
      nil
    end

    private def collect_plan_names!(plan : BinaryDynamicBulkPhysicalPlan, seen : Hash(String, Bool)) : Nil
      plan.stream_names.each_value do |name|
        reject_collision!(name, seen)
      end
      nil
    end

    private def reject_collision!(name : String, seen : Hash(String, Bool)) : Nil
      if seen.has_key?(name)
        raise UnsupportedFormatError.new("Object lanes collide on a physical stream name")
      end
      seen[name] = true
      nil
    end

    # Validate recursive descriptor work without consuming context counters.
    # The nested plan charges it once after this check and the SQL-name bound.
    private def preflight_dynamic_type(
      type : BinaryDataType,
      maximum_depth : Int,
      depth : Int,
      context : PhysicalStreamPlanContext,
      prior_nodes : UInt64,
      prior_elements : UInt64,
    ) : {UInt64, UInt64}
      if depth > maximum_depth
        raise UnsupportedFormatError.new("physical stream type depth exceeds configured limit")
      end
      # The physical Dynamic plan has no LowCardinality dictionary/index
      # roles. Refuse the descriptor during this bounded recursive walk,
      # before this planner's display-name bound and rendering step.
      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        raise UnsupportedFormatError.new(
          "physical Object Dynamic LowCardinality alternatives are not admitted"
        )
      end
      metadata = type.metadata_entry_count
      children = type.child_count
      elements = metadata.to_u64 + children.to_u64
      nodes = 1_u64
      context.preflight_type_budget(add_size(prior_nodes, nodes), add_size(prior_elements, elements))
      children.times do |index|
        child_nodes, child_elements = preflight_dynamic_type(
          type.child_at(index), maximum_depth, depth + 1, context,
          add_size(prior_nodes, nodes), add_size(prior_elements, elements)
        )
        nodes = add_size(nodes, child_nodes)
        elements = add_size(elements, child_elements)
      end
      {nodes, elements}
    end

    # Recursively bound typed Variant descriptors before the physical Object
    # planner refuses the local profile. No SQL name or typed lane roster is
    # materialized on this path.
    private def preflight_variant_typed_type(
      type : BinaryDataType,
      maximum_depth : Int,
      depth : Int,
      context : PhysicalStreamPlanContext,
      prior_nodes : UInt64,
      prior_elements : UInt64,
    ) : {UInt64, UInt64}
      if depth > maximum_depth
        raise UnsupportedFormatError.new("physical stream type depth exceeds configured limit")
      end
      metadata = type.metadata_entry_count
      children = type.child_count
      elements = add_size(metadata.to_u64, children.to_u64)
      nodes = 1_u64
      context.preflight_type_budget(add_size(prior_nodes, nodes), add_size(prior_elements, elements))
      children.times do |index|
        child_nodes, child_elements = preflight_variant_typed_type(
          type.child_at(index), maximum_depth, depth + 1, context,
          add_size(prior_nodes, nodes), add_size(prior_elements, elements)
        )
        nodes = add_size(nodes, child_nodes)
        elements = add_size(elements, child_elements)
      end
      {nodes, elements}
    end

    # Conservative but metadata-aware SQL display length. In particular,
    # opaque Tuple field bytes, Enum labels/count, and timezone bytes are all
    # bounded before BinaryDataType#name recursively materializes anything.
    private def display_name_bound(type : BinaryDataType, maximum_depth : Int, depth : Int) : UInt64
      if depth > maximum_depth
        raise UnsupportedFormatError.new("Dynamic SQL display name exceeds configured type depth")
      end
      case type.tag
      when BinaryDataType::TAG_ARRAY
        add_size(7_u64, display_name_bound(type.child_at(0), maximum_depth, depth + 1))
      when BinaryDataType::TAG_NULLABLE
        add_size(10_u64, display_name_bound(type.child_at(0), maximum_depth, depth + 1))
      when BinaryDataType::TAG_MAP
        add_size(7_u64, add_size(display_name_bound(type.child_at(0), maximum_depth, depth + 1), display_name_bound(type.child_at(1), maximum_depth, depth + 1)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = 7_u64
        type.child_count.times do |index|
          total = add_size(total, display_name_bound(type.child_at(index), maximum_depth, depth + 1))
          total = add_size(total, 2_u64) if index > 0
          if type.named_tuple?
            total = add_size(total, add_size(multiply_size(type.field_name_byte_size(index).to_u64, 2_u64), 3_u64))
          end
        end
        total
      when BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
        definition = type.enum_definition.not_nil!
        total = add_size(8_u64, multiply_size(definition.size.to_u64, 13_u64))
        definition.size.times do |index|
          total = add_size(total, multiply_size(definition.label_byte_size(index).to_u64, 2_u64))
        end
        total
      when BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
           BinaryDataType::TAG_TIME64
        zone_bytes = (type.temporal_type.not_nil!.time_zone?.try(&.name.bytesize) || 0).to_u64
        add_size(48_u64, zone_bytes)
      when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256
        32_u64
      when BinaryDataType::TAG_FIXED_STRING
        13_u64 + digit_count(type.fixed_size.not_nil!.to_u64)
      else
        16_u64
      end
    end

    private def digit_count(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def self.measure_typed_dynamic_names(
      type : BinaryDataType,
      path_bytes : UInt64,
      prefix_bytes : UInt64,
      depth : Int,
      budget : BinaryCodecBudget,
    ) : TypedDynamicNameShape
      if type.tag == BinaryDataType::TAG_DYNAMIC
        return TypedDynamicNameShape.new(
          1_u64,
          path_bytes,
          typed_dynamic_checked_add(prefix_bytes, ".dynamic_structure".bytesize.to_u64),
          0_u64
        )
      end

      case type.tag
      when BinaryDataType::TAG_ARRAY
        child = type.child_at(0)
        return empty_typed_dynamic_shape unless child.contains_dynamic?
        measure_typed_dynamic_names(
          child,
          typed_dynamic_checked_add(path_bytes, ".elements".bytesize.to_u64),
          prefix_bytes,
          depth + 1,
          budget
        )
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        return empty_typed_dynamic_shape unless child.contains_dynamic?
        measure_typed_dynamic_names(
          child,
          typed_dynamic_checked_add(path_bytes, ".nested".bytesize.to_u64),
          prefix_bytes,
          depth + 1,
          budget
        )
      when BinaryDataType::TAG_MAP
        child = type.child_at(1)
        return empty_typed_dynamic_shape unless child.contains_dynamic?
        values_prefix_bytes = typed_dynamic_checked_add(
          prefix_bytes,
          typed_dynamic_checked_add(3_u64, PhysicalStreamName.escaped_size("values"))
        )
        measure_typed_dynamic_names(
          child,
          typed_dynamic_checked_add(path_bytes, ".elements.field.1".bytesize.to_u64),
          values_prefix_bytes,
          depth + 1,
          budget
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = empty_typed_dynamic_shape
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          field_component_bytes = if type.named_tuple?
                                    raw_size = type.field_name_byte_size(index)
                                    escaped = PhysicalStreamName.escaped_size(raw_size) do |byte_index|
                                      type.field_name_byte_at(index, byte_index)
                                    end
                                    typed_dynamic_checked_add(3_u64, escaped)
                                  else
                                    typed_dynamic_checked_add(3_u64, decimal_digits(index + 1).to_u64)
                                  end
          child_shape = measure_typed_dynamic_names(
            child,
            typed_dynamic_checked_add(
              path_bytes,
              typed_dynamic_checked_add(".field.".bytesize.to_u64, decimal_digits(index).to_u64)
            ),
            typed_dynamic_checked_add(prefix_bytes, field_component_bytes),
            depth + 1,
            budget
          )
          total = add_typed_dynamic_shapes(total, child_shape)
        end
        total
      when BinaryDataType::TAG_VARIANT
        total = empty_typed_dynamic_shape
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          # The physical arm component is the canonical SQL type name. Bound
          # its rendering and escaped form before constructing any output.
          name_bounds = BinaryTypeNameBudget.measure(child, budget, depth + 1)
          escaped_component_bound = typed_dynamic_checked_add(1_u64, typed_dynamic_checked_multiply(name_bounds[0], 3_u64))
          child_shape = measure_typed_dynamic_names(
            child,
            typed_dynamic_checked_add(
              path_bytes,
              typed_dynamic_checked_add(".arm.".bytesize.to_u64, decimal_digits(index).to_u64)
            ),
            typed_dynamic_checked_add(prefix_bytes, escaped_component_bound),
            depth + 1,
            budget
          )
          child_shape = TypedDynamicNameShape.new(
            child_shape.count,
            child_shape.path_bytes,
            child_shape.physical_name_bytes,
            typed_dynamic_checked_add(child_shape.sql_name_work_bytes, name_bounds[1])
          )
          total = add_typed_dynamic_shapes(total, child_shape)
        end
        total
      else
        empty_typed_dynamic_shape
      end
    end

    private def self.collect_typed_dynamic_names(
      type : BinaryDataType,
      path : String,
      prefix : String,
      names : Hash(String, String),
      physical_seen : Hash(String, Bool),
    ) : Nil
      if type.tag == BinaryDataType::TAG_DYNAMIC
        name = PhysicalStreamName.append_literal(prefix, ".dynamic_structure")
        if names.has_key?(path) || physical_seen.has_key?(name)
          raise UnsupportedFormatError.new("typed Dynamic sites collide on a physical structure name")
        end
        names[String.new(path.to_slice)] = name
        physical_seen[name] = true
        return nil
      end

      case type.tag
      when BinaryDataType::TAG_ARRAY
        child = type.child_at(0)
        collect_typed_dynamic_names(child, path + ".elements", prefix, names, physical_seen) if child.contains_dynamic?
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        collect_typed_dynamic_names(child, path + ".nested", prefix, names, physical_seen) if child.contains_dynamic?
      when BinaryDataType::TAG_MAP
        child = type.child_at(1)
        if child.contains_dynamic?
          values_prefix = PhysicalStreamName.append_escaped_field(prefix, "values")
          collect_typed_dynamic_names(child, path + ".elements.field.1", values_prefix, names, physical_seen)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          field_name = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
          field_prefix = PhysicalStreamName.append_escaped_field(prefix, field_name)
          collect_typed_dynamic_names(child, path + ".field." + index.to_s, field_prefix, names, physical_seen)
        end
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_dynamic?
          arm_prefix = PhysicalStreamName.append_escaped_component(prefix, child.name)
          collect_typed_dynamic_names(child, path + ".arm." + index.to_s, arm_prefix, names, physical_seen)
        end
      end
      nil
    end

    private def self.empty_typed_dynamic_shape : TypedDynamicNameShape
      TypedDynamicNameShape.new(0_u64, 0_u64, 0_u64, 0_u64)
    end

    private def self.add_typed_dynamic_shapes(left : TypedDynamicNameShape, right : TypedDynamicNameShape) : TypedDynamicNameShape
      TypedDynamicNameShape.new(
        typed_dynamic_checked_add(left.count, right.count),
        typed_dynamic_checked_add(left.path_bytes, right.path_bytes),
        typed_dynamic_checked_add(left.physical_name_bytes, right.physical_name_bytes),
        typed_dynamic_checked_add(left.sql_name_work_bytes, right.sql_name_work_bytes)
      )
    end

    private def self.decimal_digits(value : Int) : Int32
      digits = 1
      remaining = value
      while remaining >= 10
        remaining //= 10
        digits += 1
      end
      digits
    end

    private def self.typed_dynamic_checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed Dynamic physical-name bound overflows UInt64")
      end
      left + right
    end

    private def self.typed_dynamic_checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("typed Dynamic physical-name bound overflows UInt64")
      end
      left * right
    end

    private def preflight_object_path(object : ObjectStructure, index : Int, column_length : UInt64, context : PhysicalStreamPlanContext) : Nil
      raw_size = object.dynamic_path_byte_size(index)
      escaped_size = PhysicalStreamName.escaped_size(raw_size) { |byte_index| object.dynamic_path_byte_at(index, byte_index) }
      context.preflight_name_bytes(add_size(column_length, add_size(1_u64, escaped_size)))
      nil
    end

    private def preflight_typed_path(plan : ObjectDocumentPlan, index : Int, column_length : UInt64, context : PhysicalStreamPlanContext) : Nil
      raw_size = plan.typed_path_byte_size_at(index)
      escaped_size = PhysicalStreamName.escaped_size(raw_size) { |byte_index| plan.typed_path_byte_at(index, byte_index) }
      context.preflight_name_bytes(add_size(column_length, add_size(1_u64, escaped_size)))
      nil
    end

    private def multiply_size(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("physical Object plan size overflows UInt64")
      end
      left * right
    end

    private def add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("physical Object plan size overflows UInt64")
      end
      left + right
    end
  end
end
