module CrystalClick
  # Reads a complete static BinaryBulk physical column through the shared role
  # grammar. Physical marks remain rooted at the part's parent row grid;
  # flattened field schedules are interpreted by the codec. The reader
  # assumes a quiescent part: PartStreamSource checks declared file sizes, but
  # does not authenticate whole-file hashes for unselected lanes.
  class BinaryBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @source : PartStreamSource
    @physical : BinaryBulkPhysicalPlan
    @grids : Hash(String, CompressedMarkGrid)
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : BinaryBulkColumnReader
      new(part_path, column_name, expected_type, limits, transport_limits)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @type : BinaryDataType,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
    )
      # Bound descriptor traversal and display-name rendering before asking
      # summary predicates, plans, or metadata owners to materialize anything.
      name_budget = BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      canonical_bytes = canonical.bytesize.to_u64
      name_budget.ensure_wire_bytes(canonical_bytes)
      name_budget.charge_wire_bytes(canonical_bytes)
      @schema_declaration = String.new(canonical.to_slice)

      # Nominal static declarations enter through their exact declaration
      # policy even when callers bypass WidePart's table admission adapter.
      if @type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE ||
         (@type.tag == BinaryDataType::TAG_NULLABLE &&
         @type.child_at(0).tag == BinaryDataType::TAG_SIMPLE_AGGREGATE)
        SimpleAggregateBulkColumnDeclaration.new(@type, @limits)
      end
      if @type.contains_aggregate_function?
        # Root Count predates the generic Sum-family route and retains its
        # specialized BinaryBulk admission. Every other admitted tree uses the
        # shared recursive static profile, with aggregate leaves remaining
        # opaque to their argument descriptors.
        unless @type.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION && @type.aggregate_count_type
          BinaryAggregateFunctionBulkColumnDeclaration.new(@type, @limits)
        end
      end

      # Validate static no-JSON/no-Dynamic binary admission only after the
      # bounded type-name walk has established the descriptor's depth/node
      # boundary. Profile-dependent planning follows metadata inspection.
      if @type.contains_json?
        raise UnsupportedFormatError.new("JSON requires a bound column-specific physical context")
      end
      if @type.contains_dynamic?
        raise UnsupportedFormatError.new("Dynamic requires a bound column-specific physical context")
      end
      static_plan = BinaryBulkTypePlan.new(
        @type, BinaryBulkProfile.single_stream, nil, @limits, false
      )
      static_plan.role_count

      raise ArgumentError.new("Binary bulk column name must be nonempty") if column_name.empty?
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)

      metadata = ObjectColumnPartMetadata.open(
        @part_path,
        @column_name,
        ->(declaration : String) {
          unless declaration == canonical
            raise CorruptPartError.new("Binary bulk source declaration differs from the expected nominal descriptor")
          end
          nil
        },
      )
      @source_declaration = metadata.source_declaration
      @ordinary_profile = metadata.ordinary_profile
      if metadata.row_count == 0_u64
        raise CorruptPartError.new("Binary bulk part must contain at least one parent row")
      end

      name_context = PhysicalStreamPlanContext.new(@limits)
      @physical = BinaryBulkPhysicalPlan.new(
        @type, @column_name, @ordinary_profile, @limits, name_context
      )
      role_names = @physical.stream_names
      expected_stream_names = role_names.values.sort!
      actual_stream_names = metadata.selected_stream_names.sort!
      unless actual_stream_names == expected_stream_names
        raise CorruptPartError.new("Binary bulk selected columns_substreams roster differs from the physical plan")
      end

      @source = PartStreamSource.new(@part_path)
      codec_budget = BinaryCodecBudget.new(@limits)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      grids = Hash(String, CompressedMarkGrid).new(initial_capacity: role_names.size)
      parent_rows = nil.as(Array(UInt64)?)
      logical_bytes = 0_u64

      role_names.keys.sort!.each do |role|
        prefix = @physical.prefix_size_for(role)
        grid = @source.inspect_grid(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true),
          prefix,
          transport_budget,
        )
        if current_rows = parent_rows
          unless grid.rows_per_mark == current_rows
            raise CorruptPartError.new("Binary bulk physical lanes disagree on the parent mark grid")
          end
        else
          parent_rows = grid.rows_per_mark
        end
        logical_size = grid.logical_size.to_u64
        if logical_size > UInt64::MAX - logical_bytes
          raise CorruptPartError.new("Binary bulk logical stream byte count overflows")
        end
        logical_bytes += logical_size
        grids[String.new(role.to_slice)] = grid

        if BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
          BinaryBulkPhysicalPrefixAdapter.preflight_read(
            [{role, prefix, 1}], codec_budget
          )
          window = @source.read_window(
            @physical.data_file_for(role, true),
            @physical.marks_file_for(role, true),
            0,
            0,
            prefix,
            transport_budget,
          )
          BinaryBulkPhysicalPrefixAdapter.read_lane(
            role, window.bytes, window.offsets, prefix
          )
        end
      end

      rows = parent_rows || raise(CorruptPartError.new("Binary bulk physical plan has no stream lanes"))
      if rows.empty? || rows.size > WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("Binary bulk physical mark count is outside the admitted range")
      end
      total_rows = 0_u64
      rows.each do |count|
        if count > WidePart::MAX_ROWS.to_u64 - total_rows
          raise CorruptPartError.new("Binary bulk physical row count exceeds the part limit")
        end
        total_rows += count
      end
      unless total_rows == metadata.row_count
        raise CorruptPartError.new("Binary bulk parent mark grid differs from count.txt")
      end

      # Validate every mark's complete Array-to-QBit occurrence schedule
      # before publishing the reader. This reads only bounded Array size
      # buffers and compares plane/null-map grid deltas; it does not decode
      # unselected QBit plane payloads.
      if site = static_plan.qbit_array_site
        BinaryQBitArrayOccurrenceSchedule.validate!(
          site,
          @physical,
          @source,
          grids,
          rows,
          @limits,
          transport_budget,
        )
      end

      @grids = grids
      @mark_row_counts = rows
      @row_count = metadata.row_count
      @mark_count = rows.size.to_i32
      @physical_stream_names = expected_stream_names
      @selected_checksum_names = checksum_names(role_names)
      @logical_read_bytes = logical_bytes
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def mark_row_counts : Array(UInt64)
      @mark_row_counts.dup
    end

    def physical_stream_names : Array(String)
      copy_strings(@physical_stream_names)
    end

    def selected_checksum_names : Array(String)
      copy_strings(@selected_checksum_names)
    end

    # Logical retained-owner charge for this reader's actual inspected grids.
    # The map count and every grid's mark-specific arrays come from the
    # retained structures, not an inferred profile roster.
    def retained_grid_workspace_bytes : UInt64
      grid_map_workspace_bytes(@grids)
    end

    # Returns selected physical marks → parent rows → exact-type BinaryValues.
    # Any LC site forces complete-lane replay, including an empty end window,
    # so malformed off-window dictionary schedules cannot be hidden.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = BinaryCodecBudget.new(@limits)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      replay_complete = @type.contains_low_cardinality?
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? @mark_count : mark_count
      rows_for_decode = replay_complete ? @mark_row_counts : selected_rows(first_mark, mark_count)
      role_names = @physical.stream_names

      prefix_reads = [] of Tuple(String, Int32, Int32)
      role_names.keys.sort!.each do |role|
        prefix = @physical.prefix_size_for(role)
        next unless BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
        if read_count == Int32::MAX
          raise CorruptPartError.new("Binary bulk Variant coordinate count exceeds the supported domain")
        end
        prefix_reads << {role, prefix, read_count + 1}
      end
      BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

      streams_by_role = Hash(String, BinaryBulkStream).new(initial_capacity: role_names.size)
      role_names.keys.sort!.each do |role|
        grid = @grids[role]? || raise(CorruptPartError.new("Binary bulk role has no inspected parent grid"))
        prefix = @physical.prefix_size_for(role)
        window = @source.read_window(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true),
          read_first,
          read_count,
          prefix,
          transport_budget,
        )
        expected_rows = selected_rows(read_first, read_count)
        unless window.rows_per_mark == expected_rows && grid.mark_count == @mark_count
          raise CorruptPartError.new("Binary bulk selected lane window differs from its inspected parent grid")
        end
        logical = BinaryBulkPhysicalPrefixAdapter.read_lane(
          role, window.bytes, window.offsets, prefix
        )
        streams_by_role[role] = BinaryBulkStream.new(logical[0], logical[1])
      end

      stream_set = BinaryBulkStreams.new(read_count, streams_by_role)
      decoded = BinaryBulkDecoder.decode(
        @type,
        stream_set,
        rows_for_decode,
        codec_budget,
        replay_complete ? first_mark : 0,
        mark_count,
        @ordinary_profile,
      )
      unless decoded.size == mark_count
        raise CorruptPartError.new("Binary bulk decoder returned the wrong physical mark count")
      end
      decoded.each_with_index do |mark_values, index|
        unless mark_values.size.to_u64 == @mark_row_counts[first_mark + index]
          raise CorruptPartError.new("Binary bulk decoder returned the wrong parent row count")
        end
      end
      decoded
    end

    private def checksum_names(role_names : Hash(String, String)) : Array(String)
      names = Array(String).new(role_names.size * 2)
      role_names.each_key do |role|
        names << @physical.data_file_for(role, true)
        names << @physical.marks_file_for(role, true)
      end
      names.sort!
    end

    private def grid_map_workspace_bytes(grids : Hash(String, CompressedMarkGrid)) : UInt64
      bytes = instance_sizeof(Hash(String, CompressedMarkGrid)).to_u64
      key_and_value_slots = sizeof(Pointer(String)).to_u64 +
                            sizeof(Pointer(CompressedMarkGrid)).to_u64 +
                            sizeof(UInt64).to_u64
      bytes = checked_grid_workspace_add(
        bytes,
        checked_grid_workspace_multiply(grids.size.to_u64, key_and_value_slots)
      )
      grids.each do |key, grid|
        bytes = checked_grid_workspace_add(bytes, grid_key_workspace_bytes(key))
        bytes = checked_grid_workspace_add(bytes, compressed_grid_workspace_bytes(grid))
      end
      bytes
    end

    private def compressed_grid_workspace_bytes(grid : CompressedMarkGrid) : UInt64
      marks = grid.mark_count.to_u64
      positions = checked_grid_workspace_add(marks, 1_u64)
      bytes = instance_sizeof(CompressedMarkGrid).to_u64
      bytes = checked_grid_workspace_add(bytes, instance_sizeof(Array(Int64)).to_u64)
      bytes = checked_grid_workspace_add(
        bytes,
        checked_grid_workspace_multiply(positions, sizeof(Int64).to_u64)
      )
      bytes = checked_grid_workspace_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_grid_workspace_add(bytes, checked_grid_workspace_multiply(marks, sizeof(UInt64).to_u64))
    end

    private def grid_key_workspace_bytes(key : String) : UInt64
      checked_grid_workspace_add(
        instance_sizeof(String).to_u64,
        checked_grid_workspace_add(key.bytesize.to_u64, 1_u64)
      )
    end

    private def checked_grid_workspace_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Binary bulk retained grid workspace overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_grid_workspace_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise BoundsError.new("Binary bulk retained grid workspace overflows UInt64")
      end
      left * right
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      total = @mark_count.to_i128
      if first < 0_i128 || first > total || count < 0_i128 || count > total - first
        raise ArgumentError.new("Binary bulk selected mark range is outside the physical grid")
      end
      nil
    end

    private def selected_rows(first_mark : Int, count : Int) : Array(UInt64)
      Array(UInt64).new(count) { |index| @mark_row_counts[first_mark + index] }
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end
  end
end
