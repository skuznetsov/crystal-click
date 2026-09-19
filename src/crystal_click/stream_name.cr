module CrystalClick
  module StreamName
    def self.hash(name : String) : String
      v0 = 0x736f6d6570736575_u64
      v1 = 0x646f72616e646f6d_u64
      v2 = 0x6c7967656e657261_u64
      v3 = 0x7465646279746573_u64
      bytes = name.to_slice
      index = 0

      while index + 8 <= bytes.size
        word = read_word(bytes, index)
        v3 ^= word
        2.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }
        v0 ^= word
        index += 8
      end

      word = bytes.size.to_u64 << 56
      remaining = bytes.size - index
      remaining.times do |offset|
        word |= bytes[index + offset].to_u64 << (offset * 8)
      end

      v3 ^= word
      2.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }
      v0 ^= word
      v2 ^= 0xff_u64
      4.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }

      hex(v2 ^ v3) + hex(v0 ^ v1)
    end

    private def self.read_word(bytes : Bytes, index : Int) : UInt64
      word = 0_u64
      8.times do |offset|
        word |= bytes[index + offset].to_u64 << (offset * 8)
      end
      word
    end

    private def self.sip_round(v0 : UInt64, v1 : UInt64, v2 : UInt64, v3 : UInt64) : {UInt64, UInt64, UInt64, UInt64}
      a = v0 &+ v1
      b = rotate_left(v1, 13) ^ a
      a = rotate_left(a, 32)
      c = v2 &+ v3
      d = rotate_left(v3, 16) ^ c
      a = a &+ d
      d = rotate_left(d, 21) ^ a
      c = c &+ b
      b = rotate_left(b, 17) ^ c
      c = rotate_left(c, 32)
      {a, b, c, d}
    end

    private def self.rotate_left(value : UInt64, amount : Int32) : UInt64
      (value << amount) | (value >> (64 - amount))
    end

    private def self.hex(value : UInt64) : String
      value.to_s(16).rjust(16, '0')
    end
  end
end
