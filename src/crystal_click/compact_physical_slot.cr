module CrystalClick
  # One physical callback position in a flattened Compact mark record.
  # Identity is the global slot index; names are descriptive and may repeat in
  # different column blocks.
  class CompactPhysicalSlot
    getter index : Int32
    getter column_name : String
    getter stream_name : String?

    def initialize(@index : Int32, column_name : String, stream_name : String?)
      raise ArgumentError.new("physical slot index must be nonnegative") if @index < 0
      @column_name = String.new(column_name.to_slice)
      @stream_name = stream_name.try { |name| String.new(name.to_slice) }
    end

    def detached_copy : CompactPhysicalSlot
      CompactPhysicalSlot.new(@index, @column_name, @stream_name)
    end
  end
end
