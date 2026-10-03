module CrystalClick
  class WidePartArrayMapArrayLeafRows(K, V) < WidePartArrayMapArrayLeafRowsBase
    getter values : Array(Array(Array(Tuple(K, Array(V)))))

    def initialize(@values : Array(Array(Array(Tuple(K, Array(V))))))
    end

    def row_count : UInt64
      @values.size.to_u64
    end

    def map_count : UInt64
      total = 0_u64
      @values.each do |row|
        count = row.size.to_u64
        raise CorruptPartError.new("selected W84 Array(Map) map count exceeds materialization limit") if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - total
        total += count
      end
      total
    end

    def entry_count : UInt64
      total = 0_u64
      @values.each do |row|
        row.each do |map|
          count = map.size.to_u64
          raise CorruptPartError.new("selected W84 Array(Map) entry count exceeds materialization limit") if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - total
          total += count
        end
      end
      total
    end

    def value_count : UInt64
      total = 0_u64
      @values.each do |row|
        row.each do |map|
          map.each do |_key, nested_values|
            count = nested_values.size.to_u64
            raise CorruptPartError.new("selected W84 nested Array element count exceeds materialization limit") if count > WidePart::MAX_ARRAY_MARK_ELEMENTS - total
            total += count
          end
        end
      end
      total
    end

    def payload_bytes : UInt64
      entries = entry_count
      leaves = value_count
      key_bytes = 0_u64
      {% if K == String %}
        @values.each do |row|
          row.each do |map|
            map.each do |key, _nested_values|
              bytes = key.bytesize.to_u64
              raise CorruptPartError.new("selected W84 key bytes overflow") if bytes > UInt64::MAX - key_bytes
              key_bytes += bytes
            end
          end
        end
      {% else %}
        raise CorruptPartError.new("selected W84 key bytes overflow") if entries > UInt64::MAX // 8_u64
        key_bytes = entries * 8_u64
      {% end %}

      value_bytes = 0_u64
      {% if V == String %}
        @values.each do |row|
          row.each do |map|
            map.each do |_key, nested_values|
              nested_values.each do |value|
                bytes = value.bytesize.to_u64
                raise CorruptPartError.new("selected W84 value bytes overflow") if bytes > UInt64::MAX - value_bytes
                value_bytes += bytes
              end
            end
          end
        end
      {% else %}
        value_width = WidePart.numeric_payload_width(WidePart.numeric_type_name(V)).to_u64
        raise CorruptPartError.new("selected W85 numeric value bytes overflow") if leaves > UInt64::MAX // value_width
        value_bytes = leaves * value_width
      {% end %}
      raise CorruptPartError.new("selected W84 payload bytes overflow") if value_bytes > UInt64::MAX - key_bytes
      key_bytes + value_bytes
    end

    def slice_rows(offset : Int, size : Int) : WidePartArrayMapNumericSliceBase
      WidePartArrayMapNumericSlice(K, Array(V)).new(@values.to_unsafe.to_slice(@values.size)[offset, size], @values)
    end
  end
end
