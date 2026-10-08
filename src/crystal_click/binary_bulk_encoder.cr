module CrystalClick
  # Recursive writer for the normalized per-mark physical-lane profile.
  module BinaryBulkEncoder
    def self.encode(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
      low_cardinality_policy : BinaryLowCardinalityStoragePolicy = BinaryLowCardinalityStoragePolicy::PartGlobalDictionary,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter? = nil,
      shared_value_depth_origin : Int = 1,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
    ) : BinaryBulkStreams
      unless budget.writing?
        raise ArgumentError.new("binary bulk encoder requires a write-direction budget")
      end
      # Generic bulk visits are root-relative (root=1). The shared scalar
      # helper adds this origin to that relative Dynamic depth; Object typed
      # fields pass their absolute descriptor root depth (2).
      budget.ensure_depth(shared_value_depth_origin)
      if dynamic_plan.try(&.has_json_object_bindings?) && json_object_writer.nil?
        raise UnsupportedFormatError.new("bound Dynamic JSON arms require the paired Object child owner")
      end
      root_json_bound = false
      if writer = json_object_writer
        if plan = dynamic_plan
          unless json_leaf_key.nil? && writer.matches_operation?(plan, budget)
            raise ArgumentError.new("Dynamic JSON Object writer does not match the bulk plan")
          end
        elsif key = json_leaf_key
          unless writer.matches_root_operation?(type, key, budget, shared_value_depth_origin)
            raise ArgumentError.new("inferred Dynamic JSON Object writer does not match the root leaf")
          end
          root_json_bound = true
        else
          raise ArgumentError.new("root Dynamic JSON Object writer requires an exact seed leaf key")
        end
      elsif json_leaf_key
        raise ArgumentError.new("binary bulk JSON seed key has no paired Object writer")
      end
      if granules.size == Int32::MAX
        raise UnsupportedFormatError.new("binary bulk mark grid exceeds the supported domain")
      end

      traversal = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      traversal.validate_type_tree(type)
      plan = BinaryBulkTypePlan.new(type, profile, dynamic_plan, budget.limits, true, root_json_bound)
      planned_role_count = plan.role_count
      ordinary_role_count = plan.ordinary_role_count

      # Every per-role offset record, plus each explicit mark row count, is
      # count-derived metadata. Preflight and charge it before allocating lane
      # buffers or the K+1 offset grids.
      mark_records = granules.size.to_u64
      offsets_per_role = checked_add(mark_records, 1_u64)
      grid_records = checked_multiply(ordinary_role_count, offsets_per_role)
      root_mark_records = type.tag == BinaryDataType::TAG_LOW_CARDINALITY ? 0_u64 : mark_records
      metadata_records = checked_add(grid_records, root_mark_records)
      budget.ensure_future_nodes(metadata_records)
      budget.ensure_future_elements(metadata_records)
      budget.charge_elements(metadata_records)
      metadata_records.times { budget.charge_node }

      qbit_column = plan.qbit_column
      all_roles = plan.roles
      unless all_roles.size.to_u64 == planned_role_count
        raise UnsupportedFormatError.new("binary bulk role plan changed while it was materialized")
      end
      # Root QBit and Nullable(QBit) have no non-ordinary stop-site roles, so
      # reuse the detached public roster rather than retain another copy.
      roles = qbit_column ? all_roles : plan.ordinary_roles
      qbit_roles = plan.qbit_plane_roles
      qbit_role_offset = 0
      qbit_scratch = nil.as(Bytes?)

      # Preflight the ordinary visitor's node/edge/wire costs before its lane
      # buffers and hidden-NULL defaults. LC subtrees are excluded here; their
      # site owner preflights staging/default payloads and W142 costs later.
      total = zero_cost
      default_costs = Hash(Tuple(UInt64, Bool), BinaryBulkDefaultValue::Cost).new
      granules.each_with_index do |rows, mark_index|
        rows.each do |value|
          minimum = minimum_value_cost(type, value, profile, default_costs, dynamic_plan, root_json_bound)
          ensure_cost_fits(budget, add_cost(total, minimum))
          total = add_cost(total, value_cost(type, value, "root", profile, budget, total, default_costs, dynamic_plan, 1, mark_index, json_object_writer, json_leaf_key))
        end
      end
      budget.ensure_future_nodes(total[:nodes])
      budget.ensure_future_elements(total[:edges])
      budget.ensure_wire_bytes(total[:wire_bytes])
      qbit_site_scratch = if total[:wire_bytes] > 0_u64
                            prepare_dynamic_qbit_scratch(dynamic_plan, budget)
                          else
                            nil
                          end

      # A single plane-width scratch buffer is an output allocation. Do not
      # create it until all selected values have passed the wire-cost preflight;
      # an empty input needs no QBit scratch at all.
      if total[:wire_bytes] > 0_u64
        if column = qbit_column
          qbit_scratch = Bytes.new(column.value_type.plane_width, 0_u8)
        end
      end

      lanes = Hash(String, Array(UInt8)).new
      offsets = Hash(String, Array(UInt64)).new
      roles.each do |role|
        lanes[role] = [] of UInt8
        offsets[role] = [0_u64]
      end

      granules.each_with_index do |rows, mark_index|
        rows.each do |value|
          write_value(type, value, "root", 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key, shared_value_depth_origin)
        end
        roles.each do |role|
          offsets[role] << lanes[role].size.to_u64
        end
      end

      streams = Hash(String, BinaryBulkStream).new
      roles.each do |role|
        lane = lanes[role]
        bytes = Bytes.new(lane.size) { |index| lane[index] }
        streams[role] = BinaryBulkStream.new(bytes, offsets[role])
      end

      low_cardinality_sites = plan.low_cardinality_sites
      low_cardinality_streams = BinaryBulkLowCardinalitySiteEncoder.encode(
        type,
        low_cardinality_sites,
        granules,
        budget,
        dynamic_plan,
        low_cardinality_policy,
      )
      low_cardinality_streams.each do |role, stream|
        streams[role] = stream
      end
      json_object_writer.try(&.ensure_consumed!)
      BinaryBulkStreams.new(granules.size, streams)
    end

    private def self.zero_cost : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      {nodes: 0_u64, edges: 0_u64, wire_bytes: 0_u64}
    end

    private def self.prepare_dynamic_qbit_scratch(
      dynamic_plan : BinaryDynamicBulkPlan?,
      budget : BinaryCodecBudget,
    ) : Hash(QBitType, Bytes)?
      return nil unless dynamic_plan

      widths = Hash(QBitType, Int32).new
      dynamic_plan.each_qbit_site do |site|
        widths[site.qbit_type] = site.plane_width
      end
      return nil if widths.empty?

      total_bytes = 0_u64
      widths.each do |_type, width|
        total_bytes = checked_add(total_bytes, width.to_u64)
      end
      if total_bytes > budget.limits.max_bytes.to_u64
        raise UnsupportedFormatError.new("Dynamic QBit scratch exceeds configured byte limit")
      end

      scratch = Hash(QBitType, Bytes).new
      widths.each do |qbit_type, width|
        scratch[qbit_type] = Bytes.new(width, 0_u8)
      end
      scratch
    end

    private def self.add_cost(
      left : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
      right : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      {
        nodes:      checked_add(left[:nodes], right[:nodes]),
        edges:      checked_add(left[:edges], right[:edges]),
        wire_bytes: checked_add(left[:wire_bytes], right[:wire_bytes]),
      }
    end

    private def self.minimum_value_cost(
      type : BinaryDataType,
      value : BinaryValue,
      profile : BinaryBulkProfile,
      default_costs : Hash(Tuple(UInt64, Bool), BinaryBulkDefaultValue::Cost),
      dynamic_plan : BinaryDynamicBulkPlan?,
      allow_bound_json : Bool = false,
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end
      nodes = 1_u64
      edges = 0_u64
      wire_bytes = 0_u64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        return zero_cost
      when BinaryDataType::TAG_JSON
        return zero_cost
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_type = type.child_at(0)
        child_value = value.child_at(0)
        child = minimum_value_cost(child_type, child_value, profile, default_costs, dynamic_plan, allow_bound_json)
        nodes = checked_add(nodes, child[:nodes])
        edges = checked_add(1_u64, child[:edges])
        wire_bytes = child[:wire_bytes]
      when BinaryDataType::TAG_VARIANT
        wire_bytes = 1_u64
        if index = value.variant_index?
          child_type = type.child_at(index.to_i)
          child_value = value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant value is missing its selected arm")
          child = minimum_value_cost(child_type, child_value, profile, default_costs, dynamic_plan, allow_bound_json)
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(1_u64, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        wire_bytes = profile.with_size_stream? ? checked_add(8_u64, size) : checked_add(var_uint_size(size), size)
      when BinaryDataType::TAG_DYNAMIC
        # Shared typed-envelope work is charged by the rebased scalar visitor
        # during the write pass; this is the common node/discriminator floor.
        wire_bytes = 1_u64
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || raise UnsupportedFormatError.new("QBit bulk descriptor is missing its nominal type")
        unless value.qbit_value.type == qbit_type
          raise UnsupportedFormatError.new("QBit bulk value does not match its nominal descriptor")
        end
        wire_bytes = checked_multiply(qbit_type.plane_count.to_u64, qbit_type.plane_width.to_u64)
      when BinaryDataType::TAG_BOOL, BinaryDataType::TAG_NOTHING
        wire_bytes = 1_u64
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          wire_bytes = BinaryAggregateCountStateCodec.encoded_size(value.count_state)
        else
          wire_bytes = value.aggregate_function_state_bytes.size.to_u64
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        count = value.element_count.to_u64
        child = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type.child_at(0), profile, default_costs, dynamic_plan, allow_bound_json)
        nodes = checked_add(nodes, checked_multiply(count, child.nodes))
        edges = checked_add(count, checked_multiply(count, child.edges))
        wire_bytes = checked_add(8_u64, checked_multiply(count, child.wire_bytes))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        unless value.element_count == count
          raise UnsupportedFormatError.new("Tuple bulk value does not match its descriptor")
        end
        if count == 0
          wire_bytes = 1_u64
        else
          edges = count.to_u64
          count.times do |index|
            child = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type.child_at(index), profile, default_costs, dynamic_plan, allow_bound_json)
            nodes = checked_add(nodes, child.nodes)
            edges = checked_add(edges, child.edges)
            wire_bytes = checked_add(wire_bytes, child.wire_bytes)
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count.to_u64
        unless flat_count.even?
          raise UnsupportedFormatError.new("Map bulk value has an incomplete key/value pair")
        end
        nodes = 1_u64
        edges = flat_count
        wire_bytes = 8_u64
        pairs = flat_count // 2_u64
        key = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type.child_at(0), profile, default_costs, dynamic_plan, allow_bound_json)
        item = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type.child_at(1), profile, default_costs, dynamic_plan, allow_bound_json)
        nodes = checked_add(nodes, checked_multiply(pairs, checked_add(key.nodes, item.nodes)))
        edges = checked_add(edges, checked_multiply(pairs, checked_add(key.edges, item.edges)))
        wire_bytes = checked_add(wire_bytes, checked_multiply(pairs, checked_add(key.wire_bytes, item.wire_bytes)))
      when BinaryDataType::TAG_NULLABLE
        child = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type.child_at(0), profile, default_costs, dynamic_plan, allow_bound_json)
        nodes = checked_add(nodes, child.nodes)
        edges = checked_add(1_u64, child.edges)
        wire_bytes = checked_add(1_u64, child.wire_bytes)
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        wire_bytes = width.to_u64
      end
      {nodes: nodes, edges: edges, wire_bytes: wire_bytes}
    end

    private def self.ensure_cost_fits(
      budget : BinaryCodecBudget,
      cost : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
    ) : Nil
      budget.ensure_future_nodes(cost[:nodes])
      budget.ensure_future_elements(cost[:edges])
      budget.ensure_wire_bytes(cost[:wire_bytes])
    end

    private def self.value_cost(
      type : BinaryDataType,
      value : BinaryValue,
      path : String,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      base : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64),
      default_costs : Hash(Tuple(UInt64, Bool), BinaryBulkDefaultValue::Cost),
      dynamic_plan : BinaryDynamicBulkPlan?,
      depth : Int,
      mark_index : Int,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter?,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
    ) : NamedTuple(nodes: UInt64, edges: UInt64, wire_bytes: UInt64)
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end

      allow_bound_json = !json_leaf_key.nil? && !json_object_writer.nil?
      minimum = minimum_value_cost(type, value, profile, default_costs, dynamic_plan, allow_bound_json)
      ensure_cost_fits(budget, add_cost(base, minimum))
      return zero_cost if type.tag == BinaryDataType::TAG_LOW_CARDINALITY

      nodes = 1_u64
      edges = 0_u64
      wire_bytes = 0_u64
      case type.tag
      when BinaryDataType::TAG_VARIANT
        wire_bytes = 1_u64
        if index = value.variant_index?
          child_type = type.child_at(index.to_i)
          child_value = value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant value is missing its selected arm")
          edges = 1_u64
          child = value_cost(
            child_type,
            child_value,
            child_path(path, ".arm.", index.to_i, budget, dynamic_plan),
            profile,
            budget,
            add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}),
            default_costs,
            dynamic_plan,
            depth + 1,
            mark_index,
            json_object_writer,
            json_leaf_key.try { |key| key.with_child(index.to_i) },
          )
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_DYNAMIC
        wire_bytes = 1_u64
        unless value.is_null?
          child_value = value.child_at(0)
          plan = dynamic_plan || raise UnsupportedFormatError.new("Dynamic bulk value has no structure plan")
          selection = plan.select_arm(path, child_value.type)
          if selection.shared
            # The exact typed envelope is emitted and charged by the rebased
            # scalar visitor in write_value; this pass preserves the common
            # Dynamic node/discriminator lower bound without double-visiting.
          else
            child_type = plan.arm_type(path, selection.index)
            leaf_key = if child_type.contains_json?
                         BinaryDynamicJsonLeafKey.new(path, selection.index, [] of Int32)
                       else
                         nil
                       end
            edges = 1_u64
            child = value_cost(
              child_type,
              child_value,
              child_path(path, ".arm.", selection.index.to_i, budget, dynamic_plan),
              profile,
              budget,
              add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}),
              default_costs,
              dynamic_plan,
              depth + 1,
              mark_index,
              json_object_writer,
              leaf_key,
            )
            nodes = checked_add(nodes, child[:nodes])
            edges = checked_add(edges, child[:edges])
            wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
          end
        end
      when BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        wire_bytes = profile.with_size_stream? ? checked_add(8_u64, size) : checked_add(var_uint_size(size), size)
      when BinaryDataType::TAG_JSON
        writer = json_object_writer || raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no paired Object writer"))
        key = json_leaf_key || raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no exact binding key"))
        writer.collect(key, value.json_row, mark_index, depth)
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || raise UnsupportedFormatError.new("QBit bulk descriptor is missing its nominal type")
        unless value.qbit_value.type == qbit_type
          raise UnsupportedFormatError.new("QBit bulk value does not match its nominal descriptor")
        end
        wire_bytes = checked_multiply(qbit_type.plane_count.to_u64, qbit_type.plane_width.to_u64)
      when BinaryDataType::TAG_BOOL
        wire_bytes = 1_u64
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          wire_bytes = BinaryAggregateCountStateCodec.encoded_size(value.count_state)
        else
          wire_bytes = value.aggregate_function_state_bytes.size.to_u64
        end
      when BinaryDataType::TAG_NOTHING
        unless value.is_null?
          raise UnsupportedFormatError.new("Nothing bulk values must use the NULL sentinel")
        end
        wire_bytes = 1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        wire_bytes = 8_u64
        count = value.element_count
        edges = count.to_u64
        count.times do |index|
          child = value_cost(type.child_at(0), value.element_at(index), child_path(path, ".elements", nil, budget, dynamic_plan), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs, dynamic_plan, depth + 1, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(0) })
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = value.element_count
        if count == 0
          wire_bytes = 1_u64
        else
          edges = count.to_u64
          count.times do |index|
            child = value_cost(type.child_at(index), value.element_at(index), child_path(path, ".field.", index, budget, dynamic_plan), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs, dynamic_plan, depth + 1, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(index) })
            nodes = checked_add(nodes, child[:nodes])
            edges = checked_add(edges, child[:edges])
            wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        wire_bytes = 8_u64
        edges = flat_count.to_u64
        flat_count.times do |index|
          child_type = type.child_at(index.even? ? 0 : 1)
          child = value_cost(child_type, value.element_at(index), child_path(path, ".elements.field.", index.even? ? 0 : 1, budget, dynamic_plan), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs, dynamic_plan, depth + 1, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(index.even? ? 0 : 1) })
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_NULLABLE
        wire_bytes = 1_u64
        edges = 1_u64
        child_type = type.child_at(0)
        if value.is_null?
          default = BinaryBulkDefaultValue.measure_excluding_low_cardinality(child_type, profile, default_costs, dynamic_plan, allow_bound_json)
          nodes = checked_add(nodes, default.nodes)
          edges = checked_add(edges, default.edges)
          wire_bytes = checked_add(wire_bytes, default.wire_bytes)
          collect_default_json_rows(
            child_type,
            json_leaf_key.try { |key| key.with_child(0) },
            json_object_writer,
            mark_index,
            depth + 1,
            profile,
          )
        else
          child = value_cost(child_type, value.child_at(0), child_path(path, ".nested", nil, budget, dynamic_plan), profile, budget, add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}), default_costs, dynamic_plan, depth + 1, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(0) })
          nodes = checked_add(nodes, child[:nodes])
          edges = checked_add(edges, child[:edges])
          wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
        end
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_type = type.child_at(0)
        edges = 1_u64
        child = value_cost(
          child_type,
          value.child_at(0),
          path,
          profile,
          budget,
          add_cost(base, {nodes: nodes, edges: edges, wire_bytes: wire_bytes}),
          default_costs,
          dynamic_plan,
          depth + 1,
          mark_index,
          json_object_writer,
          json_leaf_key.try { |key| key.with_child(0) },
        )
        nodes = checked_add(nodes, child[:nodes])
        edges = checked_add(edges, child[:edges])
        wire_bytes = checked_add(wire_bytes, child[:wire_bytes])
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        wire_bytes = width.to_u64
      end
      cost = {nodes: nodes, edges: edges, wire_bytes: wire_bytes}
      ensure_cost_fits(budget, add_cost(base, cost))
      cost
    end

    # A NULL Nullable still serializes the nested descriptor's default. Only
    # default shapes with children can produce JSON Object rows: tuples retain
    # every field, while arrays/maps/variants/dynamic defaults are empty/null.
    private def self.collect_default_json_rows(
      type : BinaryDataType,
      json_leaf_key : BinaryDynamicJsonLeafKey?,
      writer : BinaryDynamicBulkJsonObjectWriter?,
      mark_index : Int,
      depth : Int,
      profile : BinaryBulkProfile,
    ) : Nil
      return nil unless type.contains_json?
      key = json_leaf_key || raise(UnsupportedFormatError.new("Nullable JSON default has no exact binding key"))
      case type.tag
      when BinaryDataType::TAG_JSON
        owner = writer || raise(UnsupportedFormatError.new("Nullable JSON default has no paired Object writer"))
        owner.collect_default(key, mark_index, depth, profile)
      when BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_SIMPLE_AGGREGATE
        collect_default_json_rows(type.child_at(0), key.with_child(0), writer, mark_index, depth + 1, profile)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          collect_default_json_rows(type.child_at(index), key.with_child(index), writer, mark_index, depth + 1, profile)
        end
      else
        # These defaults serialize no selected child: Array/Map are empty,
        # Variant is NULL, Dynamic is NULL, and LowCardinality is delegated.
        nil
      end
      nil
    end

    private def self.write_value(
      type : BinaryDataType,
      value : BinaryValue,
      path : String,
      depth : Int,
      traversal : BinaryCodecContext,
      budget : BinaryCodecBudget,
      lanes : Hash(String, Array(UInt8)),
      profile : BinaryBulkProfile,
      dynamic_plan : BinaryDynamicBulkPlan?,
      qbit_roles : Array(String)? = nil,
      qbit_role_offset : Int32 = 0,
      qbit_scratch : Bytes? = nil,
      qbit_site_scratch : Hash(QBitType, Bytes)? = nil,
      mark_index : Int = 0,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
      shared_value_depth_origin : Int = 1,
    ) : Nil
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end
      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        traversal.ensure_depth(depth)
        return nil
      end
      traversal.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_QBIT
        if plan = dynamic_plan
          if site = plan.qbit_site_for(path)
            scratch_by_type = qbit_site_scratch || raise UnsupportedFormatError.new("Dynamic QBit plane scratch was not preflighted")
            scratch = scratch_by_type[site.qbit_type]? || raise UnsupportedFormatError.new("Dynamic QBit plane scratch is missing its nominal type")
            site.append_plane_row(value.qbit_value, scratch) do |role, byte|
              write_byte(lanes, role, byte, budget)
            end
            return nil
          end
        end
        roles = qbit_roles || raise UnsupportedFormatError.new("QBit bulk plane roles were not planned")
        scratch = qbit_scratch || raise UnsupportedFormatError.new("QBit bulk plane scratch was not preflighted")
        BinaryQBitBulkCodec.append_plane_row(value.qbit_value, roles, qbit_role_offset, scratch) do |role, byte|
          write_byte(lanes, role, byte, budget)
        end
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          BinaryAggregateCountStateCodec.write_lane(value.count_state) do |byte|
            write_byte(lanes, "#{path}.data", byte, budget)
          end
        else
          BinaryAggregateFunctionStateCodec.write_lane(value.aggregate_function_state_bytes) do |byte|
            write_byte(lanes, "#{path}.data", byte, budget)
          end
        end
      when BinaryDataType::TAG_STRING
        size = value.byte_size
        if profile.with_size_stream?
          write_u64(lanes, "#{path}.string_sizes", size.to_u64, budget)
        else
          write_var_uint(lanes, "#{path}.data", size.to_u64, budget)
        end
        size.times do |index|
          write_byte(lanes, "#{path}.data", value.byte_at(index), budget)
        end
      when BinaryDataType::TAG_BOOL
        write_byte(lanes, "#{path}.data", BoolValueCodec.encode(value.as_bool), budget)
      when BinaryDataType::TAG_NOTHING
        unless value.is_null?
          raise UnsupportedFormatError.new("Nothing bulk values must use the NULL sentinel")
        end
        write_byte(lanes, "#{path}.data", 0x30_u8, budget)
      when BinaryDataType::TAG_VARIANT
        index = value.variant_index?
        write_byte(lanes, "#{path}.discriminators", index || 0xff_u8, budget)
        if index
          child_type = type.child_at(index.to_i)
          child_value = value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant value is missing its selected arm")
          selected_path = child_path(path, ".arm.", index.to_i, budget, dynamic_plan)
          preflight_child_type(traversal, child_type, 1_u64)
          traversal.ensure_depth(depth + 1)
          write_value(child_type, child_value, selected_path, depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(index.to_i) }, shared_value_depth_origin)
        end
      when BinaryDataType::TAG_DYNAMIC
        plan = dynamic_plan || raise UnsupportedFormatError.new("Dynamic bulk value has no structure plan")
        if value.is_null?
          write_byte(lanes, "#{path}.discriminators", 0xff_u8, budget)
        else
          child_value = value.child_at(0)
          selection = plan.select_arm(path, child_value.type)
          write_byte(lanes, "#{path}.discriminators", selection.index, budget)
          arm_path = child_path(path, ".arm.", selection.index.to_i, budget, dynamic_plan)
          if selection.shared
            traversal.preflight_children(2_u64)
            reserved_framing = profile.with_size_stream? ? 8_u64 : 1_u64
            shared_scalar_depth = depth.to_i64 + shared_value_depth_origin.to_i64
            traversal.ensure_depth(shared_scalar_depth)
            envelope = BinaryValueCodec.encode_dynamic_bulk_child(
              child_value,
              budget,
              shared_scalar_depth.to_i32,
              reserved_framing,
              allow_json: true,
              allow_aggregate_function: true,
            )
            framing_bytes = profile.with_size_stream? ? 8_u64 : var_uint_size(envelope.size.to_u64)
            budget.ensure_wire_bytes(checked_add(framing_bytes, envelope.size.to_u64))
            if profile.with_size_stream?
              write_u64(lanes, "#{arm_path}.string_sizes", envelope.size.to_u64, budget)
            else
              write_var_uint(lanes, "#{arm_path}.data", envelope.size.to_u64, budget)
            end
            envelope.each { |byte| write_byte(lanes, "#{arm_path}.data", byte, budget) }
          else
            child_type = plan.arm_type(path, selection.index)
            leaf_key = if child_type.contains_json?
                         BinaryDynamicJsonLeafKey.new(path, selection.index, [] of Int32)
                       else
                         nil
                       end
            traversal.preflight_children(1_u64)
            traversal.ensure_depth(depth + 1)
            write_value(child_type, child_value, arm_path, depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, leaf_key, shared_value_depth_origin)
          end
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        count = value.element_count
        preflight_child_type(traversal, type.child_at(0), count.to_u64) unless count == 0
        traversal.ensure_depth(depth + 1) unless count == 0
        write_u64(lanes, "#{path}.sizes", count.to_u64, budget)
        count.times do |index|
          write_value(type.child_at(0), value.element_at(index), child_path(path, ".elements", nil, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(0) }, shared_value_depth_origin)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = value.element_count
        if count == 0
          write_byte(lanes, "#{path}.data", 0x30_u8, budget)
        else
          traversal.charge_elements(count.to_u64)
          ordinary_nodes = 0_u64
          count.times do |index|
            ordinary_nodes += 1_u64 unless type.child_at(index).tag == BinaryDataType::TAG_LOW_CARDINALITY
          end
          traversal.ensure_future_nodes(ordinary_nodes)
          traversal.ensure_depth(depth + 1)
          count.times do |index|
            write_value(type.child_at(index), value.element_at(index), child_path(path, ".field.", index, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(index) }, shared_value_depth_origin)
          end
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        pairs = flat_count // 2
        unless flat_count == 0
          traversal.charge_elements(flat_count.to_u64)
          ordinary_nodes = 0_u64
          flat_count.times do |index|
            child_type = type.child_at(index.even? ? 0 : 1)
            ordinary_nodes += 1_u64 unless child_type.tag == BinaryDataType::TAG_LOW_CARDINALITY
          end
          traversal.ensure_future_nodes(ordinary_nodes)
        end
        traversal.ensure_depth(depth + 1) unless flat_count == 0
        write_u64(lanes, "#{path}.sizes", pairs.to_u64, budget)
        flat_count.times do |index|
          child_index = index.even? ? 0 : 1
          selected_path = child_path(path, ".elements.field.", child_index, budget, dynamic_plan)
          write_value(type.child_at(child_index), value.element_at(index), selected_path, depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(child_index) }, shared_value_depth_origin)
        end
      when BinaryDataType::TAG_NULLABLE
        child_type = type.child_at(0)
        if value.is_null?
          write_byte(lanes, "#{path}.nulls", 1_u8, budget)
          preflight_child_type(traversal, child_type, 1_u64)
          traversal.ensure_depth(depth + 1)
          write_default_value(child_type, child_path(path, ".nested", nil, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, json_object_writer, mark_index, json_leaf_key.try { |key| key.with_child(0) })
        else
          write_byte(lanes, "#{path}.nulls", 0_u8, budget)
          preflight_child_type(traversal, child_type, 1_u64)
          traversal.ensure_depth(depth + 1)
          write_value(child_type, value.child_at(0), child_path(path, ".nested", nil, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(0) }, shared_value_depth_origin)
        end
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_type = type.child_at(0)
        preflight_child_type(traversal, child_type, 1_u64)
        traversal.ensure_depth(depth + 1)
        write_value(child_type, value.child_at(0), path, depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, qbit_site_scratch, mark_index, json_object_writer, json_leaf_key.try { |key| key.with_child(0) }, shared_value_depth_origin)
      when BinaryDataType::TAG_JSON
        writer = json_object_writer || raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no paired Object writer"))
        key = json_leaf_key || raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no exact binding key"))
        writer.consume(key, mark_index)
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk leaf")
        unless value.byte_size == width
          raise UnsupportedFormatError.new("fixed-width bulk payload does not match its descriptor")
        end
        width.times do |index|
          write_byte(lanes, "#{path}.data", value.byte_at(index), budget)
        end
      end
      nil
    end

    private def self.write_default_value(
      type : BinaryDataType,
      path : String,
      depth : Int,
      traversal : BinaryCodecContext,
      budget : BinaryCodecBudget,
      lanes : Hash(String, Array(UInt8)),
      profile : BinaryBulkProfile,
      dynamic_plan : BinaryDynamicBulkPlan?,
      qbit_roles : Array(String)? = nil,
      qbit_role_offset : Int32 = 0,
      qbit_scratch : Bytes? = nil,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter? = nil,
      mark_index : Int = 0,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
    ) : Nil
      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        traversal.ensure_depth(depth)
        return nil
      end
      traversal.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_QBIT
        roles = qbit_roles || raise(UnsupportedFormatError.new("QBit bulk plane roles were not planned"))
        scratch = qbit_scratch || raise(UnsupportedFormatError.new("QBit bulk plane scratch was not preflighted"))
        qbit_type = type.qbit_type || raise(UnsupportedFormatError.new("QBit bulk descriptor is missing its nominal type"))
        column = QBitColumnType.new(qbit_type)
        BinaryQBitBulkCodec.append_zero_planes(column, roles, qbit_role_offset, scratch) do |role, byte|
          write_byte(lanes, role, byte, budget)
        end
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          write_u64(lanes, "#{path}.string_sizes", 0_u64, budget)
        else
          write_var_uint(lanes, "#{path}.data", 0_u64, budget)
        end
      when BinaryDataType::TAG_BOOL
        write_byte(lanes, "#{path}.data", BoolValueCodec.encode(false), budget)
      when BinaryDataType::TAG_NOTHING
        write_byte(lanes, "#{path}.data", 0x30_u8, budget)
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          BinaryAggregateCountStateCodec.write_lane(0_u64) do |byte|
            write_byte(lanes, "#{path}.data", byte, budget)
          end
        else
          BinaryAggregateFunctionStateCodec.write_lane(BinaryAggregateFunctionStatePlan.for_type(type).default_state_bytes) do |byte|
            write_byte(lanes, "#{path}.data", byte, budget)
          end
        end
      when BinaryDataType::TAG_VARIANT
        write_byte(lanes, "#{path}.discriminators", 0xff_u8, budget)
      when BinaryDataType::TAG_DYNAMIC
        write_byte(lanes, "#{path}.discriminators", 0xff_u8, budget)
      when BinaryDataType::TAG_JSON
        writer = json_object_writer || raise(UnsupportedFormatError.new("bound Dynamic JSON default has no paired Object writer"))
        key = json_leaf_key || raise(UnsupportedFormatError.new("bound Dynamic JSON default has no exact binding key"))
        writer.consume(key, mark_index)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_MAP
        write_u64(lanes, "#{path}.sizes", 0_u64, budget)
      when BinaryDataType::TAG_NULLABLE
        write_byte(lanes, "#{path}.nulls", 1_u8, budget)
        child_type = type.child_at(0)
        preflight_child_type(traversal, child_type, 1_u64)
        traversal.ensure_depth(depth + 1)
        write_default_value(child_type, child_path(path, ".nested", nil, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, json_object_writer, mark_index, json_leaf_key.try { |key| key.with_child(0) })
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_type = type.child_at(0)
        preflight_child_type(traversal, child_type, 1_u64)
        traversal.ensure_depth(depth + 1)
        write_default_value(child_type, path, depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, json_object_writer, mark_index, json_leaf_key.try { |key| key.with_child(0) })
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          write_byte(lanes, "#{path}.data", 0x30_u8, budget)
        else
          traversal.charge_elements(type.child_count.to_u64)
          ordinary_nodes = 0_u64
          type.child_count.times do |index|
            ordinary_nodes += 1_u64 unless type.child_at(index).tag == BinaryDataType::TAG_LOW_CARDINALITY
          end
          traversal.ensure_future_nodes(ordinary_nodes)
          traversal.ensure_depth(depth + 1)
          type.child_count.times do |index|
            write_default_value(type.child_at(index), child_path(path, ".field.", index, budget, dynamic_plan), depth + 1, traversal, budget, lanes, profile, dynamic_plan, qbit_roles, qbit_role_offset, qbit_scratch, json_object_writer, mark_index, json_leaf_key.try { |key| key.with_child(index) })
          end
        end
      else
        width = type.fixed_width || raise UnsupportedFormatError.new("unsupported binary bulk default DataType")
        width.times { write_byte(lanes, "#{path}.data", 0_u8, budget) }
      end
      nil
    end

    private def self.child_path(
      path : String,
      suffix : String,
      index : Int32?,
      budget : BinaryCodecBudget,
      dynamic_plan : BinaryDynamicBulkPlan?,
    ) : String
      unless dynamic_plan
        return index ? "#{path}#{suffix}#{index}" : "#{path}#{suffix}"
      end

      size = path.bytesize.to_u64
      suffix_size = suffix.bytesize.to_u64
      if suffix_size > UInt64::MAX - size
        raise UnsupportedFormatError.new("binary Dynamic value path size overflows UInt64")
      end
      size += suffix_size
      if value = index
        if value < 0
          raise UnsupportedFormatError.new("binary Dynamic value path index is negative")
        end
        digits = 1_u64
        remaining = value
        while remaining >= 10
          remaining //= 10
          digits += 1_u64
        end
        if digits > UInt64::MAX - size
          raise UnsupportedFormatError.new("binary Dynamic value path size overflows UInt64")
        end
        size += digits
      end
      if size > UInt64::MAX // 2_u64
        raise UnsupportedFormatError.new("binary Dynamic value path work size overflows UInt64")
      end
      work = size * 2_u64
      budget.ensure_wire_bytes(work)
      value = String.build do |builder|
        builder << path << suffix
        builder << index.to_s if index
      end
      budget.charge_wire_bytes(work)
      value
    end

    private def self.preflight_child_type(
      traversal : BinaryCodecContext,
      child_type : BinaryDataType,
      count : UInt64,
    ) : Nil
      traversal.charge_elements(count)
      ordinary_nodes = child_type.tag == BinaryDataType::TAG_LOW_CARDINALITY ? 0_u64 : count
      traversal.ensure_future_nodes(ordinary_nodes)
      nil
    end

    private def self.write_byte(lanes : Hash(String, Array(UInt8)), role : String, byte : UInt8, budget : BinaryCodecBudget) : Nil
      buffer = lanes[role]?
      unless buffer
        raise UnsupportedFormatError.new("binary bulk value addressed an unplanned lane")
      end
      budget.charge_wire_bytes(1_u64)
      buffer << byte
      nil
    end

    private def self.write_u64(lanes : Hash(String, Array(UInt8)), role : String, value : UInt64, budget : BinaryCodecBudget) : Nil
      8.times do |index|
        write_byte(lanes, role, ((value >> (index * 8)) & 0xff_u64).to_u8, budget)
      end
      nil
    end

    private def self.write_var_uint(lanes : Hash(String, Array(UInt8)), role : String, value : UInt64, budget : BinaryCodecBudget) : Nil
      remaining = value
      loop do
        payload = (remaining & 0x7f_u64).to_u8
        remaining >>= 7
        write_byte(lanes, role, remaining == 0_u64 ? payload : payload | 0x80_u8, budget)
        break if remaining == 0_u64
      end
      nil
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      remaining = value
      size = 1_u64
      while remaining >= 128_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary bulk write cost overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("binary bulk write cost overflows UInt64")
      end
      left * right
    end
  end
end
