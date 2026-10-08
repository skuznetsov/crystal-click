module CrystalClick
  # Full-mark, size-only consistency check for one admitted static
  # Array^n(QBit/Nullable(QBit)) physical site. It authenticates no QBit plane
  # payload; it proves that every mark's lane geometry agrees with the values
  # in its bounded Array size buffers before a reader exposes any window.
  module BinaryQBitArrayOccurrenceSchedule
    def self.validate!(
      site : BinaryQBitRecursiveAdmission::StaticArraySite,
      physical : BinaryBulkPhysicalPlan,
      source : PartStreamSource,
      grids : Hash(String, CompressedMarkGrid),
      parent_rows : Array(UInt64),
      codec_limits : BinaryCodecLimits,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      size_roles = site.array_size_roles
      plane_roles = site.plane_roles
      unless !size_roles.empty? && plane_roles.size == site.qbit_type.plane_count
        raise CorruptPartError.new("recursive QBit physical schedule is incomplete")
      end

      mark_count = parent_rows.size
      if mark_count == 0 || mark_count > WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("recursive QBit schedule mark count is outside its bounded domain")
      end

      # The lane-major schedule keeps three UInt64 vectors per mark: current
      # occurrences and per-mark element/wire totals accumulated across Array
      # depths. Preflight their complete workspace before creating the arrays.
      schedule_workspace_bytes = checked_multiply(mark_count.to_u64, 24_u64)
      unless schedule_workspace_bytes <= codec_limits.max_bytes.to_u64
        raise CorruptPartError.new("recursive QBit schedule workspace exceeds the configured byte limit")
      end

      expected_items = parent_rows.dup
      mark_element_totals = Array(UInt64).new(mark_count, 0_u64)
      mark_wire_totals = Array(UInt64).new(mark_count, 0_u64)
      # Reuse the reader's transport budget so the complete schedule pass stays
      # within the same aggregate cap already consumed by grid inspection.
      # Each lane is read once for all marks; the complete returned lane is
      # bounded by the remaining max_result_bytes and Int32 domain before
      # read_window allocates.

      size_roles.each do |role|
        grid = grids[role]? || raise(CorruptPartError.new("recursive QBit Array size lane has no inspected mark grid"))
        prefix = physical.prefix_size_for(role)
        unless grid.mark_count == mark_count && grid.prefix_size == prefix
          raise CorruptPartError.new("recursive QBit Array size lane differs from its inspected mark domain")
        end

        expected_lane_bytes = 0_u64
        mark_count.times do |mark|
          unless grid.row_count_at(mark) == parent_rows[mark]
            raise CorruptPartError.new("recursive QBit Array size lane differs from the parent row grid")
          end

          items = expected_items[mark]
          expected_bytes = checked_multiply(items, 8_u64)
          require_mark_delta!(grid, mark, expected_bytes, "Array size")
          unless expected_bytes <= Int32::MAX.to_u64
            raise CorruptPartError.new("recursive QBit Array size mark exceeds its bounded buffer domain")
          end

          element_limit = codec_limits.max_elements.to_u64
          wire_limit = codec_limits.max_bytes.to_u64
          if mark_element_totals[mark] > element_limit || items > element_limit - mark_element_totals[mark]
            raise CorruptPartError.new("binary codec element limit exceeded")
          end
          if mark_wire_totals[mark] > wire_limit || expected_bytes > wire_limit - mark_wire_totals[mark]
            raise CorruptPartError.new("binary codec byte limit exceeded")
          end
          mark_element_totals[mark] = checked_add(mark_element_totals[mark], items)
          mark_wire_totals[mark] = checked_add(mark_wire_totals[mark], expected_bytes)
          expected_lane_bytes = checked_add(expected_lane_bytes, expected_bytes)
        end

        if grid.logical_size < prefix.to_i64
          raise CorruptPartError.new("recursive QBit Array size prefix exceeds its logical lane")
        end
        unless (grid.logical_size - prefix.to_i64).to_u64 == expected_lane_bytes
          raise CorruptPartError.new("recursive QBit Array size lane total differs from its mark schedule")
        end
        if grid.logical_size > Int32::MAX
          raise CorruptPartError.new("recursive QBit Array size lane exceeds its bounded result domain")
        end
        transport_budget.preflight_result_bytes(grid.logical_size)

        window = source.read_window(
          physical.data_file_for(role, true),
          physical.marks_file_for(role, true),
          0,
          mark_count,
          prefix,
          transport_budget,
        )
        unless window.first_mark == 0 && window.prefix_size == prefix && window.rows_per_mark == parent_rows
          raise CorruptPartError.new("recursive QBit Array size window differs from its inspected parent grid")
        end

        offsets = window.offsets
        unless offsets.size == mark_count + 1
          raise CorruptPartError.new("recursive QBit Array size window has the wrong offset count")
        end
        first_position = grid.position_at(0)
        (0..mark_count).each do |index|
          position = grid.position_at(index)
          unless position >= first_position
            raise CorruptPartError.new("recursive QBit Array size grid position precedes its prefix")
          end
          expected_offset = checked_add(prefix.to_u64, (position - first_position).to_u64)
          unless offsets[index] == expected_offset
            raise CorruptPartError.new("recursive QBit Array size window offsets differ from its inspected grid")
          end
        end

        bytes = window.bytes
        unless bytes.size.to_u64 == grid.logical_size.to_u64
          raise CorruptPartError.new("recursive QBit Array size window differs from its inspected logical size")
        end
        mark_count.times do |mark|
          start = offsets[mark]
          finish = offsets[mark + 1]
          expected_bytes = checked_multiply(expected_items[mark], 8_u64)
          unless finish >= start && finish - start == expected_bytes && finish <= bytes.size.to_u64
            raise CorruptPartError.new("recursive QBit Array size mark payload differs from its inspected grid")
          end
          unless start <= Int32::MAX.to_u64 && finish <= Int32::MAX.to_u64
            raise CorruptPartError.new("recursive QBit Array size mark exceeds its bounded buffer domain")
          end

          next_items = 0_u64
          offset = start.to_i
          end_offset = finish.to_i
          while offset < end_offset
            count = read_u64_le(bytes, offset)
            next_items = checked_add(next_items, count)
            offset += 8
          end
          expected_items[mark] = next_items
        end
      end

      plane_roles.each do |role|
        grid = grids[role]? || raise(CorruptPartError.new("recursive QBit plane has no inspected mark grid"))
        mark_count.times do |mark|
          plane_bytes = checked_multiply(expected_items[mark], site.qbit_type.plane_width.to_u64)
          require_mark_delta!(grid, mark, plane_bytes, "QBit plane")
        end
      end
      if null_role = site.nullable_role?
        grid = grids[null_role]? || raise(CorruptPartError.new("recursive QBit null map has no inspected mark grid"))
        mark_count.times do |mark|
          require_mark_delta!(grid, mark, expected_items[mark], "QBit null map")
        end
      end
      nil
    rescue ex : UnsupportedFormatError
      raise CorruptPartError.new("recursive QBit physical schedule exceeds configured codec limits")
    end

    # Selected in-memory windows use this same site's exact plane/null roles
    # for a materialization preflight. Full physical shape closure is supplied
    # by validate! during BinaryBulkColumnReader.open.
    def self.selected_occurrences(
      site : BinaryQBitRecursiveAdmission::StaticArraySite,
      streams : BinaryBulkStreams,
      first_mark : Int,
      mark_count : Int,
    ) : UInt64
      roles = site.plane_roles
      width = site.qbit_type.plane_width.to_u64
      total = 0_u64
      mark_count.times do |offset|
        mark = first_mark + offset
        expected_bytes = nil.as(UInt64?)
        roles.each do |role|
          unless streams.has_role?(role)
            raise CorruptPartError.new("recursive QBit selected plane is missing")
          end
          stream = streams.stream(role)
          delta = stream.offset_at(mark + 1) - stream.offset_at(mark)
          if prior = expected_bytes
            unless delta == prior
              raise CorruptPartError.new("recursive QBit selected planes disagree on their occurrence grid")
            end
          else
            expected_bytes = delta
          end
        end
        bytes = expected_bytes || raise(CorruptPartError.new("recursive QBit site has no plane roles"))
        unless bytes % width == 0_u64
          raise CorruptPartError.new("recursive QBit selected plane width is malformed")
        end
        occurrences = bytes // width
        if null_role = site.nullable_role?
          unless streams.has_role?(null_role)
            raise CorruptPartError.new("recursive QBit selected null map is missing")
          end
          nulls = streams.stream(null_role)
          null_bytes = nulls.offset_at(mark + 1) - nulls.offset_at(mark)
          unless null_bytes == occurrences
            raise CorruptPartError.new("recursive QBit selected null map differs from its occurrence grid")
          end
        end
        total = checked_add(total, occurrences)
      end
      total
    end

    private def self.require_mark_delta!(
      grid : CompressedMarkGrid,
      mark : Int,
      expected : UInt64,
      label : String,
    ) : Nil
      if mark < 0 || mark >= grid.mark_count
        raise CorruptPartError.new("recursive QBit #{label} mark is outside its inspected grid")
      end
      delta = grid.position_at(mark + 1) - grid.position_at(mark)
      unless delta >= 0 && delta.to_u64 == expected
        raise CorruptPartError.new("recursive QBit #{label} mark differs from its size-derived occurrence schedule")
      end
      nil
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("recursive QBit Array size value is truncated")
      end
      value = 0_u64
      8.times do |index|
        value |= bytes[offset + index].to_u64 << (index * 8)
      end
      value
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("recursive QBit occurrence count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("recursive QBit physical schedule size overflows UInt64")
      end
      left * right
    end
  end
end
