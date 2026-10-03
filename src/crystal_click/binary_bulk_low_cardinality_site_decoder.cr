module CrystalClick
  # Censuses LC occurrence counts from every required ancestor Array/Map size
  # lane, then delegates full dictionary/index replay to the W142 reader.
  module BinaryBulkLowCardinalitySiteDecoder
    def self.decode(
      type : BinaryDataType,
      sites : Array(BinaryBulkTypePlan::LowCardinalitySite),
      ancestor_size_roles : Array(String),
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int32,
      mark_count : Int32,
    ) : Hash(String, Array(Array(BinaryValue)))
      decoded = Hash(String, Array(Array(BinaryValue))).new
      return decoded if sites.empty?

      census_cells = checked_multiply(rows_per_mark.size.to_u64, ancestor_size_roles.size.to_u64)
      budget.ensure_future_nodes(census_cells)
      budget.ensure_future_elements(census_cells)
      budget.charge_elements(census_cells)
      census_cells.times { budget.charge_node }

      # LC dictionary/index bytes are charged by W142. Array/Map shape lanes
      # needed to reconstruct those LC schedules are instead fully charged
      # here, across all marks; selected ordinary payload remains window-only.
      shape_bytes = 0_u64
      ancestor_size_roles.each do |role|
        shape_bytes = checked_add(shape_bytes, streams.stream(role).byte_size.to_u64)
      end
      budget.ensure_wire_bytes(shape_bytes)
      budget.charge_wire_bytes(shape_bytes)

      occurrences = Hash(String, Array(UInt64)).new
      created_grids = 0_u64
      created_grids = census_type(type, "root", rows_per_mark, streams, budget, occurrences, created_grids)
      unless created_grids == ancestor_size_roles.size.to_u64
        corrupt!("binary bulk LowCardinality census did not consume its planned shape schedules")
      end

      sites.each do |site|
        per_mark = occurrences[site.path]?
        unless per_mark
          corrupt!("binary bulk LowCardinality census is missing an occurrence path")
        end
        site_lanes = {
          BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE => streams.stream(site.dictionary_role),
          BinaryLowCardinalityStorageStreams::INDEX_ROLE      => streams.stream(site.indexes_role),
        } of String => BinaryBulkStream
        site_streams = BinaryBulkStreams.new(streams.mark_count, site_lanes)
        decoded[site.path] = BinaryLowCardinalityStorageDecoder.decode_prevalidated(
          site.type,
          site_streams,
          per_mark.not_nil!,
          budget,
          first_mark,
          mark_count
        )
      end
      decoded
    end

    private def self.census_type(
      type : BinaryDataType,
      path : String,
      counts : Array(UInt64),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
      occurrences : Hash(String, Array(UInt64)),
      created_grids : UInt64,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        occurrences[path] = counts
        created_grids
      when BinaryDataType::TAG_ARRAY
        child_type = type.child_at(0)
        return created_grids unless BinaryLowCardinalityTypePolicy.contains_low_cardinality?(child_type)
        child_counts = array_child_counts("#{path}.sizes", counts, streams, budget)
        census_type(child_type, "#{path}.elements", child_counts, streams, budget, occurrences, created_grids + 1_u64)
      when BinaryDataType::TAG_NULLABLE
        child_type = type.child_at(0)
        return created_grids unless BinaryLowCardinalityTypePolicy.contains_low_cardinality?(child_type)
        census_type(child_type, "#{path}.nested", counts, streams, budget, occurrences, created_grids)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        current = created_grids
        type.child_count.times do |index|
          child_type = type.child_at(index)
          next unless BinaryLowCardinalityTypePolicy.contains_low_cardinality?(child_type)
          current = census_type(child_type, "#{path}.field.#{index}", counts, streams, budget, occurrences, current)
        end
        current
      when BinaryDataType::TAG_MAP
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        contains = BinaryLowCardinalityTypePolicy.contains_low_cardinality?(key_type) ||
                   BinaryLowCardinalityTypePolicy.contains_low_cardinality?(value_type)
        return created_grids unless contains
        child_counts = map_child_counts("#{path}.sizes", counts, streams, budget)
        current = created_grids + 1_u64
        if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(key_type)
          current = census_type(key_type, "#{path}.elements.field.0", child_counts, streams, budget, occurrences, current)
        end
        if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(value_type)
          current = census_type(value_type, "#{path}.elements.field.1", child_counts, streams, budget, occurrences, current)
        end
        current
      else
        created_grids
      end
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
        # Each Map key/value occurrence schedule has one row per pair. Keep
        # the doubled flat BinaryValue count only for the supported-domain
        # guard above.
        child_counts[mark] = pairs
      end
      child_counts
    end

    private def self.lane_context(stream : BinaryBulkStream, mark : Int32, budget : BinaryCodecBudget) : BinaryCodecContext
      start = stream.offset_at(mark)
      finish = stream.offset_at(mark + 1)
      if finish < start
        corrupt!("binary bulk ancestor size lane range is reversed")
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
        corrupt!("binary bulk LowCardinality census overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        corrupt!("binary bulk LowCardinality census overflows UInt64")
      end
      left * right
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
