module CrystalClick
  # Variable-width avg state grammar. The promoted numerator is a fixed
  # little-endian carrier; the trailing denominator is the canonical bounded
  # UInt64 VarUInt. That VarUInt, not an enclosing blob length, delimits rows.
  class BinaryAggregateAvgStateLayout
    getter numerator_width : Int32

    def initialize(input_type : BinaryDataType)
      @numerator_width = self.class.numerator_width_for(input_type)
    end

    def minimum_state_bytes : Int32
      @numerator_width + 1
    end

    def maximum_state_bytes : Int32
      @numerator_width + 10
    end

    def default_state_bytes : Bytes
      Bytes.new(minimum_state_bytes, 0_u8)
    end

    def validate_state_bytes(bytes : Bytes) : Nil
      if bytes.size < minimum_state_bytes
        raise ArgumentError.new("AggregateFunction avg state is shorter than its numerator and denominator")
      end
      if bytes.size > maximum_state_bytes
        raise ArgumentError.new("AggregateFunction avg denominator exceeds the UInt64 VarUInt bound")
      end

      denominator_size = canonical_var_uint_size(bytes, @numerator_width)
      unless @numerator_width + denominator_size == bytes.size
        raise ArgumentError.new("AggregateFunction avg state has trailing bytes")
      end
      nil
    end

    # Consume exactly one state from a cursor. The fixed numerator and bounded
    # VarUInt are copied into an owned Slice so a borrowed input row cannot
    # escape through BinaryValue.
    def read_state(context : BinaryCodecContext) : Bytes
      numerator = context.read_slice(@numerator_width.to_u64)
      denominator = [] of UInt8
      value_bytes = 0
      loop do
        byte = context.read_byte
        index = value_bytes
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          context.corrupt!("AggregateFunction avg denominator overflows UInt64")
        end
        continuing = (byte & 0x80_u8) != 0_u8
        denominator << byte
        value_bytes += 1

        unless continuing
          if index > 0 && payload == 0_u64
            context.corrupt!("AggregateFunction avg denominator VarUInt is nonminimal")
          end
          break
        end
        if index == 9
          context.corrupt!("AggregateFunction avg denominator VarUInt is too long")
        end
      end

      bytes = Bytes.new(@numerator_width + denominator.size)
      @numerator_width.times { |index| bytes[index] = numerator[index] }
      denominator.each_with_index { |byte, index| bytes[@numerator_width + index] = byte }
      bytes
    end

    def self.numerator_width_for(input_type : BinaryDataType) : Int32
      case input_type.tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_TIME, BinaryDataType::TAG_INTERVAL
        8
      when BinaryDataType::TAG_UINT128, BinaryDataType::TAG_INT128,
           BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DATETIME64,
           BinaryDataType::TAG_DATETIME64_ZONE, BinaryDataType::TAG_TIME64
        16
      when BinaryDataType::TAG_UINT256, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_DECIMAL256
        32
      else
        raise ArgumentError.new("AggregateFunction avg input has no admitted numerator type")
      end
    end

    private def canonical_var_uint_size(bytes : Bytes, start : Int32) : Int32
      10.times do |index|
        byte = bytes[start + index]
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          raise ArgumentError.new("AggregateFunction avg denominator overflows UInt64")
        end
        continuing = (byte & 0x80_u8) != 0_u8
        unless continuing
          if index > 0 && payload == 0_u64
            raise ArgumentError.new("AggregateFunction avg denominator VarUInt is nonminimal")
          end
          return index + 1
        end
        if index == 9
          raise ArgumentError.new("AggregateFunction avg denominator VarUInt is too long")
        end
        if start + index + 1 >= bytes.size
          raise ArgumentError.new("AggregateFunction avg denominator VarUInt is truncated")
        end
      end
      raise ArgumentError.new("AggregateFunction avg denominator VarUInt is too long")
    end
  end
end
