module CrystalClick
  class WidePart
    # Materializes String values from their already-validated size vector and
    # bounded raw payload. Stream identity, marks, budgets, and codec admission
    # remain the responsibility of WidePart's context-aware readers.
    private class StringPayloadDecoder
      def self.each(
        sizes : Array(UInt64),
        raw_bytes : Bytes,
        label : String,
        & : String, Int32 -> Nil
      ) : Nil
        offset = 0
        sizes.each_with_index do |size, index|
          remaining = raw_bytes.size - offset
          raise CorruptPartError.new("#{label} sizes exceed selected raw bytes") if size > remaining.to_u64

          length = size.to_i
          yield String.new(raw_bytes[offset, length]), index
          offset += length
        end

        raise CorruptPartError.new("#{label} sizes do not consume selected raw bytes") unless offset == raw_bytes.size
      end
    end
  end
end
