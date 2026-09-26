module CrystalClick
  # An IPv4 address stored as its network-order UInt32 value. It remains a
  # distinct type so typed IPv4 columns cannot be read as ordinary UInt32.
  struct IPv4Value
    getter network_order : UInt32

    def initialize(@network_order : UInt32)
    end

    def self.from_octets(first : UInt8, second : UInt8, third : UInt8, fourth : UInt8) : IPv4Value
      network_order = (first.to_u32 << 24) | (second.to_u32 << 16) | (third.to_u32 << 8) | fourth.to_u32
      new(network_order)
    end

    def ==(other : self) : Bool
      @network_order == other.network_order
    end

    def hash(hasher)
      @network_order.hash(hasher)
    end

    def to_s(io : IO) : Nil
      io << ((@network_order >> 24) & 0xff_u32) << '.'
      io << ((@network_order >> 16) & 0xff_u32) << '.'
      io << ((@network_order >> 8) & 0xff_u32) << '.'
      io << (@network_order & 0xff_u32)
    end
  end
end
