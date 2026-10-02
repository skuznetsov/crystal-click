require "../errors"
require "../variant_type_plan"

module CrystalClick
  class WidePart
    private class VariantDiscriminatorDecoder
      def self.decode(
        bytes : Bytes,
        rows : UInt64,
        mode : UInt64,
        plan : WideVariantTypePlanDescriptor,
      ) : Array(UInt8)
        offset = 0
        tags = Array(UInt8).new(rows.to_i)
        if mode == WideVariantTypePlanDescriptor::MODE_BASIC
          raise CorruptPartError.new("Variant BASIC discriminator is truncated") if bytes.size - offset < rows
          raise CorruptPartError.new("Variant BASIC discriminator has extra bytes") unless bytes.size - offset == rows
          rows.to_i.times do |index|
            tags << bytes[offset + index]
          end
          offset += rows.to_i
        else
          encoded_rows, cursor = read_var_uint(bytes, offset)
          raise CorruptPartError.new("Variant COMPACT mark row count does not match marks") unless encoded_rows == rows
          raise CorruptPartError.new("Variant COMPACT discriminator format is truncated") if cursor >= bytes.size
          format = bytes[cursor]
          cursor += 1
          case format
          when WideVariantTypePlanDescriptor::FORMAT_ROW_TAGS
            raise CorruptPartError.new("Variant COMPACT discriminator tags are truncated") if rows > (bytes.size - cursor).to_u64
            rows.to_i.times do |index|
              tags << bytes[cursor + index]
            end
            cursor += rows.to_i
          when WideVariantTypePlanDescriptor::FORMAT_UNIFORM_TAG
            raise CorruptPartError.new("Variant COMPACT uniform discriminator is truncated") if cursor >= bytes.size
            tag = bytes[cursor]
            rows.to_i.times { tags << tag }
            cursor += 1
          else
            raise CorruptPartError.new("Variant COMPACT discriminator format is unsupported")
          end
          raise CorruptPartError.new("Variant COMPACT discriminator has extra bytes") unless cursor == bytes.size
        end
        tags.each do |tag|
          raise CorruptPartError.new("Variant discriminator tag is unsupported") unless plan.valid_tag?(tag)
        end
        tags
      end

      def self.read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
        raise CorruptPartError.new("Variant COMPACT mark row count is truncated") if offset < 0
        value = 0_u64
        cursor = offset
        10.times do |index|
          raise CorruptPartError.new("Variant COMPACT mark row count is truncated") if cursor >= bytes.size
          byte = bytes[cursor]
          payload = (byte & 0x7f_u8).to_u64
          raise CorruptPartError.new("Variant COMPACT mark row count overflows") if index == 9 && payload > 1_u64
          value |= payload << (index * 7)
          cursor += 1
          unless byte & 0x80_u8 != 0
            raise CorruptPartError.new("Variant COMPACT mark row count is noncanonical") if index > 0 && payload == 0_u64
            return {value, cursor.to_i32}
          end
        end
        raise CorruptPartError.new("Variant COMPACT mark row count is too long")
      end
    end
  end
end
