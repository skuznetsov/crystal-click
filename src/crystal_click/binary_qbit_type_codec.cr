module CrystalClick
  # Owns QBit's descriptor-only child metadata and its canonical tag choice.
  # ClickHouse encodes the element descriptor recursively, then the nominal
  # dimension and (only for a non-default stride) the stride.
  module BinaryQBitTypeCodec
    def self.write(type : BinaryDataType, context : BinaryCodecContext, depth : Int) : Nil
      descriptor = type.qbit_type || context.unsupported!("QBit descriptor metadata is missing")
      element = type.qbit_element_descriptor
      context.preflight_children(1_u64)
      context.ensure_depth(depth + 1)
      BinaryDataTypeCodec.write_to(element, context, depth + 1)
      context.write_var_uint(descriptor.dimension)
      if descriptor.stride != descriptor.dimension
        context.write_var_uint(descriptor.stride)
      end
      nil
    end

    def self.read(tag : UInt8, context : BinaryCodecContext, depth : Int) : BinaryDataType
      context.preflight_children(1_u64)
      context.ensure_depth(depth + 1)
      element = BinaryDataTypeCodec.read_from(context, depth + 1)
      element_name = case element.tag
                     when BinaryDataType::TAG_INT8     then "Int8"
                     when BinaryDataType::TAG_BFLOAT16 then "BFloat16"
                     when BinaryDataType::TAG_FLOAT32  then "Float32"
                     when BinaryDataType::TAG_FLOAT64  then "Float64"
                     else
                       context.unsupported!("QBit element type is outside the admitted primitive profile")
                     end
      dimension = context.read_var_uint
      stride = if tag == BinaryDataType::TAG_QBIT_WITH_STRIDE
                 context.read_var_uint
               else
                 dimension
               end
      if tag == BinaryDataType::TAG_QBIT_WITH_STRIDE && stride == dimension
        context.unsupported!("QBitWithStride with the default stride is not canonical; use QBit")
      end

      qbit_type = begin
        QBitType.new(element_name, dimension, stride)
      rescue ex : ArgumentError
        message = ex.message || "invalid QBit descriptor"
        if local_materialization_limit?(message)
          context.unsupported!("QBit descriptor exceeds the local materialization profile: #{message}")
        else
          context.corrupt!("invalid QBit descriptor: #{message}")
        end
      end
      BinaryDataType.qbit(qbit_type)
    end

    private def self.local_materialization_limit?(message : String) : Bool
      message.includes?("64 MiB resource limit") ||
        message.includes?("exceeds Int32 representation")
    end
  end
end
