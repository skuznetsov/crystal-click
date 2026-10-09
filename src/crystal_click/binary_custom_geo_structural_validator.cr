module CrystalClick
  # Full-part non-materializing census for the admitted plain static Custom
  # Geo profile. It validates every physical role/mark before a reader can be
  # published, without retaining BinaryValue trees.
  module BinaryCustomGeoStructuralValidator
    def self.validate!(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      physical : BinaryBulkPhysicalPlan,
      source : PartStreamSource,
      role_names : Hash(String, String),
      grids : Hash(String, CompressedMarkGrid),
      rows_per_mark : Array(UInt64),
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      unless type.contains_custom_geo?
        raise ArgumentError.new("Custom Geo structural census requires a nominal Custom Geo descendant")
      end
      unless !codec_budget.writing? && codec_budget.limits.max_depth == limits.max_depth &&
             codec_budget.limits.max_nodes == limits.max_nodes &&
             codec_budget.limits.max_elements == limits.max_elements &&
             codec_budget.limits.max_bytes == limits.max_bytes
        raise ArgumentError.new("Custom Geo structural census codec budget does not match its caller")
      end
      transport_budget.ensure_direction(false)

      plan = BinaryBulkTypePlan.new(type, profile, nil, limits, false)
      role_count = plan.role_count
      unless role_count == role_names.size.to_u64 && role_names.size == grids.size
        raise CorruptPartError.new("Custom Geo physical role roster differs from its static plan")
      end
      role_names.each_key do |role|
        unless grids.has_key?(role)
          raise CorruptPartError.new("Custom Geo physical role has no inspected mark grid")
        end
      end
      unless !rows_per_mark.empty? && rows_per_mark.size <= WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("Custom Geo structural census mark domain is outside the admitted range")
      end
      rows_per_mark.each do |count|
        unless count > 0_u64 && count <= Int32::MAX.to_u64
          raise CorruptPartError.new("Custom Geo parent mark row count is outside the supported domain")
        end
      end

      traversal = BinaryCodecContext.new(limits, nil, false, codec_budget, false, false)
      traversal.validate_type_tree(type)

      # Mirror the decoder's whole-grid metadata accounting, then preflight
      # the bounded per-mark windows and context roster before any decompressed
      # lane window is requested. A one-mark window returns two offsets and one
      # row entry; the reader, window owner, and accessors each own a copy.
      # These are cumulative logical allocation records, not RSS estimates.
      mark_records = rows_per_mark.size.to_u64
      offsets_per_role = checked_add(mark_records, 1_u64)
      grid_records = checked_multiply(role_count, offsets_per_role)
      census_records = checked_add(grid_records, mark_records)
      traversal.preflight_children(census_records)
      census_records.times { codec_budget.charge_node }

      window_records_per_mark = 9_u64 # 3 copies * (2 offsets + 1 row)
      copied_window_records = checked_multiply(
        checked_multiply(mark_records, window_records_per_mark), role_count
      )
      context_records = checked_multiply(mark_records, role_count)
      scratch_records = checked_add(copied_window_records, context_records)
      traversal.charge_elements(scratch_records)

      total_rows = 0_u64
      rows_per_mark.each do |count|
        total_rows = checked_add(total_rows, count)
      end
      # Do not decompress or allocate lane windows for a root row lower bound
      # that cannot fit the same caller-owned value/node budget.
      traversal.ensure_future_nodes(total_rows)

      total_result_bytes = 0_u64
      role_names.each_key do |role|
        grid = grids[role]
        unless grid.mark_count == rows_per_mark.size && grid.rows_per_mark == rows_per_mark
          raise CorruptPartError.new("Custom Geo physical lanes disagree on the complete parent mark grid")
        end
        prefix = physical.prefix_size_for(role)
        unless grid.prefix_size == prefix
          raise CorruptPartError.new("Custom Geo physical lane prefix differs from its inspected mark grid")
        end
        # read_window returns the physical prefix with every one-mark result.
        # It is already validated by the reader's initial prefix inspection;
        # include the repeated copied bytes in this total, but do not charge
        # normalized coordinate arrays that this census does not construct.
        repeated_prefix_bytes = checked_multiply(prefix.to_u64, mark_records - 1_u64)
        lane_result_bytes = checked_add(grid.logical_size.to_u64, repeated_prefix_bytes)
        total_result_bytes = checked_add(total_result_bytes, lane_result_bytes)
      end

      # Open-time prefix inspection is budgeted separately. The current
      # read_window API re-resolves, reparses, and re-indexes the
      # complete paired files for every call. Repeating one-mark windows can
      # therefore consume transport file/record/decode budgets sooner than a
      # single full-lane read; keep the shared budget and fail closed rather
      # than resetting it. The session/index reuse needed for larger parts is
      # intentionally outside this slice.
      codec_budget.ensure_wire_bytes(total_result_bytes)
      codec_budget.charge_wire_bytes(total_result_bytes)
      if total_result_bytes > Int64::MAX.to_u64
        raise CorruptPartError.new("Custom Geo aggregate lane result exceeds the transport accounting domain")
      end
      transport_budget.preflight_result_bytes(total_result_bytes.to_i64)

      rows_per_mark.each_with_index do |row_count, mark_index|
        contexts = Hash(String, BinaryCodecContext).new(initial_capacity: role_names.size)
        role_names.keys.sort!.each do |role|
          grid = grids[role]
          prefix = physical.prefix_size_for(role)
          window = source.read_window(
            physical.data_file_for(role, true),
            physical.marks_file_for(role, true),
            mark_index,
            1,
            prefix,
            transport_budget,
          )
          unless window.first_mark == mark_index && window.prefix_size == prefix
            raise CorruptPartError.new("Custom Geo mark window does not match its physical prefix binding")
          end

          offsets = window.offsets
          observed_rows = window.rows_per_mark
          unless offsets.size == 2 && observed_rows.size == 1 && observed_rows[0] == row_count
            raise CorruptPartError.new("Custom Geo mark window differs from its inspected parent row grid")
          end
          start = prefix.to_u64
          body_size = (grid.position_at(mark_index + 1) - grid.position_at(mark_index)).to_u64
          finish = checked_add(start, body_size)
          unless offsets[0] == start && offsets[1] == finish
            raise CorruptPartError.new("Custom Geo mark window coordinates differ from the inspected grid")
          end

          bytes = window.bytes
          unless finish == bytes.size.to_u64 && finish >= start && finish <= Int32::MAX.to_u64
            raise CorruptPartError.new("Custom Geo mark byte range is outside its lane window")
          end
          input = bytes[start.to_i32, (finish - start).to_i32]
          contexts[role] = BinaryCodecContext.new(limits, input, false, codec_budget, false, false)
        end

        traversal.ensure_future_nodes(row_count)
        traversal.ensure_depth(1)
        row_count.times do
          scan_value(type, "root", 1, contexts, profile, traversal)
        end
        contexts.each_value(&.ensure_consumed)
      end
      nil
    end

    private def self.scan_value(
      type : BinaryDataType,
      path : String,
      depth : Int,
      contexts : Hash(String, BinaryCodecContext),
      profile : BinaryBulkProfile,
      traversal : BinaryCodecContext,
    ) : Nil
      traversal.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_CUSTOM
        traversal.preflight_children(1_u64)
        traversal.ensure_depth(depth + 1)
        scan_value(type.child_at(0), path, depth + 1, contexts, profile, traversal)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        raw_count = read_u64(context_for(contexts, "#{path}.sizes"))
        checked_collection_count(raw_count, "Array element count")
        if raw_count > 0_u64
          traversal.preflight_children(raw_count)
          traversal.ensure_depth(depth + 1)
          child_path = "#{path}.elements"
          child_type = type.child_at(0)
          raw_count.times { scan_value(child_type, child_path, depth + 1, contexts, profile, traversal) }
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        if count == 0
          byte = context_for(contexts, "#{path}.data").read_byte
          unless byte == 0x30_u8
            raise CorruptPartError.new("empty Tuple bulk placeholder is not canonical ASCII zero")
          end
        else
          traversal.preflight_children(count.to_u64)
          traversal.ensure_depth(depth + 1)
          count.times do |index|
            scan_value(
              type.child_at(index),
              "#{path}.field.#{index}",
              depth + 1,
              contexts,
              profile,
              traversal,
            )
          end
        end
      when BinaryDataType::TAG_MAP
        pair_count = read_u64(context_for(contexts, "#{path}.sizes"))
        if pair_count > UInt64::MAX // 2_u64
          raise CorruptPartError.new("Map pair count overflows its flat element count")
        end
        flat_count = pair_count * 2_u64
        checked_collection_count(flat_count, "Map value count")
        if flat_count > 0_u64
          traversal.preflight_children(flat_count)
          traversal.ensure_depth(depth + 1)
          key_path = "#{path}.elements.field.0"
          value_path = "#{path}.elements.field.1"
          key_type = type.child_at(0)
          value_type = type.child_at(1)
          pair_count.times do
            scan_value(key_type, key_path, depth + 1, contexts, profile, traversal)
            scan_value(value_type, value_path, depth + 1, contexts, profile, traversal)
          end
        end
      when BinaryDataType::TAG_NULLABLE
        flag = context_for(contexts, "#{path}.nulls").read_byte
        unless flag == 0_u8 || flag == 1_u8
          raise CorruptPartError.new("Nullable bulk null-map flag must be zero or one")
        end
        child_type = type.child_at(0)
        traversal.preflight_children(1_u64)
        traversal.ensure_depth(depth + 1)
        scan_value(child_type, "#{path}.nested", depth + 1, contexts, profile, traversal)
        if flag == 0_u8 && child_type.tag == BinaryDataType::TAG_NOTHING
          raise CorruptPartError.new("Nullable(Nothing) cannot contain a non-NULL Nothing value")
        end
      when BinaryDataType::TAG_VARIANT
        discriminator = context_for(contexts, "#{path}.discriminators").read_byte
        unless discriminator == 0xff_u8
          index = discriminator.to_i
          if index >= type.child_count
            raise CorruptPartError.new("Variant bulk discriminator is outside its arm roster")
          end
          traversal.preflight_children(1_u64)
          traversal.ensure_depth(depth + 1)
          scan_value(
            type.child_at(index),
            "#{path}.arm.#{index}",
            depth + 1,
            contexts,
            profile,
            traversal,
          )
        end
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          size = read_u64(context_for(contexts, "#{path}.string_sizes"))
          context_for(contexts, "#{path}.data").read_slice(size)
        else
          context = context_for(contexts, "#{path}.data")
          context.read_slice(context.read_var_uint)
        end
      when BinaryDataType::TAG_BOOL
        value = context_for(contexts, "#{path}.data").read_byte
        unless value == 0_u8 || value == 1_u8
          raise CorruptPartError.new("Bool bulk value must be zero or one")
        end
      when BinaryDataType::TAG_NOTHING
        value = context_for(contexts, "#{path}.data").read_byte
        unless value == 0x30_u8
          raise CorruptPartError.new("Nothing bulk placeholder is not canonical ASCII zero")
        end
      else
        width = type.fixed_width || raise(UnsupportedFormatError.new("unsupported Custom Geo bulk leaf"))
        context_for(contexts, "#{path}.data").read_slice(width.to_u64)
      end
      nil
    end

    private def self.context_for(
      contexts : Hash(String, BinaryCodecContext),
      role : String,
    ) : BinaryCodecContext
      contexts[role]? || raise(CorruptPartError.new("Custom Geo value addresses an unplanned physical role"))
    end

    private def self.read_u64(context : BinaryCodecContext) : UInt64
      raw = context.read_slice(8_u64)
      value = 0_u64
      8.times do |index|
        value |= raw[index].to_u64 << (index * 8)
      end
      value
    end

    private def self.checked_collection_count(count : UInt64, label : String) : Int32
      if count > Int32::MAX.to_u64
        raise CorruptPartError.new("#{label} exceeds its supported in-memory domain")
      end
      count.to_i32
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Custom Geo structural census size overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Custom Geo structural census size overflows UInt64")
      end
      left * right
    end
  end
end
