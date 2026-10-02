module CrystalClick
  # Ordered per-row Object MAP entries. Ordering is over the original path
  # bytes; no UTF-8 decoding or path normalization is performed.
  class ObjectSharedMapRow
    @entries : Array(ObjectSharedMapEntry)

    def initialize(entries : Array(ObjectSharedMapEntry))
      index = 1
      while index < entries.size
        unless compare_paths(entries[index - 1], entries[index]) < 0
          raise ArgumentError.new("Object shared MAP paths must be strictly byte-sorted and unique")
        end
        index += 1
      end
      @entries = entries.dup
    end

    def entries : Array(ObjectSharedMapEntry)
      @entries.dup
    end

    def entry_count : Int32
      @entries.size
    end

    def entry_at(index : Int) : ObjectSharedMapEntry
      @entries[index]
    end

    private def compare_paths(left : ObjectSharedMapEntry, right : ObjectSharedMapEntry) : Int32
      common_size = Math.min(left.path_byte_size, right.path_byte_size)
      common_size.times do |index|
        left_byte = left.path_byte_at(index)
        right_byte = right.path_byte_at(index)
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left.path_byte_size <=> right.path_byte_size
    end
  end
end
