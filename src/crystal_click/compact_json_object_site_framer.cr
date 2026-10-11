module CrystalClick
  # Exact named-callback source for the first Compact static-JSON checkpoint.
  # This stage admits only mrk4; an unlabelled mrk3 remainder must be parsed by
  # the later grammar-owned framer, never mistaken for one complete callback.
  class CompactJsonObjectSiteFramer < ObjectSharedPathCallbackSource
    @cursor : CompactBinaryBulkGranuleCursor
    @events : Array(Tuple(String, Bytes))
    @event_index : Int32

    def initialize(
      mode : CompactMarkFormat,
      shards : Array(CompactPartPhysicalShard),
      budget : BinaryCodecBudget,
    )
      unless mode.mrk4?
        raise UnsupportedFormatError.new("Compact static JSON callback framing currently requires mrk4")
      end
      @events = Array(Tuple(String, Bytes)).new(shards.size)
      seen = Set(String).new
      shards.each do |shard|
        name = shard.stream_name ||
               raise(CorruptPartError.new("Compact mrk4 static JSON callback has no stream name"))
        unless seen.add?(name)
          raise CorruptPartError.new("Compact mrk4 static JSON callback roster duplicates a stream name")
        end
        @events << {String.new(name.to_slice), shard.bytes}
      end
      @event_index = 0
      @cursor = CompactBinaryBulkGranuleCursor.new(mode, shards, nil)
      @cursor.charge_complete_wire_input!(budget)
    end

    protected def borrow_self_delimited(expected_name : String) : Bytes
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
      nil
    end

    def take_exact(expected_name : String, size : Int32) : Bytes
      ensure_no_active_parser!
      if size < 0
        raise CorruptPartError.new("Compact static JSON fixed callback size is negative")
      end
      name, bytes = current_event(expected_name)
      unless bytes.size == size
        raise CorruptPartError.new("Compact static JSON fixed callback has the wrong byte extent")
      end
      @cursor.begin_event(name)
      bytes = @cursor.read_exact(size)
      @cursor.finish_event
      @event_index += 1
      bytes
    end

    def take_inline_fragment(expected_name : String) : Bytes
      ensure_no_active_parser!
      name, _observed = current_event(expected_name)
      @cursor.begin_event(name)
      bytes = @cursor.remaining_slice
      @cursor.advance_borrowed_prefix(bytes.size)
      @cursor.finish_event
      @event_index += 1
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
    end

    def finish! : Nil
      unless @event_index == @events.size
        raise CorruptPartError.new("Compact static JSON callback roster was not consumed exactly")
      end
      @cursor.finish_granule
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
