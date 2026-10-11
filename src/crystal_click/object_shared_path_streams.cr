module CrystalClick
  # Detached owner for one exact path/chunk Data slice and its getter tape.
  class ObjectSharedPathStreams
    @data : Bytes
    @events : Array(ObjectSharedPathSubstreamEvent)
    @coordinate_context : ObjectSharedInlineCoordinateContext?
    @callback_relocations : Array(ObjectSharedInlineCallbackRelocation)

    def initialize(
      data : Bytes,
      events : Array(ObjectSharedPathSubstreamEvent),
      @coordinate_context : ObjectSharedInlineCoordinateContext? = nil,
      callback_relocations : Array(ObjectSharedInlineCallbackRelocation) = [] of ObjectSharedInlineCallbackRelocation,
      provenance_budget : BinaryCodecBudget? = nil,
    )
      if context = @coordinate_context
        budget = provenance_budget || raise(ArgumentError.new("authenticated path streams require their operation budget"))
        unless context.path_data_size == data.size
          raise ArgumentError.new("Object shared path coordinate context does not match the detached Data extent")
        end
        context.validate_path_bytes!(0_u64, data, budget)
      end
      @data = Bytes.new(data.size) { |index| data[index] }
      @callback_relocations = callback_relocations.dup
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

    # Retains the authenticated physical Data resolver and exact path interval
    # alongside the detached Data bytes. Ordinary/encoder-created streams do
    # not have physical provenance and therefore return nil.
    def coordinate_context : ObjectSharedInlineCoordinateContext?
      @coordinate_context
    end

    def callback_relocation_count : Int32
      @callback_relocations.size
    end

    def callback_relocation_at(index : Int) : ObjectSharedInlineCallbackRelocation
      @callback_relocations[index]
    end

    def callback_relocations : Array(ObjectSharedInlineCallbackRelocation)
      @callback_relocations.dup
    end
  end
end
