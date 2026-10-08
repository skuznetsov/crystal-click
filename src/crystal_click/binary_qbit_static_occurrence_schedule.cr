module CrystalClick
  # Complete shape-only census for every QBit leaf in an admitted static
  # product tree. Unique Array/Map size lanes are replayed once in parent-first
  # order; QBit plane payload remains unread until a selected value window.
  module BinaryQBitStaticOccurrenceSchedule
    private struct SizeLane
      getter role : String
      getter parent_role : String?

      def initialize(role : String, parent_role : String?)
        @role = String.new(role.to_slice)
        @parent_role = parent_role.try { |value| String.new(value.to_slice) }
      end
    end

    private struct NullableLane
      getter role : String
      getter parent_role : String?

      def initialize(role : String, parent_role : String?)
        @role = String.new(role.to_slice)
        @parent_role = parent_role.try { |value| String.new(value.to_slice) }
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
    ) : Nil
      unless type.contains_qbit? && !sites.empty?
        raise CorruptPartError.new("static QBit schedule has no admitted leaf sites")
      end

      # This entry point is also called directly by tests and other bounded
      # readers, so do not assume a plan already validated the recursive type
      # tree before the shape walk below allocates its role vectors.
      BinaryCodecContext.new(codec_limits, nil, false).validate_type_tree(type)

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
      visited_sites = Hash(String, Bool).new(initial_capacity: sites.size)
      collect_shape!(
        type,
        "root",
        nil,
        [] of String,
        [] of String,
        sites_by_path,
        size_lanes,
        size_indexes,
        nullable_lanes,
        nullable_indexes,
        visited_sites,
      )
      unless visited_sites.size == sites_by_path.size
        raise CorruptPartError.new("static QBit schedule omits a planned leaf site")
      end

      # The retained child-count vector for each unique size lane plus two
      # shared per-mark codec accumulators form the known schedule workspace.
      # Reject from scalar dimensions before allocating any of those arrays or
      # reading a size lane.
      if !size_lanes.empty?
        vector_count = size_lanes.size.to_u64
        if vector_count > UInt64::MAX - 2_u64
          raise CorruptPartError.new("static QBit schedule workspace size overflows")
        end
        schedule_workspace_bytes = checked_multiply(
          checked_multiply(mark_count.to_u64, vector_count + 2_u64),
          8_u64,
        )
        unless schedule_workspace_bytes <= codec_limits.max_bytes.to_u64
          raise CorruptPartError.new("static QBit schedule workspace exceeds the configured byte limit")
        end
      end

      size_counts = Hash(String, Array(UInt64)).new(initial_capacity: size_lanes.size)
      mark_element_totals = size_lanes.empty? ? nil : Array(UInt64).new(mark_count, 0_u64)
      mark_wire_totals = size_lanes.empty? ? nil : Array(UInt64).new(mark_count, 0_u64)

      size_lanes.each do |lane|
        item_counts = if parent_role = lane.parent_role
                        size_counts[parent_role]? || raise(CorruptPartError.new("static QBit size lane parent was not scheduled first"))
                      else
                        parent_rows
                      end
        grid = grids[lane.role]? || raise(CorruptPartError.new("static QBit Array/Map size lane has no inspected mark grid"))
        prefix = physical.prefix_size_for(lane.role)
        validate_parent_grid!(grid, lane.role, prefix, parent_rows, mark_count)

        expected_lane_bytes = 0_u64
        mark_count.times do |mark|
          items = item_counts[mark]
          expected_bytes = checked_multiply(items, 8_u64)
          require_mark_delta!(grid, mark, expected_bytes, "Array/Map size")
          unless expected_bytes <= Int32::MAX.to_u64
            raise CorruptPartError.new("static QBit size mark exceeds its bounded buffer domain")
          end

          if element_totals = mark_element_totals
            element_limit = codec_limits.max_elements.to_u64
            if element_totals[mark] > element_limit || items > element_limit - element_totals[mark]
              raise CorruptPartError.new("binary codec element limit exceeded")
            end
            element_totals[mark] = checked_add(element_totals[mark], items)
          end
          if wire_totals = mark_wire_totals
            wire_limit = codec_limits.max_bytes.to_u64
            if wire_totals[mark] > wire_limit || expected_bytes > wire_limit - wire_totals[mark]
              raise CorruptPartError.new("binary codec byte limit exceeded")
            end
            wire_totals[mark] = checked_add(wire_totals[mark], expected_bytes)
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
          expected_bytes = checked_multiply(item_counts[mark], 8_u64)
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
        size_counts[lane.role] = child_counts
      end

      nullable_lanes.each do |lane|
        expected_rows = if parent_role = lane.parent_role
                          size_counts[parent_role]? || raise(CorruptPartError.new("static QBit nullable domain size lane was not scheduled"))
                        else
                          parent_rows
                        end
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
        expected_rows = if role = site.size_roles.last?
                          size_counts[role]? || raise(CorruptPartError.new("static QBit leaf size lane was not scheduled"))
                        else
                          parent_rows
                        end
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

    private def self.collect_shape!(
      type : BinaryDataType,
      path : String,
      parent_size_role : String?,
      size_ancestors : Array(String),
      nullable_ancestors : Array(String),
      sites_by_path : Hash(String, BinaryQBitRecursiveAdmission::StaticSite),
      size_lanes : Array(SizeLane),
      size_indexes : Hash(String, Int32),
      nullable_lanes : Array(NullableLane),
      nullable_indexes : Hash(String, Int32),
      visited_sites : Hash(String, Bool),
    ) : Nil
      return unless type.contains_qbit?

      case type.tag
      when BinaryDataType::TAG_QBIT
        site = sites_by_path[path]? || raise(CorruptPartError.new("static QBit leaf is absent from the planned site roster"))
        unless site.size_roles == size_ancestors && site.nullable_roles == nullable_ancestors
          raise CorruptPartError.new("static QBit leaf shape roles differ from the descriptor path")
        end
        visited_sites[path] = true
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        role = "#{path}.sizes"
        add_size_lane!(size_lanes, size_indexes, role, parent_size_role)
        child_sizes = size_ancestors.dup
        child_sizes << role
        collect_shape!(
          type.child_at(0), "#{path}.elements", role, child_sizes,
          nullable_ancestors, sites_by_path, size_lanes, size_indexes,
          nullable_lanes, nullable_indexes, visited_sites,
        )
      when BinaryDataType::TAG_NULLABLE
        role = "#{path}.nulls"
        add_nullable_lane!(nullable_lanes, nullable_indexes, role, parent_size_role)
        child_nullables = nullable_ancestors.dup
        child_nullables << role
        collect_shape!(
          type.child_at(0), "#{path}.nested", parent_size_role, size_ancestors,
          child_nullables, sites_by_path, size_lanes, size_indexes,
          nullable_lanes, nullable_indexes, visited_sites,
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          collect_shape!(
            child, "#{path}.field.#{index}", parent_size_role,
            size_ancestors, nullable_ancestors, sites_by_path,
            size_lanes, size_indexes, nullable_lanes, nullable_indexes,
            visited_sites,
          )
        end
      when BinaryDataType::TAG_MAP
        role = "#{path}.sizes"
        add_size_lane!(size_lanes, size_indexes, role, parent_size_role)
        child_sizes = size_ancestors.dup
        child_sizes << role
        key = type.child_at(0)
        value = type.child_at(1)
        if key.contains_qbit?
          collect_shape!(
            key, "#{path}.elements.field.0", role, child_sizes,
            nullable_ancestors, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, visited_sites,
          )
        end
        if value.contains_qbit?
          collect_shape!(
            value, "#{path}.elements.field.1", role, child_sizes,
            nullable_ancestors, sites_by_path, size_lanes, size_indexes,
            nullable_lanes, nullable_indexes, visited_sites,
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
      parent_role : String?,
    ) : Nil
      if index = indexes[role]?
        unless lanes[index].parent_role == parent_role
          raise CorruptPartError.new("static QBit size lane has conflicting parent domains")
        end
        return nil
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << SizeLane.new(role, parent_role)
      nil
    end

    private def self.add_nullable_lane!(
      lanes : Array(NullableLane),
      indexes : Hash(String, Int32),
      role : String,
      parent_role : String?,
    ) : Nil
      if index = indexes[role]?
        unless lanes[index].parent_role == parent_role
          raise CorruptPartError.new("static QBit nullable map has conflicting parent domains")
        end
        return nil
      end
      indexes[String.new(role.to_slice)] = lanes.size.to_i32
      lanes << NullableLane.new(role, parent_role)
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

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("static QBit physical schedule size overflows UInt64")
      end
      left * right
    end
  end
end
