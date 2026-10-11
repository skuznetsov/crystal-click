module CrystalClick
  # Translates one detached Compact callback window into the role-addressed
  # BinaryBulk lanes consumed by the existing recursive decoder. This owner
  # interprets physical callback framing; it does not decode typed values.
  class CompactBinaryBulkNormalizer
    # Scalar-only descriptor census used before the operation constructs
    # retained role/name plans. It deliberately stores no child arrays or
    # detached names.
    private struct SetupCensus
      getter nodes : UInt64
      getter edges : UInt64
      getter descriptor_bytes : UInt64
      getter variant_name_bytes : UInt64
      getter variant_arm_count : UInt64
      getter qbit_plane_count : UInt64
      getter max_depth : UInt64
      getter type_name_bound : UInt64

      def initialize(
        @nodes : UInt64,
        @edges : UInt64,
        @descriptor_bytes : UInt64,
        @variant_name_bytes : UInt64,
        @variant_arm_count : UInt64,
        @qbit_plane_count : UInt64,
        @max_depth : UInt64,
        @type_name_bound : UInt64,
      )
      end
    end

    @type : BinaryDataType
    @column : String
    @profile : BinaryBulkProfile
    @limits : BinaryCodecLimits

    def initialize(
      @type : BinaryDataType,
      column : String,
      @profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      raise ArgumentError.new("Compact selected column name must be nonempty") if column.empty?
      @column = String.new(column.to_slice)
    end

    # Logical retained normalizer owners, derived from stored fields without
    # cloning. The shared parsed BinaryDataType descriptor graph is owned
    # intentionally excluded from this baseline census.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactBinaryBulkNormalizer).to_u64
      bytes = checked_add(bytes, instance_sizeof(BinaryBulkProfile).to_u64)
      checked_add(bytes, checked_add(instance_sizeof(String).to_u64, checked_add(@column.bytesize.to_u64, 1_u64)))
    end

    # Returns the normalized streams and the detached parent-row grid for the
    # supplied window. The caller chooses a complete part window when the
    # descriptor contains LowCardinality state that requires full-grid replay.
    def normalize(
      window : CompactPartPhysicalWindow,
      budget : BinaryCodecBudget,
    ) : Tuple(BinaryBulkStreams, Array(UInt64))
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      normalize(window, budget, no_workspace_observer, 0_u64)
    end

    def normalize(
      window : CompactPartPhysicalWindow,
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
    ) : Tuple(BinaryBulkStreams, Array(UInt64))
      unless !budget.writing?
        raise ArgumentError.new("Compact BinaryBulk normalization requires a read-direction budget")
      end
      unless window.column == @column
        raise ArgumentError.new("Compact physical window does not match the selected column")
      end

      mark_count = window.mark_count
      setup_workspace_bytes = estimated_setup_workspace_bytes(@type) || 0_u64
      # Account the retained serializer plans, callback roster, and the active
      # granule cursor before constructing any of them. The same allowance is
      # carried by every later observation while those owners remain live.
      workspace_observer.call(checked_add(physical_workspace_bytes, setup_workspace_bytes))
      operation_observer = ->(workspace_bytes : UInt64) {
        workspace_observer.call(checked_add(workspace_bytes, setup_workspace_bytes))
      }

      type_context = BinaryCodecContext.new(@limits, nil, false, budget, false, false)
      type_context.validate_type_tree(@type)
      physical_plan = validated_physical_plan
      roles = BinaryBulkTypePlan.new(@type, @profile, nil, @limits, false).roles

      observe_workspace(
        operation_observer,
        physical_workspace_bytes,
        roles.size,
        mark_count,
        0_u64,
        0_u64,
      )
      expected_events = callback_roster(physical_plan)
      observe_workspace(
        operation_observer,
        physical_workspace_bytes,
        roles.size,
        mark_count,
        0_u64,
        0_u64,
      )
      granules = window.granules
      offsets_per_role = mark_count.to_u64 + 1_u64
      grid_records = multiply_checked(roles.size.to_u64, offsets_per_role)
      budget.preflight_children(grid_records)
      grid_records.times { budget.charge_node }

      # Reserve the complete lane/offset grid before constructing builders or
      # appending the eight-byte LowCardinality version headers.
      observe_workspace(
        operation_observer,
        physical_workspace_bytes,
        roles.size,
        mark_count,
        0_u64,
        0_u64,
      )
      lanes = Hash(String, CompactBinaryBulkLaneBuilder).new(initial_capacity: roles.size)
      roles.each do |role|
        dictionary_header = role.ends_with?(".dictionary")
        lane = CompactBinaryBulkLaneBuilder.new(String.new(role.to_slice), dictionary_header ? 8_u64 : 0_u64)
        if dictionary_header
          observe_workspace(
            operation_observer,
            physical_workspace_bytes,
            roles.size,
            mark_count,
            checked_add(sum_lane_data_bytes(lanes), 8_u64),
            8_u64,
          )
          lane.append_u64(BinaryLowCardinalityStorageStreams::VERSION, budget)
        end
        lanes[role] = lane
      end

      observe_workspace(
        operation_observer,
        physical_workspace_bytes,
        roles.size,
        mark_count,
        0_u64,
        checked_multiply(mark_count.to_u64, sizeof(UInt64).to_u64),
      )
      rows_per_mark = Array(UInt64).new(mark_count)
      granules.each do |granule|
        if granule.row_count > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact parent rows exceed the BinaryBulk in-memory domain")
        end
        rows_per_mark << granule.row_count
        cursor = CompactBinaryBulkGranuleCursor.new(window.mode, granule.shards, expected_events)
        observe_workspace(
          operation_observer,
          physical_workspace_bytes,
          roles.size,
          mark_count,
          sum_lane_data_bytes(lanes),
          estimated_variant_mode_workspace_bytes(roles.size),
        )
        variant_modes = Hash(String, UInt64).new

        walk_prefix(@type, "root", cursor, physical_plan, variant_modes)
        walk_body(
          @type,
          "root",
          granule.row_count,
          cursor,
          physical_plan,
          lanes,
          variant_modes,
          budget,
          operation_observer,
          physical_workspace_bytes,
          mark_count,
        )
        cursor.finish_granule
        lanes.each_value(&.finish_mark)
      end

      observe_workspace(
        operation_observer,
        physical_workspace_bytes,
        roles.size,
        mark_count,
        sum_lane_data_bytes(lanes),
        0_u64,
        true,
      )
      streams = Hash(String, BinaryBulkStream).new(initial_capacity: lanes.size)
      lanes.each do |role, lane|
        unless lane.mark_count == mark_count
          raise CorruptPartError.new("Compact normalized lane has an incomplete mark grid")
        end
        streams[String.new(role.to_slice)] = lane.build
      end
      {BinaryBulkStreams.new(mark_count, streams), rows_per_mark}
    end

    # Exact ordered prefix-then-body callback names for metadata-only mrk4
    # binding. mrk3 is intentionally not name-bound: its one physical slot is
    # a grammar-delimited tape and callers must not fabricate substream names.
    def expected_physical_callback_roster : Array(String)
      callback_roster(validated_physical_plan)
    end

    private def validated_physical_plan : BinaryBulkPhysicalPlan
      type_plan = BinaryBulkTypePlan.new(@type, @profile, nil, @limits, false)
      physical = BinaryBulkPhysicalPlan.new(@type, @column, @profile, @limits)
      names = physical.stream_names
      unless names.keys.sort! == type_plan.roles
        raise CorruptPartError.new("Compact physical roles differ from the selected recursive descriptor")
      end
      physical
    end

    private def callback_roster(
      physical : BinaryBulkPhysicalPlan,
    ) : Array(String)
      expected = [] of String
      append_prefix_roster(@type, "root", physical, expected)
      append_body_roster(@type, "root", physical, expected)

      seen = Set(String).new
      expected.each do |name|
        unless seen.add?(name)
          raise CorruptPartError.new("Compact serializer maps multiple callbacks to one physical stream")
        end
      end
      expected
    end

    private def append_prefix_roster(
      type : BinaryDataType,
      role : String,
      physical : BinaryBulkPhysicalPlan,
      expected : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_prefix_roster(type.child_at(0), role, physical, expected)
      when BinaryDataType::TAG_LOW_CARDINALITY
        expected << prefix_name("#{role}.dictionary", physical)
      when BinaryDataType::TAG_VARIANT
        expected << prefix_name("#{role}.discriminators", physical)
        type.child_count.times do |index|
          append_prefix_roster(type.child_at(index), "#{role}.arm.#{index}", physical, expected)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_prefix_roster(type.child_at(0), "#{role}.elements", physical, expected)
      when BinaryDataType::TAG_NULLABLE
        append_prefix_roster(type.child_at(0), "#{role}.nested", physical, expected)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_prefix_roster(type.child_at(index), "#{role}.field.#{index}", physical, expected)
        end
      when BinaryDataType::TAG_MAP
        append_prefix_roster(type.child_at(0), "#{role}.elements.field.0", physical, expected)
        append_prefix_roster(type.child_at(1), "#{role}.elements.field.1", physical, expected)
      end
      nil
    end

    private def append_body_roster(
      type : BinaryDataType,
      role : String,
      physical : BinaryBulkPhysicalPlan,
      expected : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_body_roster(type.child_at(0), role, physical, expected)
      when BinaryDataType::TAG_STRING
        if @profile.with_size_stream?
          expected << body_name("#{role}.string_sizes", physical)
          expected << body_name("#{role}.data", physical)
        else
          expected << body_name("#{role}.data", physical)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        expected << body_name("#{role}.sizes", physical)
        append_body_roster(type.child_at(0), "#{role}.elements", physical, expected)
      when BinaryDataType::TAG_NULLABLE
        expected << body_name("#{role}.nulls", physical)
        append_body_roster(type.child_at(0), "#{role}.nested", physical, expected)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          expected << body_name("#{role}.data", physical)
        else
          type.child_count.times do |index|
            append_body_roster(type.child_at(index), "#{role}.field.#{index}", physical, expected)
          end
        end
      when BinaryDataType::TAG_MAP
        expected << body_name("#{role}.sizes", physical)
        append_body_roster(type.child_at(0), "#{role}.elements.field.0", physical, expected)
        append_body_roster(type.child_at(1), "#{role}.elements.field.1", physical, expected)
      when BinaryDataType::TAG_LOW_CARDINALITY
        expected << body_name("#{role}.dictionary", physical)
        expected << body_name("#{role}.indexes", physical)
      when BinaryDataType::TAG_VARIANT
        expected << body_name("#{role}.discriminators", physical)
        type.child_count.times do |index|
          append_body_roster(type.child_at(index), "#{role}.arm.#{index}", physical, expected)
        end
      else
        expected << body_name("#{role}.data", physical)
      end
      nil
    end

    private def walk_prefix(
      type : BinaryDataType,
      role : String,
      cursor : CompactBinaryBulkGranuleCursor,
      physical : BinaryBulkPhysicalPlan,
      variant_modes : Hash(String, UInt64),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        walk_prefix(type.child_at(0), role, cursor, physical, variant_modes)
      when BinaryDataType::TAG_LOW_CARDINALITY
        dictionary_role = "#{role}.dictionary"
        cursor.begin_event(prefix_name(dictionary_role, physical))
        version = cursor.read_u64
        cursor.finish_event
        unless version == BinaryLowCardinalityStorageStreams::VERSION
          raise UnsupportedFormatError.new("unsupported Compact LowCardinality state-prefix version")
        end
      when BinaryDataType::TAG_VARIANT
        discriminator_role = "#{role}.discriminators"
        cursor.begin_event(prefix_name(discriminator_role, physical))
        mode = cursor.read_u64
        cursor.finish_event
        unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
               mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
          raise UnsupportedFormatError.new("unsupported Compact Variant discriminator mode")
        end
        variant_modes[discriminator_role] = mode
        type.child_count.times do |index|
          walk_prefix(type.child_at(index), "#{role}.arm.#{index}", cursor, physical, variant_modes)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        walk_prefix(type.child_at(0), "#{role}.elements", cursor, physical, variant_modes)
      when BinaryDataType::TAG_NULLABLE
        walk_prefix(type.child_at(0), "#{role}.nested", cursor, physical, variant_modes)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          walk_prefix(type.child_at(index), "#{role}.field.#{index}", cursor, physical, variant_modes)
        end
      when BinaryDataType::TAG_MAP
        walk_prefix(type.child_at(0), "#{role}.elements.field.0", cursor, physical, variant_modes)
        walk_prefix(type.child_at(1), "#{role}.elements.field.1", cursor, physical, variant_modes)
      end
      nil
    end

    private def walk_body(
      type : BinaryDataType,
      role : String,
      count : UInt64,
      cursor : CompactBinaryBulkGranuleCursor,
      physical : BinaryBulkPhysicalPlan,
      lanes : Hash(String, CompactBinaryBulkLaneBuilder),
      variant_modes : Hash(String, UInt64),
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
      mark_count : Int32,
    ) : Nil
      if count > Int32::MAX.to_u64 || count > @limits.max_elements.to_u64
        raise CorruptPartError.new("Compact recursive occurrence count exceeds its bounded domain")
      end

      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        walk_body(
          type.child_at(0), role, count, cursor, physical, lanes, variant_modes, budget,
          workspace_observer, physical_workspace_bytes, mark_count
        )
      when BinaryDataType::TAG_STRING
        data_role = "#{role}.data"
        if @profile.with_size_stream?
          size_role = "#{role}.string_sizes"
          size_bytes = exact_event(size_role, count, 8_u64, cursor, physical)
          total_bytes = sum_u64_values(size_bytes, count, @limits.max_bytes.to_u64)
          append_lane(lanes, size_role, size_bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
          data_bytes = exact_event(data_role, total_bytes, 1_u64, cursor, physical)
          append_lane(lanes, data_role, data_bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
        else
          cursor.begin_event(body_name(data_role, physical))
          lane = lane_for(lanes, data_role)
          count.to_i.times do
            value_start = cursor.position
            size = cursor.read_var_uint
            if size > @limits.max_bytes.to_u64 || size > Int32::MAX.to_u64
              raise CorruptPartError.new("Compact String value exceeds its bounded byte domain")
            end
            cursor.read_exact(size.to_i32)
            append_lane(
              lanes,
              data_role,
              cursor.consumed_slice(value_start),
              budget,
              workspace_observer,
              physical_workspace_bytes,
              mark_count,
            )
          end
          cursor.finish_event
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        size_role = "#{role}.sizes"
        size_bytes = exact_event(size_role, count, 8_u64, cursor, physical)
        child_count = sum_u64_values(size_bytes, count, @limits.max_elements.to_u64)
        append_lane(lanes, size_role, size_bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
        walk_body(
          type.child_at(0), "#{role}.elements", child_count, cursor, physical, lanes, variant_modes, budget,
          workspace_observer, physical_workspace_bytes, mark_count
        )
      when BinaryDataType::TAG_NULLABLE
        null_role = "#{role}.nulls"
        nulls = exact_event(null_role, count, 1_u64, cursor, physical)
        nulls.each do |value|
          if value > 1_u8
            raise CorruptPartError.new("Compact Nullable null-map value is not zero or one")
          end
        end
        append_lane(lanes, null_role, nulls, budget, workspace_observer, physical_workspace_bytes, mark_count)
        walk_body(
          type.child_at(0), "#{role}.nested", count, cursor, physical, lanes, variant_modes, budget,
          workspace_observer, physical_workspace_bytes, mark_count
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          data_role = "#{role}.data"
          values = exact_event(data_role, count, 1_u64, cursor, physical)
          values.each do |value|
            unless value == 0x30_u8
              raise CorruptPartError.new("Compact empty Tuple body has an invalid sentinel")
            end
          end
          append_lane(lanes, data_role, values, budget, workspace_observer, physical_workspace_bytes, mark_count)
        else
          type.child_count.times do |index|
            walk_body(
              type.child_at(index), "#{role}.field.#{index}", count, cursor, physical, lanes, variant_modes, budget,
              workspace_observer, physical_workspace_bytes, mark_count
            )
          end
        end
      when BinaryDataType::TAG_MAP
        size_role = "#{role}.sizes"
        size_bytes = exact_event(size_role, count, 8_u64, cursor, physical)
        pair_count = sum_u64_values(size_bytes, count, @limits.max_elements.to_u64)
        append_lane(lanes, size_role, size_bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
        walk_body(
          type.child_at(0), "#{role}.elements.field.0", pair_count,
          cursor, physical, lanes, variant_modes, budget,
          workspace_observer, physical_workspace_bytes, mark_count
        )
        walk_body(
          type.child_at(1), "#{role}.elements.field.1", pair_count,
          cursor, physical, lanes, variant_modes, budget,
          workspace_observer, physical_workspace_bytes, mark_count
        )
      when BinaryDataType::TAG_LOW_CARDINALITY
        dictionary_role = "#{role}.dictionary"
        cursor.begin_event(body_name(dictionary_role, physical))
        cursor.finish_event
        index_role = "#{role}.indexes"
        cursor.begin_event(body_name(index_role, physical))
        start = cursor.position
        scan_low_cardinality_index(type.child_at(0), count, cursor)
        index_bytes = cursor.consumed_slice(start)
        cursor.finish_event
        append_lane(lanes, index_role, index_bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
      when BinaryDataType::TAG_VARIANT
        discriminator_role = "#{role}.discriminators"
        mode = variant_modes[discriminator_role]? ||
               raise(CorruptPartError.new("Compact Variant body has no matching state prefix"))
        cursor.begin_event(body_name(discriminator_role, physical))
        body_start = cursor.position
        if cursor_mrk4?(cursor)
          # mrk4 gives an exact callback slice; consuming it here leaves
          # grammar validation to the shared framing adapter below.
          body = cursor.read_exact(cursor.remaining)
        else
          read_variant_tape_body(cursor, mode, count)
          body = cursor.consumed_slice(body_start)
        end
        cursor.finish_event
        tags = normalize_variant_body(
          discriminator_role,
          mode,
          count,
          body,
          budget,
          lanes,
          workspace_observer,
          physical_workspace_bytes,
          mark_count,
        )
        append_lane(lanes, discriminator_role, tags, budget, workspace_observer, physical_workspace_bytes, mark_count)
        observe_workspace(
          workspace_observer,
          physical_workspace_bytes,
          lanes.size,
          mark_count,
          sum_lane_data_bytes(lanes),
          checked_multiply(type.child_count.to_u64, sizeof(UInt64).to_u64),
        )
        counts = Array(UInt64).new(type.child_count, 0_u64)
        tags.each do |tag|
          next if tag == 0xff_u8
          index = tag.to_i
          if index >= type.child_count
            raise CorruptPartError.new("Compact Variant discriminator is outside its arm roster")
          end
          counts[index] += 1_u64
        end
        type.child_count.times do |index|
          walk_body(
            type.child_at(index), "#{role}.arm.#{index}", counts[index],
            cursor, physical, lanes, variant_modes, budget,
            workspace_observer, physical_workspace_bytes, mark_count
          )
        end
      else
        data_role = "#{role}.data"
        width = if type.tag == BinaryDataType::TAG_NOTHING || type.tag == BinaryDataType::TAG_BOOL
                  1_u64
                else
                  (type.fixed_width || raise(UnsupportedFormatError.new("unsupported Compact static BinaryBulk leaf"))).to_u64
                end
        bytes = exact_event(data_role, count, width, cursor, physical)
        if type.tag == BinaryDataType::TAG_NOTHING
          bytes.each do |value|
            unless value == 0x30_u8
              raise CorruptPartError.new("Compact Nothing body has an invalid sentinel")
            end
          end
        end
        append_lane(lanes, data_role, bytes, budget, workspace_observer, physical_workspace_bytes, mark_count)
      end
      nil
    end

    private def exact_event(
      role : String,
      count : UInt64,
      width : UInt64,
      cursor : CompactBinaryBulkGranuleCursor,
      physical : BinaryBulkPhysicalPlan,
    ) : Bytes
      size = multiply_checked(count, width)
      if size > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact callback byte extent exceeds the in-memory domain")
      end
      cursor.begin_event(body_name(role, physical))
      bytes = cursor.read_exact(size.to_i32)
      cursor.finish_event
      bytes
    end

    private def scan_low_cardinality_index(
      child_type : BinaryDataType,
      expected_rows : UInt64,
      cursor : CompactBinaryBulkGranuleCursor,
    ) : Nil
      return nil if expected_rows == 0_u64

      flags = cursor.read_u64
      if (flags & ~BinaryLowCardinalityStorageStreams::ALLOWED_MASK) != 0_u64 ||
         (flags & BinaryLowCardinalityStorageStreams::GLOBAL_BIT) != 0_u64
        raise UnsupportedFormatError.new("unsupported Compact LowCardinality index flags")
      end
      unless (flags & BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT) != 0_u64 &&
             (flags & BinaryLowCardinalityStorageStreams::UPDATE_BIT) != 0_u64
        raise UnsupportedFormatError.new("Compact LowCardinality index record is not self-contained")
      end
      width = BinaryLowCardinalityStorageStreams.width_for_code(flags & 0x3_u64)
      key_count = cursor.read_u64
      if key_count == 0_u64 || key_count > @limits.max_elements.to_u64 ||
         key_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact LowCardinality additional-key count is outside its bound")
      end
      _, scalar_type = BinaryLowCardinalityStorageStreams.unwrap(child_type)
      key_count.times { skip_low_cardinality_scalar(scalar_type, cursor) }
      row_count = cursor.read_u64
      unless row_count == expected_rows
        raise CorruptPartError.new("Compact LowCardinality index row count differs from its occurrence count")
      end
      id_bytes = multiply_checked(row_count, width.to_u64)
      if id_bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact LowCardinality index IDs exceed the in-memory domain")
      end
      cursor.read_exact(id_bytes.to_i32)
      nil
    end

    private def skip_low_cardinality_scalar(type : BinaryDataType, cursor : CompactBinaryBulkGranuleCursor) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        length = cursor.read_var_uint
        if length > @limits.max_bytes.to_u64 || length > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact LowCardinality String key exceeds its bounded domain")
        end
        cursor.read_exact(length.to_i32)
      when BinaryDataType::TAG_BOOL
        value = cursor.read_exact(1)[0]
        if value > 1_u8
          raise CorruptPartError.new("Compact LowCardinality Bool key is not zero or one")
        end
      else
        width = type.fixed_width ||
                raise(UnsupportedFormatError.new("unsupported Compact LowCardinality dictionary scalar"))
        cursor.read_exact(width)
      end
      nil
    end

    private def read_variant_tape_body(
      cursor : CompactBinaryBulkGranuleCursor,
      mode : UInt64,
      expected_rows : UInt64,
    ) : Nil
      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        if expected_rows > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact Variant row count exceeds its supported domain")
        end
        cursor.read_exact(expected_rows.to_i32)
        return nil
      end
      if mode != DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise UnsupportedFormatError.new("unsupported Compact Variant discriminator mode")
      end
      if expected_rows == 0_u64
        return nil
      end
      rows = cursor.read_var_uint
      unless rows == expected_rows
        raise CorruptPartError.new("Compact Variant COMPACT frame row count differs from its mark")
      end
      format = cursor.read_exact(1)[0]
      case format
      when DynamicDiscriminatorBodyValidator::COMPACT_ROW_TAGS
        cursor.read_exact(expected_rows.to_i32)
      when DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG
        cursor.read_exact(1)
      else
        raise CorruptPartError.new("unsupported Compact Variant COMPACT frame kind")
      end
      nil
    end

    private def normalize_variant_body(
      role : String,
      mode : UInt64,
      expected_rows : UInt64,
      body : Bytes,
      budget : BinaryCodecBudget,
      lanes : Hash(String, CompactBinaryBulkLaneBuilder),
      workspace_observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
      mark_count : Int32,
    ) : Bytes
      layout = DynamicDiscriminatorBodyValidator.inspect_body(mode, body, expected_rows)
      physical_size = body.size.to_i64 + BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
      if physical_size > Int32::MAX
        raise CorruptPartError.new("Compact Variant physical body exceeds the in-memory domain")
      end
      observe_workspace(
        workspace_observer,
        physical_workspace_bytes,
        lanes.size,
        mark_count,
        sum_lane_data_bytes(lanes),
        physical_size.to_u64,
      )
      physical = Bytes.new(physical_size.to_i32)
      8.times { |index| physical[index] = ((mode >> (index * 8)) & 0xff_u64).to_u8 }
      body.each_with_index { |byte, index| physical[index + 8] = byte }
      # The shared framing adapter allocates the expanded tag lane and its two
      # coordinates. `expected_rows` is recursive Q, not parent P; for an
      # Array(Variant(...)) this is the only correct upper bound.
      adapter_workspace = checked_add(
        physical_size.to_u64,
        checked_add(expected_rows, 2_u64 * sizeof(UInt64).to_u64),
      )
      observe_workspace(
        workspace_observer,
        physical_workspace_bytes,
        lanes.size,
        mark_count,
        sum_lane_data_bytes(lanes),
        adapter_workspace,
      )
      normalized, offsets, prefix_size = BinaryBulkDiscriminatorFramingAdapter.read_lane(
        role,
        physical,
        [8_u64, physical.size.to_u64],
        BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
        budget
      )
      unless prefix_size == 0 && offsets.size == 2 &&
             offsets[0] == 0_u64 && offsets[1] == expected_rows
        raise CorruptPartError.new("Compact Variant framing adapter returned an invalid mark grid")
      end
      expected_format, _tag_offset = layout
      if expected_format == DynamicDiscriminatorBodyValidator::COMPACT_EMPTY && !normalized.empty?
        raise CorruptPartError.new("empty Compact Variant mark expanded to discriminator tags")
      end
      normalized
    end

    private def append_lane(
      lanes : Hash(String, CompactBinaryBulkLaneBuilder),
      role : String,
      bytes : Bytes,
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
      mark_count : Int32,
    ) : Nil
      lane = lane_for(lanes, role)
      projected_lane_bytes = checked_add(sum_lane_data_bytes(lanes), bytes.size.to_u64)
      observe_workspace(
        workspace_observer,
        physical_workspace_bytes,
        lanes.size,
        mark_count,
        projected_lane_bytes,
        bytes.size.to_u64,
      )
      lane.append(bytes, budget)
    end

    private def observe_workspace(
      observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
      role_count : Int32,
      mark_count : Int32,
      lane_data_bytes : UInt64,
      temporary_bytes : UInt64,
      building_output : Bool = false,
    ) : Nil
      roles = role_count.to_u64
      marks = mark_count.to_u64
      offsets_per_lane = checked_add(marks, 1_u64)

      # Builders own byte arrays and mark coordinates. Array growth can briefly
      # retain an older buffer while the replacement is populated; the
      # four-payload factor bounds that transient plus the detached Bytes and
      # BinaryBulkStream-owned copy during finalization.
      bytes = checked_multiply(lane_data_bytes, 4_u64)
      bytes = checked_add(bytes, temporary_bytes)

      builder_owner = instance_sizeof(CompactBinaryBulkLaneBuilder).to_u64
      builder_owner = checked_add(builder_owner, instance_sizeof(String).to_u64)
      builder_owner = checked_add(builder_owner, instance_sizeof(Array(UInt8)).to_u64)
      builder_owner = checked_add(builder_owner, instance_sizeof(Array(UInt64)).to_u64)
      builder_owner = checked_add(builder_owner, sizeof(Pointer(CompactBinaryBulkLaneBuilder)).to_u64)
      bytes = checked_add(bytes, checked_multiply(roles, builder_owner))

      offset_grid = checked_multiply(checked_multiply(roles, offsets_per_lane), sizeof(UInt64).to_u64)
      # Each lane's offset Array grows from its initial coordinate as marks
      # finish. Charge four times the logical grid for retained capacity slack
      # and a possible old/new buffer overlap during reallocation. Finalizing
      # BinaryBulkStream owns one additional exact coordinate copy.
      bytes = checked_add(bytes, checked_multiply(offset_grid, 4_u64))
      bytes = checked_add(bytes, offset_grid) if building_output
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(marks, sizeof(UInt64).to_u64))

      if building_output
        # Hash entries, detached role names, and BinaryBulkStream wrappers are
        # retained alongside the builders while lanes are converted.
        bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryBulkStream)).to_u64)
        stream_owner = instance_sizeof(BinaryBulkStream).to_u64
        stream_owner = checked_add(stream_owner, instance_sizeof(String).to_u64)
        stream_owner = checked_add(stream_owner, sizeof(Pointer(BinaryBulkStream)).to_u64)
        bytes = checked_add(bytes, checked_multiply(roles, stream_owner))
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStreams).to_u64)
      end

      observer.call(checked_add(physical_workspace_bytes, bytes))
      nil
    end

    private def sum_lane_data_bytes(lanes : Hash(String, CompactBinaryBulkLaneBuilder)) : UInt64
      total = 0_u64
      lanes.each_value do |lane|
        total = checked_add(total, lane.data_size)
      end
      total
    end

    # This walk is intentionally metadata-only and nonallocating: it uses
    # descriptor byte accessors rather than `name`, `field_name_at`, JSON path
    # getters, or BinaryTypeNameBudget (which builds temporary arrays and
    # consumes the codec budget). A nil result means the ordinary codec
    # validator will reject the descriptor before any physical plans are
    # constructed, so no setup allowance is needed for a successful read.
    private def estimated_setup_workspace_bytes(type : BinaryDataType) : UInt64?
      census = setup_census(type, 1) || return nil
      return nil if census.nodes > @limits.max_nodes.to_u64
      return nil if census.edges > @limits.max_elements.to_u64

      roles = checked_add(checked_multiply(census.nodes, 4_u64), census.qbit_plane_count)
      roles = checked_add(roles, 4_u64)
      return nil if roles > Int32::MAX.to_u64

      # Every recursive role has at most one short structural component per
      # descriptor level. Physical basenames additionally carry escaped Tuple
      # fields and (for Variant) escaped canonical arm names. Use descriptor
      # sizes to bound those copies without rendering a path.
      role_name_per_entry = checked_add(checked_multiply(census.max_depth, 32_u64), 32_u64)
      physical_name_per_entry = checked_add(PhysicalStreamName.escaped_size(@column), role_name_per_entry)
      physical_name_per_entry = checked_add(
        physical_name_per_entry,
        checked_multiply(checked_add(census.descriptor_bytes, census.variant_name_bytes), 3_u64),
      )
      physical_name_per_entry = checked_add(physical_name_per_entry, 64_u64)

      # The physical plan, its detached validation snapshot, the ordered
      # callback roster, and each granule cursor retain overlapping role/name
      # copies. Six payload copies cover those owners and short-lived hash/set
      # keys; slot costs cover their arrays, hashes, tuples, and Variant maps.
      name_payload = checked_add(role_name_per_entry, physical_name_per_entry)
      name_payload = checked_add(name_payload, physical_name_per_entry)
      name_payload = checked_multiply(name_payload, roles)
      name_payload = checked_multiply(name_payload, 6_u64)

      slots = checked_multiply(roles, 384_u64)
      slots = checked_add(slots, checked_multiply(census.nodes, 256_u64))
      slots = checked_add(slots, checked_multiply(census.edges, 64_u64))
      slots = checked_add(slots, checked_multiply(census.variant_arm_count, 192_u64))

      # Variant SQL-name planning holds bounds, type references, names, and
      # formatting temporaries. The recursively computed bound includes every
      # arm occurrence's subtree, so nested Variant names are not approximated
      # from parent-row counts.
      variant_work = checked_multiply(census.variant_name_bytes, 4_u64)
      variant_work = checked_add(
        variant_work,
        checked_multiply(census.variant_arm_count, 192_u64),
      )

      total = checked_add(name_payload, slots)
      checked_add(total, variant_work)
    end

    private def setup_census(type : BinaryDataType, depth : Int32) : SetupCensus?
      return nil if depth <= 0 || depth > @limits.max_depth

      nodes = 1_u64
      edges = 0_u64
      descriptor_bytes = 0_u64
      child_name_bound = 0_u64
      variant_name_bytes = 0_u64
      variant_arm_count = 0_u64
      qbit_plane_count = 0_u64
      maximum_depth = depth.to_u64
      child_count = 0
      metadata_count = 0_u64

      case type.tag
      when BinaryDataType::TAG_JSON
        descriptor = type.json_type || return nil
        typed_count = descriptor.typed_path_count.to_u64
        skip_count = descriptor.skip_path_count.to_u64
        edges = checked_add(checked_multiply(typed_count, 2_u64), skip_count)
        nodes = checked_add(nodes, checked_add(typed_count, skip_count))
        descriptor.typed_path_count.times do |index|
          descriptor_bytes = checked_add(descriptor_bytes, descriptor.typed_path_byte_size(index).to_u64)
          child = setup_census(descriptor.typed_type_at(index), depth + 1) || return nil
          nodes = checked_add(nodes, child.nodes)
          edges = checked_add(edges, child.edges)
          descriptor_bytes = checked_add(descriptor_bytes, child.descriptor_bytes)
          child_name_bound = checked_add(child_name_bound, child.type_name_bound)
          variant_name_bytes = checked_add(variant_name_bytes, child.variant_name_bytes)
          variant_arm_count = checked_add(variant_arm_count, child.variant_arm_count)
          qbit_plane_count = checked_add(qbit_plane_count, child.qbit_plane_count)
          maximum_depth = maximum_depth > child.max_depth ? maximum_depth : child.max_depth
        end
        descriptor.skip_path_count.times do |index|
          descriptor_bytes = checked_add(descriptor_bytes, descriptor.skip_path_byte_size(index).to_u64)
        end
      when BinaryDataType::TAG_QBIT
        # The validated element descriptor is one of four fixed primitive
        # names. Count its validation node/edge without calling the accessor,
        # which would allocate that temporary primitive descriptor.
        edges = 1_u64
        nodes = checked_add(nodes, 1_u64)
        child_name_bound = 64_u64
        qbit_plane_count = type.qbit_type.not_nil!.plane_count.to_u64
        descriptor_bytes = 8_u64
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if argument = type.aggregate_function_argument_type
          edges = 1_u64
          child = setup_census(argument, depth + 1) || return nil
          nodes = checked_add(nodes, child.nodes)
          edges = checked_add(edges, child.edges)
          descriptor_bytes = checked_add(descriptor_bytes, child.descriptor_bytes)
          child_name_bound = child.type_name_bound
          variant_name_bytes = child.variant_name_bytes
          variant_arm_count = child.variant_arm_count
          qbit_plane_count = child.qbit_plane_count
          maximum_depth = maximum_depth > child.max_depth ? maximum_depth : child.max_depth
        end
        descriptor_bytes = checked_add(
          descriptor_bytes,
          type.aggregate_function_type.not_nil!.function_name.bytesize.to_u64,
        )
      else
        child_count = type.child_count
        edges = child_count.to_u64
        child_count.times do |index|
          child = setup_census(type.child_at(index), depth + 1) || return nil
          nodes = checked_add(nodes, child.nodes)
          edges = checked_add(edges, child.edges)
          descriptor_bytes = checked_add(descriptor_bytes, child.descriptor_bytes)
          child_name_bound = checked_add(child_name_bound, child.type_name_bound)
          variant_name_bytes = checked_add(variant_name_bytes, child.variant_name_bytes)
          variant_arm_count = checked_add(variant_arm_count, child.variant_arm_count)
          qbit_plane_count = checked_add(qbit_plane_count, child.qbit_plane_count)
          maximum_depth = maximum_depth > child.max_depth ? maximum_depth : child.max_depth
        end

        metadata_count = type.metadata_entry_count.to_u64
        edges = checked_add(edges, metadata_count)
        nodes = checked_add(nodes, metadata_count)
        if definition = type.enum_definition
          definition.size.times do |index|
            descriptor_bytes = checked_add(descriptor_bytes, definition.label_byte_size(index).to_u64)
          end
        end
        if simple_aggregate = type.simple_aggregate_type
          descriptor_bytes = checked_add(
            descriptor_bytes,
            simple_aggregate.function_signature_byte_size,
          )
        end
        if type.named_tuple?
          child_count.times do |index|
            descriptor_bytes = checked_add(
              descriptor_bytes,
              type.field_name_byte_size(index).to_u64,
            )
          end
        end
        if interval = type.interval_type
          descriptor_bytes = checked_add(descriptor_bytes, interval.name_byte_size)
        end
        if temporal = type.temporal_type
          descriptor_bytes = checked_add(
            descriptor_bytes,
            TimezoneName::MAX_NAME_BYTES.to_u64,
          ) if temporal.time_zone?
        end
        if type.tag == BinaryDataType::TAG_CUSTOM
          descriptor_bytes = checked_add(descriptor_bytes, BinaryCustomGeoType::MAX_NAME_BYTES.to_u64)
        end

        if type.tag == BinaryDataType::TAG_VARIANT
          # `child_name_bound` already contains the bounded canonical-name
          # estimate for each direct arm. Reuse that first-pass result rather
          # than recursively census each arm a second time (nested Variants
          # would otherwise multiply the census work).
          variant_name_bytes = checked_add(variant_name_bytes, child_name_bound)
          variant_arm_count = checked_add(variant_arm_count, child_count.to_u64)
        elsif type.tag == BinaryDataType::TAG_LOW_CARDINALITY
          # The physical plan deliberately stops at LowCardinality; hidden
          # child Variant names do not become physical names.
          variant_name_bytes = 0_u64
          variant_arm_count = 0_u64
        end
      end

      return nil if nodes > @limits.max_nodes.to_u64
      return nil if edges > @limits.max_elements.to_u64

      # Every admitted type spelling has bounded punctuation/parameters per
      # node. Opaque descriptor bytes are charged at an eightfold expansion,
      # covering SQL quoting, physical escaping, and temporary formatting.
      name_bound = checked_add(256_u64, child_name_bound)
      name_bound = checked_add(name_bound, checked_multiply(descriptor_bytes, 8_u64))
      name_bound = checked_add(name_bound, checked_multiply(metadata_count, 16_u64))

      SetupCensus.new(
        nodes,
        edges,
        descriptor_bytes,
        variant_name_bytes,
        variant_arm_count,
        qbit_plane_count,
        maximum_depth,
        name_bound,
      )
    end

    private def estimated_variant_mode_workspace_bytes(role_count : Int32) : UInt64
      entries = checked_multiply(role_count.to_u64, 2_u64)
      bytes = instance_sizeof(Hash(String, UInt64)).to_u64
      checked_add(
        bytes,
        checked_multiply(entries, checked_add(instance_sizeof(String).to_u64, sizeof(UInt64).to_u64)),
      )
    end

    private def lane_for(lanes : Hash(String, CompactBinaryBulkLaneBuilder), role : String) : CompactBinaryBulkLaneBuilder
      lanes[role]? || raise(CorruptPartError.new("Compact callback addresses an unplanned BinaryBulk role"))
    end

    private def body_name(role : String, physical : BinaryBulkPhysicalPlan) : String
      physical.stream_name_for(role)
    rescue ex : KeyError
      raise CorruptPartError.new("Compact callback role is outside the selected physical plan")
    end

    private def prefix_name(role : String, physical : BinaryBulkPhysicalPlan) : String
      unless physical.prefix_size_for(role) == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("Compact state-prefix role has no admitted eight-byte prefix")
      end
      PhysicalStreamName.append_literal(physical.stream_name_for(role), "_prefix")
    rescue ex : KeyError
      raise CorruptPartError.new("Compact prefix role is outside the selected physical plan")
    end

    private def sum_u64_values(bytes : Bytes, count : UInt64, limit : UInt64) : UInt64
      total = 0_u64
      count.to_i.times do |index|
        offset = index * 8
        value = 0_u64
        8.times { |byte_index| value |= bytes[offset + byte_index].to_u64 << (byte_index * 8) }
        if value > UInt64::MAX - total
          raise CorruptPartError.new("Compact child occurrence count overflows UInt64")
        end
        total += value
      end
      if total > limit || total > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact recursive count exceeds its bounded domain")
      end
      total
    end

    private def multiply_checked(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Compact callback extent overflows UInt64")
      end
      left * right
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact workspace estimate overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      multiply_checked(left, right)
    end

    private def cursor_mrk4?(cursor : CompactBinaryBulkGranuleCursor) : Bool
      # The cursor intentionally exposes only event behavior; this predicate
      # lets Variant choose whether its exact body slice or grammar delimits
      # the unlabelled mrk3 tape.
      cursor.mrk4?
    end
  end
end
