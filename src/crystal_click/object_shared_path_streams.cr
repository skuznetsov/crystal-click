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
  end
end
