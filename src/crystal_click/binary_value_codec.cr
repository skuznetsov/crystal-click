module CrystalClick
  # Paired scalar-value codec for BinaryDataType descriptors. The descriptor
  # envelope and known-type scalar entry points share one recursive grammar,
  # but intentionally have distinct NULL/Nothing behavior.
  module BinaryValueCodec
    def self.encode(value : BinaryValue, limits : BinaryCodecLimits = BinaryCodecLimits.default) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      encode_in_context(value, context)
    end

    # Internal bounded path for one typed envelope inside a larger operation.
    # Recursive visits share the aggregate budget, while temporary envelope
    # bytes are capped by the budget's remaining final-wire allowance and are
    # charged only when the owning block appends the framed envelope.
    def self.encode_borrowed(value : BinaryValue, budget : BinaryCodecBudget) : Bytes
      context = BinaryCodecContext.new(
        budget.limits,
        nil,
        true,
        budget,
        false,
        false,
        budget.remaining_wire_bytes
      )
      encode_in_context(value, context)
    end

    private def self.encode_in_context(value : BinaryValue, context : BinaryCodecContext) : Bytes
      BinaryDataTypeCodec.write_to(value.type, context)
      if value.type.tag == BinaryDataType::TAG_NOTHING
        unless value.is_null?
          context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
        end
        context.visit_node(1)
      else
        write_value(value, context)
      end
      context.finish_bytes
    end

    def self.decode(bytes : Bytes, limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryValue
      context = BinaryCodecContext.new(limits, bytes)
      decode_in_context(context)
    end

    # Internal exact-consumption path for a borrowed frame in a block whose
    # caller has already charged all physical input lanes to the shared budget.
    def self.decode_borrowed(bytes : Bytes, budget : BinaryCodecBudget) : BinaryValue
      context = BinaryCodecContext.new(budget.limits, bytes, false, budget, false)
      decode_in_context(context)
    end

    private def self.decode_in_context(context : BinaryCodecContext) : BinaryValue
      type = BinaryDataTypeCodec.read_from(context)
      if type.tag == BinaryDataType::TAG_NOTHING
        context.visit_node(1)
        value = BinaryValue.null(type)
      else
        value = read_value(type, context)
      end
      context.ensure_consumed
      value
    end

    # Encode/decode exactly one scalar using a supplied nominal descriptor.
    # Descriptor nodes still consume traversal budget though descriptor bytes
    # are omitted, preventing deep type equality/processing from bypassing it.
    def self.encode_value(value : BinaryValue, limits : BinaryCodecLimits = BinaryCodecLimits.default) : Bytes
      context = BinaryCodecContext.new(limits, nil, true)
      context.validate_type_tree(value.type)
      if value.type.tag == BinaryDataType::TAG_NOTHING
        context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
      end
      write_value(value, context)
      context.finish_bytes
    end

    def self.decode_value(type : BinaryDataType, bytes : Bytes, limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryValue
      context = BinaryCodecContext.new(limits, bytes)
      context.validate_type_tree(type)
      value = read_value(type, context)
      context.ensure_consumed
      value
    end

    private def self.write_value(value : BinaryValue, context : BinaryCodecContext, depth : Int = 1) : Nil
      type = value.type
      context.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_NOTHING
        context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
      when BinaryDataType::TAG_STRING
        size = value.byte_size
        context.write_var_uint(size.to_u64)
        context.ensure_output_bytes(size.to_u64)
        size.times { |index| context.write_byte(value.byte_at(index)) }
      when BinaryDataType::TAG_BOOL
        context.write_byte(BoolValueCodec.encode(value.as_bool))
      when BinaryDataType::TAG_ARRAY
        count = value.element_count
        context.preflight_children(count.to_u64) unless count == 0
        context.ensure_depth(depth + 1) unless count == 0
        context.write_var_uint(count.to_u64)
        count.times do |index|
          write_value(value.element_at(index), context, depth + 1)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = value.element_count
        context.preflight_children(count.to_u64) unless count == 0
        context.ensure_depth(depth + 1) unless count == 0
        count.times do |index|
          write_value(value.element_at(index), context, depth + 1)
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        pair_count = flat_count // 2
        context.preflight_children(flat_count.to_u64) unless flat_count == 0
        context.ensure_depth(depth + 1) unless flat_count == 0
        context.write_var_uint(pair_count.to_u64)
        flat_count.times do |index|
          write_value(value.element_at(index), context, depth + 1)
        end
      when BinaryDataType::TAG_NULLABLE
        if value.is_null?
          context.write_byte(1_u8)
        else
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          context.write_byte(0_u8)
          write_value(value.child_at(0), context, depth + 1)
        end
      else
        width = type.fixed_width || context.unsupported!("unsupported scalar DataType")
        unless value.byte_size == width
          context.unsupported!("fixed-width payload does not match its DataType")
        end
        context.ensure_output_bytes(width.to_u64)
        width.times { |index| context.write_byte(value.byte_at(index)) }
      end
    end

    private def self.read_value(type : BinaryDataType, context : BinaryCodecContext, depth : Int = 1) : BinaryValue
      context.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_NOTHING
        context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
      when BinaryDataType::TAG_STRING
        length = context.read_var_uint
        raw = context.read_slice(length)
        BinaryValue.string(String.new(raw))
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(BoolValueCodec.decode(context.read_byte))
      when BinaryDataType::TAG_ARRAY
        raw_count = context.read_var_uint
        count = context.checked_count(raw_count, "Array element count")
        context.preflight_children(raw_count) unless raw_count == 0_u64
        context.ensure_depth(depth + 1) unless raw_count == 0_u64
        child_type = type.child_at(0)
        elements = Array(BinaryValue).new(count) do
          read_value(child_type, context, depth + 1)
        end
        BinaryValue.array(type, elements)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        count = type.child_count
        context.preflight_children(count.to_u64) unless count == 0
        context.ensure_depth(depth + 1) unless count == 0
        fields = Array(BinaryValue).new(count) do |index|
          read_value(type.child_at(index), context, depth + 1)
        end
        BinaryValue.tuple(type, fields)
      when BinaryDataType::TAG_MAP
        raw_pairs = context.read_var_uint
        if raw_pairs > UInt64::MAX // 2_u64
          context.corrupt!("Map pair count overflows its flat element count")
        end
        raw_flat_count = raw_pairs * 2_u64
        flat_count = context.checked_count(raw_flat_count, "Map value count")
        context.preflight_children(raw_flat_count) unless raw_flat_count == 0_u64
        context.ensure_depth(depth + 1) unless raw_flat_count == 0_u64
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        entries = Array(BinaryValue).new(flat_count) do |index|
          read_value(index.even? ? key_type : value_type, context, depth + 1)
        end
        BinaryValue.map(type, entries)
      when BinaryDataType::TAG_NULLABLE
        flag = context.read_byte
        case flag
        when 1_u8
          BinaryValue.null(type)
        when 0_u8
          if type.child_at(0).tag == BinaryDataType::TAG_NOTHING
            context.corrupt!("Nullable(Nothing) cannot contain a non-NULL Nothing scalar")
          end
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          child = read_value(type.child_at(0), context, depth + 1)
          BinaryValue.nullable(type, child)
        else
          context.corrupt!("Nullable structural flag must be zero or one")
        end
      else
        width = type.fixed_width || context.unsupported!("unsupported scalar DataType")
        raw = context.read_slice(width.to_u64)
        BinaryValue.fixed(type, raw)
      end
    end
  end
end
