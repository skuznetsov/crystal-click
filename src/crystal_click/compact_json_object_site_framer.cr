module CrystalClick
  # Compact-specific source for Object prefix/body grammar extents. mrk4
  # callbacks stay exact named events; mrk3 exposes only a borrowed remainder
  # to a parser that returns its own consumed byte count.
  class CompactJsonObjectSiteFramer < ObjectSharedPathCallbackSource
    @cursor : CompactBinaryBulkGranuleCursor
    @events : Array(Tuple(String, Bytes))
    @event_index : Int32
    @logical_event_names : Array(String)
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
      if physical_context && !mode.mrk4?
        raise UnsupportedFormatError.new("authenticated Compact inline path coordinates require named mrk4 shards")
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
      if @cursor.mrk4?
        return with_self_delimited(expected_name) do |bytes|
          value, consumed = yield bytes
          { {value, bytes}, consumed }
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

        # Extent validation precedes the only cursor mutation. Any parser
        # exception or invalid count leaves the source position and logical
        # schedule untouched; parser budget consumption is intentionally not
        # rolled back.
        @cursor.advance_borrowed_prefix(consumed)
        observed = @cursor.consumed_slice(start)
        advance_path_position(consumed)
        @logical_event_names << expected_name
        {value, observed}
      ensure
        @grammar_parser_active = false
      end
    end

    def take_exact(expected_name : String, size : Int32) : Bytes
      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      if size < 0
        raise CorruptPartError.new("Compact static JSON fixed callback size is negative")
      end
      if @cursor.mrk4?
        name, bytes = current_event(expected_name)
        unless bytes.size == size
          raise CorruptPartError.new("Compact static JSON fixed callback has the wrong byte extent")
        end
        @cursor.begin_event(name)
        observed = @cursor.read_exact(size)
        @cursor.finish_event
        @event_index += 1
        advance_path_position(size)
      else
        observed = @cursor.read_exact(size)
      end
      @logical_event_names << expected_name
      observed
    end

    def take_inline_fragment(expected_name : String) : Bytes
      ensure_no_active_parser!
      ensure_no_active_grammar_parser!
      unless @cursor.mrk4?
        raise UnsupportedFormatError.new("Compact mrk3 body fragments require descriptor-owned grammar framing")
      end
      name, _observed = current_event(expected_name)
      @cursor.begin_event(name)
      bytes = @cursor.remaining_slice
      @cursor.advance_borrowed_prefix(bytes.size)
      @cursor.finish_event
      @event_index += 1
      advance_path_position(bytes.size)
      @logical_event_names << expected_name
      bytes
    end

    def take_inline_fragment_slice(
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      bytes = take_inline_fragment(callback_name)
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

    def validate_expected_events!(names : Array(String)) : Nil
      @cursor.validate_expected_events!(names)
      unless @logical_event_names == names
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
    ) : Nil
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

      schedule = CompactJsonObjectRoleSchedule.build(
        prefix,
        physical_plan,
        prefix.nested_context.profile,
        budget,
      )
      unless schedule.body_bindings == role_bindings && schedule.body_pairs == callback_pairs
        raise CorruptPartError.new("prepared Compact body roles differ from the parsed Object schedule")
      end
      prefix_pairs = schedule.prefix_pairs
      unless prefix.prefix_callback_count == prefix_pairs.size
        raise CorruptPartError.new("prepared Compact prefix callbacks differ from the parsed Object schedule")
      end
      body_count = prefix.body_callback_count
      unless body_count == callback_pairs.size && prefix.body_callback_slice_count == body_count
        raise CorruptPartError.new("prepared Compact body callbacks differ from the parsed Object schedule")
      end
      unless @event_index == @events.size && @logical_event_names == schedule.event_names
        raise CorruptPartError.new("prepared Compact source did not consume its exact logical callback roster")
      end
      unless @events.size == prefix_pairs.size + callback_pairs.size
        raise CorruptPartError.new("prepared Compact source roster has a different callback count")
      end

      path_position = 0_u64
      event_index = 0
      prefix_pairs.each_with_index do |pair, index|
        parsed_name, parsed_bytes = prefix.prefix_callback_at(index, budget)
        event_name, event_bytes = @events[event_index]? ||
                                  raise(CorruptPartError.new("prepared Compact prefix callback is missing from its source"))
        unless pair[1] == parsed_name && event_name == parsed_name && same_bytes?(event_bytes, parsed_bytes)
          raise CorruptPartError.new("prepared Compact prefix bytes differ from their authenticated callback source")
        end
        path_position = checked_add(path_position, event_bytes.size.to_u64)
        event_index += 1
      end

      callback_pairs.each_with_index do |pair, index|
        parsed_name, parsed_bytes = prefix.body_callback_at(index, budget)
        slice = prefix.body_callback_slice_at(index)
        event_name, event_bytes = @events[event_index]? ||
                                  raise(CorruptPartError.new("prepared Compact body callback is missing from its source"))
        finish = checked_add(path_position, event_bytes.size.to_u64)
        unless parsed_name == pair[0] && event_name == pair[1] &&
               slice.canonical_name == pair[0] && slice.callback_name == pair[1] &&
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
      end
      unless event_index == @events.size && path_position == @path_position &&
             path_position == coordinate_context.path_data_size.to_u64
        raise CorruptPartError.new("prepared Compact source intervals do not cover the authenticated callback path")
      end

      # Some direct-reader captures have not bound the Object body schedule
      # onto the prefix. Bind only the schedule derived above, and only after
      # the complete finished source has passed roster, byte, context, and
      # interval validation. Existing bindings must match exactly; a repeated
      # validation is therefore safe and does not attempt to bind twice.
      begin
        unless prefix.body_role_bindings == schedule.body_bindings &&
               prefix.body_callback_pairs == schedule.body_pairs
          raise CorruptPartError.new("prepared Compact prefix retained a different body-role binding")
        end
      rescue ex : ArgumentError
        prefix.bind_body_schedule!(schedule.body_bindings, schedule.body_pairs)
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
      bytes
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
