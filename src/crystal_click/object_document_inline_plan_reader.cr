module CrystalClick
  # Reads one inline Object child from the parent Data callback tape. Its
  # prefix is parsed once, without statistics, then reused by the paired
  # ordinary/advanced body decoders and recursive Dynamic-prefix owners.
  module ObjectDocumentInlinePlanReader
    def self.read_json_leaf_prefix(
      tape : T,
      descriptor : BinaryDataType,
      key : BinaryDynamicJsonLeafKey,
      json_descriptor_depth : Int32,
      physical_prefix : String,
      callback_prefix : String,
      array_level : UInt64,
      nested_context : ObjectSharedNestedSerializationContext,
      budget : BinaryCodecBudget,
      bare_inferred_root_json : Bool = false,
      statistics_context : ObjectDocumentCallbackPrefix::StatisticsContext = ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly,
    ) : ObjectDocumentInlinePrefix forall T
      read_json_site_prefix(
        tape,
        descriptor,
        key,
        json_descriptor_depth,
        physical_prefix,
        callback_prefix,
        array_level,
        nested_context,
        budget,
        statistics_context,
        bare_inferred_root_json,
      ).as(ObjectDocumentInlinePrefix)
    end

    # Shared Object callback-prefix builder. A nil Dynamic key is a real
    # static site identity, never a fabricated Dynamic leaf key. Inline
    # callers preserve their prefix-only structure context; direct Compact
    # callers retain and validate the complete statistics-bearing prefix.
    def self.read_json_site_prefix(
      tape : T,
      descriptor : BinaryDataType,
      key : BinaryDynamicJsonLeafKey?,
      json_descriptor_depth : Int32,
      physical_prefix : String,
      callback_prefix : String,
      array_level : UInt64,
      nested_context : ObjectSharedNestedSerializationContext,
      budget : BinaryCodecBudget,
      statistics_context : ObjectDocumentCallbackPrefix::StatisticsContext,
      bare_inferred_root_json : Bool = false,
      statistics_offset_observer : Proc(String, Int32, Nil)? = nil,
    ) : ObjectDocumentCallbackPrefix | ObjectDocumentInlinePrefix forall T
      unless descriptor.tag == BinaryDataType::TAG_JSON
        raise ArgumentError.new("inline Object prefix reader requires a JSON descriptor")
      end
      if budget.writing? || nested_context.writing?
        raise ArgumentError.new("inline Object prefix reader requires read-direction contexts")
      end
      budget.ensure_depth(json_descriptor_depth)
      unless array_level <= Int32::MAX.to_u64 && array_level <= budget.limits.max_depth.to_u64
        raise UnsupportedFormatError.new("inline Object Array level exceeds the configured coordinate bound")
      end
      begin
        PhysicalStreamName.validate_canonical_escaped_prefix(physical_prefix)
      rescue ex : ArgumentError
        raise CorruptPartError.new("inline Object physical prefix is not canonical: #{ex.message}")
      end

      json_type = descriptor.json_type || raise(CorruptPartError.new("inline JSON descriptor metadata is missing"))
      typed_descriptor_root_depth = checked_depth_add(json_descriptor_depth, 1, budget)

      structure_name = PhysicalStreamName.append_literal(physical_prefix, ".object_structure")
      structure_callback_name = PhysicalStreamName.append_literal(callback_prefix, ".object_structure")
      object, statistics_offset, structure_bytes = if tape.responds_to?(:with_grammar_extent)
                                                     unless statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
                                                       raise UnsupportedFormatError.new("Compact grammar-framed Object prefixes require complete statistics")
                                                     end
                                                     parsed, consumed_structure_bytes = tape.with_grammar_extent(structure_callback_name) do |bytes|
                                                       structure_context = BinaryCodecContext.new(
                                                         budget.limits,
                                                         bytes,
                                                         false,
                                                         budget,
                                                         false,
                                                         false,
                                                       )
                                                       parsed_object, parsed_offset = ObjectStructureCodec.read_with_statistics_offset(
                                                         structure_context,
                                                         typed_descriptor_root_depth,
                                                       )
                                                       { {parsed_object, parsed_offset}, structure_context.input_offset }
                                                     end
                                                     {parsed[0], parsed[1], consumed_structure_bytes}
                                                   else
                                                     tape.with_self_delimited(structure_callback_name) do |bytes|
                                                       structure_context = BinaryCodecContext.new(
                                                         budget.limits,
                                                         bytes,
                                                         false,
                                                         budget,
                                                         false,
                                                         false,
                                                       )
                                                       parsed_object, parsed_offset = if statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly
                                                                                        ObjectStructureCodec.read_prefix_without_statistics(
                                                                                          structure_context,
                                                                                          typed_descriptor_root_depth,
                                                                                        )
                                                                                      else
                                                                                        ObjectStructureCodec.read_with_statistics_offset(
                                                                                          structure_context,
                                                                                          typed_descriptor_root_depth,
                                                                                        )
                                                                                      end
                                                       structure_context.ensure_consumed
                                                       { {parsed_object, parsed_offset, bytes}, structure_context.input_offset }
                                                     end
                                                   end
      unless statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete || statistics_offset == structure_bytes.size
        raise CorruptPartError.new("inline Object structure prefix does not end at its statistics offset")
      end
      unless object.dynamic_path_count <= json_type.max_dynamic_paths
        raise CorruptPartError.new("inline Object dynamic path count exceeds its JSON descriptor cap")
      end
      effective_nested_context = if key.nil? && statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
                                   ObjectSharedNestedSerializationContext.for_read(
                                     object.shared_data_version,
                                     nested_context.profile,
                                   )
                                 else
                                   unless object.shared_data_version == nested_context.shared_data_version
                                     raise CorruptPartError.new("inline Object shared-data version differs from its inherited context")
                                   end
                                   nested_context
                                 end
      inferred_actual_root_depth = if bare_inferred_root_json
                                     checked_depth_add(json_descriptor_depth, 1, budget)
                                   else
                                     checked_depth_add(
                                       json_descriptor_depth,
                                       object.dynamic_path_count == 0 ? 1 : 2,
                                       budget,
                                     )
                                   end
      root_dynamic_descriptor_depth = checked_depth_subtract(inferred_actual_root_depth, 1, budget)
      ensure_object_paths_sorted!(object)

      object_paths = snapshot_object_paths(object, budget)
      typed_path_entries, typed_paths = snapshot_typed_paths(json_type, typed_descriptor_root_depth, budget)

      prefix_callbacks = [] of Tuple(String, Bytes)
      retain_prefix_callback!(prefix_callbacks, structure_name, structure_bytes, budget)
      typed_dynamic_sites = Hash(String, Hash(String, DynamicStructure)).new
      root_dynamic_sites = Hash(String, Hash(String, DynamicStructure)).new
      root_dynamic_json_prefixes = Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap).new

      typed_path_entries.each do |field, type|
        physical_field_prefix = PhysicalStreamName.append_escaped_component(physical_prefix, field)
        callback_field_prefix = PhysicalStreamName.append_escaped_component(callback_prefix, field)
        if type.contains_dynamic?
          local_sites = Hash(String, DynamicStructure).new
          observer = ->(site_path : String, _raw : Bytes, site : DynamicStructure) do
            retain_site!(local_sites, site_path, site, budget)
          end
          capture = ->(name : String, bytes : Bytes) do
            retain_prefix_callback!(prefix_callbacks, name, bytes, budget)
            nil
          end
          ObjectSharedPathCodec.decode_prefix_type_with_observer(
            type,
            "root",
            physical_field_prefix,
            callback_field_prefix,
            array_level,
            typed_descriptor_root_depth,
            tape,
            budget,
            observer,
            true,
            capture,
            false,
            statistics_context: statistics_context,
            statistics_offset_observer: statistics_offset_observer,
          )
          reject_json_actuals!(local_sites)
          typed_dynamic_sites[field] = local_sites
        else
          no_dynamic_observer = ->(_site_path : String, _raw : Bytes, _site : DynamicStructure) { nil }
          capture = ->(name : String, bytes : Bytes) do
            retain_prefix_callback!(prefix_callbacks, name, bytes, budget)
            nil
          end
          ObjectSharedPathCodec.decode_prefix_type_with_observer(
            type,
            "root",
            physical_field_prefix,
            callback_field_prefix,
            array_level,
            typed_descriptor_root_depth,
            tape,
            budget,
            no_dynamic_observer,
            true,
            capture,
            false,
            statistics_context: statistics_context,
            statistics_offset_observer: statistics_offset_observer,
          )
        end
      end

      object_paths.each do |path|
        maximum_types = json_type.max_dynamic_types
        dynamic_type = BinaryDataType.dynamic(maximum_types)
        physical_dynamic_prefix = PhysicalStreamName.append_escaped_component(physical_prefix, path)
        callback_dynamic_prefix = PhysicalStreamName.append_escaped_component(callback_prefix, path)
        local_sites = Hash(String, DynamicStructure).new
        observer = ->(site_path : String, _raw : Bytes, site : DynamicStructure) do
          retain_site!(local_sites, site_path, site, budget)
        end
        nested_json_prefixes = ObjectSharedPathJsonTapeCodec::PrefixMap.new
        capture = ->(name : String, bytes : Bytes) do
          retain_prefix_callback!(prefix_callbacks, name, bytes, budget)
          nil
        end
        ObjectSharedPathCodec.decode_prefix_type_with_observer(
          dynamic_type,
          "root",
          physical_dynamic_prefix,
          callback_dynamic_prefix,
          array_level,
          root_dynamic_descriptor_depth,
          tape,
          budget,
          observer,
          false,
          capture,
          false,
          nil,
          effective_nested_context,
          nested_json_prefixes,
          virtual_root_dynamic: true,
          statistics_context: statistics_context,
          statistics_offset_observer: statistics_offset_observer,
        )
        root_dynamic_sites[path] = local_sites
        root_dynamic_json_prefixes[path] = nested_json_prefixes
      end

      root_structures = Hash(String, DynamicStructure).new(initial_capacity: object.dynamic_path_count)
      root_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new(initial_capacity: object.dynamic_path_count)
      object_paths.each do |path|
        local_sites = root_dynamic_sites[path]? || raise(CorruptPartError.new("inline Object Dynamic prefix map is missing a declared path"))
        root_structure = local_sites["root"]? || raise(CorruptPartError.new("inline Object Dynamic prefix is missing its root site"))
        root_structures[path] = root_structure
        dynamic_type = BinaryDataType.dynamic(json_type.max_dynamic_types)
        nested_json_bindings = json_leaf_bindings(root_dynamic_json_prefixes[path], budget)
        root_dynamic_plans[path] = decode_dynamic_plan(
          dynamic_type,
          local_sites,
          effective_nested_context.profile,
          root_dynamic_descriptor_depth,
          budget,
          nested_json_bindings,
        )
      end
      preflight_plan_copy_work(typed_paths, typed_dynamic_sites, root_structures, budget)
      structure_set = begin
        ObjectDynamicStructureSet.new(object, root_structures)
      rescue ex : ArgumentError
        raise CorruptPartError.new("inline Object Dynamic structure set is invalid: #{ex.message}")
      end

      typed_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new(initial_capacity: typed_dynamic_sites.size)
      typed_dynamic_sites.each do |path, sites|
        type = json_type.typed_type_for(path) || raise(CorruptPartError.new("inline typed Dynamic descriptor is missing"))
        typed_dynamic_plans[path] = begin
          ObjectDeclaredDynamicDeclaration.prepare_read_sites_plan_from_structures(
            type,
            sites,
            budget,
            effective_nested_context.profile,
            typed_descriptor_root_depth,
          )
        rescue ex : UnsupportedFormatError
          raise CorruptPartError.new("inline typed Dynamic prefix is invalid: #{ex.message}")
        end
      end

      root_dynamic_json_leaf_plans = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new(
        initial_capacity: root_dynamic_json_prefixes.size,
      )
      root_dynamic_json_prefixes.each do |path, prefixes|
        bindings = json_leaf_bindings(prefixes, budget)
        root_dynamic_json_leaf_plans[path] = bindings unless bindings.empty?
      end

      plan = begin
        ObjectDocumentPlan.new(
          structure_set,
          typed_paths,
          Hash(String, DynamicStructure).new,
          typed_dynamic_sites,
          Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
          root_dynamic_json_leaf_plans,
          budget,
          inferred_actual_root_depth,
        )
      rescue ex : ArgumentError
        raise CorruptPartError.new("inline Object child plan is invalid: #{ex.message}")
      end

      if dynamic_key = key
        ObjectDocumentInlinePrefix.new(
          dynamic_key,
          descriptor,
          json_descriptor_depth,
          typed_descriptor_root_depth,
          inferred_actual_root_depth,
          physical_prefix,
          callback_prefix,
          array_level,
          effective_nested_context,
          statistics_offset,
          plan,
          structure_set,
          prefix_callbacks,
          typed_dynamic_sites,
          root_dynamic_sites,
          typed_dynamic_plans,
          root_dynamic_plans,
          root_dynamic_json_prefixes,
          statistics_context,
        )
      else
        ObjectDocumentCallbackPrefix.new(
          descriptor,
          json_descriptor_depth,
          typed_descriptor_root_depth,
          inferred_actual_root_depth,
          physical_prefix,
          callback_prefix,
          array_level,
          effective_nested_context,
          statistics_offset,
          statistics_context,
          plan,
          structure_set,
          prefix_callbacks,
          typed_dynamic_sites,
          root_dynamic_sites,
          typed_dynamic_plans,
          root_dynamic_plans,
          root_dynamic_json_prefixes,
        )
      end
    end

    private def self.decode_dynamic_plan(
      type : BinaryDataType,
      sites : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile,
      depth : Int32,
      budget : BinaryCodecBudget,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
    ) : BinaryDynamicBulkPlan
      BinaryDynamicBulkPlan.decode_structure_prefixes_without_statistics_from_structures(
        type,
        sites,
        budget,
        profile,
        depth,
        json_object_leaf_plans,
      )
    rescue ex : UnsupportedFormatError
      raise CorruptPartError.new("inline Object Dynamic prefix plan is invalid: #{ex.message}")
    end

    private def self.json_leaf_bindings(
      prefixes : ObjectSharedPathJsonTapeCodec::PrefixMap,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))
      count = prefixes.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(count)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      bindings = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(prefixes.size)
      prefixes.each do |key, prefix|
        unless prefix.key == key
          raise CorruptPartError.new("inline nested JSON prefix key differs from its local owner map")
        end
        bindings << {key, prefix.plan}
      end
      bindings
    end

    private def self.checked_depth_add(depth : Int32, increment : Int32, budget : BinaryCodecBudget) : Int32
      depth64 = depth.to_i64 + increment.to_i64
      unless depth64 > 0 && depth64 <= Int32::MAX.to_i64 && depth64 <= budget.limits.max_depth.to_i64
        raise CorruptPartError.new("inline child Object descriptor depth exceeds the configured limit")
      end
      depth64.to_i32
    end

    private def self.checked_depth_subtract(depth : Int32, decrement : Int32, budget : BinaryCodecBudget) : Int32
      depth64 = depth.to_i64 - decrement.to_i64
      unless depth64 > 0 && depth64 <= Int32::MAX.to_i64 && depth64 <= budget.limits.max_depth.to_i64
        raise CorruptPartError.new("inline child Object descriptor depth underflows the configured bound")
      end
      depth64.to_i32
    end

    private def self.ensure_object_paths_sorted!(object : ObjectStructure) : Nil
      index = 1
      while index < object.dynamic_path_count
        if compare_object_paths(object, index - 1, index) >= 0
          raise CorruptPartError.new("inline Object dynamic paths are not in canonical byte order")
        end
        index += 1
      end
      nil
    end

    private def self.compare_object_paths(object : ObjectStructure, left : Int, right : Int) : Int32
      common_size = Math.min(object.dynamic_path_byte_size(left), object.dynamic_path_byte_size(right))
      common_size.times do |byte_index|
        comparison = object.dynamic_path_byte_at(left, byte_index) <=> object.dynamic_path_byte_at(right, byte_index)
        return comparison unless comparison == 0
      end
      object.dynamic_path_byte_size(left) <=> object.dynamic_path_byte_size(right)
    end

    private def self.snapshot_object_paths(
      object : ObjectStructure,
      budget : BinaryCodecBudget,
    ) : Array(String)
      count = object.dynamic_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      total_bytes = 0_u64
      object.dynamic_path_count.times do |index|
        total_bytes = checked_add(total_bytes, object.dynamic_path_byte_size(index).to_u64)
      end
      budget.charge_wire_bytes(total_bytes) if total_bytes > 0_u64
      count.times { budget.charge_node }
      paths = Array(String).new(count.to_i)
      object.dynamic_path_count.times do |index|
        size = object.dynamic_path_byte_size(index)
        paths << String.build(size) do |io|
          size.times { |byte_index| io.write_byte(object.dynamic_path_byte_at(index, byte_index)) }
        end
      end
      paths
    end

    private def self.snapshot_typed_paths(
      descriptor : BinaryJsonType,
      typed_descriptor_root_depth : Int32,
      budget : BinaryCodecBudget,
    ) : Tuple(Array(Tuple(String, BinaryDataType)), Hash(String, BinaryDataType))
      count = descriptor.typed_path_count.to_u64
      if count > 0_u64
        budget.preflight_children(count)
      end
      total_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        total_bytes = checked_add(total_bytes, descriptor.typed_path_byte_size(index).to_u64)
      end
      budget.charge_wire_bytes(total_bytes) if total_bytes > 0_u64
      count.times { budget.charge_node }
      entries = Array(Tuple(String, BinaryDataType)).new(descriptor.typed_path_count)
      typed_paths = Hash(String, BinaryDataType).new(initial_capacity: descriptor.typed_path_count)
      descriptor.typed_path_count.times do |index|
        path_size = descriptor.typed_path_byte_size(index)
        path = String.build(path_size) do |io|
          path_size.times { |byte_index| io.write_byte(descriptor.typed_path_byte_at(index, byte_index)) }
        end
        type = descriptor.typed_type_at(index)
        schema_context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
        schema_context.validate_type_tree(type, typed_descriptor_root_depth)
        if type.contains_json?
          raise UnsupportedFormatError.new("nested JSON typed fields are outside the inline child-plan frontier")
        end
        if type.contains_qbit?
          raise UnsupportedFormatError.new("typed QBit fields are outside the inline child-plan frontier")
        end
        entries << {path, type}
        typed_paths[path] = type
      end
      {entries, typed_paths}
    end

    private def self.retain_site!(
      sites : Hash(String, DynamicStructure),
      path : String,
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
    ) : Nil
      if sites.has_key?(path)
        raise CorruptPartError.new("inline Object Dynamic prefix site is duplicated")
      end
      budget.preflight_children(1_u64)
      budget.charge_node
      budget.charge_wire_bytes(path.bytesize.to_u64)
      sites[String.new(path.to_slice)] = structure
      nil
    end

    private def self.retain_prefix_callback!(
      callbacks : Array(Tuple(String, Bytes)),
      name : String,
      bytes : Bytes,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.preflight_children(1_u64)
      budget.charge_node
      callbacks << {name, bytes}
      nil
    end

    private def self.preflight_plan_copy_work(
      typed_paths : Hash(String, BinaryDataType),
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      root_structures : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
    ) : Nil
      copy_count = 0_u64
      copy_bytes = 0_u64

      typed_paths.each_key do |path|
        copy_count = checked_add(copy_count, 1_u64)
        copy_bytes = checked_add(copy_bytes, path.bytesize.to_u64)
      end

      typed_dynamic_sites.each do |field, sites|
        copy_count = checked_add(copy_count, 1_u64)
        copy_bytes = checked_add(copy_bytes, field.bytesize.to_u64)
        sites.each_key do |site_path|
          copy_count = checked_add(copy_count, 1_u64)
          copy_bytes = checked_add(copy_bytes, site_path.bytesize.to_u64)
        end
      end

      root_structures.each_key do |path|
        copy_count = checked_add(copy_count, 1_u64)
        copy_bytes = checked_add(copy_bytes, path.bytesize.to_u64)
      end

      if copy_count > 0_u64
        budget.preflight_children(copy_count)
        budget.charge_wire_bytes(copy_bytes)
        copy_count.times { budget.charge_node }
      end
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("inline Object metadata work size overflows UInt64")
      end
      left + right
    end

    private def self.reject_json_actuals!(sites : Hash(String, DynamicStructure)) : Nil
      sites.each_value do |structure|
        structure.type_count.times do |index|
          if structure.type_at(index).contains_json?
            raise UnsupportedFormatError.new("nested JSON actuals are outside the inline child-plan frontier")
          end
        end
      end
      nil
    end
  end
end
