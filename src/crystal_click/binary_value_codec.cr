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
    # bytes are capped by the remaining final-wire allowance less the owner's
    # pending frames and framing reserve. They are charged only when the owner
    # appends the final framed envelope, never twice for temporary output.
    def self.encode_borrowed(value : BinaryValue, budget : BinaryCodecBudget, reserved_wire_bytes : UInt64 = 0_u64) : Bytes
      unless budget.writing?
        raise ArgumentError.new("binary borrowed encoder requires a write-direction budget")
      end
      budget.ensure_wire_bytes(reserved_wire_bytes)
      context = BinaryCodecContext.new(
        budget.limits,
        nil,
        true,
        budget,
        false,
        false,
        budget.remaining_wire_bytes - reserved_wire_bytes
      )
      encode_in_context(value, context, allow_dynamic: false, allow_low_cardinality: false)
    end

    private def self.encode_in_context(
      value : BinaryValue,
      context : BinaryCodecContext,
      allow_dynamic : Bool = true,
      allow_low_cardinality : Bool = true,
    ) : Bytes
      reject_dynamic_type!(value.type, context) unless allow_dynamic
      reject_borrowed_type!(value.type, context) unless allow_low_cardinality
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
      decode_in_context(context, allow_dynamic: false, allow_low_cardinality: false)
    end

    # Internal Dynamic bulk envelope path. The enclosing lane owner charges
    # these returned bytes when it appends them; this temporary context shares
    # recursive visits with that owner without charging the same wire bytes a
    # second time. `reserved_wire_bytes` keeps pending framing/lane bytes out
    # of this envelope's output bound.
    def self.encode_dynamic_bulk_child(
      value : BinaryValue,
      budget : BinaryCodecBudget,
      depth : Int32,
      reserved_wire_bytes : UInt64 = 0_u64,
      allow_json : Bool = false,
      allow_aggregate_function : Bool = false,
      allow_recursive_qbit : Bool = false,
      allow_qbit_variants : Bool = true,
    ) : Bytes
      unless budget.writing?
        raise ArgumentError.new("Dynamic bulk child encoder requires a write-direction budget")
      end
      if value.type.contains_custom_geo?
        raise UnsupportedFormatError.new("Custom Geo is not admitted as a Dynamic shared actual type")
      end
      if allow_recursive_qbit && value.type.contains_qbit? && value.type.tag != BinaryDataType::TAG_QBIT
        # The recursive admission predicates intentionally operate on the
        # descriptor tree. Prove its depth, node, and edge bounds against the
        # caller's shared operation budget before those predicates walk it.
        type_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
        type_context.validate_type_tree(value.type, depth)
      end
      unless dynamic_aggregate_actual_allowed?(value.type, allow_aggregate_function)
        raise UnsupportedFormatError.new("AggregateFunction is not admitted as this Dynamic shared actual type")
      end
      if value.type.contains_qbit? && value.type.tag != BinaryDataType::TAG_QBIT
        unless allow_recursive_qbit && BinaryDynamicQBitAdmission.admitted_actual_type?(
                 value.type,
                 allow_qbit_variants: allow_qbit_variants,
               )
          raise UnsupportedFormatError.new("recursive QBit is not admitted as this Dynamic shared actual type")
        end
      end
      if value.type.contains_json? && !allow_json
        raise UnsupportedFormatError.new("JSON is not admitted as a Dynamic actual type")
      end
      budget.ensure_wire_bytes(reserved_wire_bytes)
      context = BinaryCodecContext.new(
        budget.limits,
        nil,
        true,
        budget,
        false,
        false,
        budget.remaining_wire_bytes - reserved_wire_bytes,
        allow_aggregate_function,
      )
      BinaryDataTypeCodec.write_to(value.type, context, depth)
      if value.type.tag == BinaryDataType::TAG_NOTHING
        unless value.is_null?
          context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
        end
        context.visit_node(depth)
      else
        write_value(value, context, depth)
      end
      context.finish_bytes
    end

    # The physical lane owner has already charged the complete input lane to
    # the shared read budget. Decode one exact descriptor/value envelope at
    # its containing occurrence depth; a Nothing descriptor is the
    # descriptor-only NULL sentinel and still consumes one scalar node visit.
    def self.decode_dynamic_bulk_child(
      bytes : Bytes,
      budget : BinaryCodecBudget,
      depth : Int32,
      charge_parent_value_edge : Bool = false,
      allow_json : Bool = false,
      allow_aggregate_function : Bool = false,
      allow_recursive_qbit : Bool = false,
      allow_qbit_variants : Bool = true,
    ) : Tuple(BinaryDataType, BinaryValue?)
      context = BinaryCodecContext.new(
        budget.limits,
        bytes,
        false,
        budget,
        false,
        true,
        nil,
        allow_aggregate_function,
      )
      type = BinaryDataTypeCodec.read_from(context, depth)
      if type.contains_custom_geo?
        context.unsupported!("Custom Geo is not admitted as a Dynamic shared actual type")
      end
      unless dynamic_aggregate_actual_allowed?(type, allow_aggregate_function)
        context.unsupported!("AggregateFunction is not admitted as this Dynamic shared actual type")
      end
      if type.contains_qbit? && type.tag != BinaryDataType::TAG_QBIT
        unless allow_recursive_qbit && BinaryDynamicQBitAdmission.admitted_actual_type?(
                 type,
                 allow_qbit_variants: allow_qbit_variants,
               )
          context.unsupported!("recursive QBit is not admitted as this Dynamic shared actual type")
        end
      end
      if type.contains_json? && !allow_json
        context.unsupported!("JSON is not admitted as a Dynamic actual type")
      end
      value : BinaryValue? = if type.tag == BinaryDataType::TAG_NOTHING
        context.visit_node(depth)
        nil
      else
        context.preflight_children(1_u64) if charge_parent_value_edge
        read_value(type, context, depth)
      end
      context.ensure_consumed
      {type, value}
    end

    private def self.decode_in_context(
      context : BinaryCodecContext,
      allow_dynamic : Bool = true,
      allow_low_cardinality : Bool = true,
    ) : BinaryValue
      type = BinaryDataTypeCodec.read_from(context)
      reject_dynamic_type!(type, context) unless allow_dynamic
      reject_borrowed_type!(type, context) unless allow_low_cardinality
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
      if value.type.geometry_storage_variant?
        raise UnsupportedFormatError.new("Geometry's fixed-order storage Variant cannot be encoded independently")
      end
      context = BinaryCodecContext.new(limits, nil, true)
      context.validate_type_tree(value.type)
      if value.type.tag == BinaryDataType::TAG_NOTHING
        context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
      end
      write_value(value, context)
      context.finish_bytes
    end

    def self.decode_value(type : BinaryDataType, bytes : Bytes, limits : BinaryCodecLimits = BinaryCodecLimits.default) : BinaryValue
      if type.geometry_storage_variant?
        raise UnsupportedFormatError.new("Geometry's fixed-order storage Variant cannot be decoded independently")
      end
      context = BinaryCodecContext.new(limits, bytes)
      context.validate_type_tree(type)
      value = read_value(type, context)
      context.ensure_consumed
      value
    end

    # Consume one already-described generic min/max argument with the ordinary
    # recursive value visitor and return an owned copy of its exact wire span.
    # This narrow adapter lets the enclosing aggregate-state codec retain the
    # child bytes without resetting the operation budget or parsing twice.
    def self.consume_minmax_argument(type : BinaryDataType, context : BinaryCodecContext, depth : Int) : Bytes
      start_offset = context.input_offset
      read_value(type, context, depth)
      borrowed = context.consumed_input_slice(start_offset)
      Bytes.new(borrowed.size) { |index| borrowed[index] }
    rescue ex : ArgumentError
      context.corrupt!("invalid generic AggregateFunction min/max argument value: #{ex.message}")
    end

    private def self.write_value(value : BinaryValue, context : BinaryCodecContext, depth : Int = 1) : Nil
      type = value.type
      context.visit_node(depth)

      case type.tag
      when BinaryDataType::TAG_NOTHING
        context.unsupported!("Nothing has no ordinary non-NULL scalar representation")
      when BinaryDataType::TAG_JSON
        BinaryJsonValueCodec.write(value.json_row, context, depth) do |child, child_depth|
          write_value(child, context, child_depth)
        end
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          BinaryAggregateCountStateCodec.write(value.count_state, context)
        else
          BinaryAggregateFunctionStateCodec.write(type, value.aggregate_function_state_bytes, context, depth)
        end
      when BinaryDataType::TAG_CUSTOM
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        write_value(value.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_STRING
        size = value.byte_size
        context.write_var_uint(size.to_u64)
        context.ensure_output_bytes(size.to_u64)
        size.times { |index| context.write_byte(value.byte_at(index)) }
      when BinaryDataType::TAG_BOOL
        context.write_byte(BoolValueCodec.encode(value.as_bool))
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || context.unsupported!("QBit descriptor metadata is missing")
        BinaryQBitValueCodec.write(value.qbit_value, qbit_type, context)
      when BinaryDataType::TAG_ARRAY
        count = value.element_count
        context.preflight_children(count.to_u64) unless count == 0
        context.ensure_depth(depth + 1) unless count == 0
        context.write_var_uint(count.to_u64)
        count.times do |index|
          write_value(value.element_at(index), context, depth + 1)
        end
      when BinaryDataType::TAG_NESTED
        count = value.element_count
        tuple_type = BinaryNestedType.tuple_for(type)
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
      when BinaryDataType::TAG_LOW_CARDINALITY
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        write_value(value.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        write_value(value.child_at(0), context, depth + 1)
      when BinaryDataType::TAG_VARIANT
        if value.is_null?
          context.write_byte(0xff_u8)
        else
          index = value.variant_index? || context.unsupported!("non-NULL Variant value has no arm discriminator")
          child = value.variant_child? || context.unsupported!("non-NULL Variant value has no selected child")
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          context.write_byte(index)
          write_value(child, context, depth + 1)
        end
      when BinaryDataType::TAG_DYNAMIC
        if value.element_count > 0 &&
           !dynamic_aggregate_actual_allowed?(value.child_at(0).type, context.allow_dynamic_aggregate_function)
          context.unsupported!("AggregateFunction is not admitted as a Dynamic actual type")
        end
        if value.element_count > 0 && value.child_at(0).type.contains_custom_geo?
          context.unsupported!("Custom Geo is not admitted as a Dynamic actual type")
        end
        BinaryDynamicEnvelope.write(value, context, depth) do |selected, selected_depth|
          write_value(selected, context, selected_depth)
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
      when BinaryDataType::TAG_JSON
        row = BinaryJsonValueCodec.read(type, context, depth) do |child_type, child_depth|
          read_value(child_type, context, child_depth)
        end
        BinaryValue.json(type, row)
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        if type.aggregate_count_type
          BinaryValue.aggregate_count_state(type, BinaryAggregateCountStateCodec.read(context))
        else
          BinaryValue.aggregate_function_state_from_context(type, context, depth)
        end
      when BinaryDataType::TAG_CUSTOM
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        body = read_value(type.child_at(0), context, depth + 1)
        begin
          BinaryValue.custom(type, body)
        rescue ex : ArgumentError
          context.corrupt!("invalid Custom Geo storage value: #{ex.message}")
        end
      when BinaryDataType::TAG_STRING
        length = context.read_var_uint
        raw = context.read_slice(length)
        BinaryValue.string(String.new(raw))
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(BoolValueCodec.decode(context.read_byte))
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || context.unsupported!("QBit descriptor metadata is missing")
        BinaryValue.qbit(type, BinaryQBitValueCodec.read(qbit_type, context))
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
      when BinaryDataType::TAG_NESTED
        raw_count = context.read_var_uint
        count = context.checked_count(raw_count, "Nested element count")
        context.preflight_children(raw_count) unless raw_count == 0_u64
        context.ensure_depth(depth + 1) unless raw_count == 0_u64
        tuple_type = BinaryNestedType.tuple_for(type)
        elements = Array(BinaryValue).new(count) do
          read_value(tuple_type, context, depth + 1)
        end
        BinaryValue.nested(type, elements)
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
      when BinaryDataType::TAG_LOW_CARDINALITY
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        child = read_value(type.child_at(0), context, depth + 1)
        BinaryValue.low_cardinality(type, child)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        context.preflight_children(1_u64)
        context.ensure_depth(depth + 1)
        child = read_value(type.child_at(0), context, depth + 1)
        BinaryValue.simple_aggregate(type, child)
      when BinaryDataType::TAG_VARIANT
        index = context.read_byte
        if index == 0xff_u8
          BinaryValue.variant_null(type)
        elsif index.to_u64 >= type.child_count.to_u64
          context.corrupt!("Variant discriminator is outside its declared arm roster")
        else
          context.preflight_children(1_u64)
          context.ensure_depth(depth + 1)
          child = read_value(type.child_at(index.to_i), context, depth + 1)
          begin
            BinaryValue.variant(type, index.to_i, child)
          rescue ex : ArgumentError
            context.corrupt!("invalid selected Variant value: #{ex.message}")
          end
        end
      when BinaryDataType::TAG_DYNAMIC
        BinaryDynamicEnvelope.read(type, context, depth) do |selected_type, selected_depth|
          if selected_type.contains_custom_geo?
            context.unsupported!("Custom Geo is not admitted as a Dynamic actual type")
          end
          unless dynamic_aggregate_actual_allowed?(selected_type, context.allow_dynamic_aggregate_function)
            context.unsupported!("AggregateFunction is not admitted as a Dynamic actual type")
          end
          read_value(selected_type, context, selected_depth)
        end
      else
        width = type.fixed_width || context.unsupported!("unsupported scalar DataType")
        raw = context.read_slice(width.to_u64)
        BinaryValue.fixed(type, raw)
      end
    end

    private def self.reject_dynamic_type!(type : BinaryDataType, context : BinaryCodecContext) : Nil
      if type.contains_dynamic?
        context.unsupported!("Dynamic values are outside the admitted RowBinary value profile")
      end
    end

    private def self.dynamic_aggregate_actual_allowed?(type : BinaryDataType, allow_aggregate_function : Bool) : Bool
      return true unless type.contains_aggregate_function?
      allow_aggregate_function && BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(type)
    end

    private def self.reject_borrowed_type!(type : BinaryDataType, context : BinaryCodecContext) : Nil
      if type.contains_json?
        context.unsupported!("JSON is outside the borrowed persisted-envelope profile")
      end
      if type.contains_variant?
        context.unsupported!("Variant is outside the borrowed persisted-envelope profile")
      end
      if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
        context.unsupported!("LowCardinality is outside the borrowed persisted-envelope profile")
      end
      if type.contains_aggregate_function?
        context.unsupported!("AggregateFunction is outside the borrowed persisted-envelope profile")
      end
      if type.contains_qbit?
        context.unsupported!("QBit is outside the borrowed persisted-envelope profile")
      end
    end
  end
end
