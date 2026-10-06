module CrystalClick
  # One byte-opaque Object path and its detached decompressed Data/getter tape.
  class ObjectSharedPhysicalPath
    @name : String
    getter streams : ObjectSharedPathStreams

    def initialize(name : String, @streams : ObjectSharedPathStreams)
      @name = String.new(name.to_slice)
      validate_event_tape!
    end

    def name : String
      String.new(@name.to_slice)
    end

    def name_byte_size : Int32
      @name.bytesize
    end

    def name_byte_at(index : Int) : UInt8
      @name.to_slice[index]
    end

    def self.compare_names(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def validate_event_tape! : Nil
      previous = 0_u64
      @streams.event_count.times do |index|
        event = @streams.event_at(index)
        offset = event.relative_offset
        if offset > @streams.data_size.to_u64 || offset < previous
          raise ArgumentError.new("Object shared path event offsets must be monotone and within Data")
        end
        if index == 0 && offset != 0_u64
          raise ArgumentError.new("Object shared path event tape must start at byte zero")
        end
        previous = offset
      end
      if @streams.data_size > 0 && @streams.event_count == 0
        raise ArgumentError.new("nonempty Object shared path Data requires a getter event tape")
      end
    end
  end
end
