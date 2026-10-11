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

    def initialize(
      @mode : CompactMarkFormat,
      shards : Array(CompactPartPhysicalShard),
      expected_events : Array(String),
    )
      @whole = nil
      @events = [] of Tuple(String, Bytes)
      @event_index = 0
      @active_name = nil
      @active_bytes = nil
      @position = 0

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
        unless observed_events == expected_events
          raise CorruptPartError.new("Compact mrk4 callbacks differ from the selected serializer roster")
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
