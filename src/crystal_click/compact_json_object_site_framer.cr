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
    @tape_size : UInt64

    def initialize(
      mode : CompactMarkFormat,
      shards : Array(CompactPartPhysicalShard),
      budget : BinaryCodecBudget,
    )
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
      @cursor = CompactBinaryBulkGranuleCursor.new(mode, shards, nil)
      @cursor.charge_complete_wire_input!(budget)
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
      @logical_event_names << expected_name
      bytes
    end

    def take_inline_fragment_slice(
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      bytes = take_inline_fragment(callback_name)
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        0_u64,
        bytes.size.to_u64,
        bytes,
        nil,
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

    private def ensure_no_active_grammar_parser! : Nil
      if @grammar_parser_active
        raise CorruptPartError.new("Compact mrk3 grammar source rejects re-entrant reads while reserved by a parser")
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
