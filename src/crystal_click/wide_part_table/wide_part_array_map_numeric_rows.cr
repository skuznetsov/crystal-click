module CrystalClick
  class WidePartArrayMapNumericRows(K, T) < WidePartArrayMapNumericRowsBase
    getter values : Array(Array(Array(Tuple(K, T))))

    def initialize(@values : Array(Array(Array(Tuple(K, T)))))
    end

    def row_count : UInt64
      @values.size.to_u64
    end

    def map_count : UInt64
      total = 0_u64
      @values.each do |row|
        count = row.size.to_u64
        raise CorruptPartError.new("selected Array(Map) map count exceeds materialization limit") if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - total
        total += count
      end
      total
    end

    def entry_count : UInt64
      total = 0_u64
      @values.each do |row|
        row.each do |map|
          count = map.size.to_u64
          raise CorruptPartError.new("selected Array(Map) entry count exceeds materialization limit") if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - total
          total += count
        end
      end
      total
    end

    def payload_bytes : UInt64
      maps = map_count
      entries = entry_count
      key_bytes = 0_u64
      {% if K == String %}
        @values.each do |row|
          row.each do |map|
            map.each do |key, _value|
              bytes = key.bytesize.to_u64
              raise CorruptPartError.new("selected Array(Map) key bytes overflow") if bytes > UInt64::MAX - key_bytes
              key_bytes += bytes
            end
          end
        end
      {% else %}
        raise CorruptPartError.new("selected Array(Map) key bytes overflow") if entries > UInt64::MAX // 8_u64
        key_bytes = entries * 8_u64
      {% end %}
      width = WidePart.numeric_payload_width(WidePart.numeric_type_name(T)).to_u64
      raise CorruptPartError.new("selected Array(Map) value bytes overflow") if entries > UInt64::MAX // width
      value_bytes = entries * width
      raise CorruptPartError.new("selected Array(Map) payload bytes overflow") if value_bytes > UInt64::MAX - key_bytes
      key_bytes + value_bytes
    end

    def slice_rows(offset : Int, size : Int) : WidePartArrayMapNumericSliceBase
      WidePartArrayMapNumericSlice(K, T).new(@values.to_unsafe.to_slice(@values.size)[offset, size], @values)
    end
  end
end
