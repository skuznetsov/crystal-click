module CrystalClick
  # Builds full-mark LC occurrence schedules from the structural lanes that
  # route flattened children. Each planned grid is budgeted before allocation;
  # discriminator bytes are validated even when they select a non-LC arm.
  module BinaryBulkLowCardinalityOccurrenceSchedule
    def self.build(
      type : BinaryDataType,
      shape_roles : Array(String),
      schedule_grid_count : UInt64,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Hash(String, Array(UInt64))
      unless rows_per_mark.size == streams.mark_count
        corrupt!("binary bulk occurrence schedule does not match its mark domain")
      end

      # Schedule metadata depends on structural routing, not the String
      # profile. Recompute it rather than trusting the direct caller: an
      # understated grid count or missing shape role must fail before census
      # allocation or any budget charge, not only at the post-census check.
      plan = BinaryBulkTypePlan.new(type, BinaryBulkProfile.single_stream)
      unless schedule_grid_count == plan.low_cardinality_schedule_grid_count &&
             shape_roles.sort == plan.low_cardinality_shape_roles
        corrupt!("binary bulk occurrence metadata differs from its descriptor plan")
      end

      cells = checked_multiply(rows_per_mark.size.to_u64, schedule_grid_count)
      shape_bytes = preflight_shape_lanes(shape_roles, streams, rows_per_mark.size)

      # All limits are checked before charging or allocating per-grid arrays.
      budget.ensure_future_nodes(cells)
      budget.ensure_future_elements(cells)
      budget.ensure_wire_bytes(shape_bytes)
      budget.charge_elements(cells)
      cells.times { budget.charge_node }
      budget.charge_wire_bytes(shape_bytes)

      occurrences = Hash(String, Array(UInt64)).new
      used_shape_roles = [] of String
      created_grids = census_type(type, "root", rows_per_mark, streams, budget, occurrences, used_shape_roles, 0_u64)

      unless created_grids == schedule_grid_count
        corrupt!("binary bulk occurrence census did not create its planned schedule grids")
      end
      used_shape_roles.sort!
      unless used_shape_roles == shape_roles.sort
        corrupt!("binary bulk occurrence census did not consume its planned shape lanes")
      end
      occurrences
    end

    private def self.preflight_shape_lanes(
      shape_roles : Array(String),
      streams : BinaryBulkStreams,
      expected_marks : Int,
    ) : UInt64
      expected_roles = shape_roles.sort
      index = 1
      while index < expected_roles.size
        if expected_roles[index - 1] == expected_roles[index]
          corrupt!("binary bulk occurrence shape roles are not unique")
        end
        index += 1
      end

      total = 0_u64
      shape_roles.each do |role|
        unless streams.has_role?(role)
          corrupt!("binary bulk occurrence shape lane is missing")
        end
        lane = streams.stream(role)
        validate_shape_grid(lane, expected_marks)
        total = checked_add(total, lane.byte_size.to_u64)
      end
      total
    end

    private def self.validate_shape_grid(stream : BinaryBulkStream, expected_marks : Int) : Nil
      unless stream.mark_count == expected_marks && stream.offset_count == expected_marks + 1
        corrupt!("binary bulk occurrence shape lane has an invalid mark grid")
      end
      unless stream.offset_at(0) == 0_u64
        corrupt!("binary bulk occurrence shape lane does not begin at offset zero")
      end

      previous = 0_u64
      mark = 0
      while mark < expected_marks
        current = stream.offset_at(mark + 1)
        if current < previous || current > stream.byte_size.to_u64
          corrupt!("binary bulk occurrence shape offsets are outside their lane")
        end
        previous = current
        mark += 1
      end
      unless previous == stream.byte_size.to_u64
        corrupt!("binary bulk occurrence shape lane has trailing bytes")
      end
      nil
    end

    private def self.census_type(
      type : BinaryDataType,
      path : String,
      counts : Array(UInt64),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
      occurrences : Hash(String, Array(UInt64)),
      used_shape_roles : Array(String),
      created_grids : UInt64,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        occurrences[path] = counts
        created_grids
      when BinaryDataType::TAG_ARRAY
        child_type = type.child_at(0)
        return created_grids unless child_type.contains_low_cardinality?
        role = "#{path}.sizes"
        used_shape_roles << role
        child_counts = array_child_counts(role, counts, streams, budget)
        census_type(child_type, "#{path}.elements", child_counts, streams, budget, occurrences, used_shape_roles, checked_add(created_grids, 1_u64))
      when BinaryDataType::TAG_NULLABLE
        child_type = type.child_at(0)
        return created_grids unless child_type.contains_low_cardinality?
        census_type(child_type, "#{path}.nested", counts, streams, budget, occurrences, used_shape_roles, created_grids)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        current = created_grids
        type.child_count.times do |index|
          child_type = type.child_at(index)
          next unless child_type.contains_low_cardinality?
          current = census_type(child_type, "#{path}.field.#{index}", counts, streams, budget, occurrences, used_shape_roles, current)
        end
        current
      when BinaryDataType::TAG_MAP
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        contains = key_type.contains_low_cardinality? || value_type.contains_low_cardinality?
        return created_grids unless contains
        role = "#{path}.sizes"
        used_shape_roles << role
        child_counts = map_child_counts(role, counts, streams, budget)
        current = checked_add(created_grids, 1_u64)
        if key_type.contains_low_cardinality?
          current = census_type(key_type, "#{path}.elements.field.0", child_counts, streams, budget, occurrences, used_shape_roles, current)
        end
        if value_type.contains_low_cardinality?
          current = census_type(value_type, "#{path}.elements.field.1", child_counts, streams, budget, occurrences, used_shape_roles, current)
        end
        current
      when BinaryDataType::TAG_VARIANT
        census_variant(type, path, counts, streams, budget, occurrences, used_shape_roles, created_grids)
      else
        created_grids
      end
    end

    private def self.census_variant(
      type : BinaryDataType,
      path : String,
      parent_counts : Array(UInt64),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
      occurrences : Hash(String, Array(UInt64)),
      used_shape_roles : Array(String),
      created_grids : UInt64,
    ) : UInt64
      unless type.contains_low_cardinality?
        return created_grids
      end

      role = "#{path}.discriminators"
      used_shape_roles << role
      arm_counts = Array(Array(UInt64)?).new(type.child_count, nil)
      current = created_grids
      type.child_count.times do |index|
        next unless type.child_at(index).contains_low_cardinality?
        arm_counts[index] = Array(UInt64).new(parent_counts.size, 0_u64)
        current = checked_add(current, 1_u64)
      end

      lane = streams.stream(role)
      parent_counts.each_with_index do |parent_count, mark|
        if parent_count > Int32::MAX.to_u64
          corrupt!("binary bulk Variant row count exceeds its supported domain")
        end
        context = lane_context(lane, mark, budget)
        context.ensure_remaining_input_bytes(parent_count)
        parent_count.times do
          discriminator = context.read_byte
          next if discriminator == 0xff_u8
          arm_index = discriminator.to_i
          if arm_index >= type.child_count
            corrupt!("binary bulk Variant discriminator is outside its arm roster")
          end
          if counts_for_arm = arm_counts[arm_index]
            count = counts_for_arm[mark]
            if count == UInt64::MAX
              corrupt!("binary bulk Variant occurrence count overflows UInt64")
            end
            counts_for_arm[mark] = count + 1_u64
          end
        end
        context.ensure_consumed
      end

      type.child_count.times do |index|
        child_type = type.child_at(index)
        next unless child_type.contains_low_cardinality?
        counts = arm_counts[index] || corrupt!("binary bulk Variant occurrence grid is missing")
        current = census_type(child_type, "#{path}.arm.#{index}", counts, streams, budget, occurrences, used_shape_roles, current)
      end
      current
    end

    private def self.array_child_counts(
      role : String,
      parent_counts : Array(UInt64),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      lane = streams.stream(role)
      child_counts = Array(UInt64).new(parent_counts.size, 0_u64)
      parent_counts.each_with_index do |parent_count, mark|
        if parent_count > Int32::MAX.to_u64
          corrupt!("binary bulk ancestor Array count exceeds its supported domain")
        end
        bytes = checked_multiply(parent_count, 8_u64)
        context = lane_context(lane, mark, budget)
        context.ensure_remaining_input_bytes(bytes)
        total = 0_u64
        parent_count.times do
          total = checked_add(total, read_u64(context))
        end
        context.ensure_consumed
        if total > Int32::MAX.to_u64
          corrupt!("binary bulk flattened Array child count exceeds its supported domain")
        end
        child_counts[mark] = total
      end
      child_counts
    end

    private def self.map_child_counts(
      role : String,
      parent_counts : Array(UInt64),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      lane = streams.stream(role)
      child_counts = Array(UInt64).new(parent_counts.size, 0_u64)
      parent_counts.each_with_index do |parent_count, mark|
        if parent_count > Int32::MAX.to_u64
          corrupt!("binary bulk ancestor Map count exceeds its supported domain")
        end
        bytes = checked_multiply(parent_count, 8_u64)
        context = lane_context(lane, mark, budget)
        context.ensure_remaining_input_bytes(bytes)
        pairs = 0_u64
        parent_count.times do
          pairs = checked_add(pairs, read_u64(context))
        end
        context.ensure_consumed
        flat_count = checked_multiply(pairs, 2_u64)
        if flat_count > Int32::MAX.to_u64
          corrupt!("binary bulk flattened Map child count exceeds its supported domain")
        end
        child_counts[mark] = pairs
      end
      child_counts
    end

    private def self.lane_context(stream : BinaryBulkStream, mark : Int, budget : BinaryCodecBudget) : BinaryCodecContext
      start = stream.offset_at(mark)
      finish = stream.offset_at(mark + 1)
      if finish < start
        corrupt!("binary bulk occurrence shape lane range is reversed")
      end
      borrowed = stream.borrowed_slice(start, finish - start)
      BinaryCodecContext.new(budget.limits, borrowed, false, budget, false, false)
    end

    private def self.read_u64(context : BinaryCodecContext) : UInt64
      raw = context.read_slice(8_u64)
      value = 0_u64
      8.times do |index|
        value |= raw[index].to_u64 << (index * 8)
      end
      value
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        corrupt!("binary bulk occurrence census overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        corrupt!("binary bulk occurrence census overflows UInt64")
      end
      left * right
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
