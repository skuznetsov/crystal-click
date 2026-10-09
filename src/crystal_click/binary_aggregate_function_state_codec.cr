module CrystalClick
  # Canonical raw state bytes for admitted non-Count AggregateFunction roots.
  # Fixed Sum states and variable Avg/Min/Max states retain their own grammars;
  # none is treated as a generic length-prefixed scalar blob.
  module BinaryAggregateFunctionStateCodec
    def self.write(type : BinaryDataType, bytes : Bytes, context : BinaryCodecContext, depth : Int = 1) : Nil
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      begin
        plan.validate_state_bytes(bytes)
      rescue ex : ArgumentError
        context.unsupported!(ex.message || "invalid AggregateFunction state width or presence")
      end
      if layout = plan.minmax_layout
        layout.validate_generic_for_write(bytes, context, depth)
      end
      context.write_slice(bytes)
    end

    def self.read(type : BinaryDataType, context : BinaryCodecContext, depth : Int = 1) : Bytes
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      if layout = plan.minmax_layout
        return layout.read_state(context, depth)
      end
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

    # The public raw-byte value constructor is one standalone operation: bound
    # the complete state frame by bytes, then validate its state grammar and
    # any Generic child body under the supplied traversal limits. This is not
    # an RSS bound or a full descriptor-tree traversal. Context reads use the
    # narrower factory below and must not repeat this traversal.
    def self.validate_owned_state_bytes(
      type : BinaryDataType,
      bytes : Bytes,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Nil
      if bytes.size.to_i64 > limits.max_bytes
        raise ArgumentError.new("AggregateFunction state exceeds the standalone byte limit")
      end
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      plan.validate_state_bytes(bytes)
      if layout = plan.minmax_layout
        layout.validate_owned_generic_body(bytes, limits)
      end
      nil
    end

    # Bulk aggregate lanes are already charged as physical bytes by their
    # enclosing operation. Validate recursive Generic bodies against the same
    # traversal budget, but never charge those bytes a second time.
    def self.validate_lane_state_for_write(
      type : BinaryDataType,
      bytes : Bytes,
      context : BinaryCodecContext,
      depth : Int,
    ) : Nil
      plan = BinaryAggregateFunctionStatePlan.for_type(type)
      begin
        plan.validate_state_bytes(bytes)
      rescue ex : ArgumentError
        context.unsupported!(ex.message || "invalid AggregateFunction state width or presence")
      end
      if layout = plan.minmax_layout
        layout.validate_generic_for_write(bytes, context, depth)
      end
      nil
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
