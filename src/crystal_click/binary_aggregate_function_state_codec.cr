module CrystalClick
  # Canonical raw state bytes for admitted non-Count AggregateFunction roots.
  # Fixed Sum states and variable Avg states retain their own grammars; neither
  # is treated as a generic length-prefixed scalar blob.
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
          prepend_presence(read_inner_state(plan, context))
        else
          context.corrupt!("AggregateFunction nullable state has an invalid presence byte")
        end
      else
        read_inner_state(plan, context)
      end
    end

    private def self.read_inner_state(plan : BinaryAggregateFunctionStatePlan, context : BinaryCodecContext) : Bytes
      if layout = plan.avg_layout
        layout.read_state(context)
      else
        context.read_slice(plan.state_width.to_u64)
      end
    end

    private def self.prepend_presence(raw : Bytes) : Bytes
      bytes = Bytes.new(raw.size + 1)
      bytes[0] = 1_u8
      raw.size.times { |index| bytes[index + 1] = raw[index] }
      bytes
    end

    # Bulk lane owner emits the same canonical state sequence without adding a
    # second framing layer.
    def self.write_lane(bytes : Bytes, &emit : UInt8 -> Nil) : Nil
      bytes.each { |byte| yield byte }
      nil
    end
  end
end
