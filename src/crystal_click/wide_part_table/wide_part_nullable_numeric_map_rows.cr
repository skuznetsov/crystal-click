module CrystalClick
  # W77 keeps NULL as a typed value while charging both the fixed-width
  # placeholder stream and its separate one-byte null bitmap.
  class WidePartNullableNumericMapRows(K, T) < WidePartNumericMapRowsBase
    getter values : Array(Array(Tuple(K, T?)))

    def initialize(@values : Array(Array(Tuple(K, T?))))
    end

    def row_count : UInt64
      @values.size.to_u64
    end

    def entry_count : UInt64
      entries = 0_u64
      @values.each do |row|
        row_entries = row.size.to_u64
        if row_entries > WidePart::MAX_ARRAY_MARK_ELEMENTS - entries
          raise CorruptPartError.new("selected nullable Map mark entry count exceeds materialization limit")
        end
        entries += row_entries
      end
      entries
    end

    def payload_bytes : UInt64
      entries = entry_count
      value_width = WidePart.numeric_payload_width(WidePart.numeric_type_name(T)).to_u64 + 1_u64
      if entries > UInt64::MAX // value_width
        raise CorruptPartError.new("selected nullable Map value payload overflows")
      end
      value_bytes = entries * value_width
      key_bytes = 0_u64
      {% if K == String %}
        @values.each do |row|
          row.each do |key, _value|
            bytes = key.bytesize.to_u64
            if bytes > UInt64::MAX - key_bytes
              raise CorruptPartError.new("selected nullable Map key/value payload overflows")
            end
            key_bytes += bytes
          end
        end
      {% else %}
        if entries > UInt64::MAX // 8_u64
          raise CorruptPartError.new("selected nullable Map key payload overflows")
        end
        key_bytes = entries * 8_u64
      {% end %}
      if value_bytes > UInt64::MAX - key_bytes
        raise CorruptPartError.new("selected nullable Map key/value payload overflows")
      end
      key_bytes + value_bytes
    end

    def slice_rows(offset : Int, size : Int) : WidePartNumericMapSliceBase
      WidePartNumericMapSlice(K, T?).new(@values.to_unsafe.to_slice(@values.size)[offset, size], @values)
    end
  end
end
