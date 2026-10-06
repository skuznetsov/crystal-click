module CrystalClick
  # Detached owner for one exact path/chunk Data slice and its getter tape.
  class ObjectSharedPathStreams
    @data : Bytes
    @events : Array(ObjectSharedPathSubstreamEvent)

    def initialize(data : Bytes, events : Array(ObjectSharedPathSubstreamEvent))
      @data = Bytes.new(data.size) { |index| data[index] }
      # Event objects are immutable and own their names; duplicating the array
      # is sufficient to detach the mutable collection boundary.
      @events = events.dup
    end

    def data : Bytes
      Bytes.new(@data.size) { |index| @data[index] }
    end

    def events : Array(ObjectSharedPathSubstreamEvent)
      @events.dup
    end

    # Non-allocating inspection lets outer physical owners preflight aggregate
    # work before requesting detached Data or tape snapshots.
    def data_size : Int32
      @data.size
    end

    def event_count : Int32
      @events.size
    end

    def data_byte_at(index : Int) : UInt8
      @data[index]
    end

    def event_at(index : Int) : ObjectSharedPathSubstreamEvent
      @events[index]
    end
  end
end
