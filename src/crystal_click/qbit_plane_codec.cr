module CrystalClick
  # Bit-exact owner for QBit's group-major, MSB-first plane layout.
  module QBitPlaneCodec
    def self.encode_plane_row(value : QBitValue, plane_index : Int32, destination : Bytes, offset : Int32 = 0) : Nil
      type = value.type
      validate_plane_buffer!(type, plane_index, destination, offset)
      width = type.plane_width
      width.times { |byte| destination[offset + byte] = 0_u8 }

      group = plane_index // type.element_bits
      plane_in_group = plane_index % type.element_bits
      source_bit = type.element_bits - 1 - plane_in_group
      source_byte = source_bit // 8
      source_mask = (1_u8 << (source_bit % 8)).to_u8
      group_start = group.to_u64 * type.stride
      local = 0_u64
      while local < type.stride
        dimension = group_start + local
        break if dimension >= type.dimension
        raw_offset = (dimension * type.element_width.to_u64 + source_byte.to_u64).to_i32
        if (value.raw_byte_at(raw_offset) & source_mask) != 0_u8
          plane_byte = (type.plane_width.to_u64 - 1_u64 - (local // 8_u64)).to_i32
          bit = (local % 8_u64).to_i
          destination[offset + plane_byte] |= (1_u8 << bit).to_u8
        end
        local += 1_u64
      end
      nil
    end

    def self.encode_zero_plane_row(type : QBitType, plane_index : Int32, destination : Bytes, offset : Int32 = 0) : Nil
      validate_plane_buffer!(type, plane_index, destination, offset)
      type.plane_width.times { |byte| destination[offset + byte] = 0_u8 }
      nil
    end

    # Reconstruct one exact raw row from a byte getter. Getter order is
    # (plane index, reversed plane-byte index) and permits streaming readers to
    # hold bounded per-stream buffers without building a plane matrix.
    def self.decode_row(type : QBitType, &plane_byte : Int32, Int32 -> UInt8) : QBitValue
      raw = Bytes.new(type.raw_row_bytes, 0_u8)
      plane_index = 0
      while plane_index < type.plane_count
        group = plane_index // type.element_bits
        plane_in_group = plane_index % type.element_bits
        source_bit = type.element_bits - 1 - plane_in_group
        source_byte = source_bit // 8
        group_start = group.to_u64 * type.stride
        byte_index = 0
        while byte_index < type.plane_width
          encoded = yield plane_index, byte_index
          local_byte = type.plane_width - 1 - byte_index
          8.times do |bit_in_byte|
            local = local_byte.to_u64 * 8_u64 + bit_in_byte.to_u64
            dimension = group_start + local
            set = (encoded & (1_u8 << bit_in_byte)) != 0_u8
            if dimension >= type.dimension
              # ClickHouse's inverse transposition ignores dimensions beyond
              # the declared vector width. The writer emits canonical zero
              # padding, but the reader does not invent a stricter rejection.
              next
            end
            if set
              raw_offset = (dimension * type.element_width.to_u64 + source_byte.to_u64).to_i32
              raw[raw_offset] |= (1_u8 << (source_bit % 8)).to_u8
            end
          end
          byte_index += 1
        end
        plane_index += 1
      end
      QBitValue.new(type, raw)
    end

    private def self.validate_plane_buffer!(type : QBitType, plane_index : Int32, destination : Bytes, offset : Int32) : Nil
      raise ArgumentError.new("QBit plane index is outside descriptor") if plane_index < 0 || plane_index >= type.plane_count
      raise IndexError.new("QBit plane destination is too small") if offset < 0 || offset > destination.size - type.plane_width
      nil
    end
  end
end
