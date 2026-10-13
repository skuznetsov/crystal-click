module CrystalClick
  # Compact-specific source for Object prefix/body grammar extents. mrk4
  # callbacks stay exact named events; mrk3 exposes only a borrowed remainder
  # to a parser that returns its own consumed byte count.
  class CompactJsonObjectSiteFramer < ObjectSharedPathCallbackSource
    @cursor : CompactBinaryBulkGranuleCursor
    @events : Array(Tuple(String, Bytes))
    @event_index : Int32
    @logical_event_names : Array(String)
    @positional_events : Array(Tuple(String, UInt64, UInt64))
    @grammar_parser_active : Bool
    @finished : Bool
    @tape_size : UInt64
    @path_position : UInt64
    @coordinate_context : CompactObjectSharedInlineCoordinateContext?
    @budget : BinaryCodecBudget

    def initialize(
      mode : CompactMarkFormat,
      shards : Array(CompactPartPhysicalShard),
      @budget : BinaryCodecBudget,
      physical_context : CompactPartPhysicalContext? = nil,
      site_identity : String? = nil,
    )
      if physical_context.nil? != site_identity.nil?
        raise ArgumentError.new("Compact inline coordinate context requires both physical owner and site identity")
      end
      if physical = physical_context
        unless physical.mode == mode
          raise CorruptPartError.new("Compact inline coordinate owner uses a different mark format")
        end
      end
      @coordinate_context = if physical = physical_context
                              CompactObjectSharedInlineCoordinateContext.new(
                                physical,
                                site_identity || raise(ArgumentError.new("Compact inline site identity is missing")),
                                shards,
                              )
                            else
                              nil
                            end
      @events = Array(Tuple(String, Bytes)).new(mode.mrk4? ? shards.size : 0)
      @tape_size = 0_u64
      if mode.mrk4?
        seen = Set(String).new
        shards.each do |shard|
          name = shard.stream_name ||
                 raise(CorruptPartError.new("Compact mrk4 static JSON callback has no stream name"))
          unless seen.add?(name)
            raise(CorruptPartError.new("Compact mrk4 static JSON callback roster duplicates a stream name"))
          end
          detached_name = String.new(name.to_slice)
          @events << {detached_name, shard.bytes}
          @tape_size = checked_add(@tape_size, shard.bytes.size.to_u64)
        end
      else
        unless shards.size == 1 && shards[0].stream_name.nil?
          raise CorruptPartError.new("Compact mrk3 static JSON mark is not one unlabelled column tape")
        end
        @tape_size = shards[0].bytes.size.to_u64
      end
      @event_index = 0
      @logical_event_names = [] of String
      @positional_events = [] of Tuple(String, UInt64, UInt64)
      @grammar_parser_active = false
      @finished = false
      @path_position = 0_u64
      @cursor = CompactBinaryBulkGranuleCursor.new(mode, shards, nil)
      @cursor.charge_complete_wire_input!(@budget)
    end

    protected def borrow_self_delimited(expected_name : String) : Bytes
      ensure_no_active_grammar_parser!
      unless @cursor.mrk4?
        raise UnsupportedFormatError.new("an unlabelled Compact mrk3 remainder is not an exact callback interval")
      end
      name, bytes = current_event(expected_name)
      bytes
    end

    protected def commit_self_delimited(expected_name : String, consumed : Int32) : Nil
      name, bytes = current_event(expected_name)
      unless consumed == bytes.size
        raise CorruptPartError.new("Compact mrk4 parser did not consume its exact named callback")
      end
      # The parser runs over the immutable local snapshot. Only after it has
      # returned the exact extent do we mutate the shared Compact cursor, so a
      # parser exception or partial extent leaves this source retryable.
      @cursor.begin_event(name)
      @cursor.advance_borrowed_prefix(consumed)
      @cursor.finish_event
      @event_index += 1
      advance_path_position(consumed)
      @logical_event_names << expected_name
      nil
    end

    # Parse one Compact-owned grammar extent. The callback source's generic
    # exact-event API remains unchanged; mrk3 never promotes its whole mark
    # remainder into one callback. A successful mrk3 parser commits only its
    # returned prefix length. A zero-length extent is permitted for a
    # scheduled body role with zero occurrences.
    def with_grammar_extent(expected_name : String, &block : Bytes -> Tuple(T, Int32)) : Tuple(T, Bytes) forall T
      with_physical_grammar_extent(expected_name, expected_name) do |bytes|
        yield bytes
      end
    end

    # Parsed Object prefixes keep physical and callback identities separate.
    # MRK4 selects the canonical physical shard while the logical traversal
    # records the raw getter name. MRK3 remains positional and records only
    # that raw logical name.
    def with_physical_grammar_extent(
      canonical_physical_name : String,
      raw_callback_name : String,
      &block : Bytes -> Tuple(T, Int32)
    ) : Tuple(T, Bytes) forall T
      if @cursor.mrk4?
        ensure_no_active_parser!
        ensure_no_active_grammar_parser!
        @grammar_parser_active = true
        begin
          name, bytes = current_event(canonical_physical_name)
          value, consumed = yield bytes
          unless consumed == bytes.size
            raise CorruptPartError.new("Compact mrk4 parser did not consume its exact canonical callback")
          end
          preflight_path_advance(consumed)

          # The parser receives an immutable snapshot. Validate its exact
          # extent before committing the canonical physical event or exposing
          # the raw callback identity to the logical traversal.
          @cursor.begin_event(name)
          @cursor.advance_borrowed_prefix(consumed)
          @cursor.finish_event
          @event_index += 1
          advance_path_position(consumed)
          @logical_event_names << String.new(raw_callback_name.to_slice)
          return {value, bytes}
        ensure
          @grammar_parser_active = false
        end
      end

      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      @grammar_parser_active = true
      begin
        start = @cursor.position
        borrowed = @cursor.remaining_slice
        value, consumed = yield borrowed
        unless consumed >= 0 && consumed <= borrowed.size
          raise CorruptPartError.new("Compact mrk3 grammar parser consumed outside its borrowed remainder")
        end

        finish = checked_position_end(start, consumed)
        validate_path_extent!(start.to_u64, finish.to_u64)
        track_position = preflight_positional_event!(start.to_u64, finish.to_u64)

        # Extent validation precedes the only cursor mutation. Any parser
        # exception or invalid count leaves the source position and logical
        # schedule untouched; parser budget consumption is intentionally not
        # rolled back.
        @cursor.advance_borrowed_prefix(consumed)
        observed = @cursor.consumed_slice(start)
        advance_path_position(consumed)
        @logical_event_names << String.new(raw_callback_name.to_slice)
        record_positional_event!(raw_callback_name, start.to_u64, finish.to_u64) if track_position
        {value, observed}
      ensure
        @grammar_parser_active = false
      end
    end

    def take_exact(expected_name : String, size : Int32) : Bytes
      take_physical_exact(expected_name, expected_name, size)
    end

    # Read an exact fixed callback using its canonical MRK4 physical name,
    # retaining the raw callback name only for the logical traversal.
    def take_physical_exact(
      canonical_physical_name : String,
      raw_callback_name : String,
      size : Int32,
    ) : Bytes
      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      if size < 0
        raise CorruptPartError.new("Compact static JSON fixed callback size is negative")
      end
      if @cursor.mrk4?
        name, bytes = current_event(canonical_physical_name)
        unless bytes.size == size
          raise CorruptPartError.new("Compact static JSON fixed callback has the wrong byte extent")
        end
        preflight_path_advance(size)
        @cursor.begin_event(name)
        observed = @cursor.read_exact(size)
        @cursor.finish_event
        @event_index += 1
        advance_path_position(size)
      else
        start = @cursor.position
        finish = checked_position_end(start, size)
        validate_path_extent!(start.to_u64, finish.to_u64)
        track_position = preflight_positional_event!(start.to_u64, finish.to_u64)
        observed = @cursor.read_exact(size)
        advance_path_position(size)
        record_positional_event!(raw_callback_name, start.to_u64, finish.to_u64) if track_position
      end
      @logical_event_names << String.new(raw_callback_name.to_slice)
      observed
    end

    def take_inline_fragment(expected_name : String) : Bytes
      take_inline_fragment_as(expected_name, expected_name)
    end

    private def take_inline_fragment_as(physical_name : String, logical_name : String) : Bytes
      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      unless @cursor.mrk4?
        raise UnsupportedFormatError.new("Compact mrk3 body fragments require descriptor-owned grammar framing")
      end
      name, _observed = current_event(physical_name)
      @cursor.begin_event(name)
      bytes = @cursor.remaining_slice
      @cursor.advance_borrowed_prefix(bytes.size)
      @cursor.finish_event
      @event_index += 1
      advance_path_position(bytes.size)
      @logical_event_names << logical_name
      bytes
    end

    def take_inline_fragment_slice(
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      # Compatibility path for direct callers: select by callback_name and
      # retain canonical_name separately as the returned slice's label.
      take_inline_fragment_slice_from(callback_name, canonical_name, callback_name)
    end

    # Parsed Compact schedules pair the canonical physical MRK4 name with the
    # raw logical getter name. Select only the physical name; never fall back
    # to the raw name if the canonical event is absent.
    def take_physical_inline_fragment_slice(
      canonical_physical_name : String,
      raw_callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      take_inline_fragment_slice_from(canonical_physical_name, canonical_physical_name, raw_callback_name)
    end

    private def take_inline_fragment_slice_from(
      physical_name : String,
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      bytes = take_inline_fragment_as(physical_name, callback_name)
      relative_start, relative_end = if @coordinate_context
                                       {@path_position - bytes.size.to_u64, @path_position}
                                     else
                                       {0_u64, bytes.size.to_u64}
                                     end
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        relative_start,
        relative_end,
        bytes,
        @coordinate_context,
        @coordinate_context ? @budget : nil,
      )
    end

    # Build an MRK3 body slice from the exact cursor interval
    # returned by the grammar parser. MRK3 has no physical callback labels;
    # these tape-relative coordinates are therefore bound to the shard-backed
    # path context rather than inferred from a persisted role name.
    def inline_callback_slice(
      canonical_name : String,
      callback_name : String,
      relative_start : Int32,
      relative_end : Int32,
      bytes : Bytes,
    ) : ObjectSharedInlineCallbackReadSlice
      if @cursor.mrk4?
        raise ArgumentError.new("positional Compact inline slices are only defined for mrk3 tapes")
      end
      if relative_start < 0 || relative_end < relative_start ||
         relative_end - relative_start != bytes.size || relative_end > @cursor.position
        raise CorruptPartError.new("Compact mrk3 inline callback interval differs from its parsed tape extent")
      end
      context = @coordinate_context
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        relative_start.to_u64,
        relative_end.to_u64,
        bytes,
        context,
        context ? @budget : nil,
      )
    end

    def validate_expected_events!(names : Array(String)) : Nil
      validate_expected_events!(names, names)
    end

    def validate_expected_events!(physical_names : Array(String), logical_names : Array(String)) : Nil
      @cursor.validate_expected_events!(physical_names)
      unless @logical_event_names == logical_names
        raise CorruptPartError.new("Compact logical callback traversal differs from the frozen serializer schedule")
      end
      nil
    end

    def finish! : Nil
      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      unless @event_index == @events.size
        if @cursor.mrk4?
          raise CorruptPartError.new("Compact static JSON callback roster was not consumed exactly")
        end
      end
      @cursor.finish_granule
      @finished = true
      nil
    end

    # Authenticate the completed prefix/body capture before an Advanced
    # prepared owner binds a decoder holder to it. The event roster was
    # detached from the selected physical shards at construction; here every
    # parsed callback and captured body interval is compared back to that
    # roster and, for body bytes, to this exact coordinate-context object.
    def validate_prepared_source!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair),
      budget : BinaryCodecBudget,
      schedule : CompactJsonObjectRoleSchedule? = nil,
    ) : Nil
      unless @cursor.mrk4?
        validate_prepared_mrk3_source!(prefix, physical_plan, role_bindings, callback_pairs, budget, schedule)
        return nil
      end
      unless @cursor.mrk4? && @finished
        raise UnsupportedFormatError.new("prepared Compact Advanced source requires a successfully finished mrk4 capture")
      end
      unless @budget.same?(budget)
        raise ArgumentError.new("prepared Compact source must retain its exact capture budget operation")
      end
      coordinate_context = @coordinate_context ||
                           raise(CorruptPartError.new("prepared Compact source has no authenticated coordinate context"))
      prefix.validate_physical_owner!(physical_plan)
      unless ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan) == prefix.physical_prefix
        raise CorruptPartError.new("prepared Compact prefix differs from its bound physical plan")
      end
      unless prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
        raise UnsupportedFormatError.new("prepared Compact Advanced source requires complete Object statistics")
      end

      callback_schedule = prepared_role_schedule(prefix, physical_plan, budget, schedule)
      root_owner = callback_schedule.validate_root_owner!(prefix, physical_plan, budget)
      unless root_owner.body_bindings == role_bindings && root_owner.body_pairs == callback_pairs
        raise CorruptPartError.new("prepared Compact body roles differ from the parsed Object schedule")
      end
      callback_schedule.each_owner do |owner|
        unless owner.prefix.prefix_callback_count == owner.prefix_pairs.size
          raise CorruptPartError.new("prepared Compact prefix callbacks differ from their owner-local schedule")
        end
        body_count = owner.prefix.body_callback_count
        unless body_count == owner.body_pairs.size && owner.prefix.body_callback_slice_count == body_count
          raise CorruptPartError.new("prepared Compact body callbacks differ from their owner-local schedule")
        end
      end
      unless @event_index == @events.size && @logical_event_names == callback_schedule.event_names
        raise CorruptPartError.new("prepared Compact source did not consume its exact logical callback roster")
      end
      unless @events.size == callback_schedule.prefix_events.size + callback_schedule.body_events.size
        raise CorruptPartError.new("prepared Compact source roster has a different callback count")
      end

      path_position = 0_u64
      event_index = 0
      prefix_owner_indices = Hash(String, Int32).new(initial_capacity: callback_schedule.owner_schedules.size)
      callback_schedule.owner_schedules.each_key { |root| prefix_owner_indices[root] = 0 }
      callback_schedule.prefix_events.each do |event|
        owner = callback_schedule.owner_for_root(event[0])
        owner_index = prefix_owner_indices[event[0]]? ||
                      raise(CorruptPartError.new("prepared Compact prefix event has no owner-local index"))
        pair = owner.prefix_pairs[owner_index]? ||
               raise(CorruptPartError.new("prepared Compact prefix event exceeds its owner-local schedule"))
        parsed_name, parsed_bytes = owner.prefix.prefix_callback_at(owner_index, budget)
        event_name, event_bytes = @events[event_index]? ||
                                  raise(CorruptPartError.new("prepared Compact prefix callback is missing from its source"))
        unless pair[0] == event[1] && pair[1] == event[2] && parsed_name == event[1] &&
               event_name == event[1] && @logical_event_names[event_index]? == event[2] &&
               same_bytes?(event_bytes, parsed_bytes)
          raise CorruptPartError.new("prepared Compact prefix bytes differ from their authenticated callback source")
        end
        coordinate_context.validate_path_bytes!(path_position, event_bytes, budget)
        path_position = checked_add(path_position, event_bytes.size.to_u64)
        event_index += 1
        prefix_owner_indices[event[0]] = owner_index + 1
      end
      prefix_owner_indices.each do |root, count|
        unless count == callback_schedule.owner_for_root(root).prefix_pairs.size
          raise CorruptPartError.new("prepared Compact prefix owner was not consumed exactly")
        end
      end

      body_owner_indices = Hash(String, Int32).new(initial_capacity: callback_schedule.owner_schedules.size)
      callback_schedule.owner_schedules.each_key { |root| body_owner_indices[root] = 0 }
      callback_schedule.body_events.each do |event|
        owner = callback_schedule.owner_for_root(event[0])
        owner_index = body_owner_indices[event[0]]? ||
                      raise(CorruptPartError.new("prepared Compact body event has no owner-local index"))
        pair = owner.body_pairs[owner_index]? ||
               raise(CorruptPartError.new("prepared Compact body event exceeds its owner-local schedule"))
        binding = owner.body_bindings[owner_index]? ||
                  raise(CorruptPartError.new("prepared Compact body event has no owner-local role binding"))
        parsed_name, parsed_bytes = owner.prefix.body_callback_at(owner_index, budget)
        slice = owner.prefix.body_callback_slice_at(owner_index)
        event_name, event_bytes = @events[event_index]? ||
                                  raise(CorruptPartError.new("prepared Compact body callback is missing from its source"))
        finish = checked_add(path_position, event_bytes.size.to_u64)
        unless pair[0] == event[1] && pair[1] == event[2] && binding[0] == event[1] &&
               parsed_name == event[1] && event_name == event[1] && @logical_event_names[event_index]? == event[2] &&
               slice.canonical_name == event[1] && slice.callback_name == event[2] &&
               same_bytes?(event_bytes, parsed_bytes) && same_bytes?(event_bytes, slice.bytes) &&
               slice.context.same?(coordinate_context) && slice.relative_start == path_position &&
               slice.relative_end == finish
          raise CorruptPartError.new("prepared Compact body bytes or interval differ from their authenticated callback source")
        end
        # Revalidate with the same capture budget, not merely a new context
        # with an equal site label or shard roster.
        coordinate_context.validate_path_bytes!(slice.relative_start, slice.bytes, budget)
        path_position = finish
        event_index += 1
        body_owner_indices[event[0]] = owner_index + 1
      end
      body_owner_indices.each do |root, count|
        unless count == callback_schedule.owner_for_root(root).body_pairs.size
          raise CorruptPartError.new("prepared Compact body owner was not consumed exactly")
        end
      end
      unless event_index == @events.size && path_position == @path_position &&
             path_position == coordinate_context.path_data_size.to_u64
        raise CorruptPartError.new("prepared Compact source intervals do not cover the authenticated callback path")
      end

      # Advanced publication consumes this source validator as its owner
      # boundary, so it must bind the derived schedule before preparing the
      # deferred decoder holder. Ordinary MAP materialization binds its own
      # schedule immediately afterward; binding here would make that normal
      # publication path attempt a forbidden second bind.
      if callback_schedule.advanced
        begin
          unless prefix.body_role_bindings == root_owner.body_bindings &&
                 prefix.body_callback_pairs == root_owner.body_pairs
            raise CorruptPartError.new("prepared Compact prefix retained a different body-role binding")
          end
        rescue ex : ArgumentError
          prefix.bind_body_schedule!(root_owner.body_bindings, root_owner.body_pairs)
        end
      end
      nil
    end

    private def validate_prepared_mrk3_source!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair),
      budget : BinaryCodecBudget,
      schedule : CompactJsonObjectRoleSchedule?,
    ) : Nil
      unless @finished
        raise UnsupportedFormatError.new("prepared Compact MRK3 source requires a successfully finished capture")
      end
      unless @budget.same?(budget)
        raise ArgumentError.new("prepared Compact source must retain its exact capture budget operation")
      end
      coordinate_context = @coordinate_context ||
                           raise(CorruptPartError.new("prepared Compact MRK3 source has no authenticated coordinate context"))
      site_identity = coordinate_context.site_identity
      mark_prefix = prefix.physical_prefix + ":mark="
      unless site_identity.starts_with?(mark_prefix)
        raise CorruptPartError.new("prepared Compact MRK3 source belongs to a different physical site")
      end
      mark_suffix = site_identity.byte_slice(mark_prefix.bytesize, site_identity.bytesize - mark_prefix.bytesize) || ""
      mark_index = mark_suffix.to_i?
      unless mark_index && mark_index >= 0 && mark_index.to_s == mark_suffix
        raise CorruptPartError.new("prepared Compact MRK3 source has a noncanonical physical mark identity")
      end
      unless site_identity == "#{prefix.physical_prefix}:mark=#{mark_index}"
        raise CorruptPartError.new("prepared Compact MRK3 source has a different physical mark identity")
      end
      prefix.validate_physical_owner!(physical_plan)
      unless ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan) == prefix.physical_prefix
        raise CorruptPartError.new("prepared Compact prefix differs from its bound physical plan")
      end
      coordinate_context.validate_mrk3_site!(
        prefix.callback_prefix,
        prefix.physical_prefix,
        mark_index,
      )
      unless prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
        raise UnsupportedFormatError.new("prepared Compact Advanced source requires complete Object statistics")
      end

      callback_schedule = prepared_role_schedule(prefix, physical_plan, budget, schedule)
      root_owner = callback_schedule.validate_root_owner!(prefix, physical_plan, budget)
      unless root_owner.body_bindings == role_bindings && root_owner.body_pairs == callback_pairs
        raise CorruptPartError.new("prepared Compact body roles differ from the parsed Object schedule")
      end
      callback_schedule.each_owner do |owner|
        unless owner.prefix.prefix_callback_count == owner.prefix_pairs.size
          raise CorruptPartError.new("prepared Compact prefix callbacks differ from their owner-local schedule")
        end
        body_count = owner.prefix.body_callback_count
        unless body_count == owner.body_pairs.size && owner.prefix.body_callback_slice_count == body_count
          raise CorruptPartError.new("prepared Compact body callbacks differ from their owner-local schedule")
        end
      end
      unless @logical_event_names == callback_schedule.event_names &&
             @positional_events.size == callback_schedule.prefix_events.size + callback_schedule.body_events.size
        raise CorruptPartError.new("prepared Compact MRK3 source did not consume its exact positional callback roster")
      end

      path_position = 0_u64
      event_index = 0
      prefix_owner_indices = Hash(String, Int32).new(initial_capacity: callback_schedule.owner_schedules.size)
      callback_schedule.owner_schedules.each_key { |root| prefix_owner_indices[root] = 0 }
      callback_schedule.prefix_events.each do |event|
        owner = callback_schedule.owner_for_root(event[0])
        owner_index = prefix_owner_indices[event[0]]? ||
                      raise(CorruptPartError.new("prepared Compact MRK3 prefix event has no owner-local index"))
        pair = owner.prefix_pairs[owner_index]? ||
               raise(CorruptPartError.new("prepared Compact MRK3 prefix event exceeds its owner-local schedule"))
        parsed_name, parsed_bytes = owner.prefix.prefix_callback_at(owner_index, budget)
        event_name, event_start, event_end = @positional_events[event_index]? ||
                                             raise(CorruptPartError.new("prepared Compact prefix callback is missing from its positional source"))
        finish = checked_add(path_position, parsed_bytes.size.to_u64)
        unless pair[0] == event[1] && pair[1] == event[2] && parsed_name == event[1] &&
               event_name == event[2] && @logical_event_names[event_index]? == event[2] &&
               event_start == path_position && event_end == finish
          raise CorruptPartError.new("prepared Compact MRK3 prefix callback differs from its positional source interval")
        end
        coordinate_context.validate_path_bytes!(event_start, parsed_bytes, budget)
        path_position = finish
        event_index += 1
        prefix_owner_indices[event[0]] = owner_index + 1
      end
      prefix_owner_indices.each do |root, count|
        unless count == callback_schedule.owner_for_root(root).prefix_pairs.size
          raise CorruptPartError.new("prepared Compact MRK3 prefix owner was not consumed exactly")
        end
      end

      body_owner_indices = Hash(String, Int32).new(initial_capacity: callback_schedule.owner_schedules.size)
      callback_schedule.owner_schedules.each_key { |root| body_owner_indices[root] = 0 }
      callback_schedule.body_events.each do |event|
        owner = callback_schedule.owner_for_root(event[0])
        owner_index = body_owner_indices[event[0]]? ||
                      raise(CorruptPartError.new("prepared Compact MRK3 body event has no owner-local index"))
        pair = owner.body_pairs[owner_index]? ||
               raise(CorruptPartError.new("prepared Compact MRK3 body event exceeds its owner-local schedule"))
        binding = owner.body_bindings[owner_index]? ||
                  raise(CorruptPartError.new("prepared Compact MRK3 body event has no owner-local role binding"))
        parsed_name, parsed_bytes = owner.prefix.body_callback_at(owner_index, budget)
        slice = owner.prefix.body_callback_slice_at(owner_index)
        event_name, event_start, event_end = @positional_events[event_index]? ||
                                             raise(CorruptPartError.new("prepared Compact body callback is missing from its positional source"))
        finish = checked_add(path_position, parsed_bytes.size.to_u64)
        unless pair[0] == event[1] && pair[1] == event[2] && binding[0] == event[1] &&
               parsed_name == event[1] && event_name == event[2] &&
               @logical_event_names[event_index]? == event[2] &&
               slice.canonical_name == pair[0] && slice.callback_name == pair[1] &&
               same_bytes?(parsed_bytes, slice.bytes) && slice.context.same?(coordinate_context) &&
               slice.relative_start == path_position && slice.relative_end == finish &&
               event_start == path_position && event_end == finish
          raise CorruptPartError.new("prepared Compact MRK3 body bytes or interval differ from their positional source")
        end
        coordinate_context.validate_path_bytes!(event_start, parsed_bytes, budget)
        path_position = finish
        event_index += 1
        body_owner_indices[event[0]] = owner_index + 1
      end
      body_owner_indices.each do |root, count|
        unless count == callback_schedule.owner_for_root(root).body_pairs.size
          raise CorruptPartError.new("prepared Compact MRK3 body owner was not consumed exactly")
        end
      end

      unless event_index == @positional_events.size && path_position == @path_position &&
             path_position == @cursor.position.to_u64 &&
             path_position == coordinate_context.path_data_size.to_u64 &&
             path_position == @tape_size
        raise CorruptPartError.new("prepared Compact MRK3 source intervals do not cover its authenticated tape")
      end

      # Advanced publication consumes this source validator as its owner
      # boundary, so it must bind the derived schedule before preparing the
      # deferred decoder holder. Ordinary MAP materialization binds its own
      # schedule immediately afterward; binding here would make that normal
      # publication path attempt a forbidden second bind.
      if callback_schedule.advanced
        begin
          unless prefix.body_role_bindings == root_owner.body_bindings &&
                 prefix.body_callback_pairs == root_owner.body_pairs
            raise CorruptPartError.new("prepared Compact prefix retained a different body-role binding")
          end
        rescue ex : ArgumentError
          prefix.bind_body_schedule!(root_owner.body_bindings, root_owner.body_pairs)
        end
      end
      nil
    end

    def position : Int32
      @cursor.position
    end

    def remaining : Int32
      @cursor.remaining
    end

    def tape_size : UInt64
      @tape_size
    end

    # Logical retained-owner census for both immutable event snapshots: this
    # framer's name/byte tuples and the Compact cursor's independently owned
    # roster. Slice descriptors are inline values; payload buffers are counted
    # by logical byte length, not allocator capacity or RSS.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonObjectSiteFramer).to_u64
      bytes = checked_add(bytes, event_roster_workspace_bytes)
      bytes = checked_add(bytes, instance_sizeof(CompactBinaryBulkGranuleCursor).to_u64)
      bytes = checked_add(bytes, event_roster_workspace_bytes)
      if context = @coordinate_context
        bytes = checked_add(bytes, context.retained_workspace_bytes)
      end
      bytes = checked_add(bytes, sizeof(UInt64).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@logical_event_names.size.to_u64, sizeof(Pointer(String)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(Tuple(String, UInt64, UInt64))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@positional_events.size.to_u64, sizeof(Tuple(String, UInt64, UInt64)).to_u64))
      bytes
    end

    private def prepared_role_schedule(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      budget : BinaryCodecBudget,
      schedule : CompactJsonObjectRoleSchedule?,
    ) : CompactJsonObjectRoleSchedule
      return schedule if schedule

      # A typed-Dynamic JSON child binds its keyed prefix to this schedule's
      # one-shot event registry during capture. Rebuilding here would either
      # rebind that owner or authenticate a different callback context, so
      # descendants require the exact schedule retained by the capture path.
      unless prefix.plan.typed_dynamic_json_object_leaf_plans(budget).empty?
        raise UnsupportedFormatError.new("prepared Compact JSON child requires its captured callback schedule")
      end
      CompactJsonObjectRoleSchedule.build(
        prefix,
        physical_plan,
        prefix.nested_context.profile,
        budget,
      )
    end

    private def current_event(expected_name : String) : Tuple(String, Bytes)
      event = @events[@event_index]? ||
              raise(CorruptPartError.new("Compact mrk4 static JSON callback is missing from its exact roster"))
      unless event[0] == expected_name
        raise CorruptPartError.new("Compact mrk4 static JSON callback order differs from the parsed serializer traversal")
      end
      event
    end

    private def same_bytes?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.each_with_index do |byte, index|
        return false unless byte == right[index]
      end
      true
    end

    private def ensure_no_active_grammar_parser! : Nil
      if @grammar_parser_active
        raise CorruptPartError.new("Compact mrk3 grammar source rejects re-entrant reads while reserved by a parser")
      end
      nil
    end

    private def advance_path_position(consumed : Int32) : Nil
      return unless @coordinate_context
      if consumed < 0 || consumed.to_u64 > UInt64::MAX - @path_position
        raise CorruptPartError.new("Compact inline callback path position overflows")
      end
      @path_position += consumed.to_u64
      if @path_position > @coordinate_context.not_nil!.path_data_size.to_u64
        raise CorruptPartError.new("Compact inline callback path exceeds its authenticated shard extent")
      end
      nil
    end

    private def preflight_path_advance(consumed : Int32) : Nil
      return unless context = @coordinate_context
      if consumed < 0 || consumed.to_u64 > UInt64::MAX - @path_position
        raise CorruptPartError.new("Compact inline callback path position overflows")
      end
      validate_path_extent!(@path_position, @path_position + consumed.to_u64)
      nil
    end

    private def checked_position_end(start : Int32, consumed : Int32) : Int32
      if start < 0 || consumed < 0 || consumed > Int32::MAX - start
        raise CorruptPartError.new("Compact static JSON callback position overflows its tape domain")
      end
      start + consumed
    end

    private def validate_path_extent!(start : UInt64, finish : UInt64) : Nil
      return unless context = @coordinate_context
      if finish < start || finish > context.path_data_size.to_u64
        raise CorruptPartError.new("Compact inline callback path exceeds its authenticated shard extent")
      end
      nil
    end

    # Positional callback tuples are provenance, not just diagnostics: account
    # for every retained interval on the capture operation before advancing
    # the shared cursor. Unauthenticated raw-grammar captures remain available
    # to diagnostics but cannot mint positional provenance or prepared owners.
    private def preflight_positional_event!(start : UInt64, finish : UInt64) : Bool
      return false unless @coordinate_context
      previous_end = @positional_events.empty? ? 0_u64 : @positional_events.last[2]
      unless finish >= start && start == previous_end
        raise CorruptPartError.new("Compact MRK3 callback intervals are not contiguous in physical tape order")
      end
      @budget.ensure_future_nodes(1_u64)
      @budget.ensure_future_elements(1_u64)
      @budget.charge_node
      @budget.charge_elements(1_u64)
      true
    end

    private def record_positional_event!(name : String, start : UInt64, finish : UInt64) : Nil
      # The callback name is already retained in @logical_event_names and
      # comes from the frozen schedule. Reuse that owner instead of allocating
      # a second String for every positional interval.
      @positional_events << {name, start, finish}
      nil
    end

    private def event_roster_workspace_bytes : UInt64
      bytes = instance_sizeof(Array(Tuple(String, Bytes))).to_u64
      bytes = checked_add(bytes, checked_multiply(@events.size.to_u64, sizeof(Tuple(String, Bytes)).to_u64))
      @events.each do |name, payload|
        bytes = checked_add(bytes, string_owner_bytes(name))
        bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, payload.size.to_u64))
      end
      bytes
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact static JSON framer workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact static JSON framer workspace estimate overflows")
      end
      left * right
    end
  end
end
