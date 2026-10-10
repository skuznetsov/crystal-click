module CrystalClick
  # ClickHouse's zero-key SipHash-2-4 variant used for Object shared-data
  # bucket assignment. This is deliberately distinct from SipHash-128.
  class ClickHouseSipHash
    @v0 : UInt64
    @v1 : UInt64
    @v2 : UInt64
    @v3 : UInt64
    @total_bytes : UInt64
    @tail : UInt64
    @tail_size : Int32
    @finished : Bool
    @result : UInt64?
    @result128 : {UInt64, UInt64}?

    def initialize
      @v0 = 0x736f6d6570736575_u64
      @v1 = 0x646f72616e646f6d_u64
      @v2 = 0x6c7967656e657261_u64
      @v3 = 0x7465646279746573_u64
      @total_bytes = 0_u64
      @tail = 0_u64
      @tail_size = 0
      @finished = false
      @result = nil
      @result128 = nil
    end

    def update(bytes : Bytes) : Nil
      raise ArgumentError.new("cannot update a finalized ClickHouse SipHash") if @finished

      bytes.each do |byte|
        @tail |= byte.to_u64 << (@tail_size * 8)
        @tail_size += 1
        @total_bytes &+= 1_u64

        if @tail_size == 8
          compress_word(@tail)
          @tail = 0_u64
          @tail_size = 0
        end
      end

      nil
    end

    def finish64 : UInt64
      finalize!
      @result.not_nil!
    end

    # ClickHouse checksum summaries use its ordinary zero-key SipHash state,
    # finalized with 0xff, and retain the two finalized state words as a pair.
    # This is intentionally not the reference SipHash-128 0xee variant.
    def finish128 : {UInt64, UInt64}
      finalize!
      @result128.not_nil!
    end

    def self.hash64(bytes : Bytes) : UInt64
      hasher = new
      hasher.update(bytes)
      hasher.finish64
    end

    def self.hash128(bytes : Bytes) : {UInt64, UInt64}
      hasher = new
      hasher.update(bytes)
      hasher.finish128
    end

    private def finalize! : Nil
      return if @finished

      final_word = @tail | ((@total_bytes & 0xff_u64) << 56)
      @v3 ^= final_word
      sip_round
      sip_round
      @v0 ^= final_word

      # ClickHouse's ordinary SipHash path uses the non-reference 0xff
      # finalization marker; the reference SipHash-128 path uses 0xee.
      @v2 ^= 0xff_u64
      4.times { sip_round }

      @result128 = {@v0 ^ @v1, @v2 ^ @v3}
      @result = @result128.not_nil![0] ^ @result128.not_nil![1]
      @finished = true
      nil
    end

    private def compress_word(word : UInt64) : Nil
      @v3 ^= word
      sip_round
      sip_round
      @v0 ^= word
      nil
    end

    private def sip_round : Nil
      @v0 = @v0 &+ @v1
      @v1 = rotate_left(@v1, 13) ^ @v0
      @v0 = rotate_left(@v0, 32)
      @v2 = @v2 &+ @v3
      @v3 = rotate_left(@v3, 16) ^ @v2
      @v0 = @v0 &+ @v3
      @v3 = rotate_left(@v3, 21) ^ @v0
      @v2 = @v2 &+ @v1
      @v1 = rotate_left(@v1, 17) ^ @v2
      @v2 = rotate_left(@v2, 32)
      nil
    end

    private def rotate_left(value : UInt64, count : Int) : UInt64
      (value << count) | (value >> (64 - count))
    end
  end
end
