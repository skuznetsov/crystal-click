module CrystalClick
  # Reads one Compact granule in declared callback order. mrk3 supplies one
  # grammar-delimited tape; mrk4 supplies separately named callback shards.
  class CompactBinaryBulkGranuleCursor
    @mode : CompactMarkFormat
    @whole : Bytes?
    @events : Array(Tuple(String, Bytes))
    @event_index : Int32
    @active_name : String?
    @active_bytes : Bytes?
    @position : Int32
    @complete_wire_input_charged : Bool

    def initialize(
      @mode : CompactMarkFormat,
      shards : Array(CompactPartPhysicalShard),
      expected_events : Array(String)?,
    )
      @whole = nil
      @events = [] of Tuple(String, Bytes)
      @event_index = 0
      @active_name = nil
      @active_bytes = nil
      @position = 0
      @complete_wire_input_charged = false

      if @mode.mrk4?
        observed_events = [] of String
        seen = Set(String).new
        shards.each do |shard|
          name = shard.stream_name ||
                 raise(CorruptPartError.new("Compact mrk4 callback has no stream name"))
          unless seen.add?(name)
            raise CorruptPartError.new("Compact mrk4 callback roster duplicates a stream name")
          end
          detached_name = String.new(name.to_slice)
          observed_events << detached_name
          @events << {detached_name, shard.bytes}
        end
        if expected = expected_events
          unless observed_events == expected
            raise CorruptPartError.new("Compact mrk4 callbacks differ from the selected serializer roster")
          end
        end
      else
        unless shards.size == 1 && shards[0].stream_name.nil?
          raise CorruptPartError.new("Compact mrk3 mark is not one unlabelled column tape")
        end
        @whole = shards[0].bytes
      end
    end

    def begin_event(name : String) : Nil
      if @active_name || @active_bytes
        raise CorruptPartError.new("Compact callback event was opened before its predecessor finished")
      end
      return nil unless @mode.mrk4?

      event = @events[@event_index]? ||
              raise(CorruptPartError.new("Compact mrk4 callback is missing from its exact roster"))
      unless event[0] == name
        raise CorruptPartError.new("Compact mrk4 callback order differs from the selected serializer traversal")
      end
      @active_name = name
      @active_bytes = event[1]
      @position = 0
      nil
    end

    # First-pass Dynamic discovery cannot know callbacks nested beneath actual
    # Dynamic arms until it has parsed the parent structure. Open the next
    # physical callback without assigning it a serializer role yet; the
    # prepared Dynamic plan later binds the complete observed roster exactly.
    # mrk3 has no callback names, but shares the same grammar-delimited tape.
    def begin_next_discovery_event : String?
      if @active_name || @active_bytes
        raise CorruptPartError.new("Compact callback event was opened before its predecessor finished")
      end
      return nil unless @mode.mrk4?

      event = @events[@event_index]? ||
              raise(CorruptPartError.new("Compact mrk4 callback is missing during Dynamic discovery"))
      @active_name = event[0]
      @active_bytes = event[1]
      @position = 0
      event[0]
    end

    # Close the learning phase by comparing every callback actually consumed
    # during prefix and body traversal with the now-known serializer roster.
    def validate_expected_events!(expected_events : Array(String)) : Nil
      return nil unless @mode.mrk4?
      unless @events.size == expected_events.size
        raise CorruptPartError.new("Compact mrk4 callbacks differ from the prepared serializer roster")
      end
      @events.each_with_index do |event, index|
        unless event[0] == expected_events[index]
          raise CorruptPartError.new("Compact mrk4 callbacks differ from the prepared serializer roster")
        end
      end
      nil
    end

    def finish_event : Nil
      return nil unless @mode.mrk4?

      @active_name ||
        raise(CorruptPartError.new("Compact mrk4 callback event has no active name"))
      bytes = @active_bytes ||
              raise(CorruptPartError.new("Compact mrk4 callback event has no active bytes"))
      unless @position == bytes.size
        raise CorruptPartError.new("Compact mrk4 callback contains trailing bytes")
      end
      @event_index += 1
      @active_name = nil
      @active_bytes = nil
      @position = 0
      nil
    end

    def read_exact(size : Int32) : Bytes
      raise CorruptPartError.new("Compact callback requested a negative byte count") if size < 0
      source = current_source
      remaining = source.size - @position
      if size > remaining
        raise CorruptPartError.new("Compact callback tape is truncated")
      end
      slice = source[@position, size]
      @position += size
      slice
    end

    def read_u64 : UInt64
      bytes = read_exact(8)
      value = 0_u64
      8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
      value
    end

    def read_var_uint : UInt64
      value = 0_u64
      10.times do |index|
        byte = read_exact(1)[0]
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          raise CorruptPartError.new("Compact callback VarUInt overflows UInt64")
        end
        value |= payload << (index * 7)
        continuing = (byte & 0x80_u8) != 0_u8
        unless continuing
          if index > 0 && payload == 0_u64
            raise CorruptPartError.new("Compact callback VarUInt is nonminimal")
          end
          return value
        end
        if index == 9
          raise CorruptPartError.new("Compact callback VarUInt is too long")
        end
      end
      raise CorruptPartError.new("Compact callback VarUInt is too long")
    end

    def position : Int32
      @position
    end

    def remaining : Int32
      current_source.size - @position
    end

    # Explicitly precharge the complete physical granule before a codec context
    # borrows any prefix slices with account_input_bytes=false. Charging the
    # whole source once avoids the mrk3 trap where every nested structure parser
    # would otherwise charge the same remaining tape tail again.
    def charge_complete_wire_input!(budget : BinaryCodecBudget) : Nil
      if budget.writing?
        raise ArgumentError.new("Compact granule wire precharge requires a read-direction budget")
      end
      if @complete_wire_input_charged
        raise ArgumentError.new("Compact granule wire input was already charged")
      end

      total = 0_u64
      if whole = @whole
        total = whole.size.to_u64
      else
        @events.each do |event|
          size = event[1].size.to_u64
          if size > UInt64::MAX - total
            raise CorruptPartError.new("Compact granule input byte count overflows UInt64")
          end
          total += size
        end
      end
      budget.ensure_wire_bytes(total)
      budget.charge_wire_bytes(total)
      @complete_wire_input_charged = true
      nil
    end

    # Borrow the next named MRK4 callback without opening or advancing it.
    # The cursor's complete physical input must already be charged. The
    # read-only view shares the event's storage and must not outlive this cursor.
    def pending_event_slice(name : String) : Bytes
      unless @complete_wire_input_charged
        raise ArgumentError.new("Compact borrowed input requires a prior complete-granule charge")
      end
      unless @mode.mrk4?
        raise ArgumentError.new("Compact pending named callback view requires mrk4")
      end
      if @active_name || @active_bytes
        raise CorruptPartError.new("Compact pending callback view cannot overlap an active callback")
      end

      event = @events[@event_index]? ||
              raise(CorruptPartError.new("Compact mrk4 callback is missing from its exact roster"))
      unless event[0] == name
        raise CorruptPartError.new("Compact mrk4 pending callback differs from the selected serializer traversal")
      end
      bytes = event[1]
      Bytes.new(bytes.to_unsafe, bytes.size, read_only: true)
    end

    # Borrow the unconsumed callback slice for an existing codec parser. The
    # returned Bytes is a view over cursor-owned bytes and remains valid while
    # this cursor is alive; callers must commit only the parser's observed
    # consumption with #advance_borrowed_prefix.
    def remaining_slice : Bytes
      unless @complete_wire_input_charged
        raise ArgumentError.new("Compact borrowed input requires a prior complete-granule charge")
      end
      source = current_source
      source[@position, source.size - @position]
    end

    # Parse and commit one bounded grammar extent without changing the
    # caller's historical input-byte accounting. The parser receives a
    # read-only borrowed view; failure, an out-of-range extent, or MRK4
    # trailing bytes leave the cursor position unchanged. This is for
    # consumers that charge their normalized output lanes rather than
    # precharging raw physical input.
    def with_transactional_borrowed_prefix(&block : Bytes -> Tuple(T, Int32)) : Tuple(T, Bytes) forall T
      source = current_source
      source_view = source[@position, source.size - @position]
      borrowed = Bytes.new(source_view.to_unsafe, source_view.size, read_only: true)
      value, consumed = yield borrowed
      unless consumed >= 0 && consumed <= borrowed.size
        raise CorruptPartError.new("Compact borrowed parser consumed outside its callback slice")
      end
      if @mode.mrk4? && consumed != borrowed.size
        raise CorruptPartError.new("Compact borrowed parser did not consume its exact named callback")
      end

      start = @position
      @position += consumed
      {value, source[start, consumed]}
    end

    # Advance after a codec parsed a borrowed prefix. The enclosing caller must
    # have charged the complete physical granule first via
    # #charge_complete_wire_input! before constructing a prepaid context.
    def advance_borrowed_prefix(consumed_bytes : Int32) : Nil
      unless @complete_wire_input_charged
        raise ArgumentError.new("Compact borrowed input requires a prior complete-granule charge")
      end
      if consumed_bytes < 0 || consumed_bytes > remaining
        raise CorruptPartError.new("Compact borrowed parser consumed outside its callback slice")
      end
      @position += consumed_bytes
      nil
    end

    def mrk4? : Bool
      @mode.mrk4?
    end

    def consumed_slice(start : Int32) : Bytes
      source = current_source
      if start < 0 || start > @position
        raise ArgumentError.new("Compact callback capture begins outside the consumed interval")
      end
      source[start, @position - start]
    end

    def finish_granule : Nil
      if @mode.mrk4?
        if @active_name || @active_bytes || @event_index != @events.size
          raise CorruptPartError.new("Compact mrk4 callback roster was not consumed exactly")
        end
      else
        source = @whole || raise(CorruptPartError.new("Compact mrk3 tape is missing"))
        unless @position == source.size
          raise CorruptPartError.new("Compact mrk3 callback tape has trailing bytes")
        end
      end
      nil
    end

    private def current_source : Bytes
      if @mode.mrk4?
        @active_bytes ||
          raise(CorruptPartError.new("Compact mrk4 cursor has no active callback"))
      else
        @whole || raise(CorruptPartError.new("Compact mrk3 tape is missing"))
      end
    end
  end
end
