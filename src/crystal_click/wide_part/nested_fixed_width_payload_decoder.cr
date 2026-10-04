module CrystalClick
  class WidePart
    # Reconstructs already-validated nested fixed-width payloads. Stream marks,
    # type admission, and payload decoding remain with the caller.
    private class NestedFixedWidthPayloadDecoder
      def self.decode(
        outer_sizes : Array(UInt64),
        element_sizes : Array(UInt64),
        rows : UInt64,
        value_bytes : Bytes,
        element_width : Int32,
        type : T.class,
        label : String,
        payload_label : String,
        &decode : Int32 -> T
      ) : Array(Array(Array(T))) forall T
        values = Array(Array(Array(T))).new(rows.to_i)
        inner_offset = 0
        value_offset = 0
        outer_sizes.each do |inner_count|
          row = Array(Array(T)).new(inner_count.to_i)
          inner_count.to_i.times do
            raise CorruptPartError.new("#{label} size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
            leaf_count = element_sizes[inner_offset]
            inner = Array(T).new(leaf_count.to_i)
            leaf_count.to_i.times do
              raise CorruptPartError.new("#{label} sizes exceed selected #{payload_label} bytes") if value_offset > value_bytes.size - element_width
              inner << yield value_offset
              value_offset += element_width
            end
            row << inner
            inner_offset += 1
          end
          values << row
        end
        raise CorruptPartError.new("#{label} sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
        raise CorruptPartError.new("#{label} sizes do not consume selected #{payload_label} bytes") unless value_offset == value_bytes.size
        values
      end

      def self.decode_nullable(
        outer_sizes : Array(UInt64),
        element_sizes : Array(UInt64),
        rows : UInt64,
        value_bytes : Bytes,
        null_bytes : Bytes,
        flat_leaf_elements : UInt64,
        element_width : Int32,
        type : T.class,
        label : String,
        payload_label : String,
        &decode : Int32 -> T
      ) : Array(Array(Array(T?))) forall T
        values = Array(Array(Array(T?))).new(rows.to_i)
        inner_offset = 0
        leaf_offset = 0
        value_offset = 0
        outer_sizes.each do |inner_count|
          row = Array(Array(T?)).new(inner_count.to_i)
          inner_count.to_i.times do
            raise CorruptPartError.new("#{label} size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
            leaf_count = element_sizes[inner_offset]
            inner = Array(T?).new(leaf_count.to_i)
            leaf_count.to_i.times do
              raise CorruptPartError.new("#{label} sizes exceed selected child streams") if leaf_offset >= flat_leaf_elements
              raise CorruptPartError.new("#{label} sizes exceed selected #{payload_label} bytes") if value_offset > value_bytes.size - element_width
              if null_bytes[leaf_offset] == 1_u8
                inner << nil
              else
                inner << yield value_offset
              end
              # Every physical slot is consumed, including bytes hidden under
              # NULL. Hidden values are deliberately never decoded.
              value_offset += element_width
              leaf_offset += 1
            end
            row << inner
            inner_offset += 1
          end
          values << row
        end
        raise CorruptPartError.new("#{label} sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
        raise CorruptPartError.new("#{label} sizes do not consume selected null-map bytes") unless leaf_offset.to_u64 == flat_leaf_elements
        raise CorruptPartError.new("#{label} sizes do not consume selected #{payload_label} bytes") unless value_offset == value_bytes.size
        values
      end
    end
  end
end
