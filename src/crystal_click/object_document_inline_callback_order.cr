module CrystalClick
  # Produces the exact nested Compact Object callback schedule from the same
  # descriptor and physical-plan owners used by the lane writer. Wide lane
  # enumeration order is intentionally not used as callback order.
  class ObjectDocumentInlineCallbackOrder
    alias CallbackPair = Tuple(String, String)
    alias CallbackOwner = Tuple(String, String, ObjectDocumentPhysicalPlan, ObjectDocumentPlan)
    alias CallbackEvent = Tuple(String, String, String)
    alias EventScheduleContext = Tuple(ObjectDocumentInlineCallbackEvents, String)
    alias JsonLeafContext = Tuple(Symbol, String, String, Int32, Array(Int32))
    alias TraversalContext = Tuple(EventScheduleContext?, Symbol, String, JsonLeafContext?, Bool, Bool, Bool)

    # One source-exact body callback mapped back to the normalized lane role
    # and owning Object site. `owner_path` is a typed/Object path for those
    # owners and the decimal bucket index for `:shared` callbacks.
    alias BodyLaneBinding = Tuple(String, Symbol, String, String)

    def self.prefix_names(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(String)
      if local_only
        unless event_context
          raise UnsupportedFormatError.new("local inline callback schedules require a validated owner context")
        end
        if !allow_advanced && plan.structures.object.shared_data_version >= 2_u64
          raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
        end
      elsif event_context
        if !allow_advanced && plan.structures.object.shared_data_version >= 2_u64
          raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
        end
      elsif allow_advanced
        reject_nested_json_layout!(plan, budget)
      else
        reject_advanced_shared_layout!(plan, budget)
      end
      descendant_roles = if local_only
                           0_u64
                         else
                           event_context.try { |context| context[0].descendant_advanced_bucket_roles(context[1], allow_advanced, budget) } || 0_u64
                         end
      maximum_callbacks = callback_count_limit(physical_plan, plan, allow_advanced, budget, descendant_roles)
      names = [] of String
      append_name!(names, physical_plan.object_structure_stream, maximum_callbacks, budget)

      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        if plan.has_typed_dynamic?(path)
          sites = typed_dynamic_sites_snapshot(plan, path, budget)
          append_dynamic_prefixes(
            names,
            type,
            "root",
            physical_plan.typed_dynamic(path),
            sites,
            physical_plan.initial_array_level,
            physical_plan.typed_descriptor_root_depth,
            maximum_callbacks,
            budget,
            traversal_context(event_context, :typed_dynamic, path, nil, local_only, allow_advanced),
          )
        else
          append_static_prefixes(
            names,
            type,
            "root",
            physical_plan.typed(path),
            physical_plan.initial_array_level,
            physical_plan.typed_descriptor_root_depth,
            maximum_callbacks,
            budget,
            traversal_context(event_context, :typed, path, nil, local_only, allow_advanced),
          )
        end
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        append_name!(names, physical_plan.dynamic_structure_stream(path), maximum_callbacks, budget)
        discriminator = physical_plan.discriminator_stream(path)
        append_name!(names, prefix_name(discriminator, ".variant_discr", budget), maximum_callbacks, budget)
        canonical_arm_pairs(structure, budget).each_with_index do |(arm_name, arm), arm_index|
          arm_physical = physical_plan.dynamic_arm(path, arm_name)
          append_static_prefixes(
            names,
            arm,
            "root",
            arm_physical,
            physical_plan.initial_array_level,
            physical_plan.inferred_actual_root_depth,
            maximum_callbacks,
            budget,
            traversal_context(
              event_context,
              :root_dynamic,
              path,
              {:root_dynamic, path, "root", arm_index.to_i32, [] of Int32},
              local_only,
              allow_advanced,
            ),
          )
        end
      end
      validate_unique_names!(names, budget)
      names
    end

    def self.body_names(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      include_advanced_shared : Bool = true,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(String)
      if local_only
        unless event_context
          raise UnsupportedFormatError.new("local inline callback schedules require a validated owner context")
        end
        if !allow_advanced && plan.structures.object.shared_data_version >= 2_u64
          raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
        end
      elsif event_context
        if !allow_advanced && plan.structures.object.shared_data_version >= 2_u64
          raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
        end
      elsif allow_advanced
        reject_nested_json_layout!(plan, budget)
      else
        reject_advanced_shared_layout!(plan, budget)
      end
      descendant_roles = if local_only
                           0_u64
                         else
                           event_context.try { |context| context[0].descendant_advanced_bucket_roles(context[1], allow_advanced, budget) } || 0_u64
                         end
      maximum_callbacks = callback_count_limit(physical_plan, plan, allow_advanced, budget, descendant_roles)
      names = [] of String

      # Nested Object's callback body is descriptor order, not sorted physical
      # basenames: typed paths first, then Object Dynamic paths, then MAP.
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        if plan.has_typed_dynamic?(path)
          sites = typed_dynamic_sites_snapshot(plan, path, budget)
          append_dynamic_bodies(
            names,
            type,
            "root",
            physical_plan.typed_dynamic(path),
            sites,
            physical_plan.initial_array_level,
            physical_plan.typed_descriptor_root_depth,
            profile,
            maximum_callbacks,
            budget,
            traversal_context(event_context, :typed_dynamic, path, nil, local_only, allow_advanced, include_advanced_shared),
          )
        else
          append_static_bodies(
            names,
            type,
            "root",
            physical_plan.typed(path),
            physical_plan.initial_array_level,
            physical_plan.typed_descriptor_root_depth,
            profile,
            maximum_callbacks,
            budget,
            traversal_context(event_context, :typed, path, nil, local_only, allow_advanced, include_advanced_shared),
          )
        end
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        discriminator = physical_plan.discriminator_stream(path)
        append_name!(names, discriminator, maximum_callbacks, budget)
        canonical_arm_pairs(structure, budget).each_with_index do |(arm_name, arm), arm_index|
          arm_physical = physical_plan.dynamic_arm(path, arm_name)
          append_static_bodies(
            names,
            arm,
            "root",
            arm_physical,
            physical_plan.initial_array_level,
            physical_plan.inferred_actual_root_depth,
            profile,
            maximum_callbacks,
            budget,
            traversal_context(
              event_context,
              :root_dynamic,
              path,
              {:root_dynamic, path, "root", arm_index.to_i32, [] of Int32},
              local_only,
              allow_advanced,
              include_advanced_shared,
            ),
          )
        end
      end

      if plan.structures.object.shared_data_version >= 2_u64
        unless allow_advanced
          raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
        end
        if include_advanced_shared
          physical_plan.shared_bucket_count.times do |bucket_index|
            ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.each do |lane|
              append_name!(names, compact_bucket_callback_name(physical_plan, bucket_index, lane, budget), maximum_callbacks, budget)
            end
          end
          {"sizes", "indexes", "values"}.each do |lane|
            append_name!(names, physical_plan.advanced_copy_stream_name(lane), maximum_callbacks, budget)
          end
        end
      else
        shared_profile = physical_plan.shared_profile
        physical_plan.shared_bucket_count.times do |bucket_index|
          shared_type = BinaryDataType.array(
            BinaryDataType.tuple([
              BinaryDataType.primitive("String"),
              BinaryDataType.primitive("String"),
            ] of BinaryDataType, ["paths", "values"] of String)
          )
          append_static_bodies(
            names,
            shared_type,
            "root",
            physical_plan.shared_bucket(bucket_index),
            physical_plan.initial_array_level,
            1,
            shared_profile,
            maximum_callbacks,
            budget,
          )
        end
      end
      validate_unique_names!(names, budget)
      names
    end

    # Prefix and body schedules are authored in the canonical physical-name
    # domain. Nested Compact callbacks deliberately keep Variant/Dynamic type
    # names raw, so the paired result is `{canonical_name, callback_name}`.
    # Tuple field components remain escaped in both domains.
    def self.prefix_callback_pairs(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      callback_root_prefix : String,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(CallbackPair)
      names = prefix_names(physical_plan, plan, budget, allow_advanced, event_context, local_only)
      mapping = callback_prefix_mapping(physical_plan, plan, callback_root_prefix, budget)
      map_callback_names(names, mapping, budget)
    end

    def self.body_callback_pairs(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      callback_root_prefix : String,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      include_advanced_shared : Bool = true,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(CallbackPair)
      names = body_names(physical_plan, plan, profile, budget, allow_advanced, include_advanced_shared, event_context, local_only)
      mapping = callback_prefix_mapping(physical_plan, plan, callback_root_prefix, budget)
      map_callback_names(names, mapping, budget)
    end

    # Flatten the callback prefix phase for one Object subtree. Descendant
    # owners are resolved by exact Dynamic JSON leaf identity, while returned
    # events retain canonical and raw callback names separately.
    def self.prefix_callback_events(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      callback_root_prefix : String,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      descendants : Array(CallbackOwner) = [] of CallbackOwner,
    ) : Array(CallbackEvent)
      root = {canonical_root_prefix(physical_plan), callback_root_prefix, physical_plan, plan}
      events = ObjectDocumentInlineCallbackEvents.new(root, descendants, budget)
      root_context = {events, root[0]}
      names = prefix_names(physical_plan, plan, budget, allow_advanced, root_context)
      eventize_names(names, events, allow_advanced, nil, true, budget)
    end

    # Flatten the callback body phase in source descriptor order. Ownership
    # comes from each owner's own schedule, not from prefix matching; this is
    # important when a parent wrapper lane shares a physical prefix with its
    # JSON child Object.
    def self.body_callback_events(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      callback_root_prefix : String,
      budget : BinaryCodecBudget,
      allow_advanced : Bool = false,
      include_advanced_shared : Bool = true,
      descendants : Array(CallbackOwner) = [] of CallbackOwner,
    ) : Array(CallbackEvent)
      root = {canonical_root_prefix(physical_plan), callback_root_prefix, physical_plan, plan}
      events = ObjectDocumentInlineCallbackEvents.new(root, descendants, budget)
      root_context = {events, root[0]}
      names = body_names(
        physical_plan,
        plan,
        profile,
        budget,
        allow_advanced,
        include_advanced_shared,
        root_context,
      )
      eventize_names(names, events, allow_advanced, profile, false, budget, include_advanced_shared)
    end

    # The canonical child root is recoverable from the object-structure lane;
    # the raw callback root is supplied independently by the parent visitor.
    def self.canonical_root_prefix(physical_plan : ObjectDocumentPhysicalPlan) : String
      name = physical_plan.object_structure_stream
      suffix = ".object_structure"
      unless name.ends_with?(suffix)
        raise UnsupportedFormatError.new("inline Object structure name has an unexpected suffix")
      end
      name.byte_slice(0, name.bytesize - suffix.bytesize) || ""
    end

    # Resolve one physically bound child prefix through the exact canonical
    # to callback mapping for this owner. This deliberately does not select a
    # longest matching prefix: the supplied key must be an admitted descriptor
    # boundary in this owner's own plan.
    def self.callback_prefix_for_exact_site(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      callback_root_prefix : String,
      canonical_site_prefix : String,
      budget : BinaryCodecBudget,
    ) : String
      mapping = callback_prefix_mapping(physical_plan, plan, callback_root_prefix, budget)
      callback_prefix = mapping[canonical_site_prefix]? ||
                        raise(UnsupportedFormatError.new("inline child site has no exact Compact callback prefix"))
      budget.ensure_wire_bytes(callback_prefix.bytesize.to_u64)
      budget.charge_wire_bytes(callback_prefix.bytesize.to_u64)
      String.new(callback_prefix.to_slice)
    end

    private def self.callback_count_limit(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      allow_advanced : Bool,
      budget : BinaryCodecBudget,
      descendant_roles : UInt64 = 0_u64,
    ) : Int32
      extra_bucket_roles = if allow_advanced && plan.structures.object.shared_data_version >= 2_u64
                             physical_plan.shared_bucket_count.to_u64
                           else
                             0_u64
                           end
      base = physical_plan.stream_count.to_u64
      extra_bucket_roles = checked_add(extra_bucket_roles, descendant_roles)
      if extra_bucket_roles > UInt64::MAX - base || base + extra_bucket_roles > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact inline callback roster exceeds the supported domain")
      end
      count = base + extra_bucket_roles
      budget.ensure_future_elements(count)
      count.to_i32
    end

    private def self.eventize_names(
      names : Array(String),
      events : ObjectDocumentInlineCallbackEvents,
      allow_advanced : Bool,
      profile : BinaryBulkProfile?,
      prefix_phase : Bool,
      budget : BinaryCodecBudget,
      include_advanced_shared : Bool = true,
    ) : Array(CallbackEvent)
      owner_by_name = Hash(String, Tuple(String, String)).new
      owners_with_prefix = Hash(String, Bool).new

      events.owner_count.times do |index|
        owner = events.owner_at(index, budget)
        owner_context = {events, owner[0]}
        local_names = if prefix_phase
                        prefix_names(owner[2], owner[3], budget, allow_advanced, owner_context, true)
                      else
                        body_names(
                          owner[2],
                          owner[3],
                          profile || raise(ArgumentError.new("body callback events require a String profile")),
                          budget,
                          allow_advanced,
                          include_advanced_shared,
                          owner_context,
                          true,
                        )
                      end
        mapping = callback_prefix_mapping(owner[2], owner[3], owner[1], budget)
        pairs = map_callback_names(local_names, mapping, budget)
        pairs.each do |pair|
          canonical = pair[0]
          if owner_by_name.has_key?(canonical)
            raise UnsupportedFormatError.new("inline callback canonical name has multiple descriptor owners")
          end
          # `canonical` is already a privately owned, charged schedule name.
          # Reuse it as the lookup key rather than allocating an uncharged copy.
          owner_by_name[canonical] = {owner[0], pair[1]}
        end
        owners_with_prefix[owner[0]] = true unless local_names.empty?
      end

      unless owner_by_name.size == names.size
        raise UnsupportedFormatError.new("recursive inline callback names do not match their owner-local schedules")
      end
      if prefix_phase && owners_with_prefix.size != events.owner_count
        raise UnsupportedFormatError.new("recursive inline callback prefix schedule omits an Object owner")
      end

      count = names.size.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      result = Array(CallbackEvent).new(names.size)
      names.each do |canonical|
        owner = owner_by_name[canonical]? || raise(UnsupportedFormatError.new("recursive inline callback has no exact owner-local binding"))
        result << {owner[0], canonical, owner[1]}
      end
      result
    end

    # Compact nested Object callbacks have seven bucket roles while the Wide
    # physical-plan roster intentionally retains the six `.bin` roles. Keep
    # this callback-only name independent of `advanced_bucket_stream_name`.
    def self.compact_bucket_callback_name(
      physical_plan : ObjectDocumentPhysicalPlan,
      bucket_index : Int32,
      lane : String,
      budget : BinaryCodecBudget,
    ) : String
      unless bucket_index >= 0 && bucket_index < physical_plan.shared_bucket_count
        raise UnsupportedFormatError.new("Compact inline bucket callback index is outside its plan")
      end
      unless ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.includes?(lane)
        raise UnsupportedFormatError.new("Compact inline bucket callback role is outside its seven-role schedule")
      end
      prefix = canonical_root_prefix(physical_plan)
      suffix = ".object_shared_data.#{bucket_index}.#{lane}"
      output_size = checked_add(prefix.bytesize.to_u64, suffix.bytesize.to_u64)
      budget.ensure_wire_bytes(output_size)
      budget.charge_wire_bytes(output_size)
      PhysicalStreamName.append_literal(prefix, suffix)
    end

    private def self.callback_prefix_mapping(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      callback_root_prefix : String,
      budget : BinaryCodecBudget,
    ) : Hash(String, String)
      canonical_root = canonical_root_prefix(physical_plan)
      mapping = Hash(String, String).new
      add_callback_prefix_mapping!(mapping, canonical_root, callback_root_prefix, budget)

      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        canonical_path = append_escaped_component(canonical_root, path, budget)
        callback_path = append_escaped_component(callback_root_prefix, path, budget)
        add_callback_prefix_mapping!(mapping, canonical_path, callback_path, budget)
        type = plan.typed_type_for(path)
        sites = if plan.has_typed_dynamic?(path)
                  typed_dynamic_sites_snapshot(plan, path, budget)
                else
                  Hash(String, DynamicStructure).new
                end
        collect_descriptor_callback_prefixes!(
          mapping,
          type,
          "root",
          canonical_path,
          callback_path,
          sites,
          physical_plan.typed_descriptor_root_depth,
          budget,
        )
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        canonical_path = append_escaped_component(canonical_root, path, budget)
        callback_path = append_escaped_component(callback_root_prefix, path, budget)
        add_callback_prefix_mapping!(mapping, canonical_path, callback_path, budget)
        structure = plan.structures.dynamic_for(path)
        canonical_arm_pairs(structure, budget).each_with_index do |pair, arm_index|
          canonical_arm = if arm_index == structure.shared_index
                            append_literal(canonical_path, ".SharedVariant", budget)
                          else
                            append_escaped_component(canonical_path, pair[0], budget)
                          end
          callback_arm = if arm_index == structure.shared_index
                           append_literal(callback_path, ".SharedVariant", budget)
                         else
                           append_literal(callback_path, ".#{pair[0]}", budget)
                         end
          add_callback_prefix_mapping!(mapping, canonical_arm, callback_arm, budget)
          collect_descriptor_callback_prefixes!(
            mapping,
            pair[1],
            "root",
            canonical_arm,
            callback_arm,
            Hash(String, DynamicStructure).new,
            physical_plan.inferred_actual_root_depth,
            budget,
          )
        end
      end
      mapping
    end

    private def self.collect_descriptor_callback_prefixes!(
      mapping : Hash(String, String),
      type : BinaryDataType,
      path : String,
      canonical_prefix : String,
      callback_prefix : String,
      dynamic_sites : Hash(String, DynamicStructure),
      depth : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        collect_descriptor_callback_prefixes!(
          mapping, type.child_at(0), path, canonical_prefix, callback_prefix, dynamic_sites, depth + 1, budget
        )
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        collect_descriptor_callback_prefixes!(
          mapping, type.child_at(0), child_path(path, ".elements", budget), canonical_prefix, callback_prefix,
          dynamic_sites, depth + 1, budget
        )
      when BinaryDataType::TAG_NULLABLE
        collect_descriptor_callback_prefixes!(
          mapping, type.child_at(0), child_path(path, ".nested", budget), canonical_prefix, callback_prefix,
          dynamic_sites, depth + 1, budget
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          field = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
          field_path = child_path(path, ".field.#{index}", budget)
          collect_descriptor_callback_prefixes!(
            mapping,
            type.child_at(index),
            field_path,
            append_escaped_field(canonical_prefix, field, budget),
            append_escaped_field(callback_prefix, field, budget),
            dynamic_sites,
            depth + 1,
            budget,
          )
        end
      when BinaryDataType::TAG_MAP
        collect_descriptor_callback_prefixes!(
          mapping,
          type.child_at(0),
          child_path(path, ".elements.field.0", budget),
          append_escaped_field(canonical_prefix, "keys", budget),
          append_escaped_field(callback_prefix, "keys", budget),
          dynamic_sites,
          depth + 1,
          budget,
        )
        collect_descriptor_callback_prefixes!(
          mapping,
          type.child_at(1),
          child_path(path, ".elements.field.1", budget),
          append_escaped_field(canonical_prefix, "values", budget),
          append_escaped_field(callback_prefix, "values", budget),
          dynamic_sites,
          depth + 1,
          budget,
        )
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          arm = type.child_at(index)
          arm_path = child_path(path, ".arm.#{index}", budget)
          canonical_arm = append_type_component(canonical_prefix, arm, true, budget)
          callback_arm = append_type_component(callback_prefix, arm, false, budget)
          add_callback_prefix_mapping!(mapping, canonical_arm, callback_arm, budget)
          collect_descriptor_callback_prefixes!(
            mapping, arm, arm_path, canonical_arm, callback_arm, dynamic_sites, depth + 1, budget
          )
        end
      when BinaryDataType::TAG_DYNAMIC
        structure = dynamic_sites[path]? ||
                    raise UnsupportedFormatError.new("inline Dynamic callback-name structure is missing")
        canonical_arm_pairs(structure, budget).each_with_index do |pair, arm_index|
          arm_path = child_path(path, ".arm.#{arm_index}", budget)
          canonical_arm = if arm_index == structure.shared_index
                            append_literal(canonical_prefix, ".SharedVariant", budget)
                          else
                            append_type_component(canonical_prefix, pair[1], true, budget)
                          end
          callback_arm = if arm_index == structure.shared_index
                           append_literal(callback_prefix, ".SharedVariant", budget)
                         else
                           append_type_component(callback_prefix, pair[1], false, budget)
                         end
          add_callback_prefix_mapping!(mapping, canonical_arm, callback_arm, budget)
          collect_descriptor_callback_prefixes!(
            mapping, pair[1], arm_path, canonical_arm, callback_arm, dynamic_sites, depth + 1, budget
          )
        end
      end
      nil
    end

    private def self.typed_dynamic_sites_snapshot(
      plan : ObjectDocumentPlan,
      path : String,
      budget : BinaryCodecBudget,
    ) : Hash(String, DynamicStructure)
      count = plan.typed_dynamic_site_count_for(path).to_u64
      budget.preflight_children(count) if count > 0_u64
      key_bytes = 0_u64
      count.to_i.times do |index|
        key_bytes = checked_add(key_bytes, plan.typed_dynamic_site_path_byte_size_at(path, index).to_u64)
      end
      budget.ensure_wire_bytes(key_bytes)
      budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      sites = Hash(String, DynamicStructure).new(initial_capacity: count.to_i)
      count.to_i.times do |index|
        site_path = plan.typed_dynamic_site_path_at(path, index)
        sites[site_path] = plan.typed_dynamic_site_structure_for(path, site_path)
      end
      sites
    end

    private def self.add_callback_prefix_mapping!(
      mapping : Hash(String, String),
      canonical_prefix : String,
      callback_prefix : String,
      budget : BinaryCodecBudget,
    ) : Nil
      if existing = mapping[canonical_prefix]?
        unless existing == callback_prefix
          raise UnsupportedFormatError.new("canonical inline prefix maps to multiple Compact callback names")
        end
        return nil
      end
      size = checked_add(canonical_prefix.bytesize.to_u64, callback_prefix.bytesize.to_u64)
      budget.preflight_children(1_u64)
      budget.ensure_wire_bytes(size)
      budget.charge_node
      budget.charge_wire_bytes(size) if size > 0_u64
      mapping[String.new(canonical_prefix.to_slice)] = String.new(callback_prefix.to_slice)
      nil
    end

    private def self.map_callback_names(
      names : Array(String),
      mapping : Hash(String, String),
      budget : BinaryCodecBudget,
    ) : Array(CallbackPair)
      comparison_count = checked_multiply(names.size.to_u64, mapping.size.to_u64)
      budget.ensure_future_elements(comparison_count)
      budget.charge_elements(comparison_count) if comparison_count > 0_u64

      output_bytes = 0_u64
      names.each do |name|
        canonical_prefix, callback_prefix = callback_prefix_for_name(name, mapping)
        suffix_size = name.bytesize.to_u64 - canonical_prefix.bytesize.to_u64
        output_bytes = checked_add(output_bytes, checked_add(callback_prefix.bytesize.to_u64, suffix_size))
      end
      count = names.size.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      budget.ensure_wire_bytes(output_bytes)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      budget.charge_wire_bytes(output_bytes) if output_bytes > 0_u64

      result = Array(CallbackPair).new(names.size)
      callback_names = Array(String).new(names.size)
      names.each do |name|
        canonical_prefix, callback_prefix = callback_prefix_for_name(name, mapping)
        suffix = name.byte_slice(canonical_prefix.bytesize, name.bytesize - canonical_prefix.bytesize) || ""
        callback_name = String.build(callback_prefix.bytesize + suffix.bytesize) do |io|
          io.write(callback_prefix.to_slice)
          io.write(suffix.to_slice)
        end
        result << {name, callback_name}
        callback_names << callback_name
      end
      validate_unique_names!(callback_names, budget)
      result
    end

    private def self.callback_prefix_for_name(
      name : String,
      mapping : Hash(String, String),
    ) : Tuple(String, String)
      selected_canonical : String? = nil
      selected_callback : String? = nil
      mapping.each do |canonical_prefix, callback_prefix|
        next unless callback_prefix_boundary?(name, canonical_prefix)
        if selected_canonical.nil? || canonical_prefix.bytesize > selected_canonical.not_nil!.bytesize
          selected_canonical = canonical_prefix
          selected_callback = callback_prefix
        end
      end
      {
        selected_canonical || raise(UnsupportedFormatError.new("inline callback name is outside the child Object prefix")),
        selected_callback || raise(UnsupportedFormatError.new("inline callback name has no paired Compact name")),
      }
    end

    private def self.callback_prefix_boundary?(name : String, prefix : String) : Bool
      return false unless name.starts_with?(prefix)
      return true if name.bytesize == prefix.bytesize
      next_byte = name.byte_at(prefix.bytesize)
      return true if next_byte == '.'.ord.to_u8
      return false if next_byte != '%'.ord.to_u8 || name.bytesize - prefix.bytesize < 3
      name.byte_at(prefix.bytesize + 1) == '2'.ord.to_u8 && name.byte_at(prefix.bytesize + 2) == 'E'.ord.to_u8
    end

    private def self.append_escaped_component(prefix : String, raw : String, budget : BinaryCodecBudget) : String
      escaped_size = PhysicalStreamName.escaped_size(raw)
      output_size = checked_add(prefix.bytesize.to_u64, checked_add(1_u64, escaped_size))
      budget.ensure_wire_bytes(output_size)
      budget.charge_wire_bytes(output_size)
      PhysicalStreamName.append_escaped_component(prefix, raw)
    end

    private def self.append_escaped_field(prefix : String, raw : String, budget : BinaryCodecBudget) : String
      output_size = checked_add(prefix.bytesize.to_u64, checked_add(3_u64, PhysicalStreamName.escaped_size(raw)))
      budget.ensure_wire_bytes(output_size)
      budget.charge_wire_bytes(output_size)
      PhysicalStreamName.append_escaped_field(prefix, raw)
    end

    private def self.append_literal(prefix : String, suffix : String, budget : BinaryCodecBudget) : String
      output_size = checked_add(prefix.bytesize.to_u64, suffix.bytesize.to_u64)
      budget.ensure_wire_bytes(output_size)
      budget.charge_wire_bytes(output_size)
      PhysicalStreamName.append_literal(prefix, suffix)
    end

    private def self.append_type_component(
      prefix : String,
      type : BinaryDataType,
      escaped : Bool,
      budget : BinaryCodecBudget,
    ) : String
      name = BinaryTypeNameBudget.materialize(type, budget)
      suffix_size = escaped ? PhysicalStreamName.escaped_size(name) : name.bytesize.to_u64
      output_size = checked_add(prefix.bytesize.to_u64, checked_add(1_u64, suffix_size))
      budget.ensure_wire_bytes(output_size)
      budget.charge_wire_bytes(output_size)
      if escaped
        PhysicalStreamName.append_escaped_component(prefix, name)
      else
        PhysicalStreamName.append_literal(prefix, ".#{name}")
      end
    end

    # Source-order callbacks plus their normalized lane ownership. The
    # materializer uses this rather than reconstructing type traversal or
    # sorting physical basenames. Tuple fields are `{name, owner_kind,
    # owner_path, logical_role}`; owner kinds are `:typed`, `:typed_dynamic`,
    # `:root_dynamic`, and `:shared`. Root Dynamic arm roles are rebased to
    # `root.arm.<canonical_index>.*`, matching its statistics-free plan.
    def self.body_lane_bindings(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(BodyLaneBinding)
      names = body_names(physical_plan, plan, profile, budget, false, true, event_context, local_only)
      binding_count = names.size.to_u64
      budget.ensure_future_nodes(binding_count)
      budget.ensure_future_elements(binding_count)
      binding_count.times { budget.charge_node }
      budget.charge_elements(binding_count) if binding_count > 0_u64

      by_name = Hash(String, Tuple(Symbol, String, String, Int32?)).new(initial_capacity: names.size)
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        if plan.has_typed_dynamic?(path)
          add_lane_owners!(by_name, physical_plan.typed_dynamic(path).data_stream_names, :typed_dynamic, path)
        else
          add_lane_owners!(by_name, physical_plan.typed(path).stream_names, :typed, path)
        end
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        add_lane_owner!(by_name, physical_plan.discriminator_stream(path), :root_dynamic, path, "root.discriminators", nil)
        canonical_arm_pairs(structure, budget).each_with_index do |pair, arm_index|
          add_lane_owners!(
            by_name,
            physical_plan.dynamic_arm(path, pair[0]).stream_names,
            :root_dynamic,
            path,
            arm_index.to_i32,
          )
        end
      end

      physical_plan.shared_bucket_count.times do |bucket_index|
        bucket = bucket_index.to_s
        add_lane_owners!(by_name, physical_plan.shared_bucket(bucket_index).stream_names, :shared, bucket)
      end

      unless by_name.size == names.size
        raise UnsupportedFormatError.new("inline body callback roster does not cover every normalized lane")
      end

      # Reserve all detached owner path/role snapshots before copying any
      # names. Callback names themselves are borrowed from the already charged
      # schedule returned above.
      owner_copy_bytes = 0_u64
      names.each do |name|
        owner = by_name[name]? || raise(UnsupportedFormatError.new("inline body callback has no normalized lane owner"))
        owner_copy_bytes = checked_add(owner_copy_bytes, owner[1].bytesize.to_u64)
        owner_copy_bytes = checked_add(owner_copy_bytes, normalized_role_size(owner[2], owner[3]))
      end
      budget.ensure_wire_bytes(owner_copy_bytes)
      budget.charge_wire_bytes(owner_copy_bytes) if owner_copy_bytes > 0_u64

      result = Array(BodyLaneBinding).new(names.size)
      names.each do |name|
        owner = by_name[name]? || raise(UnsupportedFormatError.new("inline body callback has no normalized lane owner"))
        result << {name, owner[0], String.new(owner[1].to_slice), normalized_role(owner[2], owner[3])}
      end
      result
    end

    # Full source-order body ownership for nested Compact callbacks when the
    # child Object itself uses SharedData v2/v3. Unlike the legacy MAP binding
    # method, this includes the seven per-bucket raw roles followed by the
    # three global Copy roles. Names stay in the canonical physical domain;
    # callers that consume callbacks map them with body_callback_pairs.
    def self.advanced_body_lane_bindings(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      event_context : EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Array(BodyLaneBinding)
      unless plan.structures.object.shared_data_version >= 2_u64
        raise ArgumentError.new("advanced inline callback bindings require SharedData v2 or v3")
      end
      names = body_names(physical_plan, plan, profile, budget, true, true, event_context, local_only)
      binding_count = names.size.to_u64
      budget.ensure_future_nodes(binding_count)
      budget.ensure_future_elements(binding_count)
      binding_count.times { budget.charge_node }
      budget.charge_elements(binding_count) if binding_count > 0_u64

      by_name = Hash(String, Tuple(Symbol, String, String, Int32?)).new(initial_capacity: names.size)
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        if plan.has_typed_dynamic?(path)
          add_lane_owners!(by_name, physical_plan.typed_dynamic(path).data_stream_names, :typed_dynamic, path)
        else
          add_lane_owners!(by_name, physical_plan.typed(path).stream_names, :typed, path)
        end
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        add_lane_owner!(by_name, physical_plan.discriminator_stream(path), :root_dynamic, path, "root.discriminators", nil)
        canonical_arm_pairs(structure, budget).each_with_index do |pair, arm_index|
          add_lane_owners!(
            by_name,
            physical_plan.dynamic_arm(path, pair[0]).stream_names,
            :root_dynamic,
            path,
            arm_index.to_i32,
          )
        end
      end

      physical_plan.shared_bucket_count.times do |bucket_index|
        owner_path = bucket_index.to_s
        ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.each do |lane|
          add_lane_owner!(
            by_name,
            compact_bucket_callback_name(physical_plan, bucket_index, lane, budget),
            :advanced_bucket,
            owner_path,
            lane,
            nil,
          )
        end
      end
      {"sizes", "indexes", "values"}.each do |lane|
        add_lane_owner!(
          by_name,
          physical_plan.advanced_copy_stream_name(lane),
          :advanced_copy,
          "copy",
          lane,
          nil,
        )
      end

      unless by_name.size == names.size
        raise UnsupportedFormatError.new("advanced inline callback roster does not cover every normalized lane")
      end

      owner_copy_bytes = 0_u64
      names.each do |name|
        owner = by_name[name]? || raise(UnsupportedFormatError.new("advanced inline callback has no normalized lane owner"))
        owner_copy_bytes = checked_add(owner_copy_bytes, owner[1].bytesize.to_u64)
        owner_copy_bytes = checked_add(owner_copy_bytes, normalized_role_size(owner[2], owner[3]))
      end
      budget.ensure_wire_bytes(owner_copy_bytes)
      budget.charge_wire_bytes(owner_copy_bytes) if owner_copy_bytes > 0_u64

      result = Array(BodyLaneBinding).new(names.size)
      names.each do |name|
        owner = by_name[name]? || raise(UnsupportedFormatError.new("advanced inline callback has no normalized lane owner"))
        result << {name, owner[0], String.new(owner[1].to_slice), normalized_role(owner[2], owner[3])}
      end
      result
    end

    private def self.add_lane_owners!(
      owners : Hash(String, Tuple(Symbol, String, String, Int32?)),
      role_names : Hash(String, String),
      owner_kind : Symbol,
      owner_path : String,
      arm_index : Int32? = nil,
    ) : Nil
      role_names.each do |role, name|
        add_lane_owner!(owners, name, owner_kind, owner_path, role, arm_index)
      end
      nil
    end

    private def self.add_lane_owner!(
      owners : Hash(String, Tuple(Symbol, String, String, Int32?)),
      name : String,
      owner_kind : Symbol,
      owner_path : String,
      role : String,
      arm_index : Int32?,
    ) : Nil
      if owners.has_key?(name)
        raise UnsupportedFormatError.new("inline callback physical lane has multiple normalized owners")
      end
      owners[name] = {owner_kind, owner_path, role, arm_index}
      nil
    end

    private def self.normalized_role_size(role : String, arm_index : Int32?) : UInt64
      return role.bytesize.to_u64 unless arm_index
      unless role == "root" || role.starts_with?("root.")
        raise UnsupportedFormatError.new("root Dynamic arm lane role is not rooted at the actual descriptor")
      end
      suffix_size = role.bytesize.to_u64 - "root".bytesize.to_u64
      checked_add(checked_add("root.arm.".bytesize.to_u64, decimal_digits(arm_index)), suffix_size)
    end

    private def self.normalized_role(role : String, arm_index : Int32?) : String
      return String.new(role.to_slice) unless arm_index
      unless role == "root" || role.starts_with?("root.")
        raise UnsupportedFormatError.new("root Dynamic arm lane role is not rooted at the actual descriptor")
      end
      suffix = role.byte_slice("root".bytesize, role.bytesize - "root".bytesize) || ""
      "root.arm.#{arm_index}#{suffix}"
    end

    private def self.decimal_digits(value : Int32) : UInt64
      unless value >= 0
        raise UnsupportedFormatError.new("inline Dynamic canonical arm index is negative")
      end
      digits = 1_u64
      remaining = value
      while remaining >= 10
        remaining //= 10
        digits += 1_u64
      end
      digits
    end

    private def self.traversal_context(
      event_context : EventScheduleContext?,
      scope_kind : Symbol,
      scope_path : String,
      leaf : JsonLeafContext?,
      local_only : Bool,
      allow_advanced : Bool,
      include_advanced_shared : Bool = true,
    ) : TraversalContext
      {event_context, scope_kind, scope_path, leaf, local_only, allow_advanced, include_advanced_shared}
    end

    # Extend the JSON descriptor path while staying in the same dynamic site.
    # Array/Nested/Nullable/Custom use child 0; Tuple uses its field index;
    # Map uses key=0/value=1; Variant uses its canonical arm index.
    private def self.traversal_child(
      traversal : TraversalContext?,
      child_index : Int32,
      budget : BinaryCodecBudget,
    ) : TraversalContext?
      return nil unless traversal
      leaf = traversal[3]
      return traversal unless leaf
      unless child_index >= 0
        raise UnsupportedFormatError.new("inline JSON descriptor child index is negative")
      end
      old_path = leaf[4]
      new_count = old_path.size.to_u64 + 1_u64
      budget.ensure_future_elements(new_count)
      copied_bytes = checked_multiply(new_count, 4_u64)
      budget.ensure_wire_bytes(copied_bytes)
      budget.charge_elements(new_count)
      budget.charge_wire_bytes(copied_bytes) if copied_bytes > 0_u64
      new_path = Array(Int32).new(old_path.size + 1)
      old_path.each { |index| new_path << index }
      new_path << child_index
      next_leaf : JsonLeafContext = {leaf[0], leaf[1], leaf[2], leaf[3], new_path}
      {traversal[0], traversal[1], traversal[2], next_leaf, traversal[4], traversal[5], traversal[6]}
    end

    # A nested Dynamic descriptor starts a fresh owner-local leaf key at its
    # canonical arm index. The outer scope remains part of EventScheduleContext.
    private def self.traversal_dynamic_arm(
      traversal : TraversalContext?,
      dynamic_site : String,
      canonical_arm_index : Int32,
      budget : BinaryCodecBudget,
    ) : TraversalContext?
      return nil unless traversal
      unless canonical_arm_index >= 0
        raise UnsupportedFormatError.new("inline JSON Dynamic arm index is negative")
      end
      size = dynamic_site.bytesize.to_u64
      budget.ensure_wire_bytes(size)
      budget.charge_wire_bytes(size) if size > 0_u64
      leaf : JsonLeafContext = {
        traversal[1],
        traversal[2],
        String.new(dynamic_site.to_slice),
        canonical_arm_index,
        [] of Int32,
      }
      {traversal[0], traversal[1], traversal[2], leaf, traversal[4], traversal[5], traversal[6]}
    end

    private def self.append_json_prefix_names!(
      names : Array(String),
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext?,
    ) : Nil
      context = traversal || raise(UnsupportedFormatError.new("inline JSON descriptor has no prepared Dynamic leaf context"))
      schedule = context[0] || raise(UnsupportedFormatError.new("inline JSON prefix schedule has no validated callback owner tree"))
      leaf = context[3] || raise(UnsupportedFormatError.new("inline JSON prefix schedule has no exact Dynamic leaf key"))
      key = BinaryDynamicJsonLeafKey.new(leaf[2], leaf[3], leaf[4])
      child = schedule[0].child_owner(schedule[1], context[1], context[2], key, budget)
      return nil if context[4]

      child_context : EventScheduleContext = {schedule[0], child[0]}
      child_names = prefix_names(child[2], child[3], budget, context[5], child_context)
      child_names.each { |name| append_name!(names, name, maximum_lanes, budget) }
      nil
    end

    private def self.append_json_body_names!(
      names : Array(String),
      profile : BinaryBulkProfile,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext?,
    ) : Nil
      context = traversal || raise(UnsupportedFormatError.new("inline JSON descriptor has no prepared Dynamic leaf context"))
      schedule = context[0] || raise(UnsupportedFormatError.new("inline JSON body schedule has no validated callback owner tree"))
      leaf = context[3] || raise(UnsupportedFormatError.new("inline JSON body schedule has no exact Dynamic leaf key"))
      key = BinaryDynamicJsonLeafKey.new(leaf[2], leaf[3], leaf[4])
      child = schedule[0].child_owner(schedule[1], context[1], context[2], key, budget)
      return nil if context[4]

      child_context : EventScheduleContext = {schedule[0], child[0]}
      child_names = body_names(child[2], child[3], profile, budget, context[5], context[6], child_context)
      child_names.each { |name| append_name!(names, name, maximum_lanes, budget) }
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("inline callback lane-owner work size overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("inline callback name-pair work size overflows UInt64")
      end
      left * right
    end

    private def self.append_static_prefixes(
      names : Array(String),
      type : BinaryDataType,
      path : String,
      physical : BinaryBulkPhysicalPlan,
      array_level : UInt64,
      depth : Int32,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext? = nil,
    ) : Nil
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_static_prefixes(names, type.child_at(0), path, physical, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_static_prefixes(names, type.child_at(0), child_path(path, ".elements", budget), physical, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_NULLABLE
        append_static_prefixes(names, type.child_at(0), child_path(path, ".nested", budget), physical, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_static_prefixes(names, type.child_at(index), child_path(path, ".field.#{index}", budget), physical, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_MAP
        append_static_prefixes(names, type.child_at(0), child_path(path, ".elements.field.0", budget), physical, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
        append_static_prefixes(names, type.child_at(1), child_path(path, ".elements.field.1", budget), physical, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 1_i32, budget))
      when BinaryDataType::TAG_VARIANT
        role = child_path(path, ".discriminators", budget)
        body_name = physical.stream_name_for(role)
        append_name!(names, prefix_name(body_name, ".variant_discr", budget), maximum_lanes, budget)
        type.child_count.times do |index|
          append_static_prefixes(names, type.child_at(index), child_path(path, ".arm.#{index}", budget), physical, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_LOW_CARDINALITY
        role = child_path(path, ".dictionary", budget)
        append_name!(names, prefix_name(physical.stream_name_for(role), ".dict", budget), maximum_lanes, budget)
      when BinaryDataType::TAG_DYNAMIC
        raise UnsupportedFormatError.new("nested Dynamic typed descriptor lacks its prepared Dynamic physical plan")
      when BinaryDataType::TAG_JSON
        append_json_prefix_names!(names, maximum_lanes, budget, traversal)
      end
      nil
    end

    private def self.append_dynamic_prefixes(
      names : Array(String),
      type : BinaryDataType,
      path : String,
      physical : BinaryDynamicBulkPhysicalPlan,
      structures : Hash(String, DynamicStructure),
      array_level : UInt64,
      depth : Int32,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext? = nil,
    ) : Nil
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = structures[path]? || raise(UnsupportedFormatError.new("inline typed Dynamic prefix structure is missing"))
        append_name!(names, physical.structure_name_for(path), maximum_lanes, budget)
        discriminator = physical.stream_name_for(child_path(path, ".discriminators", budget))
        append_name!(names, prefix_name(discriminator, ".variant_discr", budget), maximum_lanes, budget)
        canonical_arm_pairs(structure, budget).each_with_index do |pair, index|
          append_dynamic_prefixes(
            names,
            pair[1],
            child_path(path, ".arm.#{index}", budget),
            physical,
            structures,
            array_level,
            depth + 1,
            maximum_lanes,
            budget,
            traversal_dynamic_arm(traversal, path, index.to_i32, budget),
          )
        end
      when BinaryDataType::TAG_VARIANT
        role = child_path(path, ".discriminators", budget)
        append_name!(names, prefix_name(physical.stream_name_for(role), ".variant_discr", budget), maximum_lanes, budget)
        type.child_count.times do |index|
          append_dynamic_prefixes(names, type.child_at(index), child_path(path, ".arm.#{index}", budget), physical, structures, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_dynamic_prefixes(names, type.child_at(0), child_path(path, ".elements", budget), physical, structures, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_NULLABLE
        append_dynamic_prefixes(names, type.child_at(0), child_path(path, ".nested", budget), physical, structures, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_dynamic_prefixes(names, type.child_at(0), path, physical, structures, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_dynamic_prefixes(names, type.child_at(index), child_path(path, ".field.#{index}", budget), physical, structures, array_level, depth + 1, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_MAP
        append_dynamic_prefixes(names, type.child_at(0), child_path(path, ".elements.field.0", budget), physical, structures, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
        append_dynamic_prefixes(names, type.child_at(1), child_path(path, ".elements.field.1", budget), physical, structures, array_level + 1_u64, depth + 1, maximum_lanes, budget, traversal_child(traversal, 1_i32, budget))
      when BinaryDataType::TAG_LOW_CARDINALITY
        role = child_path(path, ".dictionary", budget)
        append_name!(names, prefix_name(physical.stream_name_for(role), ".dict", budget), maximum_lanes, budget)
      when BinaryDataType::TAG_JSON
        append_json_prefix_names!(names, maximum_lanes, budget, traversal)
      end
      nil
    end

    private def self.append_static_bodies(
      names : Array(String),
      type : BinaryDataType,
      path : String,
      physical : BinaryBulkPhysicalPlan,
      array_level : UInt64,
      depth : Int32,
      profile : BinaryBulkProfile,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext? = nil,
    ) : Nil
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_static_bodies(names, type.child_at(0), path, physical, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_STRING
        append_name!(names, physical.stream_name_for(child_path(path, ".string_sizes", budget)), maximum_lanes, budget) if profile.with_size_stream?
        append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_name!(names, physical.stream_name_for(child_path(path, ".sizes", budget)), maximum_lanes, budget)
        append_static_bodies(names, type.child_at(0), child_path(path, ".elements", budget), physical, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_NULLABLE
        append_name!(names, physical.stream_name_for(child_path(path, ".nulls", budget)), maximum_lanes, budget)
        append_static_bodies(names, type.child_at(0), child_path(path, ".nested", budget), physical, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
        else
          type.child_count.times do |index|
            append_static_bodies(names, type.child_at(index), child_path(path, ".field.#{index}", budget), physical, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
          end
        end
      when BinaryDataType::TAG_MAP
        append_name!(names, physical.stream_name_for(child_path(path, ".sizes", budget)), maximum_lanes, budget)
        append_static_bodies(names, type.child_at(0), child_path(path, ".elements.field.0", budget), physical, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
        append_static_bodies(names, type.child_at(1), child_path(path, ".elements.field.1", budget), physical, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 1_i32, budget))
      when BinaryDataType::TAG_LOW_CARDINALITY
        append_name!(names, physical.stream_name_for(child_path(path, ".dictionary", budget)), maximum_lanes, budget)
        append_name!(names, physical.stream_name_for(child_path(path, ".indexes", budget)), maximum_lanes, budget)
      when BinaryDataType::TAG_VARIANT
        append_name!(names, physical.stream_name_for(child_path(path, ".discriminators", budget)), maximum_lanes, budget)
        type.child_count.times do |index|
          append_static_bodies(names, type.child_at(index), child_path(path, ".arm.#{index}", budget), physical, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || raise(UnsupportedFormatError.new("inline QBit descriptor is missing its nominal type"))
        qbit.plane_count.times do |plane|
          append_name!(names, physical.stream_name_for(BinaryQBitBulkCodec.plane_role(path, plane)), maximum_lanes, budget)
        end
      when BinaryDataType::TAG_DYNAMIC
        raise UnsupportedFormatError.new("nested Dynamic typed descriptor lacks its prepared Dynamic physical plan")
      when BinaryDataType::TAG_JSON
        append_json_body_names!(names, profile, maximum_lanes, budget, traversal)
      else
        append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
      end
      nil
    end

    private def self.append_dynamic_bodies(
      names : Array(String),
      type : BinaryDataType,
      path : String,
      physical : BinaryDynamicBulkPhysicalPlan,
      structures : Hash(String, DynamicStructure),
      array_level : UInt64,
      depth : Int32,
      profile : BinaryBulkProfile,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
      traversal : TraversalContext? = nil,
    ) : Nil
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = structures[path]? || raise(UnsupportedFormatError.new("inline typed Dynamic body structure is missing"))
        append_name!(names, physical.stream_name_for(child_path(path, ".discriminators", budget)), maximum_lanes, budget)
        canonical_arm_pairs(structure, budget).each_with_index do |pair, index|
          append_dynamic_bodies(
            names,
            pair[1],
            child_path(path, ".arm.#{index}", budget),
            physical,
            structures,
            array_level,
            depth + 1,
            profile,
            maximum_lanes,
            budget,
            traversal_dynamic_arm(traversal, path, index.to_i32, budget),
          )
        end
      when BinaryDataType::TAG_VARIANT
        append_name!(names, physical.stream_name_for(child_path(path, ".discriminators", budget)), maximum_lanes, budget)
        type.child_count.times do |index|
          append_dynamic_bodies(names, type.child_at(index), child_path(path, ".arm.#{index}", budget), physical, structures, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
        end
      when BinaryDataType::TAG_STRING
        append_name!(names, physical.stream_name_for(child_path(path, ".string_sizes", budget)), maximum_lanes, budget) if profile.with_size_stream?
        append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_name!(names, physical.stream_name_for(child_path(path, ".sizes", budget)), maximum_lanes, budget)
        append_dynamic_bodies(names, type.child_at(0), child_path(path, ".elements", budget), physical, structures, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_NULLABLE
        append_name!(names, physical.stream_name_for(child_path(path, ".nulls", budget)), maximum_lanes, budget)
        append_dynamic_bodies(names, type.child_at(0), child_path(path, ".nested", budget), physical, structures, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_dynamic_bodies(names, type.child_at(0), path, physical, structures, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
        else
          type.child_count.times do |index|
            append_dynamic_bodies(names, type.child_at(index), child_path(path, ".field.#{index}", budget), physical, structures, array_level, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, index.to_i32, budget))
          end
        end
      when BinaryDataType::TAG_MAP
        append_name!(names, physical.stream_name_for(child_path(path, ".sizes", budget)), maximum_lanes, budget)
        append_dynamic_bodies(names, type.child_at(0), child_path(path, ".elements.field.0", budget), physical, structures, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 0_i32, budget))
        append_dynamic_bodies(names, type.child_at(1), child_path(path, ".elements.field.1", budget), physical, structures, array_level + 1_u64, depth + 1, profile, maximum_lanes, budget, traversal_child(traversal, 1_i32, budget))
      when BinaryDataType::TAG_LOW_CARDINALITY
        append_name!(names, physical.stream_name_for(child_path(path, ".dictionary", budget)), maximum_lanes, budget)
        append_name!(names, physical.stream_name_for(child_path(path, ".indexes", budget)), maximum_lanes, budget)
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || raise(UnsupportedFormatError.new("inline QBit descriptor is missing its nominal type"))
        qbit.plane_count.times do |plane|
          append_name!(names, physical.stream_name_for(BinaryQBitBulkCodec.plane_role(path, plane)), maximum_lanes, budget)
        end
      when BinaryDataType::TAG_JSON
        append_json_body_names!(names, profile, maximum_lanes, budget, traversal)
      else
        append_name!(names, physical.stream_name_for(child_path(path, ".data", budget)), maximum_lanes, budget)
      end
      nil
    end

    private def self.canonical_arm_pairs(structure : DynamicStructure, budget : BinaryCodecBudget) : Array(Tuple(String, BinaryDataType))
      count = structure.canonical_variant_count
      budget.preflight_children(count.to_u64) if count > 0
      # DynamicStructure returns an owned copy; bound and charge that copy
      # once, then reuse it for both names and the canonical descriptor roster.
      canonical_names = structure.canonical_variant_names
      unless canonical_names.size == count
        raise UnsupportedFormatError.new("inline Dynamic canonical name roster changed after preflight")
      end
      name_bytes = 0_u64
      canonical_names.each do |name|
        size = name.bytesize.to_u64
        if size > UInt64::MAX - name_bytes
          raise UnsupportedFormatError.new("inline Dynamic canonical name work overflows UInt64")
        end
        name_bytes += size
      end
      budget.ensure_wire_bytes(name_bytes)
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64
      arms = Array(BinaryDataType?).new(count, nil)
      shared_index = structure.shared_index
      unless 0 <= shared_index < count
        raise UnsupportedFormatError.new("inline Dynamic shared arm index is outside its canonical roster")
      end
      arms[shared_index] = BinaryDataType.primitive("String")
      structure.type_count.times do |index|
        type = structure.type_at(index)
        canonical_index = structure.canonical_index_for(type)
        if arms[canonical_index]?
          raise UnsupportedFormatError.new("inline Dynamic canonical arm roster is duplicated")
        end
        arms[canonical_index] = type
      end
      Array(Tuple(String, BinaryDataType)).new(count) do |index|
        arm = arms[index] || raise(UnsupportedFormatError.new("inline Dynamic canonical arm roster is incomplete"))
        {canonical_names[index], arm}
      end
    rescue ex : ArgumentError
      raise UnsupportedFormatError.new("inline Dynamic canonical arm roster is invalid: #{ex.message}")
    end

    private def self.append_name!(
      names : Array(String),
      name : String,
      maximum_lanes : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      if names.size >= maximum_lanes
        raise UnsupportedFormatError.new("inline callback schedule exceeds its physical lane roster")
      end
      bytes = name.bytesize.to_u64
      budget.preflight_children(1_u64)
      budget.ensure_wire_bytes(bytes)
      budget.charge_node
      budget.charge_wire_bytes(bytes)
      names << String.new(name.to_slice)
      nil
    end

    private def self.validate_unique_names!(names : Array(String), budget : BinaryCodecBudget) : Nil
      count = names.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(count)
      budget.charge_elements(count) if count > 0_u64
      seen = Hash(String, Bool).new(initial_capacity: names.size)
      names.each do |name|
        if seen.has_key?(name)
          raise UnsupportedFormatError.new("inline callback schedule contains a duplicate physical name")
        end
        seen[name] = true
      end
      nil
    end

    private def self.prefix_name(
      body_name : String,
      body_suffix : String,
      budget : BinaryCodecBudget,
    ) : String
      unless body_name.ends_with?(body_suffix)
        raise UnsupportedFormatError.new("inline callback physical name has an unexpected framing suffix")
      end
      prefix_suffix = body_suffix == ".variant_discr" ? ".variant_discr_prefix" : ".dict_prefix"
      retained_size = body_name.bytesize - body_suffix.bytesize
      total = retained_size.to_u64 + prefix_suffix.bytesize.to_u64
      budget.ensure_wire_bytes(total)
      budget.charge_wire_bytes(total)
      String.build(total.to_i32) do |io|
        io.write(body_name.to_slice[0, retained_size])
        io << prefix_suffix
      end
    end

    private def self.child_path(path : String, suffix : String, budget : BinaryCodecBudget) : String
      total = path.bytesize.to_u64 + suffix.bytesize.to_u64
      budget.ensure_wire_bytes(total)
      budget.charge_wire_bytes(total)
      String.build(total.to_i32) do |io|
        io << path
        io << suffix
      end
    end

    private def self.reject_advanced_shared_layout!(plan : ObjectDocumentPlan, budget : BinaryCodecBudget) : Nil
      if plan.structures.object.shared_data_version >= 2_u64
        raise UnsupportedFormatError.new("advanced inline child Object shared layouts require Compact mark-coordinate relocation")
      end
      reject_nested_json_layout!(plan, budget)
      nil
    end

    private def self.reject_nested_json_layout!(plan : ObjectDocumentPlan, budget : BinaryCodecBudget) : Nil
      if plan.typed_dynamic_json_object_leaf_plans(budget).size > 0 || plan.root_dynamic_json_object_leaf_plans(budget).size > 0
        raise UnsupportedFormatError.new("inline child Object plans with nested JSON actuals are outside this callback frontier")
      end
      nil
    end
  end
end
