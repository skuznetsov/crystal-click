module CrystalClick
  # W79 nests nullable numeric leaves under Map entries. Charge the physical
  # fixed-width value slot and its one-byte null code for every leaf.
  class WidePartNullableNumericMapArrayRows(K, T) < WidePartNumericMapRowsBase
    getter values : Array(Array(Tuple(K, Array(T?))))

    def initialize(@values : Array(Array(Tuple(K, Array(T?)))))
    end

    def row_count : UInt64
      @values.size.to_u64
    end

    def entry_count : UInt64
      entries = 0_u64
      @values.each do |row|
        count = row.size.to_u64
        if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
          raise CorruptPartError.new("selected nullable Map Array entry count exceeds materialization limit")
        end
        entries += count
      end
      entries
    end

    def payload_bytes : UInt64
      entries = entry_count
      leaves = 0_u64
      key_bytes = 0_u64
      @values.each do |row|
        row.each do |key, nested_values|
          count = nested_values.size.to_u64
          if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - leaves
            raise CorruptPartError.new("selected nullable Map nested Array element count exceeds materialization limit")
          end
          leaves += count
          {% if K == String %}
            bytes = key.bytesize.to_u64
            if bytes > UInt64::MAX - key_bytes
              raise CorruptPartError.new("selected nullable Map key bytes overflow")
            end
            key_bytes += bytes
          {% end %}
        end
      end
      {% if K == UInt64 %}
        if entries > UInt64::MAX // 8_u64
          raise CorruptPartError.new("selected nullable Map key bytes overflow")
        end
        key_bytes = entries * 8_u64
      {% end %}
      value_width = WidePart.numeric_payload_width(WidePart.numeric_type_name(T)).to_u64 + 1_u64
      if leaves > UInt64::MAX // value_width
        raise CorruptPartError.new("selected nullable Map nested Array byte count overflows")
      end
      value_bytes = leaves * value_width
      if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 || value_bytes > UInt64::MAX - key_bytes
        raise CorruptPartError.new("selected nullable Map nested Array bytes exceed materialization limit")
      end
      key_bytes + value_bytes
    end

    def slice_rows(offset : Int, size : Int) : WidePartNumericMapSliceBase
      WidePartNumericMapSlice(K, Array(T?)).new(@values.to_unsafe.to_slice(@values.size)[offset, size], @values)
    end
  end
end
