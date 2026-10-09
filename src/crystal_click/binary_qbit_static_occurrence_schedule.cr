module CrystalClick
  # Complete shape-only census for every QBit leaf in an admitted static
  # product tree. Unique Array/Map size lanes and Variant discriminator axes
  # are replayed once in parent-first order; QBit plane payload remains unread
  # until a selected value window.
  module BinaryQBitStaticOccurrenceSchedule
    SIZE_STEP    = 0_u8
    VARIANT_STEP = 1_u8

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

    private struct VariantArmAxis
      getter index : Int32
      getter path : String

      def initialize(index : Int, path : String)
        @index = index.to_i32
        @path = String.new(path.to_slice)
      end
    end

    private struct VariantLane
      getter role : String
      getter parent_axis : String
      getter arm_count : Int32
      getter qbit_arms : Array(VariantArmAxis)

      def initialize(role : String, parent_axis : String, arm_count : Int, qbit_arms : Array(VariantArmAxis))
        @role = String.new(role.to_slice)
        @parent_axis = String.new(parent_axis.to_slice)
        @arm_count = arm_count.to_i32
        @qbit_arms = qbit_arms
      end
    end

    private struct ShapeStep
      getter kind : UInt8
      getter index : Int32

      def initialize(@kind : UInt8, index : Int)
        @index = index.to_i32
      end
    end

    # A root occurrence axis may be borrowed from an existing parent-row
    # vector, or computed from an already-decoded Dynamic sparse arm schedule.
    # The latter keeps Object's logical Q counts distinct from physical P
    # without retaining a second per-mark count vector.
    private struct OccurrenceAxis
      @rows : Array(UInt64)?
      @reader : Proc(Int32, UInt64)?
      @mark_count : Int32

      def initialize(rows : Array(UInt64))
        @rows = rows
        @reader = nil
        @mark_count = rows.size.to_i32
      end

      def initialize(@mark_count : Int32, reader : Proc(Int32, UInt64))
        @rows = nil
        @reader = reader
      end

      def size : Int32
        @mark_count
      end

      def [](mark : Int) : UInt64
        unless mark >= 0 && mark < @mark_count
          raise IndexError.new("static QBit occurrence axis mark is outside its domain")
        end
        if rows = @rows
          rows[mark]
        else
          @reader.not_nil!.call(mark.to_i32)
        end
      end
    end

    def self.validate!(
      type : BinaryDataType,
      sites : Array(BinaryQBitRecursiveAdmission::StaticSite),
      physical : BinaryBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      parent_rows : Array(UInt64),
      codec_limits : BinaryCodecLimits,
      transport_budget : CompressedStreamBudget,
      root_count_at : Proc(Int32, UInt64)? = nil,
      shared_totals : BinaryQBitOccurrenceTotals? = nil,
      shared_codec_budget : BinaryCodecBudget? = nil,
    ) : Nil
      unless type.contains_qbit? && !sites.empty?
        raise CorruptPartError.new("static QBit schedule has no admitted leaf sites")
      end

      # This entry point is also called directly by tests and other bounded
      # readers, so do not assume a plan already validated the recursive type
      # tree before the shape walk below allocates its role vectors.
      if shared_totals && shared_codec_budget.nil?
        raise CorruptPartError.new("static QBit shared occurrence totals require their codec budget")
      end
      if budget = shared_codec_budget
        unless !budget.writing? && same_limits?(codec_limits, budget.limits)
          raise CorruptPartError.new("static QBit shared logical budget differs from its codec limits")
        end
        BinaryCodecContext.new(codec_limits, nil, false, budget: budget).validate_type_tree(type)
      else
        BinaryCodecContext.new(codec_limits, nil, false).validate_type_tree(type)
      end

      mark_count = parent_rows.size
      if mark_count == 0 || mark_count > WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("static QBit schedule mark count is outside its bounded domain")
      end

      sites_by_path = Hash(String, BinaryQBitRecursiveAdmission::StaticSite).new(initial_capacity: sites.size)
      sites.each do |site|
        path = site.path
        if sites_by_path.has_key?(path)
          raise CorruptPartError.new("static QBit schedule repeats a leaf site")
        end
        sites_by_path[String.new(path.to_slice)] = site
      end

      size_lanes = [] of SizeLane
      size_indexes = Hash(String, Int32).new(initial_capacity: sites.size)
      nullable_lanes = [] of NullableLane
      nullable_indexes = Hash(String, Int32).new(initial_capacity: sites.size)
      variant_lanes = [] of VariantLane
      variant_indexes = Hash(String, Int32).new(initial_capacity: sites.size)
      shape_steps = [] of ShapeStep
      visited_sites = Hash(String, Bool).new(initial_capacity: sites.size)
      site_axes = Hash(String, String).new(initial_capacity: sites.size)
      collect_shape!(
        type,
        "root",
        "root",
        [] of String,
        [] of String,
        sites_by_path,
        size_lanes,
        size_indexes,
        nullable_lanes,
        nullable_indexes,
        variant_lanes,
        variant_indexes,
        shape_steps,
        visited_sites,
        site_axes,
      )
      unless visited_sites.size == sites_by_path.size && site_axes.size == sites_by_path.size
        raise CorruptPartError.new("static QBit schedule omits a planned leaf site")
      end
      if totals = shared_totals
        unless totals.mark_count == mark_count
          raise CorruptPartError.new("static QBit shared occurrence totals have the wrong mark domain")
        end
      end

      # Each unique size lane and each QBit-bearing Variant arm retains one
      # per-mark count vector. Standalone visits also retain local counters;
      # Object visits borrow the common counter owner. Reject before allocation
      # or the first positive shape read.
      vector_count = size_lanes.size.to_u64
      variant_lanes.each do |lane|
        vector_count = checked_add(vector_count, lane.qbit_arms.size.to_u64)
      end
      if vector_count > 0_u64
        if vector_count > UInt64::MAX - 2_u64
          raise CorruptPartError.new("static QBit schedule workspace size overflows")
        end
        if totals = shared_totals
          totals.preflight_active_vectors!(vector_count, shared_codec_budget.not_nil!)
        else
          schedule_workspace_bytes = checked_multiply(
            checked_multiply(mark_count.to_u64, vector_count + 2_u64),
            8_u64,
          )
          unless schedule_workspace_bytes <= codec_limits.max_bytes.to_u64
            raise CorruptPartError.new("static QBit schedule workspace exceeds the configured byte limit")
          end
        end
      end

      # Admit the complete returned shape census before reading its first
      # positive lane. A later Variant/size lane must not discover that the
      # transport result budget is too small after earlier lanes have already
      # been materialized.
      shape_result_bytes = 0_u64
      shape_steps.each do |step|
        role = if step.kind == SIZE_STEP
                 size_lanes[step.index].role
               else
                 variant_lanes[step.index].role
               end
        grid = grids[role]? || raise(CorruptPartError.new("static QBit shape lane has no inspected mark grid"))
        shape_result_bytes = checked_add(shape_result_bytes, grid.logical_size.to_u64)
      end
      if shape_result_bytes > Int64::MAX.to_u64
        raise CorruptPartError.new("static QBit shape result workspace exceeds the bounded transport domain")
      end
      transport_budget.preflight_result_bytes(shape_result_bytes.to_i64)

      axis_counts = Hash(String, OccurrenceAxis).new(initial_capacity: (size_lanes.size + variant_lanes.size + 1))
      axis_counts["root"] = if reader = root_count_at
                              OccurrenceAxis.new(mark_count, reader)
                            else
                              OccurrenceAxis.new(parent_rows)
                            end
      shape_has_axes = vector_count > 0_u64
      mark_element_totals = shape_has_axes && shared_totals.nil? ? Array(UInt64).new(mark_count, 0_u64) : nil
      mark_wire_totals = shape_has_axes && shared_totals.nil? ? Array(UInt64).new(mark_count, 0_u64) : nil

      shape_steps.each do |step|
        case step.kind
        when SIZE_STEP
          lane = size_lanes[step.index]
          parent_counts = axis_counts[lane.parent_axis]? ||
                          raise(CorruptPartError.new("static QBit size lane parent was not scheduled first"))
          census_size_lane!(
            lane,
            parent_counts,
            physical,
            source,
            grids,
            parent_rows,
            mark_count,
            codec_limits,
            transport_budget,
            mark_element_totals,
            mark_wire_totals,
            axis_counts,
            shared_totals,
          )
        when VARIANT_STEP
          lane = variant_lanes[step.index]
          parent_counts = axis_counts[lane.parent_axis]? ||
                          raise(CorruptPartError.new("static QBit Variant parent was not scheduled first"))
          census_variant_lane!(
            lane,
            parent_counts,
            physical,
            source,
            grids,
            parent_rows,
            mark_count,
            codec_limits,
            transport_budget,
            mark_element_totals,
            mark_wire_totals,
            axis_counts,
            shared_totals,
          )
        else
          raise CorruptPartError.new("static QBit shape schedule has an unknown step")
        end
      end

      nullable_lanes.each do |lane|
        expected_rows = axis_counts[lane.parent_axis]? ||
                        raise(CorruptPartError.new("static QBit nullable domain was not scheduled"))
        grid = grids[lane.role]? || raise(CorruptPartError.new("static QBit nullable map has no inspected mark grid"))
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
        axis = site_axes[site.path]? || raise(CorruptPartError.new("static QBit leaf occurrence axis was not scheduled"))
        expected_rows = axis_counts[axis]? || raise(CorruptPartError.new("static QBit leaf occurrence counts are missing"))
        plane_roles = site.plane_roles
        unless plane_roles.size == site.qbit_type.plane_count
          raise CorruptPartError.new("static QBit leaf plane roster differs from its nominal type")
        end
        plane_roles.each do |role|
          grid = grids[role]? || raise(CorruptPartError.new("static QBit plane has no inspected mark grid"))
          prefix = physical.prefix_size_for(role)
          validate_parent_grid!(grid, role, prefix, parent_rows, mark_count)
          expected_total = 0_u64
          mark_count.times do |mark|
            plane_bytes = checked_multiply(expected_rows[mark], site.qbit_type.plane_width.to_u64)
            require_mark_delta!(grid, mark, plane_bytes, "QBit plane")
            expected_total = checked_add(expected_total, plane_bytes)
          end
          require_lane_logical_size!(grid, role, prefix, expected_total)
        end
      end
      nil
    rescue ex : UnsupportedFormatError
      raise CorruptPartError.new("static QBit physical schedule exceeds configured codec limits")
    end

    private def self.census_size_lane!(
      lane : SizeLane,
      parent_counts : OccurrenceAxis,
      physical : BinaryBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      parent_rows : Array(UInt64),
      mark_count : Int32,
      codec_limits : BinaryCodecLimits,
      transport_budget : CompressedStreamBudget,
      mark_element_totals : Array(UInt64)?,
      mark_wire_totals : Array(UInt64)?,
      axis_counts : Hash(String, OccurrenceAxis),
      shared_totals : BinaryQBitOccurrenceTotals? = nil,
    ) : Nil
      unless parent_counts.size == mark_count
        raise CorruptPartError.new("static QBit size lane parent has the wrong mark domain")
      end
      grid = grids[lane.role]? || raise(CorruptPartError.new("static QBit Array/Map size lane has no inspected mark grid"))
      prefix = physical.prefix_size_for(lane.role)
      validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)

      expected_lane_bytes = 0_u64
      mark_count.times do |mark|
        items = parent_counts[mark]
        expected_bytes = checked_multiply(items, 8_u64)
        require_mark_delta!(grid, mark, expected_bytes, "Array/Map size")
        unless expected_bytes <= Int32::MAX.to_u64
          raise CorruptPartError.new("static QBit size mark exceeds its bounded buffer domain")
        end

        if totals = shared_totals
          totals.add_elements!(mark, items)
          totals.add_wire_bytes!(mark, expected_bytes)
        elsif element_totals = mark_element_totals
          element_limit = codec_limits.max_elements.to_u64
          if element_totals[mark] > element_limit || items > element_limit - element_totals[mark]
            raise CorruptPartError.new("binary codec element limit exceeded")
          end
          element_totals[mark] = checked_add(element_totals[mark], items)
        end
        unless shared_totals
          if wire_totals = mark_wire_totals
            wire_limit = codec_limits.max_bytes.to_u64
            if wire_totals[mark] > wire_limit || expected_bytes > wire_limit - wire_totals[mark]
              raise CorruptPartError.new("binary codec byte limit exceeded")
            end
            wire_totals[mark] = checked_add(wire_totals[mark], expected_bytes)
          end
        end
        expected_lane_bytes = checked_add(expected_lane_bytes, expected_bytes)
      end

      require_lane_logical_size!(grid, lane.role, prefix, expected_lane_bytes)
      transport_budget.preflight_result_bytes(grid.logical_size)
      window = source.read_window(
        physical.data_file_for(lane.role, true),
        physical.marks_file_for(lane.role, true),
        0,
        mark_count,
        prefix,
        transport_budget,
      )
      validate_window_grid!(window, grid, lane.role, prefix, parent_rows, mark_count)

      child_counts = Array(UInt64).new(mark_count, 0_u64)
      bytes = window.bytes
      mark_count.times do |mark|
        start = window.offsets[mark]
        finish = window.offsets[mark + 1]
        expected_bytes = checked_multiply(parent_counts[mark], 8_u64)
        unless finish >= start && finish - start == expected_bytes && finish <= bytes.size.to_u64
          raise CorruptPartError.new("static QBit size mark payload differs from its inspected grid")
        end
        unless start <= Int32::MAX.to_u64 && finish <= Int32::MAX.to_u64
          raise CorruptPartError.new("static QBit size mark exceeds its bounded buffer domain")
        end

        next_items = 0_u64
        offset = start.to_i
        end_offset = finish.to_i
        while offset < end_offset
          next_items = checked_add(next_items, read_u64_le(bytes, offset))
          offset += 8
        end
        child_counts[mark] = next_items
      end
      axis_counts[lane.role] = OccurrenceAxis.new(child_counts)
      nil
    end

    private def self.census_variant_lane!(
      lane : VariantLane,
      parent_counts : OccurrenceAxis,
      physical : BinaryBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      parent_rows : Array(UInt64),
      mark_count : Int32,
      codec_limits : BinaryCodecLimits,
      transport_budget : CompressedStreamBudget,
      mark_element_totals : Array(UInt64)?,
      mark_wire_totals : Array(UInt64)?,
      axis_counts : Hash(String, OccurrenceAxis),
      shared_totals : BinaryQBitOccurrenceTotals? = nil,
    ) : Nil
      unless parent_counts.size == mark_count && lane.arm_count > 0 && lane.arm_count <= 0xff
        raise CorruptPartError.new("static QBit Variant lane has an invalid parent or arm domain")
      end
      grid = grids[lane.role]? || raise(CorruptPartError.new("static QBit Variant discriminator lane has no inspected mark grid"))
      prefix = physical.prefix_size_for(lane.role)
      validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)

      expected_lane_bytes = 0_u64
      mark_count.times do |mark|
        items = parent_counts[mark]
        require_mark_delta!(grid, mark, items, "Variant discriminator")
        unless items <= Int32::MAX.to_u64
          raise CorruptPartError.new("static QBit Variant mark exceeds its bounded buffer domain")
        end

        if totals = shared_totals
          totals.add_elements!(mark, items)
          totals.add_wire_bytes!(mark, items)
        elsif element_totals = mark_element_totals
          element_limit = codec_limits.max_elements.to_u64
          if element_totals[mark] > element_limit || items > element_limit - element_totals[mark]
            raise CorruptPartError.new("binary codec element limit exceeded")
          end
          element_totals[mark] = checked_add(element_totals[mark], items)
        end
        unless shared_totals
          if wire_totals = mark_wire_totals
            wire_limit = codec_limits.max_bytes.to_u64
            if wire_totals[mark] > wire_limit || items > wire_limit - wire_totals[mark]
              raise CorruptPartError.new("binary codec byte limit exceeded")
            end
            wire_totals[mark] = checked_add(wire_totals[mark], items)
          end
        end
        expected_lane_bytes = checked_add(expected_lane_bytes, items)
      end

      require_lane_logical_size!(grid, lane.role, prefix, expected_lane_bytes)
      transport_budget.preflight_result_bytes(grid.logical_size)
      window = source.read_window(
        physical.data_file_for(lane.role, true),
        physical.marks_file_for(lane.role, true),
        0,
        mark_count,
        prefix,
        transport_budget,
      )
      validate_window_grid!(window, grid, lane.role, prefix, parent_rows, mark_count)

      qbit_counts = Hash(Int32, Array(UInt64)).new(initial_capacity: lane.qbit_arms.size)
      lane.qbit_arms.each do |arm|
        if arm.index < 0 || arm.index >= lane.arm_count
          raise CorruptPartError.new("static QBit Variant arm axis is outside its discriminator roster")
        end
        qbit_counts[arm.index] = Array(UInt64).new(mark_count, 0_u64)
      end

      bytes = window.bytes
      mark_count.times do |mark|
        start = window.offsets[mark]
        finish = window.offsets[mark + 1]
        expected_bytes = parent_counts[mark]
        unless finish >= start && finish - start == expected_bytes && finish <= bytes.size.to_u64
          raise CorruptPartError.new("static QBit Variant mark payload differs from its inspected grid")
        end
        unless start <= Int32::MAX.to_u64 && finish <= Int32::MAX.to_u64
          raise CorruptPartError.new("static QBit Variant mark exceeds its bounded buffer domain")
        end

        offset = start.to_i
        end_offset = finish.to_i
        while offset < end_offset
          discriminator = bytes[offset]
          offset += 1
          next if discriminator == 0xff_u8
          arm_index = discriminator.to_i
          if arm_index >= lane.arm_count
            raise CorruptPartError.new("static QBit Variant discriminator is outside its arm roster")
          end
          if counts = qbit_counts[arm_index.to_i32]?
            current = counts[mark]
            if current == UInt64::MAX
              raise CorruptPartError.new("static QBit Variant occurrence count overflows UInt64")
            end
            counts[mark] = current + 1_u64
          end
        end
      end

      lane.qbit_arms.each do |arm|
        counts = qbit_counts[arm.index]? || raise(CorruptPartError.new("static QBit Variant arm counts are missing"))
        axis_counts[arm.path] = OccurrenceAxis.new(counts)
      end
      nil
    end

    private def self.collect_shape!(
      type : BinaryDataType,
      path : String,
      parent_axis : String,
      size_ancestors : Array(String),
      nullable_ancestors : Array(String),
      sites_by_path : Hash(String, BinaryQBitRecursiveAdmission::StaticSite),
      size_lanes : Array(SizeLane),
      size_indexes : Hash(String, Int32),
      nullable_lanes : Array(NullableLane),
      nullable_indexes : Hash(String, Int32),
      variant_lanes : Array(VariantLane),
      variant_indexes : Hash(String, Int32),
      shape_steps : Array(ShapeStep),
      visited_sites : Hash(String, Bool),
      site_axes : Hash(String, String),
    ) : Nil
      return unless type.contains_qbit?

      case type.tag
      when BinaryDataType::TAG_QBIT
        site = sites_by_path[path]? || raise(CorruptPartError.new("static QBit leaf is absent from the planned site roster"))
        unless site.size_roles == size_ancestors && site.nullable_roles == nullable_ancestors
          raise CorruptPartError.new("static QBit leaf shape roles differ from the descriptor path")
        end
        visited_sites[path] = true
        site_axes[String.new(path.to_slice)] = String.new(parent_axis.to_slice)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        role = "#{path}.sizes"
        if add_size_lane!(size_lanes, size_indexes, role, parent_axis)
          shape_steps << ShapeStep.new(SIZE_STEP, size_lanes.size - 1)
        end
        child_sizes = size_ancestors.dup
        child_sizes << role
        collect_shape!(
          type.child_at(0), "#{path}.elements", role, child_sizes,
          nullable_ancestors, sites_by_path, size_lanes, size_indexes,
          nullable_lanes, nullable_indexes, variant_lanes, variant_indexes,
          shape_steps, visited_sites, site_axes,
        )
      when BinaryDataType::TAG_NULLABLE
        role = "#{path}.nulls"
        add_nullable_lane!(nullable_lanes, nullable_indexes, role, parent_axis)
        child_nullables = nullable_ancestors.dup
        child_nullables << role
        collect_shape!(
          type.child_at(0), "#{path}.nested", parent_axis,
          size_ancestors, child_nullables, sites_by_path, size_lanes, size_indexes,
          nullable_lanes, nullable_indexes, variant_lanes, variant_indexes,
          shape_steps, visited_sites, site_axes,
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          collect_shape!(
            child, "#{path}.field.#{index}", parent_axis,
            size_ancestors, nullable_ancestors, sites_by_path, size_lanes,
            size_indexes, nullable_lanes, nullable_indexes, variant_lanes,
            variant_indexes, shape_steps, visited_sites, site_axes,
          )
        end
      when BinaryDataType::TAG_MAP
        role = "#{path}.sizes"
        if add_size_lane!(size_lanes, size_indexes, role, parent_axis)
          shape_steps << ShapeStep.new(SIZE_STEP, size_lanes.size - 1)
        end
        child_sizes = size_ancestors.dup
        child_sizes << role
        key = type.child_at(0)
        value = type.child_at(1)
        if key.contains_qbit?
          collect_shape!(
            key, "#{path}.elements.field.0", role, child_sizes,
            nullable_ancestors, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, variant_lanes, variant_indexes,
            shape_steps, visited_sites, site_axes,
          )
        end
        if value.contains_qbit?
          collect_shape!(
            value, "#{path}.elements.field.1", role, child_sizes,
            nullable_ancestors, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, variant_lanes, variant_indexes,
            shape_steps, visited_sites, site_axes,
          )
        end
      when BinaryDataType::TAG_VARIANT
        role = "#{path}.discriminators"
        qbit_arms = [] of VariantArmAxis
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          qbit_arms << VariantArmAxis.new(index, "#{path}.arm.#{index}")
        end
        if add_variant_lane!(variant_lanes, variant_indexes, role, parent_axis, type.child_count, qbit_arms)
          shape_steps << ShapeStep.new(VARIANT_STEP, variant_lanes.size - 1)
        end
        qbit_arms.each do |arm|
          collect_shape!(
            type.child_at(arm.index), arm.path, arm.path,
            size_ancestors, nullable_ancestors, sites_by_path, size_lanes,
            size_indexes, nullable_lanes, nullable_indexes, variant_lanes,
            variant_indexes, shape_steps, visited_sites, site_axes,
          )
        end
      else
        raise CorruptPartError.new("static QBit site appears under an unsupported descriptor wrapper")
      end
      nil
    end

    private def self.add_size_lane!(
      lanes : Array(SizeLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
    ) : Bool
      if index = indexes[role]?
        unless lanes[index].parent_axis == parent_axis
          raise CorruptPartError.new("static QBit size lane has conflicting parent domains")
        end
        return false
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << SizeLane.new(role, parent_axis)
      true
    end

    private def self.add_nullable_lane!(
      lanes : Array(NullableLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
    ) : Nil
      if index = indexes[role]?
        unless lanes[index].parent_axis == parent_axis
          raise CorruptPartError.new("static QBit nullable map has conflicting parent domains")
        end
        return nil
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << NullableLane.new(role, parent_axis)
      nil
    end

    private def self.add_variant_lane!(
      lanes : Array(VariantLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_axis : String,
      arm_count : Int,
      qbit_arms : Array(VariantArmAxis),
    ) : Bool
      if index = indexes[role]?
        existing = lanes[index]
        unless existing.parent_axis == parent_axis && existing.arm_count == arm_count &&
               existing.qbit_arms.map(&.path) == qbit_arms.map(&.path)
          raise CorruptPartError.new("static QBit Variant lane has conflicting parent or arm axes")
        end
        return false
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << VariantLane.new(role, parent_axis, arm_count, qbit_arms)
      true
    end

    private def self.validate_parent_grid!(
      grid : CompressedMarkGrid,
      role : String,
      prefix : Int32,
      parent_rows : Array(UInt64),
      mark_count : Int32,
    ) : Nil
      unless grid.mark_count == mark_count && grid.prefix_size == prefix
        raise CorruptPartError.new("static QBit lane #{role} differs from its inspected mark domain")
      end
      mark_count.times do |mark|
        unless grid.row_count_at(mark) == parent_rows[mark]
          raise CorruptPartError.new("static QBit lane #{role} differs from the parent row grid")
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
        raise CorruptPartError.new("static QBit size window #{role} differs from its inspected grid")
      end
      offsets = window.offsets
      unless offsets.size == mark_count + 1
        raise CorruptPartError.new("static QBit size window #{role} has the wrong offset count")
      end
      first_position = grid.position_at(0)
      (0..mark_count).each do |index|
        position = grid.position_at(index)
        unless position >= first_position
          raise CorruptPartError.new("static QBit size grid #{role} precedes its prefix")
        end
        expected_offset = checked_add(prefix.to_u64, (position - first_position).to_u64)
        unless offsets[index] == expected_offset
          raise CorruptPartError.new("static QBit size window #{role} offsets differ from its inspected grid")
        end
      end
      unless window.bytes.size.to_u64 == grid.logical_size.to_u64
        raise CorruptPartError.new("static QBit size window #{role} differs from its inspected logical size")
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
        raise CorruptPartError.new("static QBit prefix exceeds lane #{role}")
      end
      unless (grid.logical_size - prefix.to_i64).to_u64 == payload_bytes
        raise CorruptPartError.new("static QBit lane #{role} logical size differs from its occurrence schedule")
      end
      if grid.logical_size > Int32::MAX
        raise CorruptPartError.new("static QBit lane #{role} exceeds its bounded result domain")
      end
      nil
    end

    private def self.require_mark_delta!(
      grid : CompressedMarkGrid,
      mark : Int,
      expected : UInt64,
      label : String,
    ) : Nil
      if mark < 0 || mark >= grid.mark_count
        raise CorruptPartError.new("static QBit #{label} mark is outside its inspected grid")
      end
      delta = grid.position_at(mark + 1) - grid.position_at(mark)
      unless delta >= 0 && delta.to_u64 == expected
        raise CorruptPartError.new("static QBit #{label} mark differs from its size-derived occurrence schedule")
      end
      nil
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("static QBit size value is truncated")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("static QBit occurrence count overflows UInt64")
      end
      left + right
    end

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("static QBit physical schedule size overflows UInt64")
      end
      left * right
    end
  end
end
