module CrystalClick
  # Delimits one typed-Dynamic callback owner's recursive body roles without
  # materializing BinaryValue rows. Role names, descriptors, actual Dynamic
  # rosters, and discriminator-prefix callbacks all come from the prepared
  # Object/Dynamic plans; this class only walks their grammar to find extents.
  class CompactJsonTypedDynamicTapeGrammar
    MAX_ARRAY_SIZE = 1_u64 << 30

    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair

    @prefix : ObjectDocumentCallbackPrefix
    @prefix_pairs : Array(CallbackPair)
    @physical : BinaryDynamicBulkPhysicalPlan
    @plan : BinaryDynamicBulkPlan
    @row_count : UInt64
    @profile : BinaryBulkProfile
    @limits : BinaryCodecLimits
    @budget : BinaryCodecBudget
    @occurrences : Hash(String, UInt64)
    @arm_counts : Hash(String, Array(UInt64))
    @string_totals : Hash(String, UInt64)
    @seen_roles : Set(String)
    @visited_types : Set(Tuple(String, Int32))
    @seen_role_count : UInt64

    def initialize(
      @prefix : ObjectDocumentCallbackPrefix,
      @prefix_pairs : Array(CallbackPair),
      @physical : BinaryDynamicBulkPhysicalPlan,
      @plan : BinaryDynamicBulkPlan,
      @row_count : UInt64,
      @profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits,
      @budget : BinaryCodecBudget,
    )
      if @budget.writing?
        raise ArgumentError.new("Compact typed-Dynamic tape grammar requires a reading budget")
      end
      unless @physical.initial_descriptor_depth == @prefix.typed_descriptor_root_depth
        raise CorruptPartError.new("Compact typed-Dynamic physical owner changed its descriptor depth")
      end
      unless @plan.profile == @profile && @physical.same_prepared_layout?(@plan, @budget)
        raise CorruptPartError.new("Compact typed-Dynamic tape grammar changed its prepared physical plan")
      end
      if @row_count > Int32::MAX.to_u64 || @row_count > @limits.max_elements.to_u64
        raise UnsupportedFormatError.new("Compact typed-Dynamic mark rows exceed the bounded parser domain")
      end
      role_count = @plan.role_count
      if role_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact typed-Dynamic role roster exceeds the bounded parser domain")
      end

      # Charge fixed state owners and the maximum seen-role table before their
      # backing collections can grow. Per-path state is charged before insert.
      @budget.preflight_children(5_u64 + role_count)
      (5_u64 + role_count).times { @budget.charge_node }
      @occurrences = Hash(String, UInt64).new
      @arm_counts = Hash(String, Array(UInt64)).new
      @string_totals = Hash(String, UInt64).new
      @seen_roles = Set(String).new
      @visited_types = Set(Tuple(String, Int32)).new
      @seen_role_count = 0_u64
      retain_occurrence!("root", @row_count)
    end

    # Consumes exactly the body callback selected by the enclosing Object
    # schedule. A zero-byte callback remains a real role and is still recorded.
    def parse!(role : String, context : BinaryCodecContext, borrowed_tape : Bytes) : Nil
      unless context.input_offset == 0_i32 && context.remaining_input_bytes == borrowed_tape.size.to_u64
        raise CorruptPartError.new("Compact typed-Dynamic role context does not begin at its borrowed tape")
      end
      unless context.budget.same?(@budget) && !context.budget.writing?
        raise CorruptPartError.new("Compact typed-Dynamic role context changed its read budget")
      end
      unless same_limits?(context.limits, @limits)
        raise CorruptPartError.new("Compact typed-Dynamic role context changed its codec limits")
      end
      unless @plan.has_data_role?(role)
        raise CorruptPartError.new("Compact typed-Dynamic body role is absent from its prepared plan")
      end
      unless @seen_roles.add?(role)
        raise CorruptPartError.new("Compact typed-Dynamic body role is duplicated")
      end
      if @seen_role_count >= @plan.role_count
        raise CorruptPartError.new("Compact typed-Dynamic body schedule contains an extra role")
      end
      @seen_role_count += 1_u64

      parsed = parse_node!(
        @plan.type,
        "root",
        @row_count,
        @physical.initial_descriptor_depth,
        role,
        context,
        borrowed_tape,
      )
      unless parsed
        raise UnsupportedFormatError.new("Compact typed-Dynamic body role is outside the admitted recursive grammar")
      end
      nil
    end

    def finish! : Nil
      unless @seen_role_count == @plan.role_count
        raise CorruptPartError.new("Compact typed-Dynamic body role schedule is incomplete")
      end
      nil
    end

    # Exact selected count for one already-consumed discriminator arm. JSON
    # child Object framers use this local count, never the enclosing Object
    # row count or another Dynamic field's arm census.
    def selected_arm_count(path : String, arm_index : Int) : UInt64
      unless arm_index >= 0
        raise CorruptPartError.new("Compact typed-Dynamic selected arm index is negative")
      end
      counts = @arm_counts[path]? ||
               raise(CorruptPartError.new("Compact typed-Dynamic child owner precedes its discriminator census"))
      counts[arm_index]? ||
        raise(CorruptPartError.new("Compact typed-Dynamic selected arm index is outside its exact discriminator roster"))
    end

    # Exact element occurrence for one admitted Array(JSON) arm. This is
    # available only after that arm's physical sizes role has been parsed;
    # the arm count remains the number of parent rows selecting the Array.
    def selected_array_json_element_count(path : String, arm_index : Int) : UInt64
      selected_rows = selected_arm_count(path, arm_index)
      actual_type = @plan.arm_type(path, arm_index)
      unless actual_type.tag == BinaryDataType::TAG_ARRAY && actual_type.child_count == 1 &&
             actual_type.child_at(0).tag == BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("Compact typed-Dynamic Array element count is outside the single Array(JSON) slice")
      end

      arm_path = append_indexed_path(path, ".arm.", arm_index.to_i32)
      unless required_occurrence(arm_path) == selected_rows
        raise CorruptPartError.new("Compact typed-Dynamic Array row occurrence differs from its discriminator arm census")
      end
      sizes_role = append_path(arm_path, ".sizes")
      unless @seen_roles.includes?(sizes_role)
        raise CorruptPartError.new("Compact typed-Dynamic Array element count precedes its exact sizes callback")
      end
      required_occurrence(append_path(arm_path, ".elements"))
    end

    private def parse_node!(
      type : BinaryDataType,
      path : String,
      count : UInt64,
      depth : Int32,
      target_role : String,
      context : BinaryCodecContext,
      borrowed_tape : Bytes,
    ) : Bool
      ensure_count!(count)
      retain_occurrence!(path, count)
      visit_type!(type, path, depth, count)

      case type.tag
      when BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_VARIANT
        discriminator_role = append_path(path, ".discriminators")
        if target_role == discriminator_role
          parse_discriminators!(type, path, discriminator_role, count, context, borrowed_tape)
          return true
        end

        arm_count = if type.tag == BinaryDataType::TAG_DYNAMIC
                      unless @plan.has_site?(path)
                        raise CorruptPartError.new("Compact typed-Dynamic body has no prepared actual site for #{path.inspect}")
                      end
                      @plan.arm_count(path)
                    else
                      type.child_count
                    end
        arm_index = role_index(target_role, path, ".arm.", arm_count)
        return false unless arm_index
        counts = @arm_counts[path]? ||
                 raise(CorruptPartError.new("Compact typed-Dynamic arm body precedes its discriminator role"))
        child_count = counts[arm_index]
        child_type = if type.tag == BinaryDataType::TAG_DYNAMIC
                       @plan.arm_type(path, arm_index)
                     else
                       type.child_at(arm_index)
                     end
        child_path = append_indexed_path(path, ".arm.", arm_index)
        retain_occurrence!(child_path, child_count)
        parse_node!(child_type, child_path, child_count, depth + 1, target_role, context, borrowed_tape)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        if exact_path_role?(target_role, path, ".sizes")
          child_count = parse_sizes!(count, context, "Array")
          charge_edges!(child_count)
          child_path = append_path(path, ".elements")
          retain_occurrence!(child_path, child_count)
          return true
        end
        child_path = append_path(path, ".elements")
        return false unless path_or_descendant?(target_role, child_path)
        child_count = required_occurrence(child_path)
        parse_node!(type.child_at(0), child_path, child_count, depth + 1, target_role, context, borrowed_tape)
      when BinaryDataType::TAG_NULLABLE
        if exact_path_role?(target_role, path, ".nulls")
          # This pass only determines the lane extent. The common bulk decoder
          # remains responsible for validating each flag as zero or one.
          context.read_slice(count)
          child_path = append_path(path, ".nested")
          retain_occurrence!(child_path, count)
          return true
        end
        child_path = append_path(path, ".nested")
        return false unless path_or_descendant?(target_role, child_path)
        child_count = required_occurrence(child_path)
        parse_node!(type.child_at(0), child_path, child_count, depth + 1, target_role, context, borrowed_tape)
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_path = path
        parse_node!(type.child_at(0), child_path, count, depth + 1, target_role, context, borrowed_tape)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          if exact_path_role?(target_role, path, ".data")
            bytes = context.read_slice(count)
            bytes.each do |byte|
              unless byte == 0x30_u8
                raise CorruptPartError.new("Compact typed-Dynamic empty Tuple has an invalid sentinel")
              end
            end
            return true
          end
          return false
        end
        field_index = role_index(target_role, path, ".field.", type.child_count)
        return false unless field_index
        child_path = append_indexed_path(path, ".field.", field_index)
        retain_occurrence!(child_path, count)
        parse_node!(type.child_at(field_index), child_path, count, depth + 1, target_role, context, borrowed_tape)
      when BinaryDataType::TAG_MAP
        if exact_path_role?(target_role, path, ".sizes")
          entries = parse_sizes!(count, context, "Map")
          charge_edges!(checked_multiply(entries, 2_u64, "Map child count"))
          {0, 1}.each do |field|
            child_path = append_map_field_path(path, field)
            retain_occurrence!(child_path, entries)
          end
          return true
        end
        {0, 1}.each do |field|
          child_path = append_map_field_path(path, field)
          next unless path_or_descendant?(target_role, child_path)
          entries = required_occurrence(child_path)
          return parse_node!(type.child_at(field), child_path, entries, depth + 1, target_role, context, borrowed_tape)
        end
        false
      when BinaryDataType::TAG_STRING
        if @profile.with_size_stream?
          if exact_path_role?(target_role, path, ".string_sizes")
            total_bytes = parse_string_sizes!(count, context)
            retain_string_total!(path, total_bytes)
            return true
          end
          if exact_path_role?(target_role, path, ".data")
            total_bytes = @string_totals[path]? ||
                          raise(CorruptPartError.new("Compact typed-Dynamic String data precedes its size lane"))
            context.read_slice(total_bytes)
            return true
          end
        else
          if exact_path_role?(target_role, path, ".data")
            parse_string_values!(count, context)
            return true
          end
        end
        false
      when BinaryDataType::TAG_LOW_CARDINALITY
        raise UnsupportedFormatError.new("Compact typed-Dynamic LowCardinality body requires its dictionary/index grammar")
      when BinaryDataType::TAG_QBIT
        raise UnsupportedFormatError.new("Compact typed-Dynamic QBit body requires its plane grammar")
      when BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("Dynamic-owned JSON callbacks remain outside W270 typed-Dynamic framing")
      else
        if exact_path_role?(target_role, path, ".data")
          width = if type.tag == BinaryDataType::TAG_NOTHING
                    1_u64
                  else
                    fixed_width(type)
                  end
          fixed_extent!(context, count, width)
          # In particular, Nothing's placeholder byte is semantically checked
          # by the common decoder after this framing-only pass.
          return true
        end
        false
      end
    end

    private def parse_discriminators!(
      type : BinaryDataType,
      path : String,
      role : String,
      count : UInt64,
      context : BinaryCodecContext,
      borrowed_tape : Bytes,
    ) : Nil
      arm_count = if type.tag == BinaryDataType::TAG_DYNAMIC
                    @plan.arm_count(path)
                  else
                    type.child_count
                  end
      unless arm_count > 0 && arm_count <= 255
        raise CorruptPartError.new("Compact typed-Dynamic discriminator has an invalid arm roster")
      end
      mode = discriminator_mode(role)
      if mode != DynamicDiscriminatorBodyValidator::BASIC_MODE &&
         mode != DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("Compact typed-Dynamic discriminator mode is unknown")
      end

      if count == 0_u64
        empty = context.read_slice(0_u64)
        DynamicDiscriminatorBodyValidator.inspect_body(mode, empty, count)
        record_arm_counts!(path, new_arm_counts(arm_count))
        return nil
      end

      counts = new_arm_counts(arm_count)
      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        tags = context.read_slice(count)
        DynamicDiscriminatorBodyValidator.inspect_body(mode, tags, count)
        tags.each { |tag| count_tag!(counts, tag) }
      else
        if context.input_offset < 0 || context.input_offset >= borrowed_tape.size
          raise CorruptPartError.new("Compact typed-Dynamic COMPACT frame is missing")
        end
        frame_rows, _format, _tag_offset, frame_end =
          DynamicDiscriminatorBodyValidator.inspect_frame(borrowed_tape, context.input_offset)
        unless frame_rows == count
          raise CorruptPartError.new("Compact typed-Dynamic COMPACT frame rows differ from its mark occurrence count")
        end
        consumed = frame_end - context.input_offset
        if consumed <= 0
          raise CorruptPartError.new("Compact typed-Dynamic COMPACT frame has an empty positive extent")
        end
        frame = context.read_slice(consumed.to_u64)
        layout = DynamicDiscriminatorBodyValidator.inspect_body(mode, frame, count)
        count.times do |index|
          count_tag!(counts, DynamicDiscriminatorBodyValidator.tag_at(frame, layout, index.to_i))
        end
      end
      total_selected = 0_u64
      counts.each { |selected| total_selected = checked_add(total_selected, selected, "Dynamic selected-arm total") }
      charge_edges!(total_selected)
      record_arm_counts!(path, counts)
      nil
    rescue ex : KeyError
      raise CorruptPartError.new("Compact typed-Dynamic discriminator has no prepared site: #{ex.message}")
    end

    private def new_arm_counts(arm_count : Int32) : Array(UInt64)
      if arm_count <= 0 || arm_count > 255
        raise CorruptPartError.new("Compact typed-Dynamic discriminator arm count is outside its supported domain")
      end
      @budget.preflight_children(arm_count.to_u64)
      arm_count.times { @budget.charge_node }
      Array(UInt64).new(arm_count, 0_u64)
    end

    private def record_arm_counts!(path : String, counts : Array(UInt64)) : Nil
      if @arm_counts.has_key?(path)
        raise CorruptPartError.new("Compact typed-Dynamic discriminator role was consumed more than once")
      end
      @budget.preflight_children(1_u64)
      @budget.charge_node
      @arm_counts[path] = counts
      nil
    end

    private def count_tag!(counts : Array(UInt64), tag : UInt8) : Nil
      return if tag == DynamicDiscriminatorCodec::NULL_TAG
      index = tag.to_i
      unless index < counts.size
        raise CorruptPartError.new("Compact typed-Dynamic tag is outside its canonical arm roster")
      end
      if counts[index] == UInt64::MAX
        raise CorruptPartError.new("Compact typed-Dynamic arm occurrence count overflows UInt64")
      end
      counts[index] += 1_u64
      nil
    end

    private def discriminator_mode(role : String) : UInt64
      body_name = @physical.stream_name_for(role)
      body_suffix = ".variant_discr"
      unless body_name.ends_with?(body_suffix)
        raise CorruptPartError.new("Compact typed-Dynamic discriminator stream has an unexpected physical suffix")
      end
      prefix_suffix = ".variant_discr_prefix"
      prefix_bytes = body_name.bytesize - body_suffix.bytesize
      prefix_size = prefix_bytes.to_u64 + prefix_suffix.bytesize.to_u64
      @budget.ensure_wire_bytes(prefix_size)
      @budget.charge_wire_bytes(prefix_size)
      prefix_name = String.build(prefix_size.to_i32) do |io|
        io.write(body_name.to_slice[0, prefix_bytes])
        io << prefix_suffix
      end

      prefix_index = nil.as(Int32?)
      @prefix_pairs.each_with_index do |pair, index|
        next unless pair[0] == prefix_name
        if prefix_index
          raise CorruptPartError.new("Compact typed-Dynamic discriminator prefix is duplicated in its schedule")
        end
        prefix_index = index
      end
      index = prefix_index ||
              raise(CorruptPartError.new("Compact typed-Dynamic discriminator prefix is absent from its schedule"))
      name, bytes = @prefix.prefix_callback_at(index, @budget)
      unless name == prefix_name
        raise CorruptPartError.new("Compact typed-Dynamic discriminator prefix order changed after plan preparation")
      end
      unless bytes.size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("Compact typed-Dynamic discriminator prefix is not exactly eight bytes")
      end
      mode = read_u64_le(bytes)
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("Compact typed-Dynamic discriminator prefix has an unsupported mode")
      end
      mode
    rescue ex : KeyError
      raise CorruptPartError.new("Compact typed-Dynamic discriminator prefix has no physical role: #{ex.message}")
    end

    private def parse_sizes!(count : UInt64, context : BinaryCodecContext, label : String) : UInt64
      ensure_count!(count)
      if count > UInt64::MAX // 8_u64
        raise CorruptPartError.new("Compact typed-Dynamic #{label} sizes extent overflows UInt64")
      end
      context.ensure_remaining_input_bytes(count * 8_u64)
      total = 0_u64
      count.times do
        value = read_u64_le(context.read_slice(8_u64))
        if value > MAX_ARRAY_SIZE || value > @limits.max_elements.to_u64 || value > UInt64::MAX - total
          raise CorruptPartError.new("Compact typed-Dynamic #{label} child count exceeds its bounded domain")
        end
        total += value
      end
      if total > Int32::MAX.to_u64 || total > @limits.max_elements.to_u64
        raise CorruptPartError.new("Compact typed-Dynamic #{label} child count exceeds its parser domain")
      end
      total
    end

    private def parse_string_sizes!(count : UInt64, context : BinaryCodecContext) : UInt64
      ensure_count!(count)
      if count > UInt64::MAX // 8_u64
        raise CorruptPartError.new("Compact typed-Dynamic String sizes extent overflows UInt64")
      end
      context.ensure_remaining_input_bytes(count * 8_u64)
      total = 0_u64
      count.times do
        size = read_u64_le(context.read_slice(8_u64))
        if size > @limits.max_bytes.to_u64 || size > UInt64::MAX - total
          raise CorruptPartError.new("Compact typed-Dynamic String data exceeds its bounded byte domain")
        end
        total += size
      end
      if total > @limits.max_bytes.to_u64 || total > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact typed-Dynamic String data exceeds its parser domain")
      end
      total
    end

    private def parse_string_values!(count : UInt64, context : BinaryCodecContext) : Nil
      ensure_count!(count)
      count.times do
        size = context.read_var_uint
        if size > @limits.max_bytes.to_u64 || size > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact typed-Dynamic String value exceeds its bounded byte domain")
        end
        context.read_slice(size)
      end
      nil
    end

    private def fixed_extent!(context : BinaryCodecContext, count : UInt64, width : UInt64) : Nil
      if width == 0_u64 || count > UInt64::MAX // width
        raise CorruptPartError.new("Compact typed-Dynamic fixed-width callback extent overflows UInt64")
      end
      bytes = count * width
      if bytes > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact typed-Dynamic fixed-width callback exceeds its in-memory domain")
      end
      context.read_slice(bytes)
      nil
    end

    private def fixed_width(type : BinaryDataType) : UInt64
      width = type.fixed_width ||
              raise(UnsupportedFormatError.new("Compact typed-Dynamic leaf is outside the fixed-width body grammar"))
      unless width > 0
        raise UnsupportedFormatError.new("Compact typed-Dynamic leaf has an invalid fixed width")
      end
      width.to_u64
    end

    private def visit_type!(type : BinaryDataType, path : String, depth : Int32, count : UInt64) : Nil
      @budget.ensure_depth(depth)
      key = {path, depth}
      return if @visited_types.includes?(key)
      @budget.preflight_children(1_u64)
      @budget.charge_node
      @visited_types.add(key)
      unless count == 0_u64
        @budget.ensure_future_nodes(count)
        @budget.preflight_children(count)
        count.times { @budget.charge_node }
      end

      child_edges = case type.tag
                    when BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
                      count
                    when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
                      checked_multiply(count, type.child_count.to_u64, "Tuple child edges")
                    else
                      0_u64
                    end
      charge_edges!(child_edges) if child_edges > 0_u64
      nil
    end

    private def charge_edges!(count : UInt64) : Nil
      return if count == 0_u64
      @budget.charge_elements(count)
      @budget.ensure_future_nodes(count)
      nil
    end

    private def retain_occurrence!(path : String, count : UInt64) : Nil
      if existing = @occurrences[path]?
        unless existing == count
          raise CorruptPartError.new("Compact typed-Dynamic recursive occurrence count changed for #{path.inspect}")
        end
        return nil
      end
      @budget.preflight_children(1_u64)
      @budget.charge_node
      @occurrences[path] = count
      nil
    end

    private def required_occurrence(path : String) : UInt64
      @occurrences[path]? || raise(CorruptPartError.new("Compact typed-Dynamic child role precedes its parent count lane"))
    end

    private def retain_string_total!(path : String, total : UInt64) : Nil
      if @string_totals.has_key?(path)
        raise CorruptPartError.new("Compact typed-Dynamic String sizes role was consumed more than once")
      end
      @budget.preflight_children(1_u64)
      @budget.charge_node
      @string_totals[path] = total
      nil
    end

    private def ensure_count!(count : UInt64) : Nil
      if count > Int32::MAX.to_u64 || count > @limits.max_elements.to_u64
        raise CorruptPartError.new("Compact typed-Dynamic recursive occurrence count exceeds its bounded domain")
      end
      nil
    end

    private def exact_path_role?(role : String, path : String, suffix : String) : Bool
      expected_size = path.bytesize + suffix.bytesize
      return false unless role.bytesize == expected_size
      path.bytesize.times do |index|
        return false if role.byte_at(index) != path.byte_at(index)
      end
      suffix.bytesize.times do |index|
        return false if role.byte_at(path.bytesize + index) != suffix.byte_at(index)
      end
      true
    end

    private def path_or_descendant?(role : String, path : String) : Bool
      return false if role.bytesize < path.bytesize
      path.bytesize.times do |index|
        return false if role.byte_at(index) != path.byte_at(index)
      end
      role.bytesize == path.bytesize || role.byte_at(path.bytesize) == '.'.ord.to_u8
    end

    private def role_index(role : String, path : String, marker : String, count : Int32) : Int32?
      prefix_size = path.bytesize + marker.bytesize
      return nil if role.bytesize < prefix_size
      path.bytesize.times do |index|
        return nil if role.byte_at(index) != path.byte_at(index)
      end
      marker.bytesize.times do |index|
        return nil if role.byte_at(path.bytesize + index) != marker.byte_at(index)
      end
      cursor = prefix_size
      start = cursor
      while cursor < role.bytesize && role.byte_at(cursor) >= '0'.ord.to_u8 && role.byte_at(cursor) <= '9'.ord.to_u8
        cursor += 1
      end
      if cursor == start || cursor >= role.bytesize || role.byte_at(cursor) != '.'.ord.to_u8
        raise CorruptPartError.new("Compact typed-Dynamic recursive role has a malformed descriptor index")
      end
      token = role.byte_slice(start, cursor - start) || ""
      index = token.to_i? || raise(CorruptPartError.new("Compact typed-Dynamic recursive index is malformed"))
      unless index >= 0 && index < count && index.to_s == token
        raise CorruptPartError.new("Compact typed-Dynamic recursive index is outside its descriptor roster")
      end
      index
    end

    private def append_path(path : String, suffix : String) : String
      size = path.bytesize.to_u64 + suffix.bytesize.to_u64
      @budget.ensure_wire_bytes(size)
      @budget.charge_wire_bytes(size)
      String.build(size.to_i32) do |io|
        io << path
        io << suffix
      end
    end

    private def append_indexed_path(path : String, marker : String, index : Int32) : String
      index_text = index.to_s
      size = path.bytesize.to_u64 + marker.bytesize.to_u64 + index_text.bytesize.to_u64
      @budget.ensure_wire_bytes(size)
      @budget.charge_wire_bytes(size)
      String.build(size.to_i32) do |io|
        io << path
        io << marker
        io << index_text
      end
    end

    private def append_map_field_path(path : String, field : Int32) : String
      base = append_path(path, ".elements.field.")
      index_text = field.to_s
      size = base.bytesize.to_u64 + index_text.bytesize.to_u64
      @budget.ensure_wire_bytes(size)
      @budget.charge_wire_bytes(size)
      String.build(size.to_i32) do |io|
        io << base
        io << index_text
      end
    end

    private def checked_add(left : UInt64, right : UInt64, label : String) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact typed-Dynamic #{label} overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Compact typed-Dynamic #{label} overflows UInt64")
      end
      left * right
    end

    private def read_u64_le(bytes : Bytes) : UInt64
      unless bytes.size == 8
        raise CorruptPartError.new("Compact typed-Dynamic framing field is not eight bytes")
      end
      value = 0_u64
      8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
      value
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end
  end
end
