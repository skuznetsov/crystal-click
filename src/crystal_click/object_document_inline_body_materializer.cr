module CrystalClick
  # Rebuilds one inline Object child's ordinary document streams from
  # source-ordered callback bytes and delegates v2/v3 bucket+Copy roles to the
  # advanced inline decoder. Prefix discovery and callback census happen in
  # separate passes, so child rows always come from the exact occurrence grid.
  class ObjectDocumentInlineBodyMaterializer
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding

    def self.materialize(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(BodyBinding)? = nil,
      callback_pairs_override : Array(ObjectDocumentInlineCallbackOrder::CallbackPair)? = nil,
      statistics_offsets : Hash(String, Int32)? = nil,
    ) : ObjectDocumentStreams
      context = prefix.nested_context
      if budget.writing? || context.writing?
        raise ArgumentError.new("inline Object body materialization requires read-direction contexts")
      end
      prefix.validate_physical_owner!(physical_plan)
      unless context.shared_data_version == prefix.plan.structures.object.shared_data_version
        raise CorruptPartError.new("inline Object shared-data version differs from its inherited context")
      end
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("inline Object shared MAP lanes require the source single-stream profile")
      end
      grid.validate_for!(1, budget)

      prefix_callbacks = read_prefix_callbacks(prefix, budget)
      body_callbacks = read_body_callbacks(prefix, budget)
      plan = prefix.plan
      profile = context.profile
      advanced = context.shared_data_version >= 2_u64
      bound_roles, callback_pairs = if roles = role_bindings
                                      pairs = callback_pairs_override || prefix.body_callback_pairs
                                      {roles, pairs}
                                    else
                                      inline_prefix = prefix.as?(ObjectDocumentInlinePrefix) ||
                                                      raise(ArgumentError.new("unbound static Object callback schedule"))
                                      event_context = inline_prefix.event_schedule_context
                                      roles = if advanced
                                                ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
                                                  physical_plan,
                                                  plan,
                                                  profile,
                                                  budget,
                                                  event_context,
                                                  true,
                                                )
                                              else
                                                ObjectDocumentInlineCallbackOrder.body_lane_bindings(
                                                  physical_plan,
                                                  plan,
                                                  profile,
                                                  budget,
                                                  event_context,
                                                  true,
                                                )
                                              end
                                      pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
                                        physical_plan,
                                        plan,
                                        profile,
                                        prefix.callback_prefix,
                                        budget,
                                        advanced,
                                        true,
                                        event_context,
                                        true,
                                      )
                                      {roles, pairs}
                                    end
      unless bound_roles.size == body_callbacks.size &&
             callback_pairs.size == body_callbacks.size &&
             prefix.body_callback_slice_count == body_callbacks.size
        raise CorruptPartError.new("inline Object body callback count does not match its physical lane plan")
      end
      bindings = [] of BodyBinding
      ordinary_callbacks = [] of Tuple(String, Bytes)
      bound_roles.each_with_index do |binding, index|
        canonical_name, owner_kind, _owner_path, _role = binding
        pair = callback_pairs[index]
        slice = prefix.body_callback_slice_at(index)
        unless body_callbacks[index][0] == canonical_name &&
               pair[0] == canonical_name &&
               slice.canonical_name == canonical_name &&
               slice.callback_name == pair[1]
          raise CorruptPartError.new("inline Object body callback order differs from its physical lane plan")
        end
        next if owner_kind == :advanced_bucket || owner_kind == :advanced_copy
        bindings << binding
        ordinary_callbacks << body_callbacks[index]
      end

      typed_schema = prefix.typed_schema_for(budget)
      object_structure = plan.structures.object
      validate_structure_callbacks!(prefix, physical_plan, prefix_callbacks, typed_schema, budget, statistics_offsets)

      rows = grid.logical_occurrences_at(0)
      root_paths = snapshot_object_dynamic_paths(object_structure, budget)
      root_roles = Hash(String, Hash(String, Hash(String, BinaryBulkStream))).new(initial_capacity: root_paths.size)
      root_discriminators = Hash(String, DynamicDiscriminatorStream).new(initial_capacity: root_paths.size)
      root_arm_names = Hash(String, Array(String)).new(initial_capacity: root_paths.size)
      root_paths.each do |path|
        structure = plan.structures.dynamic_for(path)
        names = canonical_arm_names(structure, budget)
        root_arm_names[path] = names
        arm_groups = Hash(String, Hash(String, BinaryBulkStream)).new(initial_capacity: names.size)
        names.each do |arm_name|
          arm_groups[arm_name] = Hash(String, BinaryBulkStream).new
        end
        root_roles[path] = arm_groups
      end

      static_typed_paths = Hash(String, Hash(String, BinaryBulkStream)).new
      typed_dynamic_roles = Hash(String, Hash(String, BinaryBulkStream)).new
      typed_dynamic_sites = Hash(String, Hash(String, DynamicStructure)).new
      typed_dynamic_site_bytes = Hash(String, Hash(String, Bytes)).new
      typed_site_offsets = Hash(String, Hash(String, Int32)).new
      typed_mode : UInt64? = nil
      typed_schema.each do |path, _type|
        if plan.has_typed_dynamic?(path)
          typed_dynamic_roles[path] = Hash(String, BinaryBulkStream).new
          sites = prefix.typed_dynamic_sites_for(path, budget)
          typed_dynamic_sites[path] = sites
          site_bytes = Hash(String, Bytes).new(initial_capacity: sites.size)
          site_offsets = Hash(String, Int32).new(initial_capacity: sites.size)
          physical_dynamic = physical_plan.typed_dynamic(path)
          sites.each_key do |site_path|
            name = physical_dynamic.structure_name_for(site_path)
            bytes = prefix_callbacks[name]? || raise(CorruptPartError.new("inline typed Dynamic metadata callback is missing"))
            site_bytes[site_path] = bytes
            site_offsets[site_path] = structure_statistics_offset(prefix, name, bytes, statistics_offsets)
          end
          typed_dynamic_site_bytes[path] = site_bytes
          typed_site_offsets[path] = site_offsets
        else
          static_typed_paths[path] = Hash(String, BinaryBulkStream).new
        end
      end

      shared_roles = Array(Hash(String, BinaryBulkStream)).new(advanced ? 0 : physical_plan.shared_bucket_count) do
        Hash(String, BinaryBulkStream).new
      end

      preflight = preflight_materialization(
        bindings,
        ordinary_callbacks,
        prefix_callbacks,
        PhysicalStreamName.append_literal(prefix.physical_prefix, ".object_structure"),
        physical_plan,
        plan,
        typed_schema,
        root_paths,
        typed_dynamic_sites,
        root_arm_names,
        grid,
        budget,
      )
      budget.ensure_wire_bytes(preflight[0])
      budget.ensure_future_nodes(preflight[1])
      budget.ensure_future_elements(preflight[2])
      budget.charge_wire_bytes(preflight[3]) if preflight[3] > 0_u64
      budget.charge_elements(preflight[2]) if preflight[2] > 0_u64
      preflight[1].times { budget.charge_node }

      bindings.each_with_index do |binding, index|
        name, owner_kind, owner_path, role = binding
        body = ordinary_callbacks[index][1]
        if owner_kind == :root_dynamic && role == "root.discriminators"
          mode = read_mode_header(prefix_fragment_for(name, prefix_callbacks), name)
          DynamicDiscriminatorBodyValidator.inspect_body(mode, body, rows, false)
          full = join_prefix_and_body(prefix_fragment_for(name, prefix_callbacks), body)
          unless root_discriminators[owner_path]?.nil?
            raise CorruptPartError.new("inline Object root Dynamic discriminator callback is duplicated")
          end
          marks = [
            DynamicDiscriminatorMark.new(8_u64, rows),
            DynamicDiscriminatorMark.new(full.size.to_u64, 0_u64),
          ] of DynamicDiscriminatorMark
          root_discriminators[owner_path] = DynamicDiscriminatorStream.new(full, marks)
          next
        end

        bytes, offsets, observed_mode = normalize_lane(
          name,
          owner_kind,
          owner_path,
          role,
          body,
          prefix_callbacks,
          physical_plan,
          rows,
          budget,
          root_arm_names,
        )
        if owner_kind == :typed_dynamic && role.ends_with?(".discriminators")
          if previous = typed_mode
            unless previous == observed_mode
              raise CorruptPartError.new("inline typed Dynamic discriminator modes are inconsistent")
            end
          else
            typed_mode = observed_mode
          end
        end
        lane = BinaryBulkStream.new(bytes, offsets)
        case owner_kind
        when :typed
          add_lane!(static_typed_paths[owner_path]?, role, lane, "typed Object")
        when :typed_dynamic
          add_lane!(typed_dynamic_roles[owner_path]?, role, lane, "typed Dynamic Object")
        when :shared
          bucket = parse_bucket_index(owner_path, shared_roles.size)
          add_lane!(shared_roles[bucket], role, lane, "shared MAP bucket")
        when :root_dynamic
          path, arm_name, local_role = parse_root_arm_role(owner_path, role, root_arm_names)
          arms = root_roles[path]? || raise(CorruptPartError.new("inline Object root Dynamic path is not in the parsed structure roster"))
          arm_group = arms[arm_name]? || raise(CorruptPartError.new("inline Object Dynamic arm is not in the parsed canonical roster"))
          add_lane!(arm_group, local_role, lane, "root Dynamic arm")
        else
          raise CorruptPartError.new("inline Object body callback has an unknown normalized owner")
        end
      end

      dynamic_paths = Hash(String, DynamicValueStreams).new(initial_capacity: root_paths.size)
      root_paths.each do |path|
        discriminator = root_discriminators[path]? ||
                        raise CorruptPartError.new("inline Object root Dynamic discriminator is missing")
        arm_names = root_arm_names[path]
        arms = Hash(String, BinaryBulkStreams).new(initial_capacity: arm_names.size)
        arm_names.each do |arm_name|
          arm_groups = root_roles[path]? || raise(CorruptPartError.new("inline Object root Dynamic arm map is missing"))
          grouped = arm_groups[arm_name]? || raise(CorruptPartError.new("inline Object Dynamic arm is not in the parsed canonical roster"))
          arms[arm_name] = BinaryBulkStreams.new(1, grouped)
        end
        dynamic_paths[path] = DynamicValueStreams.new(discriminator, arms)
      end

      typed_dynamic_paths = Hash(String, BinaryDynamicBulkStreams).new(initial_capacity: typed_dynamic_roles.size)
      typed_dynamic_roles.each do |path, roles|
        site_bytes = typed_dynamic_site_bytes[path]? ||
                     raise(CorruptPartError.new("inline typed Dynamic structure bytes are missing"))
        structures = BinaryDynamicStructureStreams.new(site_bytes)
        typed_dynamic_paths[path] = BinaryDynamicBulkStreams.new(
          structures,
          BinaryBulkStreams.new(1, roles),
        )
      end

      object_bytes = prefix_callbacks[
        PhysicalStreamName.append_literal(prefix.physical_prefix, ".object_structure"),
      ]? || raise(CorruptPartError.new("inline Object structure prefix callback is missing"))
      root_structure_bytes = Hash(String, Bytes).new(initial_capacity: root_paths.size)
      dynamic_offsets = Hash(String, Int32).new(initial_capacity: root_paths.size)
      root_paths.each do |path|
        name = physical_plan.dynamic_structure_stream(path)
        bytes = prefix_callbacks[name]? || raise(CorruptPartError.new("inline Object Dynamic structure callback is missing"))
        root_structure_bytes[path] = bytes
        dynamic_offsets[path] = structure_statistics_offset(prefix, name, bytes, statistics_offsets)
      end
      object_dynamic = ObjectDynamicStructureStreams.new(
        object_bytes,
        root_structure_bytes,
        prefix.object_structure_statistics_offset,
        dynamic_offsets,
      )

      typed_paths = Hash(String, BinaryBulkStreams).new(initial_capacity: static_typed_paths.size)
      static_typed_paths.each do |path, roles|
        typed_paths[path] = BinaryBulkStreams.new(1, roles)
      end

      typed_site_offsets.each_value do |offsets|
        # PrefixOnly callers retain terminal offsets; direct Complete callers
        # supply parser-observed statistics boundaries for every Dynamic site.
        offsets.each_value { |offset| raise CorruptPartError.new("inline typed Dynamic statistics offset is invalid") if offset < 0 }
      end

      advanced_shared_rows = if advanced
                               ObjectSharedAdvancedInlineDecoder.decode(
                                 prefix,
                                 physical_plan,
                                 grid,
                                 budget,
                                 bound_roles,
                                 callback_pairs,
                               )
                             else
                               [] of Array(ObjectSharedMapRow)
                             end

      ObjectDocumentStreams.new(
        object_dynamic,
        [rows] of UInt64,
        typed_paths,
        dynamic_paths,
        shared_roles.map { |roles| BinaryBulkStreams.new(1, roles) },
        typed_dynamic_paths,
        Hash(String, Int32).new,
        typed_site_offsets,
        typed_mode || DynamicDiscriminatorBodyValidator::BASIC_MODE,
        advanced_shared_rows,
      )
    rescue ex : KeyError
      raise CorruptPartError.new("inline Object physical plan is incomplete: #{ex.message}")
    end

    private def self.read_prefix_callbacks(
      prefix : ObjectDocumentCallbackPrefix,
      budget : BinaryCodecBudget,
    ) : Hash(String, Bytes)
      count = prefix.prefix_callback_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      callbacks = Hash(String, Bytes).new(initial_capacity: prefix.prefix_callback_count)
      prefix.prefix_callback_count.times do |index|
        name, bytes = prefix.prefix_callback_at(index, budget)
        if callbacks.has_key?(name)
          raise CorruptPartError.new("inline Object prefix callback name is duplicated")
        end
        callbacks[name] = bytes
      end
      callbacks
    end

    private def self.read_body_callbacks(
      prefix : ObjectDocumentCallbackPrefix,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(String, Bytes))
      count = prefix.body_callback_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      callbacks = Array(Tuple(String, Bytes)).new(prefix.body_callback_count)
      prefix.body_callback_count.times do |index|
        callbacks << prefix.body_callback_at(index, budget)
      end
      callbacks
    end

    private def self.validate_structure_callbacks!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      prefix_callbacks : Hash(String, Bytes),
      typed_schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
      statistics_offsets : Hash(String, Int32)?,
    ) : Nil
      object_name = PhysicalStreamName.append_literal(prefix.physical_prefix, ".object_structure")
      object_bytes = prefix_callbacks[object_name]? || raise(CorruptPartError.new("inline Object structure callback is missing"))
      object_offset = prefix.object_structure_statistics_offset
      if prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly
        unless object_bytes.size == object_offset
          raise CorruptPartError.new("inline Object structure prefix does not end at its statistics offset")
        end
      elsif object_offset < 0 || object_offset > object_bytes.size
        raise CorruptPartError.new("inline Object structure prefix does not end at its statistics offset")
      end

      object = prefix.plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        name = physical_plan.dynamic_structure_stream(path)
        bytes = prefix_callbacks[name]? || raise(CorruptPartError.new("inline Object Dynamic structure callback is missing"))
        structure_statistics_offset(prefix, name, bytes, statistics_offsets)
      end

      typed_schema.each do |path, type|
        next unless prefix.plan.has_typed_dynamic?(path)
        sites = prefix.typed_dynamic_sites_for(path, budget)
        physical = physical_plan.typed_dynamic(path)
        sites.each_key do |site_path|
          name = physical.structure_name_for(site_path)
          bytes = prefix_callbacks[name]?
          unless bytes
            raise CorruptPartError.new("inline typed Dynamic structure callback is missing")
          end
          structure_statistics_offset(prefix, name, bytes.not_nil!, statistics_offsets)
        end
      end
      nil
    end

    private def self.structure_statistics_offset(
      prefix : ObjectDocumentCallbackPrefix,
      name : String,
      bytes : Bytes,
      statistics_offsets : Hash(String, Int32)?,
    ) : Int32
      offset = if prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
                 offsets = statistics_offsets || raise(CorruptPartError.new("complete Object statistics offsets are missing"))
                 offsets[name]? || raise(CorruptPartError.new("complete Dynamic statistics offset is missing"))
               else
                 bytes.size
               end
      unless offset >= 0 && offset <= bytes.size
        raise CorruptPartError.new("inline Dynamic statistics offset is outside its parsed prefix")
      end
      offset
    end

    private def self.snapshot_object_dynamic_paths(
      object : ObjectStructure,
      budget : BinaryCodecBudget,
    ) : Array(String)
      count = object.dynamic_path_count.to_u64
      byte_count = 0_u64
      object.dynamic_path_count.times do |index|
        byte_count = checked_add(byte_count, object.dynamic_path_byte_size(index).to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(byte_count) if byte_count > 0_u64
      count.times { budget.charge_node }
      Array(String).new(object.dynamic_path_count) do |index|
        String.build(object.dynamic_path_byte_size(index)) do |io|
          object.dynamic_path_byte_size(index).times do |byte_index|
            io.write_byte(object.dynamic_path_byte_at(index, byte_index))
          end
        end
      end
    end

    private def self.canonical_arm_names(
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
    ) : Array(String)
      count = structure.canonical_variant_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      names = structure.canonical_variant_names
      bytes = 0_u64
      names.each { |name| bytes = checked_add(bytes, name.bytesize.to_u64) }
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
      count.times { budget.charge_node }
      names
    end

    private def self.preflight_materialization(
      bindings : Array(BodyBinding),
      body_callbacks : Array(Tuple(String, Bytes)),
      prefix_callbacks : Hash(String, Bytes),
      object_structure_name : String,
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      typed_schema : Hash(String, BinaryDataType),
      root_paths : Array(String),
      typed_sites : Hash(String, Hash(String, DynamicStructure)),
      root_arm_names : Hash(String, Array(String)),
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64, UInt64, UInt64)
      rows = grid.logical_occurrences_at(0)
      output_bytes = 0_u64
      temporary_bytes = 0_u64
      expansion_bytes = 0_u64
      role_bytes = 0_u64
      offset_elements = 0_u64
      node_count = bindings.size.to_u64

      bindings.each_with_index do |binding, index|
        name, owner_kind, owner_path, role = binding
        body = body_callbacks[index][1]
        if owner_kind == :root_dynamic && role == "root.discriminators"
          header = required_prefix(name, prefix_callbacks)
          mode = read_mode_header(header, name)
          DynamicDiscriminatorBodyValidator.inspect_body(mode, body, rows, false)
          output_bytes = checked_add(output_bytes, 8_u64 + body.size.to_u64)
          role_bytes = checked_add(role_bytes, role.bytesize.to_u64)
          temporary_bytes = checked_add(temporary_bytes, 8_u64 + body.size.to_u64)
          offset_elements = checked_add(offset_elements, 2_u64)
          node_count = checked_add(node_count, 2_u64)
          next
        end

        physical, physical_role = lane_physical(owner_kind, owner_path, role, physical_plan, root_arm_names)
        prefix_size = physical.prefix_size_for(physical_role)
        role_bytes = checked_add(role_bytes, role.bytesize.to_u64)
        if prefix_size == 0
          output_bytes = checked_add(output_bytes, body.size.to_u64)
        elsif prefix_size == BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
          header = required_prefix(name, prefix_callbacks)
          unless header.size == prefix_size
            raise CorruptPartError.new("inline Object physical lane prefix has the wrong byte width")
          end
          if owner_kind == :typed_dynamic && role.ends_with?(".discriminators")
            mode = read_mode_header(header, name)
            DynamicDiscriminatorBodyValidator.inspect_body(mode, body, rows, false)
            temporary_bytes = checked_add(temporary_bytes, 8_u64 + body.size.to_u64)
            normalized_size = mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE ? rows : body.size.to_u64
            output_bytes = checked_add(output_bytes, normalized_size)
            expansion_bytes = checked_add(expansion_bytes, mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE ? rows : 0_u64)
          elsif physical_role.ends_with?(".discriminators")
            mode = read_mode_header(header, name)
            unless mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
              raise CorruptPartError.new("inline Variant discriminator must use Compact mode: #{name}")
            end
            DynamicDiscriminatorBodyValidator.inspect_body(mode, body, rows, false)
            temporary_bytes = checked_add(temporary_bytes, 8_u64 + body.size.to_u64)
            output_bytes = checked_add(output_bytes, rows)
            expansion_bytes = checked_add(expansion_bytes, rows)
          elsif physical_role.ends_with?(".dictionary")
            validate_dictionary_header!(header, name)
            temporary_bytes = checked_add(temporary_bytes, 8_u64 + body.size.to_u64)
            output_bytes = checked_add(output_bytes, 8_u64 + body.size.to_u64)
          else
            raise UnsupportedFormatError.new("inline Object lane prefix role is outside the admitted profile")
          end
        else
          raise UnsupportedFormatError.new("inline Object lane prefix width is outside the admitted profile")
        end
        offset_elements = checked_add(offset_elements, 2_u64)
        node_count = checked_add(node_count, 2_u64)
      end

      # Callback payload owners, structure owners, and copied map keys are all
      # counted before any normalized stream is allocated.
      structure_bytes = 0_u64
      root_paths.each do |path|
        name = physical_plan.dynamic_structure_stream(path)
        structure = prefix_callbacks[name]? || raise(CorruptPartError.new("inline Object Dynamic structure callback is missing"))
        structure_bytes = checked_add(structure_bytes, structure.size.to_u64)
        role_bytes = checked_add(role_bytes, path.bytesize.to_u64)
      end
      object_structure = prefix_callbacks[object_structure_name]? || raise(CorruptPartError.new("inline Object structure callback is missing"))
      structure_bytes = checked_add(structure_bytes, object_structure.size.to_u64)
      typed_sites.each do |path, sites|
        physical = physical_plan.typed_dynamic(path)
        role_bytes = checked_add(role_bytes, path.bytesize.to_u64)
        sites.each_key do |site_path|
          structure = prefix_callbacks[physical.structure_name_for(site_path)]? || raise(CorruptPartError.new("inline typed Dynamic structure callback is missing"))
          structure_bytes = checked_add(structure_bytes, structure.size.to_u64)
          role_bytes = checked_add(role_bytes, site_path.bytesize.to_u64)
        end
      end
      typed_schema.each_key do |path|
        role_bytes = checked_add(role_bytes, path.bytesize.to_u64)
      end
      root_arm_names.each_value do |names|
        names.each { |name| role_bytes = checked_add(role_bytes, name.bytesize.to_u64) }
      end
      total_bytes = checked_add(checked_add(output_bytes, temporary_bytes), checked_add(structure_bytes, role_bytes))
      node_count = checked_add(node_count, root_paths.size.to_u64 * 4_u64)
      node_count = checked_add(node_count, typed_sites.size.to_u64 * 3_u64)
      node_count = checked_add(node_count, plan.typed_path_count.to_u64 * 2_u64)
      node_count = checked_add(node_count, physical_plan.shared_bucket_count.to_u64 * 2_u64)
      node_count = checked_add(node_count, expansion_bytes == 0_u64 ? 0_u64 : 1_u64)
      elements = checked_add(offset_elements, physical_plan.shared_bucket_count.to_u64)
      elements = checked_add(elements, root_paths.size.to_u64 * 2_u64)
      elements = checked_add(elements, typed_sites.size.to_u64 * 2_u64)
      elements = checked_add(elements, 2_u64)
      required_wire_bytes = checked_add(total_bytes, expansion_bytes)
      {required_wire_bytes, node_count, elements, total_bytes}
    end

    private def self.normalize_lane(
      name : String,
      owner_kind : Symbol,
      owner_path : String,
      role : String,
      body : Bytes,
      prefix_callbacks : Hash(String, Bytes),
      physical_plan : ObjectDocumentPhysicalPlan,
      rows : UInt64,
      budget : BinaryCodecBudget,
      root_arm_names : Hash(String, Array(String)),
    ) : Tuple(Bytes, Array(UInt64), UInt64?)
      physical, physical_role = lane_physical(owner_kind, owner_path, role, physical_plan, root_arm_names)
      prefix_size = physical.prefix_size_for(physical_role)
      if prefix_size == 0
        return {body, [0_u64, body.size.to_u64] of UInt64, nil}
      end
      header = required_prefix(name, prefix_callbacks)
      if owner_kind == :typed_dynamic && role.ends_with?(".discriminators")
        full = join_prefix_and_body(header, body)
        offsets = [8_u64, full.size.to_u64] of UInt64
        normalized = BinaryBulkDiscriminatorFramingAdapter.read_lane(physical_role, full, offsets, 8, budget)
        mode = read_mode_header(header, name)
        return {normalized[0], normalized[1], mode}
      end

      if physical_role.ends_with?(".discriminators")
        mode = read_mode_header(header, name)
        unless mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
          raise CorruptPartError.new("inline Variant discriminator must use Compact mode: #{name}")
        end
        full = join_prefix_and_body(header, body)
        offsets = [8_u64, full.size.to_u64] of UInt64
        normalized = BinaryBulkDiscriminatorFramingAdapter.read_lane(physical_role, full, offsets, 8, budget)
        return {normalized[0], normalized[1], nil}
      elsif physical_role.ends_with?(".dictionary")
        validate_dictionary_header!(header, name)
        full = join_prefix_and_body(header, body)
        # The dictionary lane's version header is part of the byte buffer but
        # outside every dictionary mark coordinate. This is the same
        # prefix-relative grid consumed by BinaryLowCardinalityStorageDecoder.
        return {full, [8_u64, full.size.to_u64] of UInt64, nil}
      end
      raise UnsupportedFormatError.new("inline Object lane prefix role is outside the admitted profile")
    end

    private def self.lane_physical(
      owner_kind : Symbol,
      owner_path : String,
      role : String,
      physical_plan : ObjectDocumentPhysicalPlan,
      root_arm_names : Hash(String, Array(String)),
    ) : Tuple(BinaryBulkPhysicalPlan | BinaryDynamicBulkPhysicalPlan, String)
      case owner_kind
      when :typed
        {physical_plan.typed(owner_path), role}
      when :typed_dynamic
        {physical_plan.typed_dynamic(owner_path), role}
      when :shared
        {physical_plan.shared_bucket(parse_bucket_index(owner_path, physical_plan.shared_bucket_count)), role}
      when :root_dynamic
        path, arm_name, local_role = parse_root_arm_role(owner_path, role, root_arm_names)
        {physical_plan.dynamic_arm(path, arm_name), local_role}
      else
        raise CorruptPartError.new("inline Object lane has an unknown physical owner")
      end
    end

    private def self.parse_root_arm_role(
      path : String,
      role : String,
      root_arm_names : Hash(String, Array(String)),
    ) : Tuple(String, String, String)
      unless role.starts_with?("root.arm.")
        raise CorruptPartError.new("inline root Dynamic arm role is not canonical")
      end
      arm_start = "root.arm.".bytesize
      dot = role.index('.', arm_start)
      index_size = dot ? dot.not_nil! - arm_start : role.bytesize - arm_start
      raw_index = role.byte_slice(arm_start, index_size) || ""
      arm_index = raw_index.to_i?
      names = root_arm_names[path]? || raise(CorruptPartError.new("inline root Dynamic path is not in the parsed structure roster"))
      unless arm_index && arm_index >= 0 && arm_index < names.size && arm_index.to_s == raw_index
        raise CorruptPartError.new("inline root Dynamic arm index is outside its canonical roster")
      end
      if dot
        suffix = role.byte_slice(dot.not_nil!, role.bytesize - dot.not_nil!) || ""
        {path, names[arm_index], "root#{suffix}"}
      else
        {path, names[arm_index], "root"}
      end
    end

    private def self.parse_bucket_index(path : String, bucket_count : Int32) : Int32
      index = path.to_i?
      unless index && index >= 0 && index < bucket_count && index.to_s == path
        raise CorruptPartError.new("inline shared MAP bucket index is outside its physical roster")
      end
      index
    end

    private def self.add_lane!(
      roles : Hash(String, BinaryBulkStream)?,
      role : String,
      lane : BinaryBulkStream,
      owner : String,
    ) : Nil
      group = roles || raise(CorruptPartError.new("inline #{owner} lane owner is missing"))
      if group.has_key?(role)
        raise CorruptPartError.new("inline #{owner} lane role is duplicated")
      end
      group[role] = lane
    end

    private def self.required_prefix(name : String, callbacks : Hash(String, Bytes)) : Bytes
      suffix = if name.ends_with?(".variant_discr")
                 ".variant_discr_prefix"
               elsif name.ends_with?(".dict")
                 ".dict_prefix"
               else
                 raise CorruptPartError.new("inline callback has no known prefix-framing suffix")
               end
      body_suffix = suffix == ".variant_discr_prefix" ? ".variant_discr" : ".dict"
      base = name.byte_slice(0, name.bytesize - body_suffix.bytesize) || ""
      prefix_name = base + suffix
      callbacks[prefix_name]? || raise(CorruptPartError.new("inline physical lane prefix callback is missing"))
    end

    private def self.prefix_fragment_for(name : String, callbacks : Hash(String, Bytes)) : Bytes
      required_prefix(name, callbacks)
    end

    private def self.read_mode_header(header : Bytes, name : String) : UInt64
      unless header.size == 8
        raise CorruptPartError.new("inline Dynamic discriminator prefix has the wrong byte width: #{name}")
      end
      mode = 0_u64
      8.times { |index| mode |= header[index].to_u64 << (index * 8) }
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE || mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("inline Dynamic discriminator has an unsupported mode: #{name}")
      end
      mode
    end

    private def self.validate_variant_header!(header : Bytes, name : String) : Nil
      unless header.size == 8 && header.all?(&.zero?)
        raise CorruptPartError.new("inline Variant discriminator prefix is invalid: #{name}")
      end
      nil
    end

    private def self.validate_dictionary_header!(header : Bytes, name : String) : Nil
      unless header.size == 8 && header[0] == 1_u8 && header[1, 7].all?(&.zero?)
        raise CorruptPartError.new("inline LowCardinality dictionary prefix is invalid: #{name}")
      end
      nil
    end

    private def self.join_prefix_and_body(prefix : Bytes, body : Bytes) : Bytes
      if body.size > Int32::MAX - prefix.size
        raise CorruptPartError.new("inline physical lane exceeds the supported byte domain")
      end
      Bytes.new(prefix.size + body.size) do |index|
        index < prefix.size ? prefix[index] : body[index - prefix.size]
      end
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("inline Object materialization work size overflows UInt64")
      end
      left + right
    end
  end
end
