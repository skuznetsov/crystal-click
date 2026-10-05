module CrystalClick
  # RowBinary QBit scalar framing. Values are owned by QBitValue and remain
  # exact little-endian element bytes; this codec never constructs float
  # values or physical QBit planes.
  module BinaryQBitValueCodec
    def self.write(value : QBitValue, expected : QBitType, context : BinaryCodecContext) : Nil
      unless value.type == expected
        context.unsupported!("QBit value type does not match its nominal descriptor")
      end
      context.write_var_uint(expected.dimension)
      width = expected.raw_row_bytes
      context.ensure_output_bytes(width.to_u64)
      width.times do |index|
        context.write_byte(value.raw_byte_at(index))
      end
      nil
    end

    def self.read(expected : QBitType, context : BinaryCodecContext) : QBitValue
      dimension = context.read_var_uint
      unless dimension == expected.dimension
        context.corrupt!("QBit scalar dimension does not match its descriptor")
      end
      raw = context.read_slice(expected.raw_row_bytes.to_u64)
      begin
        QBitValue.new(expected, raw)
      rescue ex : ArgumentError
        context.corrupt!("invalid QBit scalar payload: #{ex.message}")
      end
    end
  end
end
