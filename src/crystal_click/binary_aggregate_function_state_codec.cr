module CrystalClick
  # Canonical raw state bytes for admitted non-Count AggregateFunction roots.
  # The function state is opaque to the scalar value grammar; this codec only
  # enforces the source-derived width and nullable-presence envelope.
  module BinaryAggregateFunctionStateCodec
    def self.write(type : BinaryDataType, bytes : Bytes, context : BinaryCodecContext) : Nil
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      begin
        plan.validate_state_bytes(bytes)
      rescue ex : ArgumentError
        context.unsupported!(ex.message || "invalid AggregateFunction state width or presence")
      end
      context.write_slice(bytes)
    end

    def self.read(type : BinaryDataType, context : BinaryCodecContext) : Bytes
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      if plan.nullable_argument?
        presence = context.read_byte
        case presence
        when 0_u8
          Bytes[0_u8]
        when 1_u8
          raw = context.read_slice(plan.state_width.to_u64)
          bytes = Bytes.new(raw.size + 1)
          bytes[0] = 1_u8
          raw.size.times { |index| bytes[index + 1] = raw[index] }
          bytes
        else
          context.corrupt!("AggregateFunction nullable state has an invalid presence byte")
        end
      else
        context.read_slice(plan.state_width.to_u64)
      end
    end

    # Bulk lane owner emits the same canonical state sequence without adding a
    # second framing layer.
    def self.write_lane(bytes : Bytes, &emit : UInt8 -> Nil) : Nil
      bytes.each { |byte| yield byte }
      nil
    end
  end
end
