module CrystalClick
  # The bounded, self-contained LC index-record grammar shared by ordinary
  # normalization and recursive JSON Bulk capture. This parser is deliberately
  # independent of BinaryCodecContext: the normalizer budgets emitted lanes,
  # while recursive readers precharge the complete physical parent mark.
  module BinaryLowCardinalityAdditionalIndexGrammar
    private class Cursor
      @bytes : Bytes
      @position : Int32

      def initialize(@bytes : Bytes)
        @position = 0
      end

      def position : Int32
        @position
      end

      def read_byte : UInt8
        read_slice(1_u64)[0]
      end

      def read_u64 : UInt64
        bytes = read_slice(8_u64)
        value = 0_u64
        8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
        value
      end

      def read_var_uint : UInt64
        value = 0_u64
        10.times do |index|
          byte = read_byte
          payload = (byte & 0x7f_u8).to_u64
          if index == 9 && payload > 1_u64
            raise CorruptPartError.new("Compact LowCardinality String key length overflows UInt64")
          end
          value |= payload << (index * 7)
          continuing = (byte & 0x80_u8) != 0_u8
          unless continuing
            if index > 0 && payload == 0_u64
              raise CorruptPartError.new("Compact LowCardinality String key length is nonminimal")
            end
            return value
          end
          if index == 9
            raise CorruptPartError.new("Compact LowCardinality String key length is too long")
          end
        end
        raise CorruptPartError.new("Compact LowCardinality String key length is too long")
      end

      def read_slice(size : UInt64) : Bytes
        if size > Int32::MAX.to_u64 || size > (@bytes.size - @position).to_u64
          raise CorruptPartError.new("Compact LowCardinality index record is truncated")
        end
        start = @position
        @position += size.to_i32
        @bytes[start, size.to_i32]
      end
    end

    def self.parse_extent(
      child_type : BinaryDataType,
      expected_rows : UInt64,
      bytes : Bytes,
      limits : BinaryCodecLimits,
    ) : Int32
      return 0_i32 if expected_rows == 0_u64
      if expected_rows > limits.max_elements.to_u64 || expected_rows > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact LowCardinality index row count is outside its bound")
      end

      cursor = Cursor.new(bytes)
      flags = cursor.read_u64
      if (flags & ~BinaryLowCardinalityStorageStreams::ALLOWED_MASK) != 0_u64 ||
         (flags & BinaryLowCardinalityStorageStreams::GLOBAL_BIT) != 0_u64
        raise UnsupportedFormatError.new("unsupported Compact LowCardinality index flags")
      end
      unless (flags & BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT) != 0_u64 &&
             (flags & BinaryLowCardinalityStorageStreams::UPDATE_BIT) != 0_u64
        raise UnsupportedFormatError.new("Compact LowCardinality index record is not self-contained")
      end

      width = BinaryLowCardinalityStorageStreams.width_for_code(flags & 0x3_u64)
      key_count = cursor.read_u64
      if key_count == 0_u64 || key_count > limits.max_elements.to_u64 ||
         key_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact LowCardinality additional-key count is outside its bound")
      end
      _, scalar_type = BinaryLowCardinalityStorageStreams.unwrap(child_type)
      key_count.times { skip_scalar!(scalar_type, cursor, limits) }

      row_count = cursor.read_u64
      unless row_count == expected_rows
        raise CorruptPartError.new("Compact LowCardinality index row count differs from its occurrence count")
      end
      id_bytes = BinaryLowCardinalityStorageStreams.checked_multiply(
        row_count,
        width.to_u64,
        "Compact LowCardinality index IDs exceed their supported domain",
      )
      if id_bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact LowCardinality index IDs exceed the in-memory domain")
      end
      cursor.read_slice(id_bytes)
      if cursor.position.to_u64 > limits.max_bytes.to_u64
        raise CorruptPartError.new("Compact LowCardinality index record exceeds its byte bound")
      end
      cursor.position
    end

    private def self.skip_scalar!(type : BinaryDataType, cursor : Cursor, limits : BinaryCodecLimits) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        length = cursor.read_var_uint
        if length > limits.max_bytes.to_u64 || length > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact LowCardinality String key exceeds its bounded domain")
        end
        cursor.read_slice(length)
      when BinaryDataType::TAG_BOOL
        value = cursor.read_byte
        if value > 1_u8
          raise CorruptPartError.new("Compact LowCardinality Bool key is not zero or one")
        end
      else
        width = type.fixed_width ||
                raise UnsupportedFormatError.new("unsupported Compact LowCardinality dictionary scalar")
        cursor.read_slice(width.to_u64)
      end
      nil
    end
  end
end
