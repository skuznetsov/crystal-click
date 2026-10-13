require "./compact_json_typed_dynamic_tape_grammar"

module CrystalClick
  # Grammar-only boundary finder for the bounded root JSON MAP tape. It walks
  # the frozen role schedule and existing descriptors/count lanes, retaining
  # only callback slices. It never materializes BinaryValue/ObjectDocument
  # values to discover a callback boundary.
  class CompactJsonObjectMapTapeFramer(T)
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding
    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair

    @prefix : ObjectDocumentCallbackPrefix
    @physical_plan : ObjectDocumentPhysicalPlan
    @schedule : CompactJsonObjectRoleSchedule
    @owner : CompactJsonObjectRoleSchedule::OwnerSchedule
    @source : T
    @row_count : UInt64
    @profile : BinaryBulkProfile
    @limits : BinaryCodecLimits
    @budget : BinaryCodecBudget
    @string_totals : Hash(String, UInt64)
    @dynamic_arm_counts : Hash(String, Array(UInt64))
    @typed_dynamic_grammars : Hash(String, CompactJsonTypedDynamicTapeGrammar)
    @child_framers : Hash(String, CompactJsonObjectMapTapeFramer(T))
    @map_counts : Array(UInt64)?
    @map_entry_count : UInt64?
    @bucket_counts : Hash(String, Array(UInt64))
    @bucket_entry_counts : Hash(String, UInt64)
    @bucket_seen_roles : Hash(String, Set(String))
    @advanced_grammar : CompactJsonObjectSharedAdvancedTapeGrammar?

    private def initialize(
      @prefix : ObjectDocumentCallbackPrefix,
      @physical_plan : ObjectDocumentPhysicalPlan,
      @schedule : CompactJsonObjectRoleSchedule,
      @source : T,
      @row_count : UInt64,
      @profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits,
      @budget : BinaryCodecBudget,
      owner_root : String? = nil,
    )
      root = owner_root || ObjectDocumentInlineCallbackOrder.canonical_root_prefix(@physical_plan)
      @owner = @schedule.owner_for_root(root)
      unless @owner.physical_plan.same?(@physical_plan) && @owner.prefix.same?(@prefix)
        raise CorruptPartError.new("Compact MAP framer owner differs from its exact parsed callback prefix")
      end
      @string_totals = Hash(String, UInt64).new
      @dynamic_arm_counts = Hash(String, Array(UInt64)).new
      typed_dynamic_owners = @prefix.plan.typed_dynamic_count.to_u64
      if typed_dynamic_owners == UInt64::MAX
        raise CorruptPartError.new("Compact JSON typed-Dynamic owner count overflows its parser domain")
      end
      typed_dynamic_state_nodes = typed_dynamic_owners + 1_u64
      @budget.preflight_children(typed_dynamic_state_nodes)
      typed_dynamic_state_nodes.times { @budget.charge_node }
      @typed_dynamic_grammars = Hash(String, CompactJsonTypedDynamicTapeGrammar).new(
        initial_capacity: typed_dynamic_owners.to_i,
      )
      @child_framers = Hash(String, CompactJsonObjectMapTapeFramer(T)).new
      @map_counts = nil
      @map_entry_count = nil
      @bucket_counts = Hash(String, Array(UInt64)).new
      @bucket_entry_counts = Hash(String, UInt64).new
      @bucket_seen_roles = Hash(String, Set(String)).new
      @advanced_grammar = if @owner.advanced
                            CompactJsonObjectSharedAdvancedTapeGrammar.new(
                              @prefix,
                              @physical_plan,
                              @schedule,
                              @row_count,
                              @profile,
                              @limits,
                              @budget,
                            )
                          else
                            nil
                          end
    end

    def self.capture_body!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      schedule : CompactJsonObjectRoleSchedule,
      source : T,
      row_count : UInt64,
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Nil forall T
      new(prefix, physical_plan, schedule, source, row_count, profile, limits, budget).capture_body!
    end

    # Narrow class factory for schedule-proven child owners. Keep initialize
    # private; its constructor still validates the exact prefix/physical owner
    # pair against the shared callback registry.
    def self.for_child_owner(
      owner : CompactJsonObjectRoleSchedule::OwnerSchedule,
      schedule : CompactJsonObjectRoleSchedule,
      source : T,
      row_count : UInt64,
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : CompactJsonObjectMapTapeFramer(T) forall T
      unless owner.parent_typed_path && owner.parent_key
        raise CorruptPartError.new("Compact child Object owner has no exact typed-Dynamic parent identity")
      end
      new(owner.prefix, owner.physical_plan, schedule, source, row_count, profile, limits, budget, owner.root)
    end

    def capture_body! : Nil
      if @row_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact MRK3 root MAP mark rows exceed the parser domain")
      end
      @schedule.body_events.each do |event|
        owner = @schedule.owner_for_root(event[0])
        binding, pair = owner_binding_for_event(owner, event)
        target = framer_for_owner(owner)
        target.capture_owner_body_event!(owner.prefix, binding, pair)
      end

      finish!
      nil
    end

    # Parent framers dispatch flattened descendant events only after resolving
    # the exact owner-local binding. Keep the capture operation narrow and
    # public for that cross-instance call; parsing remains private.
    def capture_owner_body_event!(
      owner_prefix : ObjectDocumentCallbackPrefix,
      binding : BodyBinding,
      pair : CallbackPair,
    ) : Nil
      unless owner_prefix.same?(@prefix)
        raise CorruptPartError.new("Compact MAP body event was routed to a foreign callback-prefix owner")
      end
      unless pair[0] == binding[0]
        raise CorruptPartError.new("Compact MAP body event differs from its exact owner-local binding")
      end
      capture_one!(owner_prefix, binding, pair)
    end

    def finish! : Nil
      unless @typed_dynamic_grammars.size == @prefix.plan.typed_dynamic_count
        raise CorruptPartError.new("Compact JSON typed-Dynamic body schedule omitted a declared typed Dynamic owner")
      end
      @typed_dynamic_grammars.each_value do |grammar|
        grammar.finish!
      end

      shared_version = @prefix.plan.structures.object.shared_data_version
      case shared_version
      when 0_u64
        unless @map_counts && @map_entry_count
          raise CorruptPartError.new("Compact MRK3 root MAP schedule omitted its shared sizes lane")
        end
      when 1_u64
        finish_bucket_maps!
      when 2_u64, 3_u64
        (@advanced_grammar || raise(CorruptPartError.new("Compact MRK3 Advanced grammar owner is missing"))).finish!
      else
        raise UnsupportedFormatError.new("Compact MRK3 shared-data version is outside the admitted role grammar")
      end
      @child_framers.each_value(&.finish!)
      nil
    end

    private def capture_one!(owner_prefix : ObjectDocumentCallbackPrefix, binding : BodyBinding, pair : CallbackPair) : Nil
      canonical_name, callback_name = pair
      start = @source.position
      owner_prefix.capture_body_callback_from!(canonical_name, callback_name, @budget) do
        _value, exact_bytes = @source.with_grammar_extent(callback_name) do |remaining|
          context = BinaryCodecContext.new(@limits, remaining, false, @budget, false, false)
          parse_binding!(binding, context, remaining)
          {nil, context.input_offset}
        end
        finish = @source.position
        @source.inline_callback_slice(canonical_name, callback_name, start, finish, exact_bytes)
      end
      nil
    end

    private def owner_binding_for_event(
      owner : CompactJsonObjectRoleSchedule::OwnerSchedule,
      event : CompactJsonObjectRoleSchedule::CallbackEvent,
    ) : Tuple(BodyBinding, CallbackPair)
      found : Tuple(BodyBinding, CallbackPair)? = nil
      unless owner.body_bindings.size == owner.body_pairs.size
        raise CorruptPartError.new("Compact MAP owner has mismatched local bindings and callback names")
      end
      owner.body_bindings.each_with_index do |binding, index|
        pair = owner.body_pairs[index]
        next unless pair[0] == event[1]
        unless pair[1] == event[2] && binding[0] == event[1]
          raise CorruptPartError.new("Compact MAP event differs from its exact raw callback identity")
        end
        if found
          raise CorruptPartError.new("Compact MAP event has more than one owner-local role")
        end
        found = {binding, pair}
      end
      found || raise(CorruptPartError.new("Compact MAP event has no exact owner-local role binding"))
    end

    private def framer_for_owner(owner : CompactJsonObjectRoleSchedule::OwnerSchedule) : CompactJsonObjectMapTapeFramer(T)
      return self if owner.root == @owner.root
      if existing = @child_framers[owner.root]?
        return existing
      end
      parent_path = owner.parent_typed_path ||
                    raise(CorruptPartError.new("Compact child Object owner has no typed-Dynamic parent path"))
      key = owner.parent_key ||
            raise(CorruptPartError.new("Compact child Object owner has no exact typed-Dynamic JSON leaf key"))
      parent_grammar = @typed_dynamic_grammars[parent_path]? ||
                       raise(CorruptPartError.new("Compact child Object callback precedes its parent typed-Dynamic discriminator"))
      selected_rows = parent_grammar.selected_arm_count("root", key.canonical_arm_index)
      if owner.advanced
        raise UnsupportedFormatError.new("Compact typed-Dynamic JSON child Advanced shared layouts are outside this slice")
      end
      @budget.preflight_children(1_u64)
      @budget.charge_node
      child = CompactJsonObjectMapTapeFramer(T).for_child_owner(
        owner,
        @schedule,
        @source,
        selected_rows,
        @profile,
        @limits,
        @budget,
      )
      @child_framers[owner.root] = child
      child
    end

    private def parse_binding!(
      binding : BodyBinding,
      context : BinaryCodecContext,
      borrowed_tape : Bytes,
    ) : Nil
      _canonical_name, owner_kind, owner_path, role = binding
      case owner_kind
      when :typed
        parse_typed!(owner_path, role, context)
      when :root_dynamic
        parse_root_dynamic!(owner_path, role, context, borrowed_tape)
      when :typed_dynamic
        parse_typed_dynamic!(owner_path, role, context, borrowed_tape)
      when :shared
        parse_shared!(owner_path, role, context)
      when :advanced_bucket, :advanced_copy
        grammar = @advanced_grammar ||
                  raise(CorruptPartError.new("Compact MRK3 Advanced role has no prepared grammar owner"))
        grammar.parse!(owner_path, role, context, borrowed_tape)
      else
        raise UnsupportedFormatError.new("Compact MRK3 MAP tape contains an unsupported body owner")
      end
      nil
    end

    private def parse_typed_dynamic!(
      owner_path : String,
      role : String,
      context : BinaryCodecContext,
      borrowed_tape : Bytes,
    ) : Nil
      unless @prefix.plan.has_typed_dynamic?(owner_path)
        raise CorruptPartError.new("Compact JSON body callback has no declared typed-Dynamic owner: #{owner_path.inspect}")
      end
      grammar = @typed_dynamic_grammars[owner_path]? || begin
        type = @prefix.plan.typed_type_for(owner_path)
        unless type.contains_dynamic?
          raise CorruptPartError.new("Compact JSON typed-Dynamic owner has no declared Dynamic site: #{owner_path.inspect}")
        end
        plan = @prefix.typed_dynamic_plan_for(owner_path)
        unless plan.type == type
          raise CorruptPartError.new("Compact JSON typed-Dynamic plan descriptor differs from its declaration: #{owner_path.inspect}")
        end
        physical = @physical_plan.typed_dynamic(owner_path)
        created = CompactJsonTypedDynamicTapeGrammar.new(
          @prefix,
          @owner.prefix_pairs,
          physical,
          plan,
          @row_count,
          @profile,
          @limits,
          @budget,
        )
        @typed_dynamic_grammars[owner_path] = created
        created
      end
      grammar.parse!(role, context, borrowed_tape)
      nil
    rescue ex : KeyError
      raise CorruptPartError.new("Compact JSON typed-Dynamic callback has no prepared owner: #{ex.message}")
    end

    private def parse_typed!(owner_path : String, role : String, context : BinaryCodecContext) : Nil
      type = @prefix.plan.typed_type_for(owner_path)
      count = @row_count
      parse_scalar_role!(type, "typed:#{owner_path}", role, count, context)
    rescue ex : KeyError
      raise CorruptPartError.new("Compact MRK3 typed body role has no parsed descriptor: #{ex.message}")
    end

    private def parse_root_dynamic!(
      owner_path : String,
      role : String,
      context : BinaryCodecContext,
      borrowed_tape : Bytes,
    ) : Nil
      plan = @prefix.root_dynamic_plan_for(owner_path)
      arm_count = plan.arm_count("root")
      shared_index = plan.shared_index("root")
      unless arm_count > 0 && shared_index >= 0 && shared_index < arm_count && arm_count <= 255
        raise CorruptPartError.new("Compact MRK3 Dynamic plan has an invalid canonical arm roster")
      end

      if role == "root.discriminators"
        mode = dynamic_prefix_mode(owner_path)
        unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
               mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
          raise CorruptPartError.new("Compact MRK3 Dynamic discriminator mode is unknown")
        end

        if @row_count == 0_u64
          empty = context.read_slice(0_u64)
          DynamicDiscriminatorBodyValidator.inspect_body(mode, empty, @row_count)
          charge_occurrences!(@row_count)
          @dynamic_arm_counts[owner_path] = Array(UInt64).new(arm_count, 0_u64)
          return nil
        end

        if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
          bytes = context.read_slice(@row_count)
          DynamicDiscriminatorBodyValidator.inspect_body(mode, bytes, @row_count)
          charge_occurrences!(@row_count)
          counts = Array(UInt64).new(arm_count, 0_u64)
          bytes.each do |tag|
            count_dynamic_tag!(counts, tag)
          end
        else
          frame_start = context.input_offset
          frame_rows, format, tag_offset, frame_end =
            DynamicDiscriminatorBodyValidator.inspect_frame(borrowed_tape, frame_start)
          unless frame_rows == @row_count
            raise CorruptPartError.new("Compact MRK3 Dynamic COMPACT frame rows do not equal its mark rows")
          end
          consumed = frame_end - frame_start
          if consumed < 0
            raise CorruptPartError.new("Compact MRK3 Dynamic COMPACT frame ends before its borrowed start")
          end
          frame = context.read_slice(consumed.to_u64)
          charge_occurrences!(@row_count)
          counts = Array(UInt64).new(arm_count, 0_u64)
          layout = {format, tag_offset - frame_start}
          @row_count.times do |row_index|
            tag = DynamicDiscriminatorBodyValidator.tag_at(frame, layout, row_index.to_i)
            count_dynamic_tag!(counts, tag)
          end
        end
        @dynamic_arm_counts[owner_path] = counts
        return nil
      end

      arm_index, arm_suffix = parse_arm_role(role, arm_count)
      counts = @dynamic_arm_counts[owner_path]? ||
               raise(CorruptPartError.new("Compact MRK3 Dynamic arm body precedes its discriminator callback"))
      count = counts[arm_index]
      arm_type = plan.arm_type("root", arm_index)
      parse_scalar_role!(arm_type, "dynamic:#{owner_path}:#{arm_index}", arm_suffix, count, context)
    rescue ex : KeyError
      raise CorruptPartError.new("Compact MRK3 Dynamic body role has no parsed descriptor: #{ex.message}")
    end

    private def count_dynamic_tag!(counts : Array(UInt64), tag : UInt8) : Nil
      return if tag == DynamicDiscriminatorCodec::NULL_TAG

      index = tag.to_i
      unless index < counts.size
        raise CorruptPartError.new("Compact MRK3 Dynamic tag is outside the parsed canonical arm roster")
      end
      previous = counts[index]
      if previous == UInt64::MAX
        raise CorruptPartError.new("Compact MRK3 Dynamic arm occurrence count overflows")
      end
      counts[index] = previous + 1_u64
      nil
    end

    private def parse_shared!(owner_path : String, role : String, context : BinaryCodecContext) : Nil
      if @prefix.plan.structures.object.shared_data_version == 1_u64
        parse_bucket_shared!(owner_path, role, context)
        return nil
      end
      unless @prefix.plan.structures.object.shared_data_version == 0_u64 && owner_path == "0"
        raise CorruptPartError.new("Compact MRK3 root MAP lane has a different shared owner")
      end
      case role
      when "root.sizes"
        parse_map_sizes!(context)
      when "root.elements.field.0.data"
        parse_map_paths!(context)
      when "root.elements.field.1.data"
        parse_map_values!(context)
      else
        raise UnsupportedFormatError.new("Compact MRK3 root shared MAP role is outside its String/String grammar")
      end
    end

    private def parse_scalar_role!(
      type : BinaryDataType,
      owner_key : String,
      role : String,
      count : UInt64,
      context : BinaryCodecContext,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_UINT8
        unless role == "root.data"
          raise UnsupportedFormatError.new("Compact MRK3 typed UInt8 role is outside the admitted fixed-width grammar")
        end
        fixed_bytes!(context, count, 1_u64)
        charge_occurrences!(count)
      when BinaryDataType::TAG_BOOL
        unless role == "root.data"
          raise UnsupportedFormatError.new("Compact MRK3 Bool role is outside the admitted fixed-width grammar")
        end
        # This framer authenticates the lane extent; the common Binary decoder
        # remains the sole owner of Bool value validation and decoding.
        fixed_bytes!(context, count, 1_u64)
        charge_occurrences!(count)
      when BinaryDataType::TAG_UINT64
        unless role == "root.data"
          raise UnsupportedFormatError.new("Compact MRK3 UInt64 role is outside the admitted fixed-width grammar")
        end
        # Keep value decoding in the common Binary decoder after framing.
        fixed_bytes!(context, count, 8_u64)
        charge_occurrences!(count)
      when BinaryDataType::TAG_INT64
        unless role == "root.data"
          raise UnsupportedFormatError.new("Compact MRK3 Int64 role is outside the admitted fixed-width grammar")
        end
        fixed_bytes!(context, count, 8_u64)
        charge_occurrences!(count)
      when BinaryDataType::TAG_FLOAT64
        unless role == "root.data"
          raise UnsupportedFormatError.new("Compact MRK3 Float64 role is outside the admitted fixed-width grammar")
        end
        # The grammar-only framer locates this authenticated lane; the existing
        # Object decoder remains the sole owner of Float64 value decoding.
        fixed_bytes!(context, count, 8_u64)
        charge_occurrences!(count)
      when BinaryDataType::TAG_STRING
        if role == "root.string_sizes"
          parse_string_sizes!(owner_key, role, count, context)
        elsif role == "root.data"
          parse_string_data!(owner_key, role, count, context)
        else
          raise UnsupportedFormatError.new("Compact MRK3 String role is outside the admitted serializer grammar")
        end
      else
        raise UnsupportedFormatError.new("Compact MRK3 MAP root body descriptor is not in the admitted scalar grammar")
      end
      nil
    end

    private def parse_bucket_shared!(owner_path : String, role : String, context : BinaryCodecContext) : Nil
      bucket_index = owner_bucket_index(owner_path)
      physical_bucket = @physical_plan.shared_bucket(bucket_index)
      unless physical_bucket.stream_names.has_key?(role)
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS role is absent from its physical bucket roster")
      end
      seen = @bucket_seen_roles[owner_path]? || begin
        created = Set(String).new
        @bucket_seen_roles[owner_path] = created
        created
      end
      unless seen.add?(role)
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS role is duplicated within its bucket")
      end

      case role
      when "root.sizes"
        parse_bucket_sizes!(owner_path, context)
      when "root.elements.field.0.data"
        parse_bucket_string_data!(owner_path, role, context, true)
      when "root.elements.field.1.data"
        parse_bucket_string_data!(owner_path, role, context, false)
      else
        raise UnsupportedFormatError.new("Compact MRK3 MAP_WITH_BUCKETS role is outside its String/String bucket grammar")
      end
      nil
    end

    private def parse_bucket_sizes!(owner_path : String, context : BinaryCodecContext) : Nil
      if @bucket_counts.has_key?(owner_path)
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS sizes role is duplicated")
      end
      rows = @row_count
      if rows > UInt64::MAX // 8_u64
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS sizes lane length overflows UInt64")
      end
      if rows > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact MRK3 MAP_WITH_BUCKETS row count exceeds the parser domain")
      end
      @budget.ensure_future_nodes(rows)
      @budget.ensure_future_elements(rows)
      context.ensure_remaining_input_bytes(rows * 8_u64)

      counts = Array(UInt64).new(rows.to_i)
      total = 0_u64
      rows.times do
        count = read_u64_le(context.read_slice(8_u64))
        if count > Int32::MAX.to_u64 || count > UInt64::MAX - total
          raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS entry count exceeds its supported domain")
        end
        total += count
        counts << count
      end
      if total > (UInt64::MAX - rows) // 3_u64
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS traversal work overflows UInt64")
      end
      minimum_nodes = rows + total * 3_u64
      future_elements = rows + total
      @budget.ensure_future_nodes(minimum_nodes)
      @budget.ensure_future_elements(future_elements)
      rows.times do
        @budget.charge_node
        @budget.charge_elements(1_u64)
      end
      total.times do
        @budget.charge_node
        @budget.charge_elements(1_u64)
      end
      @bucket_counts[owner_path] = counts
      @bucket_entry_counts[owner_path] = total
      nil
    end

    private def parse_bucket_string_data!(
      owner_path : String,
      role : String,
      context : BinaryCodecContext,
      paths : Bool,
    ) : Nil
      counts = @bucket_counts[owner_path]? ||
               raise(CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS String data precedes its sizes lane"))
      total = @bucket_entry_counts[owner_path]? ||
              raise(CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS entry total is missing"))
      if role == "root.elements.field.1.data" &&
         !(@bucket_seen_roles[owner_path]?.try(&.includes?("root.elements.field.0.data")) || false)
        raise(CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS values precede their path lane"))
      end
      if total > context.remaining_input_bytes
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS String lane cannot contain its declared entries")
      end

      if paths
        previous : Bytes? = nil
        counts.each do |row_entries|
          previous = nil
          row_entries.times do
            path = context.read_slice(context.read_var_uint)
            if prior = previous
              if compare_bytes(prior, path) >= 0
                raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS paths are not strictly byte-sorted")
              end
            end
            previous = path
          end
        end
      else
        total.times do
          value_size = context.read_var_uint
          if value_size == 0_u64
            raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS value string is empty")
          end
          context.read_slice(value_size)
        end
      end
      nil
    end

    private def finish_bucket_maps! : Nil
      unless @bucket_counts.size == @physical_plan.shared_bucket_count &&
             @bucket_entry_counts.size == @physical_plan.shared_bucket_count &&
             @bucket_seen_roles.size == @physical_plan.shared_bucket_count
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS tape omitted a configured bucket")
      end
      @physical_plan.shared_bucket_count.times do |index|
        owner_path = index.to_s
        expected_roles = @physical_plan.shared_bucket(index).stream_names.keys.to_set
        observed_roles = @bucket_seen_roles[owner_path]? ||
                         raise(CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS bucket omitted all roles"))
        unless observed_roles == expected_roles && expected_roles.size == 3
          raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS roles do not exactly cover their physical bucket")
        end
        unless @bucket_counts.has_key?(owner_path) && @bucket_entry_counts.has_key?(owner_path)
          raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS bucket omitted its size-derived entry roster")
        end
      end
      nil
    end

    private def owner_bucket_index(owner_path : String) : Int32
      index = owner_path.to_i?
      unless index && index >= 0 && index.to_s == owner_path && index < @physical_plan.shared_bucket_count
        raise CorruptPartError.new("Compact MRK3 MAP_WITH_BUCKETS owner path is not a canonical bucket index")
      end
      index
    end

    private def parse_string_sizes!(owner_key : String, role : String, count : UInt64, context : BinaryCodecContext) : Nil
      unless @profile.with_size_stream?
        raise CorruptPartError.new("Compact MRK3 String size callback contradicts the selected serialization profile")
      end
      total = 0_u64
      count.times do
        size = read_u64_le(context.read_slice(8_u64))
        if size > UInt64::MAX - total
          raise CorruptPartError.new("Compact MRK3 String byte total overflows UInt64")
        end
        total += size
      end
      @string_totals[string_total_key(owner_key, role)] = total
      nil
    end

    private def parse_string_data!(owner_key : String, role : String, count : UInt64, context : BinaryCodecContext) : Nil
      if @profile.with_size_stream?
        total = @string_totals[string_total_key(owner_key, "root.string_sizes")]? ||
                raise(CorruptPartError.new("Compact MRK3 String data callback has no preceding size lane"))
        context.read_slice(total)
      else
        charge_occurrences!(count)
        count.times do
          context.read_slice(context.read_var_uint)
        end
      end
      nil
    end

    private def parse_map_sizes!(context : BinaryCodecContext) : Nil
      if @map_counts
        raise CorruptPartError.new("Compact MRK3 shared MAP sizes callback is duplicated")
      end
      rows = @row_count
      if rows > UInt64::MAX // 8_u64
        raise CorruptPartError.new("Compact MRK3 shared MAP size lane length overflows UInt64")
      end
      if rows > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact MRK3 shared MAP row count exceeds the parser domain")
      end
      @budget.ensure_future_nodes(rows)
      @budget.ensure_future_elements(rows)
      context.ensure_remaining_input_bytes(rows * 8_u64)

      counts = Array(UInt64).new(rows.to_i)
      total = 0_u64
      rows.times do
        count = read_u64_le(context.read_slice(8_u64))
        if count > Int32::MAX.to_u64 || count > UInt64::MAX - total
          raise CorruptPartError.new("Compact MRK3 shared MAP entry count exceeds its supported domain")
        end
        total += count
        counts << count
      end
      if total > (UInt64::MAX - rows) // 3_u64
        raise CorruptPartError.new("Compact MRK3 shared MAP traversal work overflows UInt64")
      end
      minimum_nodes = rows + total * 3_u64
      future_elements = rows + total
      @budget.ensure_future_nodes(minimum_nodes)
      @budget.ensure_future_elements(future_elements)
      rows.times do
        @budget.charge_node
        @budget.charge_elements(1_u64)
      end
      total.times do
        @budget.charge_node
        @budget.charge_elements(1_u64)
      end
      @map_counts = counts
      @map_entry_count = total
      nil
    end

    private def parse_map_paths!(context : BinaryCodecContext) : Nil
      counts = @map_counts || raise(CorruptPartError.new("Compact MRK3 MAP paths precede their size lane"))
      total = @map_entry_count || raise(CorruptPartError.new("Compact MRK3 MAP entry total is missing"))
      if total > context.remaining_input_bytes
        raise CorruptPartError.new("Compact MRK3 MAP path lane cannot contain the declared entries")
      end
      previous : Bytes? = nil
      counts.each do |row_entries|
        previous = nil
        row_entries.times do
          path = context.read_slice(context.read_var_uint)
          if prior = previous
            if compare_bytes(prior, path) >= 0
              raise CorruptPartError.new("Compact MRK3 shared MAP paths are not strictly byte-sorted")
            end
          end
          previous = path
        end
      end
      nil
    end

    private def parse_map_values!(context : BinaryCodecContext) : Nil
      total = @map_entry_count || raise(CorruptPartError.new("Compact MRK3 MAP values precede their size lane"))
      if total > context.remaining_input_bytes // 2_u64
        raise CorruptPartError.new("Compact MRK3 MAP value lane cannot contain the declared entries")
      end
      total.times do
        value_size = context.read_var_uint
        if value_size == 0_u64
          raise CorruptPartError.new("Compact MRK3 shared MAP value envelope is empty")
        end
        context.read_slice(value_size)
      end
      nil
    end

    private def dynamic_prefix_mode(owner_path : String) : UInt64
      body_name = @physical_plan.discriminator_stream(owner_path)
      suffix = ".variant_discr"
      unless body_name.ends_with?(suffix)
        raise CorruptPartError.new("Compact MRK3 Dynamic discriminator name has an unexpected suffix")
      end
      prefix_name = body_name.byte_slice(0, body_name.bytesize - suffix.bytesize) + ".variant_discr_prefix"
      schedule_entry_found = false
      @owner.prefix_pairs.each do |canonical, callback|
        if canonical == prefix_name
          if schedule_entry_found
            raise CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix is duplicated in its parsed schedule")
          end
          schedule_entry_found = true
        end
      end
      unless schedule_entry_found
        raise CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix is absent from its parsed schedule")
      end
      observed = nil.as(Bytes?)
      @prefix.prefix_callback_count.times do |index|
        name, bytes = @prefix.prefix_callback_at(index, @budget)
        if name == prefix_name
          if observed
            raise(CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix is duplicated"))
          end
          observed = bytes
        end
      end
      bytes = observed || raise(CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix bytes are missing"))
      unless bytes.size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix is not exactly eight bytes")
      end
      read_u64_le(bytes)
    rescue ex : KeyError
      raise CorruptPartError.new("Compact MRK3 Dynamic discriminator prefix has no physical plan: #{ex.message}")
    end

    private def parse_arm_role(role : String, arm_count : Int32) : Tuple(Int32, String)
      prefix = "root.arm."
      unless role.starts_with?(prefix)
        raise UnsupportedFormatError.new("Compact MRK3 Dynamic body role is not a canonical arm role")
      end
      cursor = prefix.bytesize
      start = cursor
      while cursor < role.bytesize &&
            role.byte_at(cursor) >= '0'.ord.to_u8 && role.byte_at(cursor) <= '9'.ord.to_u8
        cursor += 1
      end
      if cursor == start || cursor >= role.bytesize || role.byte_at(cursor) != '.'.ord.to_u8
        raise UnsupportedFormatError.new("Compact MRK3 Dynamic arm role has no normalized suffix")
      end
      arm_index = ((role.byte_slice(start, cursor - start) || "").to_i? ||
                   raise(CorruptPartError.new("Compact MRK3 Dynamic arm index is malformed")))
      unless arm_index >= 0 && arm_index < arm_count && arm_index.to_s == role.byte_slice(start, cursor - start)
        raise CorruptPartError.new("Compact MRK3 Dynamic arm index is outside its parsed roster")
      end
      {arm_index, "root" + (role.byte_slice(cursor, role.bytesize - cursor) || "")}
    end

    private def string_total_key(owner_key : String, role : String) : String
      "#{owner_key}|#{role}"
    end

    private def fixed_bytes!(context : BinaryCodecContext, count : UInt64, width : UInt64) : Nil
      if count > UInt64::MAX // width
        raise CorruptPartError.new("Compact MRK3 fixed-width callback extent overflows UInt64")
      end
      context.read_slice(count * width)
      nil
    end

    private def charge_occurrences!(count : UInt64) : Nil
      return if count == 0_u64
      @budget.preflight_children(count)
      count.times { @budget.charge_node }
      nil
    end

    private def read_u64_le(bytes : Bytes) : UInt64
      unless bytes.size == 8
        raise CorruptPartError.new("Compact MRK3 UInt64 framing field is not eight bytes")
      end
      value = 0_u64
      8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
      value
    end

    private def compare_bytes(left : Bytes, right : Bytes) : Int32
      common = Math.min(left.size, right.size)
      common.times do |index|
        return -1 if left[index] < right[index]
        return 1 if left[index] > right[index]
      end
      left.size <=> right.size
    end
  end
end
