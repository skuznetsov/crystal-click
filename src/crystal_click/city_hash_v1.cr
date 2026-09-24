# Copyright (c) 2011 Google, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

module CrystalClick
  # CityHash v1.0.2 is used by ClickHouse for compressed-frame and part-file
  # checksums. Results are returned as {low64, high64}, matching ClickHouse's
  # little-endian UInt128 serialization order. The algorithm follows the
  # permissively licensed contrib/cityhash102 implementation bundled with
  # ClickHouse.
  module CityHashV1
    K0 = 0xc3a5c85c97cb3127_u64
    K1 = 0xb492b66fbe98f273_u64
    K2 = 0x9ae16a3b2f90404f_u64
    K3 = 0xc949d7c7509e6557_u64

    # Incremental equivalent of ClickHouse IHashingBuffer with its default
    # 2048-byte block size.
    class FileHasher
      BLOCK_SIZE = 2048

      @pending : Bytes
      @pending_size : Int32
      @state_low : UInt64
      @state_high : UInt64
      @finished : Bool

      def initialize
        @pending = Bytes.new(BLOCK_SIZE)
        @pending_size = 0
        @state_low = 0_u64
        @state_high = 0_u64
        @finished = false
      end

      def update(bytes : Bytes) : Nil
        raise ArgumentError.new("cannot update a finalized CityHash file hash") if @finished
        offset = 0
        while offset < bytes.size
          copied = {BLOCK_SIZE - @pending_size, bytes.size - offset}.min
          bytes[offset, copied].copy_to(@pending[@pending_size, copied])
          @pending_size += copied
          offset += copied
          if @pending_size == BLOCK_SIZE
            @state_low, @state_high = CityHashV1.hash128_with_seed(@pending, @state_low, @state_high)
            @pending_size = 0
          end
        end
        nil
      end

      def finish : {UInt64, UInt64}
        unless @finished
          if @pending_size > 0
            @state_low, @state_high = CityHashV1.hash128_with_seed(@pending[0, @pending_size], @state_low, @state_high)
            @pending_size = 0
          end
          @finished = true
        end
        {@state_low, @state_high}
      end
    end

    def self.hash128(bytes : Bytes) : {UInt64, UInt64}
      length = bytes.size
      if length >= 16
        hash128_with_seed_from(
          bytes,
          16,
          length - 16,
          fetch64(bytes, 0) ^ K3,
          fetch64(bytes, 8)
        )
      elsif length >= 8
        hash128_with_seed_from(
          bytes,
          0,
          0,
          fetch64(bytes, 0) ^ (length.to_u64 &* K0),
          fetch64(bytes, length - 8) ^ K1
        )
      else
        hash128_with_seed_from(bytes, 0, length, K0, K1)
      end
    end

    def self.hash128_with_seed(bytes : Bytes, seed_low : UInt64, seed_high : UInt64) : {UInt64, UInt64}
      hash128_with_seed_from(bytes, 0, bytes.size, seed_low, seed_high)
    end

    # Match ClickHouse HashingWriteBuffer's 2048-byte block chaining. The final
    # partial block is hashed with the accumulated state; an empty input keeps
    # the all-zero initial state.
    def self.file_hash(bytes : Bytes) : {UInt64, UInt64}
      hasher = FileHasher.new
      hasher.update(bytes)
      hasher.finish
    end

    private def self.hash128_with_seed_from(
      bytes : Bytes,
      offset : Int,
      length : Int,
      seed_low : UInt64,
      seed_high : UInt64,
    ) : {UInt64, UInt64}
      return city_murmur(bytes, offset, length, seed_low, seed_high) if length < 128

      x = seed_low
      y = seed_high
      z = length.to_u64 &* K1
      v_first = rotate(y ^ K1, 49) &* K1 &+ fetch64(bytes, offset)
      v_second = rotate(v_first, 42) &* K1 &+ fetch64(bytes, offset + 8)
      w_first = rotate(y &+ z, 35) &* K1 &+ x
      w_second = rotate(x &+ fetch64(bytes, offset + 88), 53) &* K1

      remaining = length
      cursor = offset
      loop do
        x = rotate(x &+ y &+ v_first &+ fetch64(bytes, cursor + 16), 37) &* K1
        y = rotate(y &+ v_second &+ fetch64(bytes, cursor + 48), 42) &* K1
        x ^= w_second
        y ^= v_first
        z = rotate(z ^ w_first, 33)
        v_first, v_second = weak_hash_len32_with_seeds(bytes, cursor, v_second &* K1, x &+ w_first)
        w_first, w_second = weak_hash_len32_with_seeds(bytes, cursor + 32, z &+ w_second, y)
        z, x = x, z
        cursor += 64

        x = rotate(x &+ y &+ v_first &+ fetch64(bytes, cursor + 16), 37) &* K1
        y = rotate(y &+ v_second &+ fetch64(bytes, cursor + 48), 42) &* K1
        x ^= w_second
        y ^= v_first
        z = rotate(z ^ w_first, 33)
        v_first, v_second = weak_hash_len32_with_seeds(bytes, cursor, v_second &* K1, x &+ w_first)
        w_first, w_second = weak_hash_len32_with_seeds(bytes, cursor + 32, z &+ w_second, y)
        z, x = x, z
        cursor += 64
        remaining -= 128
        break if remaining < 128
      end

      y = y &+ rotate(w_first, 37) &* K0 &+ z
      x = x &+ rotate(v_first &+ z, 49) &* K0
      tail_done = 0
      while tail_done < remaining
        tail_done += 32
        y = rotate(y &- x, 42) &* K0 &+ v_second
        w_first = w_first &+ fetch64(bytes, cursor + remaining - tail_done + 16)
        x = rotate(x, 49) &* K0 &+ w_first
        w_first = w_first &+ v_first
        v_first, v_second = weak_hash_len32_with_seeds(bytes, cursor + remaining - tail_done, v_first, v_second)
      end

      x = hash_len16(x, v_first)
      y = hash_len16(y, w_first)
      {hash_len16(x &+ v_second, w_second) &+ y, hash_len16(x &+ w_second, y &+ v_second)}
    end

    private def self.city_murmur(
      bytes : Bytes,
      offset : Int,
      length : Int,
      seed_low : UInt64,
      seed_high : UInt64,
    ) : {UInt64, UInt64}
      a = seed_low
      b = seed_high
      c = 0_u64
      d = 0_u64
      remaining = length - 16
      if remaining <= 0
        a = shift_mix(a &* K1) &* K1
        c = b &* K1 &+ hash_len0_to16(bytes, offset, length)
        d = shift_mix(a &+ (length >= 8 ? fetch64(bytes, offset) : c))
      else
        c = hash_len16(fetch64(bytes, offset + length - 8) &+ K1, a)
        d = hash_len16(b &+ length.to_u64, c &+ fetch64(bytes, offset + length - 16))
        a = a &+ d
        cursor = offset
        while remaining > 0
          a ^= shift_mix(fetch64(bytes, cursor) &* K1) &* K1
          a = a &* K1
          b ^= a
          c ^= shift_mix(fetch64(bytes, cursor + 8) &* K1) &* K1
          c = c &* K1
          d ^= c
          cursor += 16
          remaining -= 16
        end
      end
      a = hash_len16(a, c)
      b = hash_len16(d, b)
      {a ^ b, hash_len16(b, a)}
    end

    private def self.hash_len0_to16(bytes : Bytes, offset : Int, length : Int) : UInt64
      if length > 8
        a = fetch64(bytes, offset)
        b = fetch64(bytes, offset + length - 8)
        hash_len16(a, rotate(b &+ length.to_u64, length)) ^ b
      elsif length >= 4
        a = fetch32(bytes, offset).to_u64
        b = fetch32(bytes, offset + length - 4).to_u64
        hash_len16(length.to_u64 &+ (a << 3), b)
      elsif length > 0
        a = bytes[offset].to_u64
        b = bytes[offset + (length >> 1)].to_u64
        c = bytes[offset + length - 1].to_u64
        y = a | (b << 8)
        z = length.to_u64 &+ (c << 2)
        shift_mix(y &* K2 ^ z &* K3) &* K2
      else
        K2
      end
    end

    private def self.hash_len16(u : UInt64, v : UInt64) : UInt64
      a = (u ^ v) &* 0x9ddfea08eb382d69_u64
      a ^= a >> 47
      b = (v ^ a) &* 0x9ddfea08eb382d69_u64
      b ^= b >> 47
      b &* 0x9ddfea08eb382d69_u64
    end

    private def self.weak_hash_len32_with_seeds(
      bytes : Bytes,
      offset : Int,
      a : UInt64,
      b : UInt64,
    ) : {UInt64, UInt64}
      w = fetch64(bytes, offset)
      x = fetch64(bytes, offset + 8)
      y = fetch64(bytes, offset + 16)
      z = fetch64(bytes, offset + 24)
      a = a &+ w
      b = rotate(b &+ a &+ z, 21)
      c = a
      a = a &+ x &+ y
      b = b &+ rotate(a, 44)
      {a &+ z, b &+ c}
    end

    private def self.rotate(value : UInt64, shift : Int) : UInt64
      shift == 0 ? value : (value >> shift) | (value << (64 - shift))
    end

    private def self.shift_mix(value : UInt64) : UInt64
      value ^ (value >> 47)
    end

    private def self.fetch64(bytes : Bytes, offset : Int) : UInt64
      value = 0_u64
      8.times do |index|
        value |= bytes[offset + index].to_u64 << (index * 8)
      end
      value
    end

    private def self.fetch32(bytes : Bytes, offset : Int) : UInt32
      value = 0_u32
      4.times do |index|
        value |= bytes[offset + index].to_u32 << (index * 8)
      end
      value
    end
  end
end
