module CrystalClick
  class WidePart
    # Owns LowCardinality's bounded dictionary and index binary grammar.
    # Stream framing, marks, and cache lifecycle remain with WidePart.
    private class LowCardinalityBinaryCodec
      def self.parse_index_mark(
        bytes : Bytes,
        start_offset : UInt64,
        end_offset : UInt64,
        mark : Mark,
        mark_index : Int,
        global_dictionary : Bool,
        shared_keys : Array(String),
      ) : {Array(String), Int32}
        raise CorruptPartError.new("LowCardinality index mark boundaries are invalid") if start_offset > end_offset || end_offset > bytes.size.to_u64
        segment = bytes[start_offset.to_i, (end_offset - start_offset).to_i]
        header = read_u64(segment, 0)
        expected_header = if global_dictionary
                            mark_index == 0 ? 0x500_u64 : 0x100_u64
                          else
                            0x600_u64
                          end
        if header != expected_header
          raise UnsupportedFormatError.new("unsupported or changing LowCardinality dictionary state")
        end
        keys = shared_keys
        cursor = 8
        unless global_dictionary
          key_count = read_u64(segment, cursor)
          cursor += 8
          raise CorruptPartError.new("LowCardinality local dictionary is empty or exceeds key limit") if key_count == 0_u64 || key_count > WidePart::MAX_LOW_CARDINALITY_DICTIONARY_KEYS
          keys = Array(String).new(key_count.to_i)
          seen = Set(String).new
          key_count.to_i.times do
            key, cursor = read_string(segment, cursor)
            raise CorruptPartError.new("LowCardinality local dictionary contains duplicate keys") unless seen.add?(key)
            keys << key
          end
          raise CorruptPartError.new("LowCardinality local dictionary must reserve the empty default at ID zero") unless keys.first.empty?
        end
        row_count = read_u64(segment, cursor)
        cursor += 8
        raise CorruptPartError.new("LowCardinality index row count differs from marks") unless row_count == mark.rows
        raise CorruptPartError.new("LowCardinality index row count exceeds limit") if row_count > WidePart::MAX_LOW_CARDINALITY_MARK_ROWS
        raise CorruptPartError.new("LowCardinality index IDs are truncated or have trailing bytes") unless segment.size - cursor == row_count
        {keys, start_offset.to_i + cursor}
      end

      def self.read_dictionary(bytes : Bytes, offset : Int, limit : Int?) : {Array(String), Int32}
        count = read_u64(bytes, offset)
        cursor = offset + 8
        maximum = limit || bytes.size
        raise CorruptPartError.new("LowCardinality dictionary is empty or exceeds key limit") if count == 0_u64 || count > WidePart::MAX_LOW_CARDINALITY_DICTIONARY_KEYS
        keys = Array(String).new(count.to_i)
        seen = Set(String).new
        count.to_i.times do
          key, cursor = read_string(bytes, cursor)
          raise CorruptPartError.new("LowCardinality dictionary contains duplicate keys") unless seen.add?(key)
          keys << key
        end
        raise CorruptPartError.new("LowCardinality dictionary record exceeds mark boundary") if cursor > maximum
        {keys, cursor.to_i32}
      end

      def self.read_u64(bytes : Bytes, offset : Int) : UInt64
        raise CorruptPartError.new("LowCardinality UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
        u64(bytes, offset)
      end

      def self.read_string(bytes : Bytes, offset : Int) : {String, Int32}
        length, data_offset = read_var_uint(bytes, offset)
        raise CorruptPartError.new("LowCardinality String length exceeds remaining bytes") if length > (bytes.size - data_offset).to_u64
        finish = data_offset + length.to_i
        {String.new(bytes[data_offset, length.to_i]), finish.to_i32}
      end

      def self.read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
        raise CorruptPartError.new("LowCardinality VarUInt is truncated") if offset < 0
        value = 0_u64
        cursor = offset
        10.times do |index|
          raise CorruptPartError.new("LowCardinality VarUInt is truncated") if cursor >= bytes.size
          byte = bytes[cursor]
          payload = (byte & 0x7f_u8).to_u64
          raise CorruptPartError.new("LowCardinality VarUInt overflows UInt64") if index == 9 && payload > 1_u64
          value |= payload << (index * 7)
          cursor += 1
          unless byte & 0x80_u8 != 0
            raise CorruptPartError.new("LowCardinality VarUInt is noncanonical") if index > 0 && payload == 0_u64
            return {value, cursor.to_i32}
          end
        end
        raise CorruptPartError.new("LowCardinality VarUInt is too long")
      end

      private def self.u64(bytes : Bytes, offset : Int) : UInt64
        raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 8
        value = 0_u64
        8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
        value
      end
    end
  end
end
