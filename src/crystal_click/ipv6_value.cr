module CrystalClick
  # A ClickHouse IPv6 value backed by its two network-order UInt64 halves.
  # This is deliberately distinct from UUIDValue and numeric UInt128 values.
  struct IPv6Value
    getter high : UInt64
    getter low : UInt64

    def initialize(@high : UInt64, @low : UInt64)
    end

    def self.from_hextets(
      h0 : UInt16,
      h1 : UInt16,
      h2 : UInt16,
      h3 : UInt16,
      h4 : UInt16,
      h5 : UInt16,
      h6 : UInt16,
      h7 : UInt16,
    ) : IPv6Value
      high = (h0.to_u64 << 48) | (h1.to_u64 << 32) | (h2.to_u64 << 16) | h3.to_u64
      low = (h4.to_u64 << 48) | (h5.to_u64 << 32) | (h6.to_u64 << 16) | h7.to_u64
      new(high, low)
    end

    def ==(other : self) : Bool
      @high == other.high && @low == other.low
    end

    def hash(hasher)
      @high.hash(hasher)
      @low.hash(hasher)
    end

    def to_s(io : IO) : Nil
      if @high == 0_u64 && @low == 0_u64
        io << "::"
        return
      end

      # Match ClickHouse's IPv4-compatible boundary: lower 32-bit values whose
      # upper 16 bits are zero stay in hextet form; larger values use dotted
      # notation. The unspecified and loopback forms naturally stay `::`/`::1`.
      if @high == 0_u64 && (@low >> 32) == 0_u64 && (@low & 0xffff_0000_u64) != 0_u64
        io << "::"
        write_ipv4_tail(io)
        return
      end

      # IPv4-mapped addresses have exactly 80 zero bits followed by 16 one bits.
      if @high == 0_u64 && (@low >> 32) == 0x0000_ffff_u64
        io << "::ffff:"
        write_ipv4_tail(io)
        return
      end

      hextets = StaticArray(UInt16, 8).new do |index|
        if index < 4
          ((@high >> ((3 - index) * 16)) & 0xffff_u64).to_u16
        else
          ((@low >> ((7 - index) * 16)) & 0xffff_u64).to_u16
        end
      end

      best_start = -1
      best_length = 0
      index = 0
      while index < hextets.size
        unless hextets[index] == 0_u16
          index += 1
          next
        end

        run_start = index
        index += 1
        while index < hextets.size && hextets[index] == 0_u16
          index += 1
        end
        run_length = index - run_start
        if run_length >= 2 && run_length > best_length
          best_start = run_start
          best_length = run_length
        end
      end

      index = 0
      while index < hextets.size
        if index == best_start
          io << "::"
          index += best_length
          next
        end

        io << ':' unless index == 0 || index == best_start + best_length
        io << hextets[index].to_s(16)
        index += 1
      end
    end

    private def write_ipv4_tail(io : IO) : Nil
      first = ((@low >> 24) & 0xff_u64).to_u16
      second = ((@low >> 16) & 0xff_u64).to_u16
      third = ((@low >> 8) & 0xff_u64).to_u16
      fourth = (@low & 0xff_u64).to_u16
      io << first << '.' << second << '.' << third << '.' << fourth
    end
  end
end
