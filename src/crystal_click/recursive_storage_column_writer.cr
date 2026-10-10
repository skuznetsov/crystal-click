module CrystalClick
  # Composes Tuple and Array edges around existing Object, BinaryBulk, and Dynamic leaf
  # owners. Structural sites carry schedules; serializers remain per leaf.
  module RecursiveStorageColumnWriter
    def self.encode(
      plan : RecursiveStorageColumnPlan,
      granules : Array(Array(StorageColumnValue)),
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : RecursiveStorageColumnFiles
      validate_mark_grid!(granules)
      limits = plan.limits
      write_codec_budget = codec_budget || BinaryCodecBudget.new(limits, true)
      unless write_codec_budget.writing? && same_limits?(write_codec_budget.limits, limits)
        raise ArgumentError.new("recursive storage requires a compatible write codec budget")
      end
      write_transport_budget = transport_budget || CompressedStreamBudget.new(plan.transport_limits, true)
      validate_transport_budget!(write_transport_budget, plan.transport_limits)
      granules.each do |rows|
        rows.each do |value|
          StorageColumnDepthGuard.validate(value, limits, writing: true)
        end
      end

      validate_rows!(plan.schema, granules, write_codec_budget)
      physical_rows = mark_counts_for(granules, write_codec_budget)
      root_grid = StorageOccurrenceGrid.new(physical_rows, physical_rows, write_codec_budget)

      objects = Hash(String, Array(Array(ObjectDocument))).new
      bulks = Hash(String, Array(Array(BinaryValue))).new
      site_grids = Hash(String, StorageOccurrenceGrid).new
      frames = prepare_array_frames(plan, granules, physical_rows, write_codec_budget)
      collect_sites!(
        plan.schema, granules, "root", 0_u64, physical_rows, root_grid,
        write_codec_budget, objects, bulks, site_grids, frames
      )
      validate_collected_rosters!(plan, objects, bulks, site_grids, frames)

      pairs = Hash(String, CompressedMarkFiles).new

      # Array size lanes are complete schedules prepared before this first
      # physical encoding. Their .mrk2 rows are P; byte offsets describe Q.
      plan.array_site_count.times do |index|
        site = plan.array_site_at(index)
        frame = frames[site.key]? || raise(UnsupportedFormatError.new("recursive Array frame is missing"))
        unless frame.array_level == site.array_level
          raise UnsupportedFormatError.new("recursive Array frame level differs from its admitted plan")
        end
        stream = frame.size_stream
        lane = ObjectDocumentColumnLane.new(
          site.size_name,
          stream.borrowed_slice(0, stream.byte_size),
          bulk_source: stream
        )
        add_pair!(pairs, lane.name, lane.encode_child_site(frame.parent_grid, plan.frame_bytes, write_transport_budget))
      end

      plan.object_site_count.times do |index|
        site = plan.object_site_at(index)
        site_granules = objects[site.key]? || raise(UnsupportedFormatError.new("recursive Object site data is missing"))
        grid = site_grids[site.key]? || raise(UnsupportedFormatError.new("recursive Object site grid is missing"))
        files = if site.array_level == 0_u64
                  ObjectDocumentColumnWriter.encode_at_physical_site(
                    site.prefix,
                    site.object_plan,
                    site.physical,
                    site_granules,
                    write_codec_budget,
                    write_transport_budget,
                    plan.profile,
                    plan.shared_profile,
                    plan.mode,
                    plan.hashed?,
                    plan.frame_bytes,
                    site.array_level
                  )
                else
                  ObjectDocumentColumnWriter.encode_child_at_physical_site(
                    site.prefix,
                    site.object_plan,
                    site.physical,
                    grid,
                    site_granules,
                    write_codec_budget,
                    write_transport_budget,
                    plan.profile,
                    plan.shared_profile,
                    plan.mode,
                    plan.hashed?,
                    plan.frame_bytes,
                    site.array_level
                  )
                end
        site_names = files.stream_names
        expected_names = site.physical.stream_names
        raise UnsupportedFormatError.new("encoded Object site roster changed after planning") unless site_names == expected_names
        site_names.each { |name| add_pair!(pairs, name, files.pair_for(name)) }
      end

      plan.bulk_site_count.times do |index|
        site = plan.bulk_site_at(index)
        site_granules = bulks[site.key]? || raise(UnsupportedFormatError.new("recursive BinaryBulk site data is missing"))
        grid = site_grids[site.key]? || raise(UnsupportedFormatError.new("recursive BinaryBulk site grid is missing"))
        streams = BinaryBulkCodec.encode_with_budget(site.type, site_granules, write_codec_budget, profile: plan.profile)
        physical_names = site.physical.stream_names
        roles = streams.roles
        unless physical_names.keys.sort == roles && streams.mark_count == granules.size
          raise UnsupportedFormatError.new("BinaryBulk output roles or marks differ from the admitted physical plan")
        end

        lanes = Array(ObjectDocumentColumnLane).new(roles.size)
        prefix_adapter_lanes = [] of Tuple(String, BinaryBulkStream, Int32)
        roles.each do |role|
          stream = streams.stream(role)
          prefix = site.physical.prefix_size_for(role)
          variant_prefix = BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
          prefix_adapter_lanes << {role, stream, prefix}
          lanes << ObjectDocumentColumnLane.new(
            physical_names[role],
            stream.borrowed_slice(0, stream.byte_size),
            nil,
            stream,
            nil,
            prefix,
            variant_prefix ? role : nil
          )
        end
        raw_sizes = Array(Int32).new(lanes.size) { |lane_index| lanes[lane_index].byte_size }
        CompressedMarkWriter.preflight_batch(raw_sizes, granules.size + 1, plan.frame_bytes, write_transport_budget)
        BinaryBulkPhysicalPrefixAdapter.preflight_write(prefix_adapter_lanes, write_codec_budget) unless prefix_adapter_lanes.empty?
        lanes.each do |lane|
          pair = if site.array_level == 0_u64
                   lane.encode(physical_rows, plan.frame_bytes, write_transport_budget)
                 else
                   lane.encode_child_site(grid, plan.frame_bytes, write_transport_budget)
                 end
          add_pair!(pairs, lane.name, pair)
        end
      end

      plan.dynamic_site_count.times do |index|
        site = plan.dynamic_site_at(index)
        site_granules = bulks[site.key]? || raise(UnsupportedFormatError.new("recursive Dynamic site data is missing"))
        grid = site_grids[site.key]? || raise(UnsupportedFormatError.new("recursive Dynamic site grid is missing"))
        files = DynamicBulkColumnWriter.encode_at_site(
          site.plan,
          site.physical,
          site_granules,
          grid,
          plan.frame_bytes,
          limits,
          plan.transport_limits,
          write_codec_budget,
          write_transport_budget,
        )
        expected_names = site.physical.stream_names.values.sort!
        unless files.keys.sort == expected_names
          raise UnsupportedFormatError.new("encoded Dynamic site roster changed after planning")
        end
        files.each { |name, pair| add_pair!(pairs, name, pair) }
      end

      RecursiveStorageColumnFiles.new(plan, pairs)
    end

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def self.validate_transport_budget!(budget : CompressedStreamBudget, limits : CompressedStreamLimits) : Nil
      budget.ensure_direction(true)
      unless budget.limits.max_file_bytes == limits.max_file_bytes &&
             budget.limits.max_mark_bytes == limits.max_mark_bytes &&
             budget.limits.max_frame_compressed_bytes == limits.max_frame_compressed_bytes &&
             budget.limits.max_frame_decompressed_bytes == limits.max_frame_decompressed_bytes &&
             budget.limits.max_records == limits.max_records &&
             budget.limits.max_decoded_bytes == limits.max_decoded_bytes &&
             budget.limits.max_result_bytes == limits.max_result_bytes
        raise ArgumentError.new("recursive storage requires a compatible write transport budget")
      end
      nil
    end

    private def self.validate_mark_grid!(granules : Array(Array(StorageColumnValue))) : Nil
      if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
        raise ArgumentError.new("recursive storage requires a bounded nonempty mark grid")
      end
      total_rows = 0_u64
      granules.each do |rows|
        if rows.empty? || rows.size > WidePartWriter::MAX_ROWS_PER_MARK
          raise ArgumentError.new("recursive storage mark row count is outside the admitted range")
        end
        count = rows.size.to_u64
        if count > WidePart::MAX_ROWS.to_u64 - total_rows
          raise ArgumentError.new("recursive storage row count exceeds the part limit")
        end
        total_rows += count
      end
      nil
    end

    private def self.validate_rows!(
      schema : StorageColumnSchema,
      granules : Array(Array(StorageColumnValue)),
      budget : BinaryCodecBudget,
    ) : Nil
      granules.each do |rows|
        rows.each do |value|
          validate_value!(schema, value, 1, budget)
        end
      end
      nil
    end

    private def self.validate_value!(
      schema : StorageColumnSchema,
      value : StorageColumnValue,
      depth : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.visit_node(depth)
      if schema.tuple? || schema.array?
        unless (schema.tuple? && value.tuple?) || (schema.array? && value.array?)
          raise ArgumentError.new("recursive structural value kind differs from its declaration")
        end
        if schema.tuple? && value.child_count != schema.child_count
          raise ArgumentError.new("recursive Tuple value shape differs from its declaration")
        end
        child_count = value.child_count.to_u64
        budget.preflight_children(child_count) if child_count > 0_u64
        child_depth = next_depth(depth)
        value.child_count.times do |index|
          child_schema = schema.tuple? ? schema.child_at(index) : schema.child_at(0)
          validate_value!(child_schema, value.child_at(index), child_depth, budget)
        end
      elsif schema.object?
        raise ArgumentError.new("recursive JSON site requires an Object document value") unless value.object?
      elsif schema.bulk?
        raise ArgumentError.new("recursive BinaryBulk site requires a bulk value") unless value.bulk?
        unless value.bulk_value.type == schema.bulk_type
          raise ArgumentError.new("recursive BinaryBulk value type differs from its declaration")
        end
        ObjectRecursiveDeclaration.account_descriptor(schema.bulk_type, budget, budget.limits, depth) ||
          raise(UnsupportedFormatError.new("recursive BinaryBulk descriptor exceeds its inherited depth budget"))
      else
        raise UnsupportedFormatError.new("recursive storage schema contains an unknown node")
      end
      nil
    end

    private def self.collect_sites!(
      schema : StorageColumnSchema,
      values_by_mark : Array(Array(StorageColumnValue)),
      site_key : String,
      array_level : UInt64,
      physical_rows : Array(UInt64),
      current_grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      objects : Hash(String, Array(Array(ObjectDocument))),
      bulks : Hash(String, Array(Array(BinaryValue))),
      site_grids : Hash(String, StorageOccurrenceGrid),
      frames : Hash(String, StorageArrayOccurrenceFrame),
    ) : Nil
      validate_grid_values!(values_by_mark, current_grid)
      if schema.object?
        docs = Array(Array(ObjectDocument)).new(values_by_mark.size)
        total = total_values(values_by_mark)
        preflight_nested_marks!(values_by_mark.size, total, budget)
        values_by_mark.each do |values|
          mark_docs = Array(ObjectDocument).new(values.size)
          values.each { |value| mark_docs << value.object_document }
          docs << mark_docs
        end
        objects[site_key] = docs
        site_grids[site_key] = current_grid
        return nil
      end
      if schema.bulk?
        values = Array(Array(BinaryValue)).new(values_by_mark.size)
        total = total_values(values_by_mark)
        preflight_nested_marks!(values_by_mark.size, total, budget)
        values_by_mark.each do |mark|
          mark_values = Array(BinaryValue).new(mark.size)
          mark.each { |value| mark_values << value.bulk_value }
          values << mark_values
        end
        bulks[site_key] = values
        site_grids[site_key] = current_grid
        return nil
      end
      if schema.tuple?
        schema.child_count.times do |child_index|
          child_key = String.build { |io| io << site_key << "/tuple[" << child_index << ']' }
          child_marks = project_tuple_child(values_by_mark, child_index, budget)
          collect_sites!(
            schema.child_at(child_index), child_marks, child_key, array_level,
            physical_rows, current_grid, budget, objects, bulks, site_grids, frames
          )
        end
        return nil
      end
      if schema.array?
        frame = frames[site_key]? || raise(UnsupportedFormatError.new("recursive Array frame is missing"))
        unless frame.array_level == array_level
          raise UnsupportedFormatError.new("recursive Array frame level differs from its schema site")
        end
        validate_grid_values!(values_by_mark, frame.parent_grid)
        child_marks = flatten_array_children(values_by_mark, frame, budget)
        child_key = String.build { |io| io << site_key << "/array[0]" }
        collect_sites!(
          schema.child_at(0), child_marks, child_key, array_level + 1_u64,
          physical_rows, frame.child_grid, budget, objects, bulks, site_grids, frames
        )
        return nil
      end
      raise UnsupportedFormatError.new("recursive storage schema contains an unknown node")
    end

    # Census every structural Array site against the original value tree
    # before projecting Tuple columns or flattening any Array payload. The
    # ArraySite ordering is schema DFS order, so a site index is stable even
    # when an earlier site's child count is zero.
    private def self.prepare_array_frames(
      plan : RecursiveStorageColumnPlan,
      granules : Array(Array(StorageColumnValue)),
      physical_rows : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Hash(String, StorageArrayOccurrenceFrame)
      site_count = plan.array_site_count
      return Hash(String, StorageArrayOccurrenceFrame).new if site_count == 0
      unless plan.schema.array_site_count == site_count
        raise UnsupportedFormatError.new("recursive Array census differs from its admitted site roster")
      end

      mark_count = physical_rows.size
      counter_slots = checked_multiply(site_count.to_u64, mark_count.to_u64)
      counter_records = checked_multiply(counter_slots, 2_u64)
      if counter_records > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive Array census exceeds the Int32 allocation domain")
      end
      budget.ensure_future_nodes(2_u64)
      budget.ensure_future_elements(counter_records)
      2.times { budget.charge_node }
      budget.charge_elements(counter_records)

      parent_counts = Array(UInt64).new(counter_slots.to_i, 0_u64)
      child_counts = Array(UInt64).new(counter_slots.to_i, 0_u64)
      granules.each_with_index do |rows, mark|
        rows.each do |value|
          census_array_counts!(plan.schema, value, mark, 0, mark_count, parent_counts, child_counts)
        end
      end
      validate_array_count_grids!(plan.schema, 0, nil, physical_rows, mark_count, parent_counts, child_counts)

      total_parents = 0_u64
      total_children = 0_u64
      frame_records = 0_u64
      wire_bytes = 0_u64
      site_count.times do |site|
        site_parents = 0_u64
        site_children = 0_u64
        mark_count.times do |mark|
          slot = site * mark_count + mark
          parents = parent_counts[slot]
          children = child_counts[slot]
          if parents > Int32::MAX.to_u64 || children > Int32::MAX.to_u64
            raise UnsupportedFormatError.new("recursive Array schedule exceeds the Int32 mark domain")
          end
          site_parents = checked_add(site_parents, parents)
          site_children = checked_add(site_children, children)
        end
        if site_children > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("recursive Array children exceed the Int32 flattened domain")
        end
        total_children = checked_add(total_children, site_children)
        if total_children > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("recursive Array census exceeds the aggregate Int32 child domain")
        end
        if checked_multiply(site_parents, 8_u64) > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("recursive Array size lane exceeds the Int32 byte domain")
        end
        total_parents = checked_add(total_parents, site_parents)
        # Each frame charges Q + (K + 1) schedule/offset records and 4K grid
        # records. Reserve the aggregate before any per-site schedule copy.
        per_frame = checked_add(site_parents, mark_count.to_u64 + 1_u64)
        per_frame = checked_add(per_frame, checked_multiply(mark_count.to_u64, 4_u64))
        frame_records = checked_add(frame_records, per_frame)
        wire_bytes = checked_add(wire_bytes, checked_multiply(site_parents, 8_u64))
      end

      site_slots = checked_multiply(site_count.to_u64, mark_count.to_u64)
      # Retained writer-side schedule input: parent-row vectors plus nested
      # size vectors. Charge all container nodes/edges before creating them.
      workspace_nodes = checked_add(2_u64, checked_multiply(site_count.to_u64, 2_u64))
      workspace_nodes = checked_add(workspace_nodes, site_slots)
      workspace_elements = checked_add(checked_multiply(site_count.to_u64, 2_u64), checked_multiply(site_slots, 2_u64))
      workspace_elements = checked_add(workspace_elements, total_parents)
      all_nodes = checked_add(workspace_nodes, frame_records)
      all_elements = checked_add(workspace_elements, frame_records)
      budget.ensure_future_nodes(all_nodes)
      budget.ensure_future_elements(all_elements)
      budget.ensure_wire_bytes(wire_bytes)
      budget.charge_node
      budget.charge_node
      remaining_workspace_nodes = workspace_nodes - 2_u64
      while remaining_workspace_nodes > 0_u64
        budget.charge_node
        remaining_workspace_nodes -= 1_u64
      end
      budget.charge_elements(workspace_elements)

      parent_rows_by_site = Array(Array(UInt64)).new(site_count)
      sizes_by_site = Array(Array(Array(UInt64))).new(site_count)
      site_count.times do |site|
        parent_rows = Array(UInt64).new(mark_count)
        sizes_by_mark = Array(Array(UInt64)).new(mark_count)
        mark_count.times do |mark|
          count = parent_counts[site * mark_count + mark]
          parent_rows << count
          sizes_by_mark << Array(UInt64).new(count.to_i)
        end
        parent_rows_by_site << parent_rows
        sizes_by_site << sizes_by_mark
      end

      granules.each_with_index do |rows, mark|
        rows.each do |value|
          fill_array_sizes!(plan.schema, value, mark, 0, mark_count, sizes_by_site)
        end
      end
      site_count.times do |site|
        mark_count.times do |mark|
          expected = parent_counts[site * mark_count + mark]
          unless sizes_by_site[site][mark].size.to_u64 == expected
            raise UnsupportedFormatError.new("recursive Array size schedule changed after census")
          end
        end
      end

      frames = Hash(String, StorageArrayOccurrenceFrame).new(initial_capacity: site_count)
      site_count.times do |site_index|
        site = plan.array_site_at(site_index)
        frame = StorageArrayOccurrenceFrame.for_write(
          site.array_level, physical_rows, parent_rows_by_site[site_index], sizes_by_site[site_index], budget
        )
        frames[site.key] = frame
      end
      frames
    end

    private def self.census_array_counts!(
      schema : StorageColumnSchema,
      value : StorageColumnValue,
      mark : Int,
      site_start : Int32,
      mark_count : Int,
      parent_counts : Array(UInt64),
      child_counts : Array(UInt64),
    ) : Nil
      if schema.array?
        slot = site_start.to_i64 * mark_count.to_i64 + mark.to_i64
        slot_index = slot.to_i
        parent_counts[slot_index] = checked_add(parent_counts[slot_index], 1_u64)
        child_counts[slot_index] = checked_add(child_counts[slot_index], value.child_count.to_u64)
        child_start = next_site(site_start, 1)
        value.child_count.times do |index|
          census_array_counts!(schema.child_at(0), value.child_at(index), mark, child_start, mark_count, parent_counts, child_counts)
        end
      elsif schema.tuple?
        offset = site_start
        schema.child_count.times do |index|
          child_schema = schema.child_at(index)
          census_array_counts!(child_schema, value.child_at(index), mark, offset, mark_count, parent_counts, child_counts)
          offset = next_site(offset, child_schema.array_site_count)
        end
      end
      nil
    end

    private def self.fill_array_sizes!(
      schema : StorageColumnSchema,
      value : StorageColumnValue,
      mark : Int,
      site_start : Int32,
      mark_count : Int,
      sizes_by_site : Array(Array(Array(UInt64))),
    ) : Nil
      if schema.array?
        sizes_by_site[site_start][mark] << value.child_count.to_u64
        child_start = next_site(site_start, 1)
        value.child_count.times do |index|
          fill_array_sizes!(schema.child_at(0), value.child_at(index), mark, child_start, mark_count, sizes_by_site)
        end
      elsif schema.tuple?
        offset = site_start
        schema.child_count.times do |index|
          child_schema = schema.child_at(index)
          fill_array_sizes!(child_schema, value.child_at(index), mark, offset, mark_count, sizes_by_site)
          offset = next_site(offset, child_schema.array_site_count)
        end
      end
      nil
    end

    private def self.validate_array_count_grids!(
      schema : StorageColumnSchema,
      site_start : Int32,
      parent_site : Int32?,
      physical_rows : Array(UInt64),
      mark_count : Int,
      parent_counts : Array(UInt64),
      child_counts : Array(UInt64),
    ) : Nil
      if schema.array?
        mark_count.times do |mark|
          slot = site_start.to_i64 * mark_count.to_i64 + mark.to_i64
          slot_index = slot.to_i
          expected = if parent_index = parent_site
                       child_counts[(parent_index.to_i64 * mark_count.to_i64 + mark.to_i64).to_i]
                     else
                       physical_rows[mark]
                     end
          unless parent_counts[slot_index] == expected
            raise UnsupportedFormatError.new("recursive Array parent counts differ from the inherited occurrence grid")
          end
        end
        validate_array_count_grids!(
          schema.child_at(0), next_site(site_start, 1), site_start,
          physical_rows, mark_count, parent_counts, child_counts
        )
      elsif schema.tuple?
        offset = site_start
        schema.child_count.times do |index|
          child_schema = schema.child_at(index)
          validate_array_count_grids!(child_schema, offset, parent_site, physical_rows, mark_count, parent_counts, child_counts)
          offset = next_site(offset, child_schema.array_site_count)
        end
      end
      nil
    end

    private def self.next_site(site_start : Int32, increment : Int32) : Int32
      if increment < 0 || site_start > Int32::MAX - increment
        raise UnsupportedFormatError.new("recursive Array site index exceeds Int32")
      end
      site_start + increment
    end

    private def self.project_tuple_child(
      values_by_mark : Array(Array(StorageColumnValue)),
      child_index : Int32,
      budget : BinaryCodecBudget,
    ) : Array(Array(StorageColumnValue))
      total = total_values(values_by_mark)
      preflight_nested_marks!(values_by_mark.size, total, budget)
      projected = Array(Array(StorageColumnValue)).new(values_by_mark.size)
      values_by_mark.each do |mark|
        child_values = Array(StorageColumnValue).new(mark.size)
        mark.each { |value| child_values << value.child_at(child_index) }
        projected << child_values
      end
      projected
    end

    private def self.flatten_array_children(
      values_by_mark : Array(Array(StorageColumnValue)),
      frame : StorageArrayOccurrenceFrame,
      budget : BinaryCodecBudget,
    ) : Array(Array(StorageColumnValue))
      total_children = 0_u64
      frame.mark_count.times do |mark|
        total_children = checked_add(total_children, frame.child_count_at(mark))
      end
      preflight_nested_marks!(frame.mark_count, total_children, budget)
      flattened = Array(Array(StorageColumnValue)).new(frame.mark_count)
      values_by_mark.each_with_index do |parents, mark_index|
        children = Array(StorageColumnValue).new(frame.child_count_at(mark_index).to_i)
        parents.each { |parent| parent.child_count.times { |index| children << parent.child_at(index) } }
        unless children.size.to_u64 == frame.child_count_at(mark_index)
          raise UnsupportedFormatError.new("Array child rows changed after schedule admission")
        end
        flattened << children
      end
      flattened
    end

    private def self.preflight_nested_marks!(
      mark_count : Int,
      value_count : UInt64,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.ensure_future_nodes(mark_count.to_u64 + 1_u64)
      element_records = checked_add(value_count, mark_count.to_u64)
      budget.ensure_future_elements(element_records)
      (mark_count + 1).times { budget.charge_node }
      budget.charge_elements(element_records)
      nil
    end

    private def self.mark_counts_for(
      values_by_mark : Array(Array(StorageColumnValue)),
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(values_by_mark.size.to_u64)
      budget.charge_node
      budget.charge_elements(values_by_mark.size.to_u64)
      counts = Array(UInt64).new(values_by_mark.size)
      values_by_mark.each do |mark|
        count = mark.size.to_u64
        if count > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("recursive child rows exceed the Int32 domain")
        end
        counts << count
      end
      counts
    end

    private def self.validate_grid_values!(
      values_by_mark : Array(Array(StorageColumnValue)),
      grid : StorageOccurrenceGrid,
    ) : Nil
      unless values_by_mark.size == grid.mark_count
        raise UnsupportedFormatError.new("recursive child value grid differs from the parent mark grid")
      end
      values_by_mark.each_with_index do |mark, index|
        unless mark.size.to_u64 == grid.logical_occurrences_at(index)
          raise UnsupportedFormatError.new("recursive child value count differs from its inherited occurrence grid")
        end
      end
      nil
    end

    private def self.total_values(values_by_mark : Array(Array(StorageColumnValue))) : UInt64
      total = 0_u64
      values_by_mark.each do |mark|
        total = checked_add(total, mark.size.to_u64)
      end
      if total > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive child value grid exceeds the Int32 flattened domain")
      end
      total
    end

    private def self.validate_collected_rosters!(
      plan : RecursiveStorageColumnPlan,
      objects : Hash(String, Array(Array(ObjectDocument))),
      bulks : Hash(String, Array(Array(BinaryValue))),
      site_grids : Hash(String, StorageOccurrenceGrid),
      frames : Hash(String, StorageArrayOccurrenceFrame),
    ) : Nil
      object_keys = Array(String).new(plan.object_site_count) { |index| plan.object_site_at(index).key }.sort!
      bulk_keys = Array(String).new(plan.bulk_site_count) { |index| plan.bulk_site_at(index).key }.sort!
      dynamic_keys = Array(String).new(plan.dynamic_site_count) { |index| plan.dynamic_site_at(index).key }.sort!
      array_keys = Array(String).new(plan.array_site_count) { |index| plan.array_site_at(index).key }.sort!
      all_bulk_keys = bulk_keys + dynamic_keys
      all_bulk_keys.sort!
      expected_grid_keys = object_keys + all_bulk_keys
      expected_grid_keys.sort!
      unless objects.keys.sort == object_keys && bulks.keys.sort == all_bulk_keys &&
             frames.keys.sort == array_keys && site_grids.keys.sort == expected_grid_keys
        raise UnsupportedFormatError.new("recursive collected site roster differs from its admitted plan")
      end
      nil
    end

    private def self.add_pair!(
      pairs : Hash(String, CompressedMarkFiles),
      name : String,
      pair : CompressedMarkFiles,
    ) : Nil
      if pairs.has_key?(name)
        raise UnsupportedFormatError.new("recursive physical lanes collide after site encoding")
      end
      pairs[String.new(name.to_slice)] = pair
      nil
    end

    private def self.next_depth(depth : Int32) : Int32
      if depth == Int32::MAX
        raise UnsupportedFormatError.new("recursive storage schema depth exceeds Int32")
      end
      depth + 1
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("recursive storage count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      product = left.to_u128 * right.to_u128
      if product > UInt64::MAX.to_u128
        raise UnsupportedFormatError.new("recursive storage count overflows UInt64")
      end
      product.to_u64
    end
  end
end
