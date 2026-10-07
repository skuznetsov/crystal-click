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
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
      json_object_reader : BinaryDynamicBulkJsonObjectReader? = nil,
    ) : Array(Array(BinaryValue))
      unless !budget.writing?
        raise ArgumentError.new("binary bulk decoder requires a read-direction budget")
      end
      if dynamic_plan.try(&.has_json_object_bindings?) && json_object_reader.nil?
        corrupt!("bound Dynamic JSON arms require the paired Object child reader")
      end
      if reader = json_object_reader
        unless dynamic_plan && reader.matches_operation?(dynamic_plan, budget)
          raise ArgumentError.new("Dynamic JSON Object reader does not match the bulk plan")
        end
      end

      real_marks = streams.mark_count
      if real_marks < 0 || rows_per_mark.size != real_marks
        corrupt!("binary bulk row-count grid does not match its mark domain")
      end
      selected_first, selected_count = validate_selection(first_mark, mark_count, real_marks)

      traversal = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      traversal.validate_type_tree(type)
      plan = BinaryBulkTypePlan.new(type, profile, dynamic_plan, budget.limits, false)
      planned_role_count = plan.role_count
      ordinary_role_count = plan.ordinary_role_count
      low_cardinality_sites = plan.low_cardinality_sites
      shape_roles = plan.low_cardinality_shape_roles

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

      qbit_column = plan.qbit_column
      roles = plan.roles
      unless roles.size.to_u64 == planned_role_count
        corrupt!("binary bulk role plan changed while it was materialized")
      end
      # The admitted QBit roots have no separate stop-site roster.
      ordinary_roles = qbit_column ? roles : plan.ordinary_roles
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

      qbit_site_roles = prepare_dynamic_qbit_site_roles(
        dynamic_plan,
        streams,
        real_marks,
        selected_first,
        selected_count,
        budget,
      )
      qbit_roles = plan.qbit_plane_roles
      qbit_role_offset = 0
      if column = qbit_column
        BinaryQBitBulkCodec.preflight_materialization!(column, selected_rows, budget.limits, false)
      end

      minimum = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile, nil, dynamic_plan)
      minimum_nodes = checked_multiply(selected_rows, minimum.nodes)
      minimum_edges = checked_multiply(selected_rows, minimum.edges)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_edges)

      low_cardinality_values = BinaryBulkLowCardinalitySiteDecoder.decode(
        type,
        low_cardinality_sites,
        shape_roles,
        plan.low_cardinality_schedule_grid_count,
        streams,
        rows_per_mark,
        budget,
        selected_first,
        selected_count,
        dynamic_plan
      )

      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        return low_cardinality_values["root"]? || corrupt!("binary bulk root LowCardinality site is missing")
      end

      selected_wire_bytes = selected_byte_size(streams, ordinary_roles, shape_roles, selected_first, selected_count)
      budget.ensure_wire_bytes(selected_wire_bytes)
      budget.charge_wire_bytes(selected_wire_bytes)

      result = Array(Array(BinaryValue)).new(selected_count)
      selected_count.times do |window_offset|
        mark = selected_first + window_offset
        root_count = rows_per_mark[mark].to_i32
        contexts = selected_contexts(streams, ordinary_roles, mark, budget)
        ensure_minimum_count(type, "root", root_count.to_u64, profile, contexts, budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)

        traversal.ensure_future_nodes(type.tag == BinaryDataType::TAG_LOW_CARDINALITY ? 0_u64 : root_count.to_u64)
        traversal.ensure_depth(1) if root_count > 0
        lc_values_for_mark = Hash(String, Array(BinaryValue)).new
        low_cardinality_values.each do |path, mark_values|
          lc_values_for_mark[path] = mark_values[window_offset]
        end
        lc_cursors = Hash(String, Int32).new(0)
        json_object_reader.try(&.begin_mark(mark))
        values = Array(BinaryValue).new(root_count) do
          decode_value(type, "root", 1, contexts, traversal, profile, lc_values_for_mark, lc_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader)
        end
        contexts.each_value do |context|
          context.ensure_consumed
        end
        lc_values_for_mark.each do |path, mark_values|
          unless (lc_cursors[path]? || 0) == mark_values.size
            corrupt!("binary bulk value traversal did not consume the complete LowCardinality occurrence schedule")
          end
        end
        result << values
      end
      if reader = json_object_reader
        reader.ensure_consumed!
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

    private def self.prepare_dynamic_qbit_site_roles(
      dynamic_plan : BinaryDynamicBulkPlan?,
      streams : BinaryBulkStreams,
      real_marks : Int32,
      selected_first : Int32,
      selected_count : Int32,
      budget : BinaryCodecBudget,
    ) : Hash(String, Tuple(QBitType, Array(String)))?
      return nil unless dynamic_plan

      site_count = 0_u64
      role_copy_bytes = 0_u64
      dynamic_plan.each_qbit_site do |site|
        site_count = checked_add(site_count, 1_u64)
        role_copy_bytes = checked_add(role_copy_bytes, site.path_bytesize)
        role_copy_bytes = checked_add(role_copy_bytes, site.plane_role_bytesize)
      end
      return nil if site_count == 0_u64

      # The path and numeric-order role copies below are retained codec work.
      # Bound the aggregate before asking any site for detached strings.
      budget.ensure_wire_bytes(role_copy_bytes)
      budget.charge_wire_bytes(role_copy_bytes)

      sites = Hash(String, Tuple(QBitType, Array(String))).new
      total_materialization = 0_u64
      selected_end = selected_first + selected_count
      dynamic_plan.each_qbit_site do |site|
        path = site.path
        qbit_type = site.qbit_type
        roles = site.plane_roles
        unless roles.size == qbit_type.plane_count
          corrupt!("Dynamic QBit plane-role count does not match its descriptor")
        end
        sites[path] = {qbit_type, roles}

        column = begin
          QBitColumnType.new(qbit_type)
        rescue ex : ArgumentError
          corrupt!("Dynamic QBit descriptor exceeds the bounded plane profile")
        end
        selected_site_rows = 0_u64
        mark = 0
        while mark < real_marks
          expected_size = nil.as(UInt64?)
          roles.each do |role|
            stream = streams.stream(role)
            size = stream.offset_at(mark + 1) - stream.offset_at(mark)
            if previous = expected_size
              unless size == previous
                corrupt!("Dynamic QBit plane lanes disagree on occurrence count")
              end
            else
              expected_size = size
            end
          end
          size = expected_size || corrupt!("Dynamic QBit site has no plane roles")
          width = qbit_type.plane_width.to_u64
          unless size % width == 0_u64
            corrupt!("Dynamic QBit plane lane is not aligned to its row width")
          end
          if mark >= selected_first && mark < selected_end
            selected_site_rows = checked_add(selected_site_rows, size // width)
          end
          mark += 1
        end

        charge = begin
          column.materialization_charge(selected_site_rows)
        rescue ex : ArgumentError
          corrupt!("Dynamic QBit materialization exceeds its bounded range")
        end
        total_materialization = checked_add(total_materialization, charge)
      end

      if total_materialization > budget.limits.max_bytes.to_u64
        corrupt!("Dynamic QBit aggregate materialization exceeds configured byte limit")
      end
      sites
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
      budget : BinaryCodecBudget,
      dynamic_plan : BinaryDynamicBulkPlan?,
      qbit_roles : Array(String)? = nil,
      qbit_role_offset : Int32 = 0,
      qbit_site_roles : Hash(String, Tuple(QBitType, Array(String)))? = nil,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || unsupported!("QBit bulk descriptor is missing its nominal type")
        site_entry = qbit_site_roles.try { |entries| entries[path]? }
        roles = if entry = site_entry
                  unless entry[0] == qbit_type
                    corrupt!("Dynamic QBit site nominal type does not match its actual arm")
                  end
                  entry[1]
                else
                  qbit_roles || unsupported!("QBit bulk plane roles were not planned")
                end
        unless qbit_role_offset >= 0 && qbit_role_offset <= roles.size - qbit_type.plane_count
          corrupt!("QBit bulk plane roles do not match their descriptor")
        end
        qbit_type.plane_count.times do |plane|
          ensure_role_minimum(contexts, roles[qbit_role_offset + plane], count, qbit_type.plane_width.to_u64)
        end
      when BinaryDataType::TAG_AGGREGATE_COUNT
        ensure_role_minimum(contexts, child_path(path, ".data", nil, budget, dynamic_plan), count, 1_u64)
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          ensure_role_minimum(contexts, child_path(path, ".string_sizes", nil, budget, dynamic_plan), count, 8_u64)
        else
          ensure_role_minimum(contexts, child_path(path, ".data", nil, budget, dynamic_plan), count, 1_u64)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_MAP
        ensure_role_minimum(contexts, child_path(path, ".sizes", nil, budget, dynamic_plan), count, 8_u64)
      when BinaryDataType::TAG_VARIANT
        ensure_role_minimum(contexts, child_path(path, ".discriminators", nil, budget, dynamic_plan), count, 1_u64)
      when BinaryDataType::TAG_DYNAMIC
        ensure_role_minimum(contexts, child_path(path, ".discriminators", nil, budget, dynamic_plan), count, 1_u64)
      when BinaryDataType::TAG_JSON
        # Direct JSON actual values are consumed by the paired Object reader.
        nil
      when BinaryDataType::TAG_LOW_CARDINALITY
        # The LC owner validates every mark and pays its full-state wire cost.
      when BinaryDataType::TAG_NULLABLE
        ensure_role_minimum(contexts, child_path(path, ".nulls", nil, budget, dynamic_plan), count, 1_u64)
        ensure_minimum_count(type.child_at(0), child_path(path, ".nested", nil, budget, dynamic_plan), count, profile, contexts, budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        ensure_minimum_count(type.child_at(0), path, count, profile, contexts, budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          ensure_role_minimum(contexts, child_path(path, ".data", nil, budget, dynamic_plan), count, 1_u64)
        else
          type.child_count.times do |index|
            ensure_minimum_count(type.child_at(index), child_path(path, ".field.", index, budget, dynamic_plan), count, profile, contexts, budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
          end
        end
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        ensure_role_minimum(contexts, child_path(path, ".data", nil, budget, dynamic_plan), count, 1_u64)
      else
        width = type.fixed_width || unsupported!("unsupported binary bulk DataType")
        ensure_role_minimum(contexts, child_path(path, ".data", nil, budget, dynamic_plan), count, width.to_u64)
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
      dynamic_plan : BinaryDynamicBulkPlan?,
      qbit_roles : Array(String)? = nil,
      qbit_role_offset : Int32 = 0,
      qbit_site_roles : Hash(String, Tuple(QBitType, Array(String)))? = nil,
      json_object_reader : BinaryDynamicBulkJsonObjectReader? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
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
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || unsupported!("QBit bulk descriptor is missing its nominal type")
        site_entry = qbit_site_roles.try { |entries| entries[path]? }
        roles = if entry = site_entry
                  unless entry[0] == qbit_type
                    corrupt!("Dynamic QBit site nominal type does not match its actual arm")
                  end
                  entry[1]
                else
                  qbit_roles || corrupt!("QBit bulk plane roles were not planned")
                end
        unless qbit_role_offset >= 0 && qbit_role_offset <= roles.size - qbit_type.plane_count
          corrupt!("QBit bulk plane roles do not match their descriptor")
        end
        value = QBitPlaneCodec.decode_row(qbit_type) do |plane, _byte_index|
          context_for(contexts, roles[qbit_role_offset + plane]).read_byte
        end
        BinaryValue.qbit(value)
      when BinaryDataType::TAG_AGGREGATE_COUNT
        count = BinaryAggregateCountStateCodec.read(context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)))
        BinaryValue.aggregate_count_state(type, count)
      when BinaryDataType::TAG_VARIANT
        discriminator = context_for(contexts, child_path(path, ".discriminators", nil, traversal.budget, dynamic_plan)).read_byte
        if discriminator == 0xff_u8
          BinaryValue.variant_null(type)
        else
          index = discriminator.to_i
          if index >= type.child_count
            corrupt!("Variant bulk discriminator is outside its arm roster")
          end
          child_type = type.child_at(index)
          selected_path = child_path(path, ".arm.", discriminator.to_i, traversal.budget, dynamic_plan)
          preflight_child_type(traversal, child_type, 1_u64)
          traversal.ensure_depth(depth + 1)
          ensure_minimum_count(child_type, selected_path, 1_u64, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
          child = decode_value(child_type, selected_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(index) })
          BinaryValue.variant(type, discriminator.to_i, child)
        end
      when BinaryDataType::TAG_DYNAMIC
        plan = dynamic_plan || corrupt!("binary Dynamic value has no structure plan")
        discriminator = context_for(contexts, child_path(path, ".discriminators", nil, traversal.budget, dynamic_plan)).read_byte
        if discriminator == 0xff_u8
          BinaryValue.dynamic(type)
        else
          index = discriminator.to_i
          if index >= plan.arm_count(path)
            corrupt!("Dynamic bulk discriminator is outside its actual arm roster")
          end
          selected_path = child_path(path, ".arm.", index, traversal.budget, dynamic_plan)
          if index == plan.shared_index(path)
            # Preflight the Dynamic-to-envelope descriptor edge before even
            # reading the selected String envelope. The helper owns the
            # descriptor/value visits and, for non-Nothing, the descriptor's
            # child edge.
            traversal.preflight_children(1_u64)
            data_context = context_for(contexts, child_path(selected_path, ".data", nil, traversal.budget, dynamic_plan))
            envelope_size = if profile.with_size_stream?
                              read_u64(context_for(contexts, child_path(selected_path, ".string_sizes", nil, traversal.budget, dynamic_plan)))
                            else
                              data_context.read_var_uint
                            end
            envelope = data_context.read_slice(envelope_size)
            # The shared scalar visitor preflights the selected value's edge
            # only after seeing a non-Nothing descriptor and before allocating
            # it.
            child_type, child_value = BinaryValueCodec.decode_dynamic_bulk_child(
              envelope,
              traversal.budget,
              (depth + 1).to_i32,
              true,
              allow_json: true,
            )
            if value = child_value
              BinaryValue.dynamic(type, value)
            else
              BinaryValue.dynamic(type)
            end
          else
            child_type = plan.arm_type(path, index)
            leaf_key = if child_type.contains_json?
                         BinaryDynamicJsonLeafKey.new(path, index, [] of Int32)
                       else
                         nil
                       end
            traversal.preflight_children(1_u64)
            traversal.ensure_depth(depth + 1)
            ensure_minimum_count(child_type, selected_path, 1_u64, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
            child = decode_value(child_type, selected_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, leaf_key)
            BinaryValue.dynamic(type, child)
          end
        end
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_type = type.child_at(0)
        traversal.preflight_children(1_u64)
        traversal.ensure_depth(depth + 1)
        ensure_minimum_count(child_type, path, 1_u64, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
        child = decode_value(child_type, path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(0) })
        BinaryValue.simple_aggregate(type, child)
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          size = read_u64(context_for(contexts, child_path(path, ".string_sizes", nil, traversal.budget, dynamic_plan)))
          raw = context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)).read_slice(size)
          BinaryValue.string(String.new(raw))
        else
          context = context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan))
          size = context.read_var_uint
          raw = context.read_slice(size)
          BinaryValue.string(String.new(raw))
        end
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(BoolValueCodec.decode(context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)).read_byte))
      when BinaryDataType::TAG_NOTHING
        byte = context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)).read_byte
        unless byte == 0x30_u8
          corrupt!("Nothing bulk placeholder is not canonical ASCII zero")
        end
        BinaryValue.null(type)
      when BinaryDataType::TAG_JSON
        reader = json_object_reader || corrupt!("bound Dynamic JSON leaf has no paired Object reader")
        key = json_leaf_key || corrupt!("bound Dynamic JSON leaf has no exact binding key")
        BinaryValue.json(type, reader.next_row(key, depth))
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        sizes = context_for(contexts, child_path(path, ".sizes", nil, traversal.budget, dynamic_plan))
        raw_count = read_u64(sizes)
        count = checked_collection_count(raw_count, "Array element count")
        preflight_child_type(traversal, type.child_at(0), raw_count) unless raw_count == 0_u64
        traversal.ensure_depth(depth + 1) unless raw_count == 0_u64
        elements_path = child_path(path, ".elements", nil, traversal.budget, dynamic_plan)
        ensure_minimum_count(type.child_at(0), elements_path, raw_count, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
        child_type = type.child_at(0)
        elements = Array(BinaryValue).new(count) do
          decode_value(child_type, elements_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(0) })
        end
        if type.tag == BinaryDataType::TAG_NESTED
          BinaryValue.nested(type, elements)
        else
          BinaryValue.array(type, elements)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        if count == 0
          byte = context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)).read_byte
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
            selected_path = child_path(path, ".field.", index, traversal.budget, dynamic_plan)
            ensure_minimum_count(child_type, selected_path, 1_u64, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
          end
          fields = Array(BinaryValue).new(count) do |index|
            child_type = type.child_at(index)
            selected_path = child_path(path, ".field.", index, traversal.budget, dynamic_plan)
            decode_value(child_type, selected_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(index) })
          end
          BinaryValue.tuple(type, fields)
        end
      when BinaryDataType::TAG_MAP
        raw_pairs = read_u64(context_for(contexts, child_path(path, ".sizes", nil, traversal.budget, dynamic_plan)))
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
        key_path = child_path(path, ".elements.field.0", nil, traversal.budget, dynamic_plan)
        value_path = child_path(path, ".elements.field.1", nil, traversal.budget, dynamic_plan)
        ensure_minimum_count(type.child_at(0), key_path, raw_pairs, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
        ensure_minimum_count(type.child_at(1), value_path, raw_pairs, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
        entries = Array(BinaryValue).new(count) do |index|
          child_index = index.even? ? 0 : 1
          selected_path = child_index == 0 ? key_path : value_path
          decode_value(type.child_at(child_index), selected_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(child_index) })
        end
        BinaryValue.map(type, entries)
      when BinaryDataType::TAG_NULLABLE
        flag = context_for(contexts, child_path(path, ".nulls", nil, traversal.budget, dynamic_plan)).read_byte
        unless flag == 0_u8 || flag == 1_u8
          corrupt!("Nullable bulk null-map flag must be zero or one")
        end
        preflight_child_type(traversal, type.child_at(0), 1_u64)
        traversal.ensure_depth(depth + 1)
        child_type = type.child_at(0)
        selected_path = child_path(path, ".nested", nil, traversal.budget, dynamic_plan)
        ensure_minimum_count(child_type, selected_path, 1_u64, profile, contexts, traversal.budget, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles)
        child = decode_value(child_type, selected_path, depth + 1, contexts, traversal, profile, low_cardinality_values, low_cardinality_cursors, dynamic_plan, qbit_roles, qbit_role_offset, qbit_site_roles, json_object_reader, json_leaf_key.try { |key| key.with_child(0) })
        if flag == 1_u8
          BinaryValue.null(type)
        elsif child_type.tag == BinaryDataType::TAG_NOTHING
          corrupt!("Nullable(Nothing) cannot contain a non-NULL Nothing value")
        else
          BinaryValue.nullable(type, child)
        end
      else
        width = type.fixed_width || unsupported!("unsupported binary bulk leaf")
        raw = context_for(contexts, child_path(path, ".data", nil, traversal.budget, dynamic_plan)).read_slice(width.to_u64)
        BinaryValue.fixed(type, raw)
      end
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
        corrupt!("binary Dynamic value path size overflows UInt64")
      end
      size += suffix_size
      if value = index
        if value < 0
          corrupt!("binary Dynamic value path index is negative")
        end
        digits = 1_u64
        remaining = value
        while remaining >= 10
          remaining //= 10
          digits += 1_u64
        end
        if digits > UInt64::MAX - size
          corrupt!("binary Dynamic value path size overflows UInt64")
        end
        size += digits
      end
      if size > UInt64::MAX // 2_u64
        corrupt!("binary Dynamic value path work size overflows UInt64")
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
