module CrystalClick
  # Recursive reader for the normalized per-mark physical-lane profile.
  module BinaryBulkDecoder
    def self.decode(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
    ) : Array(Array(BinaryValue))
      unless !budget.writing?
        raise ArgumentError.new("binary bulk decoder requires a read-direction budget")
      end

      real_marks = streams.mark_count
      if real_marks < 0 || rows_per_mark.size != real_marks
        corrupt!("binary bulk row-count grid does not match its mark domain")
      end
      selected_first, selected_count = validate_selection(first_mark, mark_count, real_marks)

      traversal = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      traversal.validate_type_tree(type)
      plan = BinaryBulkTypePlan.new(type, profile)
      planned_role_count = plan.role_count
      ordinary_role_count = plan.ordinary_role_count
      low_cardinality_sites = plan.low_cardinality_sites
      ancestor_size_roles = plan.ancestor_size_roles

      # Offset records and parent-supplied per-mark row counts are metadata.
      # Charge and preflight these before allocating the role roster, contexts,
      # or any selected value collection.
      mark_records = real_marks.to_u64
      offsets_per_role = checked_add(mark_records, 1_u64)
      grid_records = checked_multiply(ordinary_role_count, offsets_per_role)
      root_mark_records = type.tag == BinaryDataType::TAG_LOW_CARDINALITY ? 0_u64 : mark_records
      metadata_records = checked_add(grid_records, root_mark_records)
      traversal.preflight_children(metadata_records)
      metadata_records.times { budget.charge_node }

      roles = plan.roles
      unless roles.size.to_u64 == planned_role_count
        corrupt!("binary bulk role plan changed while it was materialized")
      end
      ordinary_roles = plan.ordinary_roles
      unless streams.role_count == roles.size && streams.mark_count == real_marks
        corrupt!("binary bulk role set or mark domain is incomplete")
      end
      roles.each do |role|
        unless streams.has_role?(role)
          corrupt!("binary bulk role set is incomplete")
        end
      end

      validate_grids(streams, ordinary_roles, real_marks)

      selected_rows = 0_u64
      rows_per_mark.each do |count|
        if count > Int32::MAX.to_u64
          corrupt!("binary bulk root row count exceeds its supported domain")
        end
      end
      selected_count.times do |offset|
        count = rows_per_mark[selected_first + offset]
        selected_rows = checked_add(selected_rows, count)
      end

      minimum = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile)
      minimum_nodes = checked_multiply(selected_rows, minimum.nodes)
      minimum_edges = checked_multiply(selected_rows, minimum.edges)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_edges)

      low_cardinality_values = BinaryBulkLowCardinalitySiteDecoder.decode(
        type,
        low_cardinality_sites,
        ancestor_size_roles,
        streams,
        rows_per_mark,
        budget,
        selected_first,
        selected_count
      )

      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        return low_cardinality_values["root"]? || corrupt!("binary bulk root LowCardinality site is missing")
      end

      selected_wire_bytes = selected_byte_size(streams, ordinary_roles, ancestor_size_roles, selected_first, selected_count)
      budget.ensure_wire_bytes(selected_wire_bytes)
      budget.charge_wire_bytes(selected_wire_bytes)

      result = Array(Array(BinaryValue)).new(selected_count)
      selected_count.times do |window_offset|
        mark = selected_first + window_offset
        root_count = rows_per_mark[mark].to_i32
        contexts = selected_contexts(streams, ordinary_roles, mark, budget)
        ensure_minimum_count(type, "root", root_count.to_u64, profile, contexts)

        traversal.ensure_future_nodes(type.tag == BinaryDataType::TAG_LOW_CARDINALITY ? 0_u64 : root_count.to_u64)
        traversal.ensure_depth(1) if root_count > 0
        lc_values_for_mark = Hash(String, Array(BinaryValue)).new
        low_cardinality_values.each do |path, mark_values|
          lc_values_for_mark[path] = mark_values[window_offset]
        end
        lc_cursors = Hash(String, Int32).new(0)
        values = Array(BinaryValue).new(root_count) do
          decode_value(type, "root", 1, contexts, traversal, profile, lc_values_for_mark, lc_cursors)
        end
        contexts.each_value(&.ensure_consumed)
        lc_values_for_mark.each do |path, mark_values|
          unless (lc_cursors[path]? || 0) == mark_values.size
            corrupt!("binary bulk value traversal did not consume the complete LowCardinality occurrence schedule")
          end
        end
        result << values
      end
      result
    end

    private def self.validate_selection(first_mark : Int, mark_count : Int?, real_marks : Int32) : {Int32, Int32}
      first = first_mark.to_i128
      marks = real_marks.to_i128
      if first < 0_i128 || first > marks
        corrupt!("binary bulk selected mark range is outside the real mark domain")
      end

      count = mark_count.try(&.to_i128) || (marks - first)
      if count < 0_i128 || count > (marks - first)
        corrupt!("binary bulk selected mark range is outside the real mark domain")
      end
      {first.to_i32, count.to_i32}
    end

    private def self.validate_grids(streams : BinaryBulkStreams, roles : Array(String), real_marks : Int32) : Nil
      expected_offsets = real_marks.to_i64 + 1_i64
      roles.each do |role|
        stream = streams.stream(role)
        unless stream.mark_count == real_marks && stream.offset_count.to_i64 == expected_offsets
          corrupt!("binary bulk lane has an invalid mark-grid length")
        end
        unless stream.offset_at(0) == 0_u64
          corrupt!("binary bulk lane does not begin at offset zero")
        end

        previous = 0_u64
        1.upto(real_marks) do |index|
          current = stream.offset_at(index)
          if current < previous || current > stream.byte_size.to_u64
            corrupt!("binary bulk lane offsets are not monotone within the byte domain")
          end
          previous = current
        end
        unless previous == stream.byte_size.to_u64
          corrupt!("binary bulk lane terminal offset does not match its byte size")
        end
      end
      nil
    end

    private def self.selected_byte_size(
      streams : BinaryBulkStreams,
      roles : Array(String),
      prepaid_full_roles : Array(String),
      first_mark : Int32,
      mark_count : Int32,
    ) : UInt64
      total = 0_u64
      finish = first_mark + mark_count
      roles.each do |role|
        next if prepaid_full_roles.includes?(role)
        stream = streams.stream(role)
        mark = first_mark
        while mark < finish
          start_offset = stream.offset_at(mark)
          end_offset = stream.offset_at(mark + 1)
          total = checked_add(total, end_offset - start_offset)
          mark += 1
        end
      end
      total
    end

    private def self.selected_contexts(
      streams : BinaryBulkStreams,
      roles : Array(String),
      mark : Int32,
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryCodecContext)
      contexts = Hash(String, BinaryCodecContext).new
      roles.each do |role|
        stream = streams.stream(role)
        start_offset = stream.offset_at(mark)
        size = stream.offset_at(mark + 1) - start_offset
        borrowed = stream.borrowed_slice(start_offset, size)
        contexts[role] = BinaryCodecContext.new(budget.limits, borrowed, false, budget, false, false)
      end
      contexts
    end

    # Prove a per-occurrence lower bound in each required role before allocating
    # root or child value arrays. Arrays and Maps can have zero children, so
    # their child lanes deliberately contribute no bound until their sizes are
    # read.
    private def self.ensure_minimum_count(
      type : BinaryDataType,
      path : String,
      count : UInt64,
      profile : BinaryBulkProfile,
      contexts : Hash(String, BinaryCodecContext),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          ensure_role_minimum(contexts, "#{path}.string_sizes", count, 8_u64)
        else
          ensure_role_minimum(contexts, "#{path}.data", count, 1_u64)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_MAP
        ensure_role_minimum(contexts, "#{path}.sizes", count, 8_u64)
      when BinaryDataType::TAG_LOW_CARDINALITY
        # The LC owner validates every mark and pays its full-state wire cost.
      when BinaryDataType::TAG_NULLABLE
        ensure_role_minimum(contexts, "#{path}.nulls", count, 1_u64)
        ensure_minimum_count(type.child_at(0), "#{path}.nested", count, profile, contexts)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          ensure_role_minimum(contexts, "#{path}.data", count, 1_u64)
        else
          type.child_count.times do |index|
            ensure_minimum_count(type.child_at(index), "#{path}.field.#{index}", count, profile, contexts)
          end
        end
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        ensure_role_minimum(contexts, "#{path}.data", count, 1_u64)
      else
        width = type.fixed_width || unsupported!("unsupported binary bulk DataType")
        ensure_role_minimum(contexts, "#{path}.data", count, width.to_u64)
      end
      nil
    end

    private def self.ensure_role_minimum(
      contexts : Hash(String, BinaryCodecContext),
      role : String,
      count : UInt64,
      width : UInt64,
    ) : Nil
      return if count == 0_u64 || width == 0_u64
      if count > UInt64::MAX // width
        corrupt!("binary bulk minimum lane size overflows UInt64")
      end
      context = contexts[role]? || corrupt!("binary bulk value addresses an unplanned lane")
      context.ensure_remaining_input_bytes(count * width)
    end

    private def self.decode_value(
      type : BinaryDataType,
      path : String,
      depth : Int,
      contexts : Hash(String, BinaryCodecContext),
      traversal : BinaryCodecContext,
      profile : BinaryBulkProfile,
      low_cardinality_values : Hash(String, Array(BinaryValue)),
      low_cardinality_cursors : Hash(String, Int32),
    ) : BinaryValue
      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        traversal.ensure_depth(depth)
        values = low_cardinality_values[path]? || corrupt!("binary bulk value addresses an unplanned LowCardinality site")
        cursor = low_cardinality_cursors[path]?
        unless cursor
          cursor = 0
        end
        if cursor >= values.size
          corrupt!("binary bulk value exceeds its LowCardinality occurrence schedule")
        end
        low_cardinality_cursors[path] = cursor + 1
        return values[cursor]
      end
      traversal.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          size = read_u64(context_for(contexts, "#{path}.string_sizes"))
          raw = context_for(contexts, "#{path}.data").read_slice(size)
          BinaryValue.string(String.new(raw))
        else
          context = context_for(contexts, "#{path}.data")
          size = context.read_var_uint
          raw = context.read_slice(size)
          BinaryValue.string(String.new(raw))
        end
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(BoolValueCodec.decode(context_for(contexts, "#{path}.data").read_byte))
      when BinaryDataType::TAG_NOTHING
        byte = context_for(contexts, "#{path}.data").read_byte
        unless byte == 0x30_u8
          corrupt!("Nothing bulk placeholder is not canonical ASCII zero")
        end
        BinaryValue.null(type)
      when BinaryDataType::TAG_ARRAY
        sizes = context_for(contexts, "#{path}.sizes")
        raw_count = read_u64(sizes)
        count = checked_collection_count(raw_count, "Array element count")
        preflight_child_type(traversal, type.child_at(0), raw_count) unless raw_count == 0_u64
        traversal.ensure_depth(depth + 1) unless raw_count == 0_u64
        ensure_minimum_count(type.child_at(0), "#{path}.elements", raw_count, profile, contexts)
        child_type = type.child_at(0)
        elements = Array(BinaryValue).new(count) do
          decode_value(child_type, "#{path}.elements", depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors)
        end
        BinaryValue.array(type, elements)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        if count == 0
          byte = context_for(contexts, "#{path}.data").read_byte
          unless byte == 0x30_u8
            corrupt!("empty Tuple bulk placeholder is not canonical ASCII zero")
          end
          BinaryValue.tuple(type, [] of BinaryValue)
        else
          traversal.charge_elements(count.to_u64)
          ordinary_nodes = 0_u64
          count.times do |index|
            ordinary_nodes += 1_u64 unless type.child_at(index).tag == BinaryDataType::TAG_LOW_CARDINALITY
          end
          traversal.ensure_future_nodes(ordinary_nodes)
          traversal.ensure_depth(depth + 1)
          count.times do |index|
            child_type = type.child_at(index)
            child_path = "#{path}.field.#{index}"
            ensure_minimum_count(child_type, child_path, 1_u64, profile, contexts)
          end
          fields = Array(BinaryValue).new(count) do |index|
            child_type = type.child_at(index)
            child_path = "#{path}.field.#{index}"
            decode_value(child_type, child_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors)
          end
          BinaryValue.tuple(type, fields)
        end
      when BinaryDataType::TAG_MAP
        raw_pairs = read_u64(context_for(contexts, "#{path}.sizes"))
        if raw_pairs > UInt64::MAX // 2_u64
          corrupt!("Map pair count overflows its flat element count")
        end
        flat_count = raw_pairs * 2_u64
        count = checked_collection_count(flat_count, "Map value count")
        unless flat_count == 0_u64
          traversal.charge_elements(flat_count)
          ordinary_nodes = 0_u64
          flat_count.times do |index|
            child_type = type.child_at(index.even? ? 0 : 1)
            ordinary_nodes += 1_u64 unless child_type.tag == BinaryDataType::TAG_LOW_CARDINALITY
          end
          traversal.ensure_future_nodes(ordinary_nodes)
        end
        traversal.ensure_depth(depth + 1) unless flat_count == 0_u64
        ensure_minimum_count(type.child_at(0), "#{path}.elements.field.0", raw_pairs, profile, contexts)
        ensure_minimum_count(type.child_at(1), "#{path}.elements.field.1", raw_pairs, profile, contexts)
        entries = Array(BinaryValue).new(count) do |index|
          child_index = index.even? ? 0 : 1
          child_path = "#{path}.elements.field.#{child_index}"
          decode_value(type.child_at(child_index), child_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors)
        end
        BinaryValue.map(type, entries)
      when BinaryDataType::TAG_NULLABLE
        flag = context_for(contexts, "#{path}.nulls").read_byte
        unless flag == 0_u8 || flag == 1_u8
          corrupt!("Nullable bulk null-map flag must be zero or one")
        end
        preflight_child_type(traversal, type.child_at(0), 1_u64)
        traversal.ensure_depth(depth + 1)
        child_type = type.child_at(0)
        child_path = "#{path}.nested"
        ensure_minimum_count(child_type, child_path, 1_u64, profile, contexts)
        child = decode_value(child_type, child_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors)
        if flag == 1_u8
          BinaryValue.null(type)
        elsif child_type.tag == BinaryDataType::TAG_NOTHING
          corrupt!("Nullable(Nothing) cannot contain a non-NULL Nothing value")
        else
          BinaryValue.nullable(type, child)
        end
      else
        width = type.fixed_width || unsupported!("unsupported binary bulk leaf")
        raw = context_for(contexts, "#{path}.data").read_slice(width.to_u64)
        BinaryValue.fixed(type, raw)
      end
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

    private def self.context_for(contexts : Hash(String, BinaryCodecContext), role : String) : BinaryCodecContext
      contexts[role]? || corrupt!("binary bulk value addresses an unplanned lane")
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
        corrupt!("#{label} exceeds its supported in-memory domain")
      end
      count.to_i32
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        corrupt!("binary bulk read size overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        corrupt!("binary bulk read size overflows UInt64")
      end
      left * right
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    private def self.unsupported!(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end
  end
end
