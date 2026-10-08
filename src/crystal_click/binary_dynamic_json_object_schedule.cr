module CrystalClick
  # Reconstructs exact normalized JSON Object row schedules from Dynamic
  # discriminators and the wrapper shape lanes in the same operation budget.
  # This is a census only; value serde remains in BinaryBulkDecoder.
  class BinaryDynamicJsonObjectSchedule
    @plan : BinaryDynamicBulkPlan?
    @root_type : BinaryDataType?
    @budget : BinaryCodecBudget
    @initial_descriptor_depth : Int32

    def self.build(
      plan : BinaryDynamicBulkPlan,
      streams : BinaryBulkStreams,
      mark_count : Int,
      binding_keys : Array(BinaryDynamicJsonLeafKey),
      budget : BinaryCodecBudget,
      initial_descriptor_depth : Int32,
    ) : Hash(BinaryDynamicJsonLeafKey, Array(UInt64))
      new(plan, budget, initial_descriptor_depth).build(streams, mark_count, binding_keys)
    end

    def self.build_root(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      binding_keys : Array(BinaryDynamicJsonLeafKey),
      budget : BinaryCodecBudget,
      initial_descriptor_depth : Int32,
    ) : Hash(BinaryDynamicJsonLeafKey, Array(UInt64))
      new(type, budget, initial_descriptor_depth).build_root(streams, rows_per_mark, binding_keys)
    end

    private def initialize(
      @plan : BinaryDynamicBulkPlan,
      @budget : BinaryCodecBudget,
      @initial_descriptor_depth : Int32,
    )
      @root_type = nil
    end

    private def initialize(
      @root_type : BinaryDataType,
      @budget : BinaryCodecBudget,
      @initial_descriptor_depth : Int32,
    )
      @plan = nil
    end

    protected def build(
      streams : BinaryBulkStreams,
      mark_count : Int,
      binding_keys : Array(BinaryDynamicJsonLeafKey),
    ) : Hash(BinaryDynamicJsonLeafKey, Array(UInt64))
      plan = @plan || raise(ArgumentError.new("Dynamic JSON schedule requires a Dynamic plan"))
      mark_records = mark_count.to_u64
      binding_records = binding_keys.size.to_u64
      retained_records = checked_multiply(binding_records, checked_add(mark_records, 1_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = plan.json_object_binding_key_bytesize_total
      @budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64

      counts = Hash(BinaryDynamicJsonLeafKey, Array(UInt64)).new(initial_capacity: binding_keys.size)
      binding_keys.each do |key|
        counts[key] = Array(UInt64).new(mark_count, 0_u64)
      end

      discriminator_bytes = 0_u64
      plan.each_site_path do |site|
        role = plan.discriminator_role_for(site)
        lane = streams.stream(role)
        discriminator_bytes = checked_add(discriminator_bytes, lane.byte_size.to_u64)
      end
      @budget.charge_wire_bytes(discriminator_bytes)

      shape_role_count = 0_u64
      plan.each_site_path do |site|
        plan.arm_count(site).times do |arm_index|
          shape_role_count = checked_add(
            shape_role_count,
            json_shape_role_count(plan.arm_type(site, arm_index)),
          )
        end
      end

      # The shape-role array and the per-role/per-mark cursor map are retained
      # census metadata. Admit both bounded record sets before allocating their
      # backing arrays or inserting any cursor keys.
      @budget.preflight_children(shape_role_count) if shape_role_count > 0_u64
      shape_role_count.times { @budget.charge_node }
      cursor_cells = checked_multiply(shape_role_count, mark_records)
      @budget.preflight_children(cursor_cells) if cursor_cells > 0_u64
      cursor_cells.times { @budget.charge_node }

      shape_roles = Array(String).new(shape_role_count.to_i)
      plan.each_site_path do |site|
        plan.arm_count(site).times do |arm_index|
          arm_type = plan.arm_type(site, arm_index)
          next unless has_json_leaf?(arm_type)
          arm_path = schedule_child_path(site, ".arm.", arm_index)
          append_json_shape_roles(arm_type, arm_path, shape_roles)
        end
      end
      unless shape_roles.size.to_u64 == shape_role_count
        corrupt!("Dynamic JSON shape-role census differs from its descriptor plan")
      end

      # Hash cursor keys retain the role name once per mark. Charge their
      # worst-case copied bytes before the first insertion; roles that remain
      # unused simply leave some of this conservative reservation unused.
      cursor_key_bytes = 0_u64
      shape_roles.each do |role|
        cursor_key_bytes = checked_add(
          cursor_key_bytes,
          checked_multiply(role.bytesize.to_u64, mark_records),
        )
      end
      @budget.charge_wire_bytes(cursor_key_bytes) if cursor_key_bytes > 0_u64

      shape_cursors = Hash(Tuple(String, Int32), UInt64).new
      plan.each_site_path do |site|
        arm_count = plan.arm_count(site)
        json_arm_count = 0_u64
        arm_count.times do |arm_index|
          json_arm_count += 1_u64 if has_json_leaf?(plan.arm_type(site, arm_index))
        end
        next if json_arm_count == 0_u64

        arm_cells = checked_multiply(json_arm_count, mark_records)
        arm_records = checked_add(arm_count.to_u64, arm_cells)
        @budget.preflight_children(arm_records)
        arm_records.times { @budget.charge_node }
        arm_counts = Array(Array(UInt64)?).new(arm_count, nil)
        arm_count.times do |arm_index|
          next unless has_json_leaf?(plan.arm_type(site, arm_index))
          arm_counts[arm_index] = Array(UInt64).new(mark_count, 0_u64)
        end

        discriminator_role = plan.discriminator_role_for(site)
        lane = streams.stream(discriminator_role)
        mark_count.times do |mark|
          cursor = lane.offset_at(mark)
          end_offset = lane.offset_at(mark + 1)
          while cursor < end_offset
            discriminator = lane.byte_at(cursor.to_i)
            unless discriminator == 0xff_u8 || discriminator.to_i < plan.arm_count(site)
              corrupt!("Dynamic bulk discriminator is outside its actual arm roster")
            end
            if discriminator != 0xff_u8
              if mark_counts = arm_counts[discriminator.to_i]?
                mark_counts[mark] = checked_add(mark_counts[mark], 1_u64)
              end
            end
            cursor += 1_u64
          end
        end

        arm_count.times do |arm_index|
          mark_counts = arm_counts[arm_index]?
          next unless mark_counts
          arm_type = plan.arm_type(site, arm_index)
          arm_path = schedule_child_path(site, ".arm.", arm_index)
          leaf_key = BinaryDynamicJsonLeafKey.new(site, arm_index, [] of Int32)
          mark_count.times do |mark|
            rows = mark_counts[mark]
            next if rows == 0_u64
            census_json_type(
              arm_type,
              arm_path,
              leaf_key,
              rows,
              mark,
              streams,
              shape_cursors,
              counts,
              @initial_descriptor_depth + plan.depth_for_site(site),
            )
          end
        end
      end

      validate_shape_cursors!(streams, shape_cursors, shape_roles, mark_count)
      counts
    end

    protected def build_root(
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      binding_keys : Array(BinaryDynamicJsonLeafKey),
    ) : Hash(BinaryDynamicJsonLeafKey, Array(UInt64))
      type = @root_type || raise(ArgumentError.new("root JSON schedule requires an actual type"))
      validate_root_binding_keys!(type, binding_keys)
      unless streams.mark_count == rows_per_mark.size
        corrupt!("root JSON row-count grid does not match its mark domain")
      end

      mark_records = rows_per_mark.size.to_u64
      binding_records = binding_keys.size.to_u64
      retained_records = checked_multiply(binding_records, checked_add(mark_records, 1_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = 0_u64
      binding_keys.each do |key|
        key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64)
        key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
      end
      @budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64

      counts = Hash(BinaryDynamicJsonLeafKey, Array(UInt64)).new(initial_capacity: binding_keys.size)
      binding_keys.each do |key|
        counts[key] = Array(UInt64).new(rows_per_mark.size, 0_u64)
      end

      shape_role_count = json_shape_role_count(type)
      @budget.preflight_children(shape_role_count) if shape_role_count > 0_u64
      shape_role_count.times { @budget.charge_node }
      cursor_cells = checked_multiply(shape_role_count, mark_records)
      @budget.preflight_children(cursor_cells) if cursor_cells > 0_u64
      cursor_cells.times { @budget.charge_node }
      shape_roles = Array(String).new(shape_role_count.to_i)
      append_json_shape_roles(type, "root", shape_roles)
      unless shape_roles.size.to_u64 == shape_role_count
        corrupt!("root JSON shape-role census differs from its descriptor")
      end

      cursor_key_bytes = 0_u64
      shape_roles.each do |role|
        cursor_key_bytes = checked_add(cursor_key_bytes, checked_multiply(role.bytesize.to_u64, mark_records))
      end
      @budget.charge_wire_bytes(cursor_key_bytes) if cursor_key_bytes > 0_u64
      shape_cursors = Hash(Tuple(String, Int32), UInt64).new

      root_key = BinaryDynamicJsonLeafKey.new(
        "root",
        binding_keys[0].canonical_arm_index,
        [] of Int32,
      )
      rows_per_mark.each_with_index do |rows, mark|
        if rows > Int32::MAX.to_u64
          corrupt!("root JSON actual mark row count exceeds Int32")
        end
        census_json_type(
          type,
          "root",
          root_key,
          rows,
          mark,
          streams,
          shape_cursors,
          counts,
          @initial_descriptor_depth,
        )
      end
      validate_shape_cursors!(streams, shape_cursors, shape_roles, rows_per_mark.size)
      counts
    end

    # `build_root` is public, so it cannot rely on BinaryDynamicBulkJsonObjectReader
    # having validated the descriptor first. Bound the complete descriptor
    # before any recursive shape/JSON summary and prove the caller's leaf-key
    # array is an exact, unique cover rather than accepting it as a census
    # certificate.
    private def validate_root_binding_keys!(
      type : BinaryDataType,
      binding_keys : Array(BinaryDynamicJsonLeafKey),
    ) : Nil
      unless @initial_descriptor_depth > 0 && @initial_descriptor_depth <= @budget.limits.max_depth
        corrupt!("root JSON descriptor depth exceeds the configured limit")
      end
      context = BinaryCodecContext.new(
        @budget.limits,
        nil,
        @budget.writing?,
        @budget,
        false,
        false,
      )
      context.validate_type_tree(type, @initial_descriptor_depth)

      if type.contains_dynamic? || type.contains_variant? ||
         BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
        corrupt!("root JSON actual descriptor contains an unsupported Dynamic, Variant, or LowCardinality node")
      end
      leaf_count = root_json_leaf_count(type, @initial_descriptor_depth)
      unless leaf_count > 0_u64 && !binding_keys.empty?
        corrupt!("root JSON binding roster is empty or its descriptor has no JSON leaves")
      end

      canonical_arm = binding_keys[0].canonical_arm_index
      seen = Hash(BinaryDynamicJsonLeafKey, Bool).new(initial_capacity: binding_keys.size)
      binding_keys.each do |key|
        unless key.dynamic_site == "root" && key.canonical_arm_index == canonical_arm
          corrupt!("root JSON binding keys do not identify one canonical ordinary arm")
        end
        begin
          key.resolve_json_type(type)
        rescue ex : ArgumentError | IndexError
          corrupt!(ex.message || "root JSON binding key does not identify a JSON leaf")
        end
        if seen.has_key?(key)
          corrupt!("root JSON binding key is duplicated")
        end
        seen[key] = true
      end
      unless binding_keys.size.to_u64 == leaf_count
        corrupt!("root JSON binding roster does not exactly cover every descriptor JSON leaf")
      end
      nil
    end

    private def root_json_leaf_count(type : BinaryDataType, depth : Int32) : UInt64
      @budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_JSON
        1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE,
           BinaryDataType::TAG_SIMPLE_AGGREGATE
        unless type.child_count == 1
          corrupt!("root JSON wrapper has an invalid child count")
        end
        root_json_leaf_count(type.child_at(0), root_json_child_depth(depth))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        count = 0_u64
        type.child_count.times do |index|
          count = checked_add(count, root_json_leaf_count(type.child_at(index), root_json_child_depth(depth)))
        end
        count
      else
        if type.contains_json?
          corrupt!("root JSON leaf crosses an unsupported descriptor wrapper")
        end
        0_u64
      end
    end

    private def root_json_child_depth(depth : Int32) : Int32
      value = depth.to_i64 + 1_i64
      @budget.ensure_depth(value)
      value.to_i32
    end

    # The schedule pass follows only ordinary JSON-bearing descriptor paths.
    # Nested Dynamic sites own their own discriminator and leaf schedule.
    private def has_json_leaf?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_JSON
        true
      when BinaryDataType::TAG_DYNAMIC
        false
      else
        type.child_count.times do |index|
          return true if has_json_leaf?(type.child_at(index))
        end
        false
      end
    end

    private def json_shape_role_count(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_JSON, BinaryDataType::TAG_DYNAMIC
        0_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        return 0_u64 unless has_json_leaf?(child)
        checked_add(1_u64, json_shape_role_count(child))
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        json_shape_role_count(type.child_at(0))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = 0_u64
        type.child_count.times do |index|
          count = checked_add(count, json_shape_role_count(type.child_at(index)))
        end
        count
      when BinaryDataType::TAG_MAP
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        return 0_u64 unless has_json_leaf?(key_type) || has_json_leaf?(value_type)
        checked_add(1_u64, checked_add(json_shape_role_count(key_type), json_shape_role_count(value_type)))
      when BinaryDataType::TAG_VARIANT
        return 0_u64 unless has_json_leaf?(type)
        count = 1_u64
        type.child_count.times do |index|
          count = checked_add(count, json_shape_role_count(type.child_at(index)))
        end
        count
      else
        0_u64
      end
    end

    private def append_json_shape_roles(
      type : BinaryDataType,
      path : String,
      roles : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_JSON, BinaryDataType::TAG_DYNAMIC
        nil
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        child = type.child_at(0)
        if has_json_leaf?(child)
          roles << schedule_child_path(path, ".sizes")
          append_json_shape_roles(child, schedule_child_path(path, ".elements"), roles)
        end
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        if has_json_leaf?(child)
          roles << schedule_child_path(path, ".nulls")
          append_json_shape_roles(child, schedule_child_path(path, ".nested"), roles)
        end
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child = type.child_at(0)
        append_json_shape_roles(child, path, roles) if has_json_leaf?(child)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless has_json_leaf?(child)
          append_json_shape_roles(child, schedule_child_path(path, ".field.", index), roles)
        end
      when BinaryDataType::TAG_MAP
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        return nil unless has_json_leaf?(key_type) || has_json_leaf?(value_type)
        roles << schedule_child_path(path, ".sizes")
        if has_json_leaf?(key_type)
          append_json_shape_roles(key_type, schedule_child_path(path, ".elements.field.0"), roles)
        end
        if has_json_leaf?(value_type)
          append_json_shape_roles(value_type, schedule_child_path(path, ".elements.field.1"), roles)
        end
      when BinaryDataType::TAG_VARIANT
        return nil unless has_json_leaf?(type)
        roles << schedule_child_path(path, ".discriminators")
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless has_json_leaf?(child)
          append_json_shape_roles(child, schedule_child_path(path, ".arm.", index), roles)
        end
      end
      nil
    end

    # Nullable always traverses its serialized nested value, including the
    # default JSON row emitted for NULL.
    private def census_json_type(
      type : BinaryDataType,
      path : String,
      leaf_key : BinaryDynamicJsonLeafKey,
      rows : UInt64,
      mark : Int,
      streams : BinaryBulkStreams,
      cursors : Hash(Tuple(String, Int32), UInt64),
      counts : Hash(BinaryDynamicJsonLeafKey, Array(UInt64)),
      depth : Int32,
    ) : Nil
      return nil if rows == 0_u64 || !has_json_leaf?(type)
      @budget.ensure_depth(depth)
      @budget.charge_node

      case type.tag
      when BinaryDataType::TAG_JSON
        mark_counts = counts[leaf_key]? || corrupt!("selected Dynamic JSON leaf has no Object child binding")
        count = checked_add(mark_counts[mark], rows)
        if count > Int32::MAX.to_u64
          corrupt!("Dynamic JSON Object child rows exceed Int32")
        end
        mark_counts[mark] = count
      when BinaryDataType::TAG_DYNAMIC
        nil
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        role = schedule_child_path(path, ".sizes")
        ensure_shape_bytes!(streams, cursors, role, mark, checked_multiply(rows, 8_u64))
        child_rows = 0_u64
        rows.times do
          size = read_shape_u64(streams, cursors, role, mark)
          if size > Int32::MAX.to_u64
            corrupt!("Array element count exceeds Int32")
          end
          child_rows = checked_add(child_rows, size)
        end
        @budget.ensure_future_elements(child_rows)
        census_json_type(
          type.child_at(0),
          schedule_child_path(path, ".elements"),
          leaf_key.with_child(0),
          child_rows,
          mark,
          streams,
          cursors,
          counts,
          depth + 1,
        )
      when BinaryDataType::TAG_NULLABLE
        role = schedule_child_path(path, ".nulls")
        ensure_shape_bytes!(streams, cursors, role, mark, rows)
        rows.times do
          flag = read_shape_byte(streams, cursors, role, mark)
          unless flag == 0_u8 || flag == 1_u8
            corrupt!("Nullable bulk null-map flag must be zero or one")
          end
        end
        census_json_type(
          type.child_at(0),
          schedule_child_path(path, ".nested"),
          leaf_key.with_child(0),
          rows,
          mark,
          streams,
          cursors,
          counts,
          depth + 1,
        )
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        census_json_type(
          type.child_at(0), path, leaf_key.with_child(0), rows, mark,
          streams, cursors, counts, depth + 1,
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child_type = type.child_at(index)
          next unless has_json_leaf?(child_type)
          census_json_type(
            child_type,
            schedule_child_path(path, ".field.", index),
            leaf_key.with_child(index),
            rows,
            mark,
            streams,
            cursors,
            counts,
            depth + 1,
          )
        end
      when BinaryDataType::TAG_MAP
        role = schedule_child_path(path, ".sizes")
        ensure_shape_bytes!(streams, cursors, role, mark, checked_multiply(rows, 8_u64))
        pair_rows = 0_u64
        rows.times do
          pairs = read_shape_u64(streams, cursors, role, mark)
          if pairs > (Int32::MAX.to_u64 // 2_u64)
            corrupt!("Map pair count exceeds its supported flat element domain")
          end
          pair_rows = checked_add(pair_rows, pairs)
        end
        @budget.ensure_future_elements(checked_multiply(pair_rows, 2_u64))
        if has_json_leaf?(type.child_at(0))
          census_json_type(
            type.child_at(0),
            schedule_child_path(path, ".elements.field.0"),
            leaf_key.with_child(0),
            pair_rows,
            mark,
            streams,
            cursors,
            counts,
            depth + 1,
          )
        end
        if has_json_leaf?(type.child_at(1))
          census_json_type(
            type.child_at(1),
            schedule_child_path(path, ".elements.field.1"),
            leaf_key.with_child(1),
            pair_rows,
            mark,
            streams,
            cursors,
            counts,
            depth + 1,
          )
        end
      when BinaryDataType::TAG_VARIANT
        role = schedule_child_path(path, ".discriminators")
        ensure_shape_bytes!(streams, cursors, role, mark, rows)
        arm_records = type.child_count.to_u64
        @budget.preflight_children(arm_records) if arm_records > 0_u64
        arm_records.times { @budget.charge_node }
        arm_counts = Array(UInt64).new(type.child_count, 0_u64)
        rows.times do
          discriminator = read_shape_byte(streams, cursors, role, mark)
          unless discriminator == 0xff_u8 || discriminator.to_i < type.child_count
            corrupt!("Variant discriminator is outside its arm roster")
          end
          if discriminator != 0xff_u8 && has_json_leaf?(type.child_at(discriminator.to_i))
            arm_counts[discriminator.to_i] = checked_add(arm_counts[discriminator.to_i], 1_u64)
          end
        end
        type.child_count.times do |index|
          arm_rows = arm_counts[index]
          next if arm_rows == 0_u64 || !has_json_leaf?(type.child_at(index))
          census_json_type(
            type.child_at(index),
            schedule_child_path(path, ".arm.", index),
            leaf_key.with_child(index),
            arm_rows,
            mark,
            streams,
            cursors,
            counts,
            depth + 1,
          )
        end
      end
      nil
    end

    private def ensure_shape_bytes!(
      streams : BinaryBulkStreams,
      cursors : Hash(Tuple(String, Int32), UInt64),
      role : String,
      mark : Int,
      required : UInt64,
    ) : Nil
      lane = streams.stream(role)
      cursor = cursors[{role, mark.to_i32}]? || lane.offset_at(mark)
      end_offset = lane.offset_at(mark + 1)
      if cursor > end_offset || required > end_offset - cursor
        corrupt!("binary bulk shape lane is too short for the JSON occurrence schedule")
      end
      nil
    end

    private def read_shape_byte(
      streams : BinaryBulkStreams,
      cursors : Hash(Tuple(String, Int32), UInt64),
      role : String,
      mark : Int,
    ) : UInt8
      lane = streams.stream(role)
      key = {role, mark.to_i32}
      cursor = cursors[key]? || lane.offset_at(mark)
      end_offset = lane.offset_at(mark + 1)
      if cursor >= end_offset
        corrupt!("binary bulk shape lane is too short for the JSON occurrence schedule")
      end
      value = lane.byte_at(cursor.to_i)
      cursors[key] = cursor + 1_u64
      @budget.charge_wire_bytes(1_u64)
      value
    end

    private def read_shape_u64(
      streams : BinaryBulkStreams,
      cursors : Hash(Tuple(String, Int32), UInt64),
      role : String,
      mark : Int,
    ) : UInt64
      value = 0_u64
      8.times do |index|
        value |= read_shape_byte(streams, cursors, role, mark).to_u64 << (index * 8)
      end
      value
    end

    private def validate_shape_cursors!(
      streams : BinaryBulkStreams,
      cursors : Hash(Tuple(String, Int32), UInt64),
      expected_roles : Array(String),
      mark_count : Int,
    ) : Nil
      expected_roles.each do |role|
        lane = streams.stream(role)
        mark_count.times do |mark|
          cursor = cursors[{role, mark.to_i32}]? || lane.offset_at(mark)
          unless cursor == lane.offset_at(mark + 1)
            corrupt!("binary bulk shape lane has trailing bytes after the JSON occurrence schedule")
          end
        end
      end
      nil
    end

    private def schedule_child_path(path : String, suffix : String, index : Int? = nil) : String
      suffix_bytes = suffix.bytesize.to_u64
      if value = index
        if value < 0
          corrupt!("Dynamic JSON schedule child index is negative")
        end
        digits = 1_u64
        while value >= 10
          value //= 10
          digits += 1_u64
        end
        suffix_bytes = checked_add(suffix_bytes, digits)
      end
      size = checked_add(path.bytesize.to_u64, suffix_bytes)
      if size > UInt64::MAX // 2_u64
        corrupt!("binary Dynamic JSON schedule role size overflows UInt64")
      end
      # Charge before interpolation and concatenation allocate either String.
      @budget.charge_wire_bytes(size * 2_u64)
      addition = index ? "#{suffix}#{index}" : suffix
      "#{path}#{addition}"
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        corrupt!("Dynamic JSON reader count overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        corrupt!("Dynamic JSON lane-grid count overflows UInt64")
      end
      left * right
    end

    private def corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
