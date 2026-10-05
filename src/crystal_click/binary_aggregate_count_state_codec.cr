module CrystalClick
  # Wire owner for the admitted count state. ClickHouse serializes count as a
  # VarUInt even though the owned in-memory BinaryValue payload uses UInt64 LE.
  # The shared context supplies minimality, UInt64 overflow, and byte budgets.
  module BinaryAggregateCountStateCodec
    def self.write(count : UInt64, context : BinaryCodecContext) : Nil
      context.write_var_uint(count)
    end

    def self.read(context : BinaryCodecContext) : UInt64
      context.read_var_uint
    end

    # Emit the canonical state into an ordinary bulk lane. The callback
    # remains owned by that lane writer so shared wire bytes are charged once.
    def self.write_lane(count : UInt64, &emit : UInt8 -> Nil) : Nil
      remaining = count
      loop do
        payload = (remaining & 0x7f_u64).to_u8
        remaining >>= 7
        yield(remaining == 0_u64 ? payload : payload | 0x80_u8)
        break if remaining == 0_u64
      end
      nil
    end

    def self.encoded_size(count : UInt64) : UInt64
      remaining = count
      size = 1_u64
      while remaining >= 128_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end
  end
end
