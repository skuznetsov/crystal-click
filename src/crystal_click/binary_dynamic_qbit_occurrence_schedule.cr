module CrystalClick
  # Complete shape-only census for QBit leaves in a prepared Dynamic plan.
  # The plan's leaf roster, rather than the declared descriptor's recursive
  # predicates, determines which Dynamic/Variant axes lead to QBit payload.
  module BinaryDynamicQBitOccurrenceSchedule
    SIZE_STEP     = 0_u8
    SELECTOR_STEP = 1_u8

    private struct SizeLane
      getter role : String
      getter parent_axis : String

      def initialize(role : String, parent_axis : String)
        @role = String.new(role.to_slice)
        @parent_axis = String.new(parent_axis.to_slice)
      end
    end

    private struct NullableLane
      getter role : String
      getter parent_axis : String

      def initialize(role : String, parent_axis : String)
        @role = String.new(role.to_slice)
        @parent_axis = String.new(parent_axis.to_slice)
      end
    end

    private struct SelectorArm
      getter index : Int32
      getter path : String

      def initialize(index : Int, path : String)
        @index = index.to_i32
        @path = String.new(path.to_slice)
      end
    end

    private struct SelectorLane
      getter role : String
      getter parent_axis : String
      getter arm_count : Int32
      getter dynamic : Bool
      getter shared_index : Int32
      getter qbit_arms : Array(SelectorArm)

      def initialize(
        role : String,
        parent_axis : String,
        arm_count : Int,
        @dynamic : Bool,
        @shared_index : Int,
        @qbit_arms : Array(SelectorArm),
      )
        @role = String.new(role.to_slice)
        @parent_axis = String.new(parent_axis.to_slice)
        @arm_count = arm_count.to_i32
      end
    end

    private struct ShapeStep
      getter kind : UInt8
      getter index : Int32

      def initialize(@kind : UInt8, index : Int)
        @index = index.to_i32
      end
    end

    def self.validate!(
      plan : BinaryDynamicBulkPlan,
      type : BinaryDataType,
      physical : BinaryDynamicBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      dynamic_modes : Hash(String, UInt64),
      parent_rows : Array(UInt64),
      site_grid : StorageOccurrenceGrid,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      sites = plan.qbit_sites
      return nil if sites.empty?
      unless plan.type == type && !codec_budget.writing? && !transport_budget.writing?
        raise CorruptPartError.new("Dynamic QBit occurrence schedule differs from its prepared plan")
      end

      BinaryCodecContext.new(codec_budget.limits, nil, false).validate_type_tree(type)
      mark_count = parent_rows.size
      if mark_count == 0 || mark_count > WidePartWriter::MAX_MARKS || site_grid.mark_count != mark_count
        raise CorruptPartError.new("Dynamic QBit occurrence schedule mark count is outside its bounded domain")
      end

      sites_by_path = Hash(String, BinaryDynamicQBitSite).new(initial_capacity: sites.size)
      qbit_prefixes = Hash(String, Bool).new(initial_capacity: sites.size * 4)
      sites.each do |site|
        path = site.path
        if sites_by_path.has_key?(path)
          raise CorruptPartError.new("Dynamic QBit occurrence schedule repeats a leaf site")
        end
        sites_by_path[String.new(path.to_slice)] = site
        qbit_prefixes[String.new(path.to_slice)] = true
        path.bytes.each_with_index do |byte, index|
          if byte == '.'.ord.to_u8 && index > 0
            qbit_prefixes[String.new(path[0, index].to_slice)] = true
          end
        end
      end

      size_lanes = [] of SizeLane
      size_indexes = Hash(String, Int32).new
      nullable_lanes = [] of NullableLane
      nullable_indexes = Hash(String, Int32).new
      selector_lanes = [] of SelectorLane
      selector_indexes = Hash(String, Int32).new
      shape_steps = [] of ShapeStep
      visited_sites = Hash(String, Bool).new(initial_capacity: sites.size)
      site_axes = Hash(String, String).new(initial_capacity: sites.size)
      collect_shape!(
        type, "root", "root", plan, qbit_prefixes, sites_by_path,
        size_lanes, size_indexes, nullable_lanes, nullable_indexes,
        selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
      )
      unless visited_sites.size == sites_by_path.size && site_axes.size == sites_by_path.size
        raise CorruptPartError.new("Dynamic QBit occurrence schedule omits a planned leaf site")
      end

      selector_arm_count = 0_u64
      selector_lanes.each do |lane|
        selector_arm_count = checked_add(selector_arm_count, lane.qbit_arms.size.to_u64)
      end
      vector_count = checked_add(checked_add(1_u64, size_lanes.size.to_u64), selector_arm_count)
      workspace_vectors = checked_add(vector_count, 2_u64) # per-mark element/wire accumulators
      workspace_bytes = checked_multiply(checked_multiply(mark_count.to_u64, workspace_vectors), 8_u64)
      unless workspace_bytes <= codec_budget.limits.max_bytes.to_u64
        raise CorruptPartError.new("Dynamic QBit occurrence workspace requires #{workspace_bytes} bytes, exceeding the configured byte limit")
      end
      workspace_values = checked_multiply(mark_count.to_u64, workspace_vectors)
      codec_budget.ensure_future_nodes(workspace_values)
      codec_budget.ensure_future_elements(workspace_values)

      root_counts = Array(UInt64).new(mark_count) do |mark|
        site_grid.logical_occurrences_at(mark)
      end
      axis_counts = Hash(String, Array(UInt64)).new(initial_capacity: size_lanes.size + selector_arm_count.to_i)
      axis_counts["root"] = root_counts
      mark_element_totals = Array(UInt64).new(mark_count, 0_u64)
      mark_wire_totals = Array(UInt64).new(mark_count, 0_u64)

      # Reserve the aggregate returned bytes for every distinct size or
      # selector lane before the first positive shape window is requested.
      result_bytes = 0_u64
      shape_steps.each do |step|
        role = if step.kind == SIZE_STEP
                 size_lanes[step.index].role
               else
                 selector_lanes[step.index].role
               end
        grid = grids[role]? || raise(CorruptPartError.new("Dynamic QBit shape lane has no inspected mark grid"))
        result_bytes = checked_add(result_bytes, grid.logical_size.to_u64)
      end
      if result_bytes > Int64::MAX.to_u64
        raise CorruptPartError.new("Dynamic QBit shape result workspace exceeds the bounded transport domain")
      end
      transport_budget.preflight_result_bytes(result_bytes.to_i64)

      preflight_selector_transforms!(selector_lanes, physical, codec_budget, mark_count)

      shape_steps.each do |step|
        case step.kind
        when SIZE_STEP
          lane = size_lanes[step.index]
          parent_counts = axis_counts[lane.parent_axis]? ||
                          raise(CorruptPartError.new("Dynamic QBit size lane parent was not scheduled first"))
          census_size_lane!(
            lane, parent_counts, physical, source, grids, parent_rows,
            mark_count, codec_budget.limits, transport_budget,
            mark_element_totals, mark_wire_totals, axis_counts,
          )
        when SELECTOR_STEP
          lane = selector_lanes[step.index]
          parent_counts = axis_counts[lane.parent_axis]? ||
                          raise(CorruptPartError.new("Dynamic QBit selector parent was not scheduled first"))
          census_selector_lane!(
            lane, parent_counts, physical, source, grids, dynamic_modes, parent_rows,
            mark_count, codec_budget, transport_budget,
            mark_element_totals, mark_wire_totals, axis_counts,
          )
        else
          raise CorruptPartError.new("Dynamic QBit shape schedule has an unknown step")
        end
      end

      nullable_lanes.each do |lane|
        expected_rows = axis_counts[lane.parent_axis]? ||
                        raise(CorruptPartError.new("Dynamic QBit Nullable domain was not scheduled"))
        grid = grids[lane.role]? || raise(CorruptPartError.new("Dynamic QBit Nullable map has no inspected mark grid"))
        prefix = physical.prefix_size_for(lane.role)
        validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)
        expected_total = 0_u64
        mark_count.times do |mark|
          require_mark_delta!(grid, mark, expected_rows[mark], "Nullable map")
          expected_total = checked_add(expected_total, expected_rows[mark])
        end
        require_lane_logical_size!(grid, lane.role, prefix, expected_total)
      end

      sites.each do |site|
        axis = site_axes[site.path]? || raise(CorruptPartError.new("Dynamic QBit leaf occurrence axis was not scheduled"))
        expected_rows = axis_counts[axis]? || raise(CorruptPartError.new("Dynamic QBit leaf occurrence counts are missing"))
        roles = site.plane_roles
        unless roles.size == site.qbit_type.plane_count
          raise CorruptPartError.new("Dynamic QBit leaf plane roster differs from its nominal type")
        end
        roles.each do |role|
          grid = grids[role]? || raise(CorruptPartError.new("Dynamic QBit plane has no inspected mark grid"))
          prefix = physical.prefix_size_for(role)
          validate_parent_grid!(grid, role, prefix, parent_rows, mark_count)
          expected_total = 0_u64
          mark_count.times do |mark|
            plane_bytes = checked_multiply(expected_rows[mark], site.plane_width.to_u64)
            require_mark_delta!(grid, mark, plane_bytes, "QBit plane")
            expected_total = checked_add(expected_total, plane_bytes)
          end
          require_lane_logical_size!(grid, role, prefix, expected_total)
        end
      end
      nil
    rescue ex : UnsupportedFormatError
      raise CorruptPartError.new("Dynamic QBit physical occurrence schedule exceeds configured codec limits")
    end

    private def self.collect_shape!(
      type : BinaryDataType,
      path : String,
      parent_axis : String,
      plan : BinaryDynamicBulkPlan,
      qbit_prefixes : Hash(String, Bool),
      sites_by_path : Hash(String, BinaryDynamicQBitSite),
      size_lanes : Array(SizeLane),
      size_indexes : Hash(String, Int32),
      nullable_lanes : Array(NullableLane),
      nullable_indexes : Hash(String, Int32),
      selector_lanes : Array(SelectorLane),
      selector_indexes : Hash(String, Int32),
      shape_steps : Array(ShapeStep),
      visited_sites : Hash(String, Bool),
      site_axes : Hash(String, String),
    ) : Nil
      return unless qbit_prefixes.has_key?(path)

      case type.tag
      when BinaryDataType::TAG_QBIT
        site = sites_by_path[path]? || raise(CorruptPartError.new("Dynamic QBit leaf is absent from the planned site roster"))
        visited_sites[path] = true
        site_axes[String.new(path.to_slice)] = String.new(parent_axis.to_slice)
      when BinaryDataType::TAG_DYNAMIC
        unless plan.has_site?(path)
          raise CorruptPartError.new("Dynamic QBit selector has no prepared Dynamic site")
        end
        arm_count = plan.arm_count(path)
        shared_index = plan.shared_index(path)
        arms = [] of SelectorArm
        arm_count.times do |index|
          child_path = "#{path}.arm.#{index}"
          if qbit_prefixes.has_key?(child_path)
            if index == shared_index
              raise CorruptPartError.new("Dynamic shared arm unexpectedly contains a planned QBit leaf")
            end
            arms << SelectorArm.new(index, child_path)
          end
        end
        lane_index = add_selector_lane!(
          selector_lanes, selector_indexes, "#{path}.discriminators", parent_axis,
          arm_count, true, shared_index, arms,
        )
        shape_steps << ShapeStep.new(SELECTOR_STEP, lane_index) if lane_index >= 0
        arms.each do |arm|
          collect_shape!(
            plan.arm_type(path, arm.index), arm.path, arm.path, plan,
            qbit_prefixes, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, selector_lanes, selector_indexes,
            shape_steps, visited_sites, site_axes,
          )
        end
      when BinaryDataType::TAG_VARIANT
        arms = [] of SelectorArm
        type.child_count.times do |index|
          child_path = "#{path}.arm.#{index}"
          arms << SelectorArm.new(index, child_path) if qbit_prefixes.has_key?(child_path)
        end
        lane_index = add_selector_lane!(
          selector_lanes, selector_indexes, "#{path}.discriminators", parent_axis,
          type.child_count, false, -1, arms,
        )
        shape_steps << ShapeStep.new(SELECTOR_STEP, lane_index) if lane_index >= 0
        arms.each do |arm|
          collect_shape!(
            type.child_at(arm.index), arm.path, arm.path, plan,
            qbit_prefixes, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, selector_lanes, selector_indexes,
            shape_steps, visited_sites, site_axes,
          )
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        role = "#{path}.sizes"
        index = add_size_lane!(size_lanes, size_indexes, role, parent_axis)
        shape_steps << ShapeStep.new(SIZE_STEP, index) if index >= 0
        collect_shape!(
          type.child_at(0), "#{path}.elements", role, plan, qbit_prefixes,
          sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
          selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
        )
      when BinaryDataType::TAG_MAP
        role = "#{path}.sizes"
        index = add_size_lane!(size_lanes, size_indexes, role, parent_axis)
        shape_steps << ShapeStep.new(SIZE_STEP, index) if index >= 0
        key_path = "#{path}.elements.field.0"
        if qbit_prefixes.has_key?(key_path)
          collect_shape!(
            type.child_at(0), key_path, role, plan, qbit_prefixes,
            sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
            selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
          )
        end
        value_path = "#{path}.elements.field.1"
        if qbit_prefixes.has_key?(value_path)
          collect_shape!(
            type.child_at(1), value_path, role, plan, qbit_prefixes,
            sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
            selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
          )
        end
      when BinaryDataType::TAG_NULLABLE
        role = "#{path}.nulls"
        add_nullable_lane!(nullable_lanes, nullable_indexes, role, parent_axis)
        collect_shape!(
          type.child_at(0), "#{path}.nested", parent_axis, plan, qbit_prefixes,
          sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
          selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
        )
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        collect_shape!(
          type.child_at(0), path, parent_axis, plan, qbit_prefixes,
          sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
          selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child_path = "#{path}.field.#{index}"
          next unless qbit_prefixes.has_key?(child_path)
          collect_shape!(
            type.child_at(index), child_path, parent_axis, plan, qbit_prefixes,
            sites_by_path, size_lanes, size_indexes, nullable_lanes, nullable_indexes,
            selector_lanes, selector_indexes, shape_steps, visited_sites, site_axes,
          )
        end
      else
        raise CorruptPartError.new("Dynamic QBit site appears under an unsupported descriptor wrapper")
      end
      nil
    end

    # Returns the newly-added index, or -1 when a shared lane was already
    # recorded after checking that its complete parent/selector shape agrees.
    private def self.add_size_lane!(
      lanes : Array(SizeLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
    ) : Int32
      if index = indexes[role]?
        existing = lanes[index]
        unless existing.parent_axis == parent_axis
          raise CorruptPartError.new("Dynamic QBit size lane has conflicting parent domains")
        end
        return -1
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << SizeLane.new(role, parent_axis)
      lanes.size - 1
    end

    private def self.add_nullable_lane!(
      lanes : Array(NullableLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
    ) : Nil
      if index = indexes[role]?
        unless lanes[index].parent_axis == parent_axis
          raise CorruptPartError.new("Dynamic QBit Nullable lane has conflicting parent domains")
        end
        return nil
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << NullableLane.new(role, parent_axis)
      nil
    end

    private def self.add_selector_lane!(
      lanes : Array(SelectorLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
      arm_count : Int,
      dynamic : Bool,
      shared_index : Int,
      qbit_arms : Array(SelectorArm),
    ) : Int32
      if index = indexes[role]?
        existing = lanes[index]
        unless existing.parent_axis == parent_axis && existing.arm_count == arm_count &&
               existing.dynamic == dynamic && existing.shared_index == shared_index &&
               existing.qbit_arms.map(&.path) == qbit_arms.map(&.path)
          raise CorruptPartError.new("Dynamic QBit selector lane has conflicting parent or arm axes")
        end
        return -1
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << SelectorLane.new(role, parent_axis, arm_count, dynamic, shared_index, qbit_arms)
      lanes.size - 1
    end

    private def self.preflight_selector_transforms!(
      lanes : Array(SelectorLane),
      physical : BinaryDynamicBulkPhysicalPlan,
      budget : BinaryCodecBudget,
      mark_count : Int32,
    ) : Nil
      dynamic_headers = 0_u64
      dynamic_coordinates = 0_u64
      variant_prefixes = [] of Tuple(String, Int32, Int32)
      lanes.each do |lane|
        prefix = physical.prefix_size_for(lane.role)
        coordinates = mark_count.to_i64 + 1_i64
        if coordinates > Int32::MAX
          raise CorruptPartError.new("Dynamic QBit selector coordinate count exceeds its bounded domain")
        end
        if lane.dynamic
          unless prefix == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
            raise CorruptPartError.new("Dynamic QBit selector has an invalid physical prefix")
          end
          dynamic_headers = checked_add(dynamic_headers, prefix.to_u64)
          dynamic_coordinates = checked_add(dynamic_coordinates, coordinates.to_u64)
        else
          variant_prefixes << {lane.role, prefix, coordinates.to_i32}
        end
      end
      # Dynamic owns its BASIC/COMPACT header separately from BinaryBulk's
      # Variant prefix adapter; reserve its detached K+1 vectors and headers
      # alongside the Variant transform before opening any positive window.
      budget.ensure_wire_bytes(dynamic_headers)
      budget.ensure_future_elements(dynamic_coordinates)
      BinaryBulkPhysicalPrefixAdapter.preflight_read(variant_prefixes, budget) unless variant_prefixes.empty?
      budget.charge_wire_bytes(dynamic_headers) if dynamic_headers > 0_u64
      budget.charge_elements(dynamic_coordinates) if dynamic_coordinates > 0_u64
      nil
    end

    private def self.census_size_lane!(
      lane : SizeLane,
      parent_counts : Array(UInt64),
      physical : BinaryDynamicBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      parent_rows : Array(UInt64),
      mark_count : Int32,
      limits : BinaryCodecLimits,
      transport_budget : CompressedStreamBudget,
      mark_element_totals : Array(UInt64),
      mark_wire_totals : Array(UInt64),
      axis_counts : Hash(String, Array(UInt64)),
    ) : Nil
      grid = grids[lane.role]? || raise(CorruptPartError.new("Dynamic QBit Array/Map size lane has no inspected mark grid"))
      prefix = physical.prefix_size_for(lane.role)
      validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)
      expected_total = 0_u64
      mark_count.times do |mark|
        items = parent_counts[mark]
        expected_bytes = checked_multiply(items, 8_u64)
        require_mark_delta!(grid, mark, expected_bytes, "Array/Map size")
        unless expected_bytes <= Int32::MAX.to_u64
          raise CorruptPartError.new("Dynamic QBit size mark exceeds its bounded buffer domain")
        end
        charge_mark_totals!(
          mark, items, expected_bytes, limits,
          mark_element_totals, mark_wire_totals,
        )
        expected_total = checked_add(expected_total, expected_bytes)
      end
      require_lane_logical_size!(grid, lane.role, prefix, expected_total)
      window = source.read_window(
        physical.data_file_for(lane.role, true),
        physical.marks_file_for(lane.role, true),
        0, mark_count, prefix, transport_budget,
      )
      validate_window_grid!(window, grid, lane.role, prefix, parent_rows, mark_count)
      bytes = window.bytes
      child_counts = Array(UInt64).new(mark_count, 0_u64)
      mark_count.times do |mark|
        start = window.offsets[mark]
        finish = window.offsets[mark + 1]
        expected_bytes = checked_multiply(parent_counts[mark], 8_u64)
        unless finish >= start && finish - start == expected_bytes && finish <= bytes.size.to_u64 &&
               start <= Int32::MAX.to_u64 && finish <= Int32::MAX.to_u64
          raise CorruptPartError.new("Dynamic QBit size mark payload differs from its inspected grid")
        end
        sum = 0_u64
        offset = start.to_i
        finish_offset = finish.to_i
        while offset < finish_offset
          sum = checked_add(sum, read_u64_le(bytes, offset))
          offset += 8
        end
        child_counts[mark] = sum
      end
      axis_counts[lane.role] = child_counts
      nil
    end

    private def self.census_selector_lane!(
      lane : SelectorLane,
      parent_counts : Array(UInt64),
      physical : BinaryDynamicBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      dynamic_modes : Hash(String, UInt64),
      parent_rows : Array(UInt64),
      mark_count : Int32,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      mark_element_totals : Array(UInt64),
      mark_wire_totals : Array(UInt64),
      axis_counts : Hash(String, Array(UInt64)),
    ) : Nil
      unless lane.arm_count > 0 && lane.arm_count <= 0xff
        raise CorruptPartError.new("Dynamic QBit selector has an invalid arm domain")
      end
      if lane.dynamic && (lane.shared_index < 0 || lane.shared_index >= lane.arm_count)
        raise CorruptPartError.new("Dynamic QBit selector has an invalid shared arm")
      end
      grid = grids[lane.role]? || raise(CorruptPartError.new("Dynamic QBit selector has no inspected mark grid"))
      prefix = physical.prefix_size_for(lane.role)
      validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)
      dynamic_mode = if lane.dynamic
                       dynamic_modes[lane.role]? ||
                         raise(CorruptPartError.new("Dynamic QBit discriminator has no validated framing mode"))
                     else
                       DynamicDiscriminatorBodyValidator::BASIC_MODE
                     end
      expected_total = 0_u64
      mark_count.times do |mark|
        count = parent_counts[mark]
        unless count <= Int32::MAX.to_u64
          raise CorruptPartError.new("Dynamic QBit selector mark exceeds its bounded buffer domain")
        end
        expected_total = checked_add(expected_total, count)
      end
      if !lane.dynamic
        mark_count.times do |mark|
          require_mark_delta!(grid, mark, parent_counts[mark], "Variant discriminator")
          charge_mark_totals!(
            mark, parent_counts[mark], parent_counts[mark], codec_budget.limits,
            mark_element_totals, mark_wire_totals,
          )
        end
        require_lane_logical_size!(grid, lane.role, prefix, expected_total)
      else
        # The expanded Dynamic tag buffer is part of this open-time census.
        # Bound its element domain before COMPACT framing allocates it.
        codec_budget.ensure_future_elements(expected_total)
        mark_count.times do |mark|
          if dynamic_mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
            require_mark_delta!(grid, mark, parent_counts[mark], "Dynamic discriminator")
          end
          charge_mark_totals!(
            mark, parent_counts[mark], parent_counts[mark], codec_budget.limits,
            mark_element_totals, mark_wire_totals,
          )
        end
        if dynamic_mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
          require_lane_logical_size!(grid, lane.role, prefix, expected_total)
        end
      end

      window = source.read_window(
        physical.data_file_for(lane.role, true),
        physical.marks_file_for(lane.role, true),
        0, mark_count, prefix, transport_budget,
      )
      validate_window_grid!(window, grid, lane.role, prefix, parent_rows, mark_count)
      if lane.dynamic
        mode = BinaryBulkDiscriminatorFramingAdapter.validate_header(lane.role, window.bytes, prefix)
        unless mode == dynamic_mode
          raise CorruptPartError.new("Dynamic QBit discriminator framing mode changed after header validation")
        end
        logical_bytes, logical_offsets, _logical_prefix = BinaryBulkDiscriminatorFramingAdapter.read_lane(
          lane.role, window.bytes, window.offsets, prefix, codec_budget,
        )
        if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
          require_lane_logical_size!(grid, lane.role, prefix, expected_total)
        end
        census_selector_tags!(
          lane, logical_bytes, logical_offsets, parent_counts, mark_count, axis_counts,
        )
      else
        logical_bytes, logical_offsets, _logical_prefix = BinaryBulkPhysicalPrefixAdapter.read_lane(
          lane.role, window.bytes, window.offsets, prefix,
        )
        census_selector_tags!(
          lane, logical_bytes, logical_offsets, parent_counts, mark_count, axis_counts,
        )
      end
      nil
    end

    private def self.census_selector_tags!(
      lane : SelectorLane,
      bytes : Bytes,
      offsets : Array(UInt64),
      parent_counts : Array(UInt64),
      mark_count : Int32,
      axis_counts : Hash(String, Array(UInt64)),
    ) : Nil
      unless offsets.size == mark_count + 1
        raise CorruptPartError.new("Dynamic QBit selector has the wrong logical offset count")
      end
      qbit_counts = Hash(Int32, Array(UInt64)).new(initial_capacity: lane.qbit_arms.size)
      lane.qbit_arms.each do |arm|
        if arm.index < 0 || arm.index >= lane.arm_count || (lane.dynamic && arm.index == lane.shared_index)
          raise CorruptPartError.new("Dynamic QBit arm axis is outside its selector roster")
        end
        qbit_counts[arm.index] = Array(UInt64).new(mark_count, 0_u64)
      end

      mark_count.times do |mark|
        start = offsets[mark]
        finish = offsets[mark + 1]
        count = parent_counts[mark]
        unless finish >= start && finish - start == count && finish <= bytes.size.to_u64 &&
               start <= Int32::MAX.to_u64 && finish <= Int32::MAX.to_u64
          raise CorruptPartError.new("Dynamic QBit selector mark differs from its parent occurrence axis")
        end
        offset = start.to_i
        finish_offset = finish.to_i
        while offset < finish_offset
          discriminator = bytes[offset]
          offset += 1
          next if discriminator == 0xff_u8
          arm_index = discriminator.to_i
          if arm_index >= lane.arm_count
            raise CorruptPartError.new("Dynamic QBit selector is outside its arm roster")
          end
          if lane.dynamic && arm_index == lane.shared_index
            next
          end
          if counts = qbit_counts[arm_index.to_i32]?
            if counts[mark] == UInt64::MAX
              raise CorruptPartError.new("Dynamic QBit selector occurrence count overflows UInt64")
            end
            counts[mark] += 1_u64
          end
        end
      end
      lane.qbit_arms.each do |arm|
        counts = qbit_counts[arm.index]? || raise(CorruptPartError.new("Dynamic QBit selector arm counts are missing"))
        axis_counts[arm.path] = counts
      end
      nil
    end

    private def self.charge_mark_totals!(
      mark : Int,
      elements : UInt64,
      wire_bytes : UInt64,
      limits : BinaryCodecLimits,
      mark_element_totals : Array(UInt64),
      mark_wire_totals : Array(UInt64),
    ) : Nil
      element_limit = limits.max_elements.to_u64
      wire_limit = limits.max_bytes.to_u64
      if mark_element_totals[mark] > element_limit || elements > element_limit - mark_element_totals[mark]
        raise CorruptPartError.new("binary codec element limit exceeded")
      end
      if mark_wire_totals[mark] > wire_limit || wire_bytes > wire_limit - mark_wire_totals[mark]
        raise CorruptPartError.new("binary codec byte limit exceeded")
      end
      mark_element_totals[mark] = checked_add(mark_element_totals[mark], elements)
      mark_wire_totals[mark] = checked_add(mark_wire_totals[mark], wire_bytes)
      nil
    end

    private def self.validate_parent_grid!(
      grid : CompressedMarkGrid,
      role : String,
      prefix : Int32,
      parent_rows : Array(UInt64),
      mark_count : Int32,
    ) : Nil
      unless grid.mark_count == mark_count && grid.prefix_size == prefix
        raise CorruptPartError.new("Dynamic QBit lane #{role} differs from its inspected mark domain")
      end
      mark_count.times do |mark|
        unless grid.row_count_at(mark) == parent_rows[mark]
          raise CorruptPartError.new("Dynamic QBit lane #{role} differs from the parent row grid")
        end
      end
      nil
    end

    private def self.validate_window_grid!(
      window : CompressedMarkWindow,
      grid : CompressedMarkGrid,
      role : String,
      prefix : Int32,
      parent_rows : Array(UInt64),
      mark_count : Int32,
    ) : Nil
      unless window.first_mark == 0 && window.prefix_size == prefix && window.rows_per_mark == parent_rows
        raise CorruptPartError.new("Dynamic QBit shape window #{role} differs from its inspected grid")
      end
      offsets = window.offsets
      unless offsets.size == mark_count + 1
        raise CorruptPartError.new("Dynamic QBit shape window #{role} has the wrong offset count")
      end
      first_position = grid.position_at(0)
      (0..mark_count).each do |index|
        position = grid.position_at(index)
        unless position >= first_position
          raise CorruptPartError.new("Dynamic QBit shape grid #{role} precedes its prefix")
        end
        expected_offset = checked_add(prefix.to_u64, (position - first_position).to_u64)
        unless offsets[index] == expected_offset
          raise CorruptPartError.new("Dynamic QBit shape window #{role} offsets differ from its inspected grid")
        end
      end
      unless window.bytes.size.to_u64 == grid.logical_size.to_u64
        raise CorruptPartError.new("Dynamic QBit shape window #{role} differs from its inspected logical size")
      end
      nil
    end

    private def self.require_lane_logical_size!(
      grid : CompressedMarkGrid,
      role : String,
      prefix : Int32,
      payload_bytes : UInt64,
    ) : Nil
      if grid.logical_size < prefix.to_i64
        raise CorruptPartError.new("Dynamic QBit prefix exceeds lane #{role}")
      end
      unless (grid.logical_size - prefix.to_i64).to_u64 == payload_bytes
        raise CorruptPartError.new("Dynamic QBit lane #{role} logical size differs from its occurrence schedule")
      end
      if grid.logical_size > Int32::MAX
        raise CorruptPartError.new("Dynamic QBit lane #{role} exceeds its bounded result domain")
      end
      nil
    end

    private def self.require_mark_delta!(grid : CompressedMarkGrid, mark : Int, expected : UInt64, label : String) : Nil
      if mark < 0 || mark >= grid.mark_count
        raise CorruptPartError.new("Dynamic QBit #{label} mark is outside its inspected grid")
      end
      delta = grid.position_at(mark + 1) - grid.position_at(mark)
      unless delta >= 0 && delta.to_u64 == expected
        raise CorruptPartError.new("Dynamic QBit #{label} mark differs from its occurrence schedule")
      end
      nil
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("Dynamic QBit size value is truncated")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Dynamic QBit occurrence count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Dynamic QBit occurrence workspace overflows UInt64")
      end
      left * right
    end
  end
end
