module CrystalClick
  # :nodoc:
  # Mutable operation-wide counters shared by a parent part and every
  # projection child it publishes.
  class ProjectionWriterBudgets
    getter write_codec : BinaryCodecBudget
    getter write_transport : CompressedStreamBudget
    getter read_codec : BinaryCodecBudget
    getter read_transport : CompressedStreamBudget

    def initialize(
      @write_codec : BinaryCodecBudget,
      @write_transport : CompressedStreamBudget,
      @read_codec : BinaryCodecBudget,
      @read_transport : CompressedStreamBudget,
    )
      unless @write_codec.writing? && @write_transport.writing? &&
             !@read_codec.writing? && !@read_transport.writing?
        raise ArgumentError.new("projection operation budgets have inconsistent directions")
      end
    end
  end
end
