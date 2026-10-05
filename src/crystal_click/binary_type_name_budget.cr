module CrystalClick
  # Bounds the recursive SQL display-name work performed by BinaryDataType#name.
  # The returned sizes include a conservative bound for temporary child and
  # formatted-field strings, so callers can reject oversized names first.
  class BinaryTypeNameBudget
    alias Bounds = Tuple(UInt64, UInt64)

    def self.measure(type : BinaryDataType, budget : BinaryCodecBudget, depth : Int = 1) : Bounds
      budget.visit_node(depth)
      child_count = type.child_count.to_u64
      budget.preflight_children(child_count) if child_count > 0_u64
      aggregate_count_argument_bounds : Bounds? = nil
      if type.tag == BinaryDataType::TAG_AGGREGATE_COUNT
        if argument = type.aggregate_count_argument_type
          # Count's argument is descriptor metadata, not a generic child. It
          # still consumes one edge, one node, and one depth level so callers
          # using this public name-budget owner cannot bypass type-tree limits.
          budget.preflight_children(1_u64)
          aggregate_count_argument_bounds = measure(argument, budget, depth + 1)
        end
      end
      metadata_count = type.metadata_entry_count.to_u64
      if metadata_count > 0_u64
        budget.preflight_children(metadata_count)
        metadata_count.times { budget.visit_node(depth) }
      end

      children = Array(Bounds).new(type.child_count)
      type.child_count.times do |index|
        children << measure(type.child_at(index), budget, depth + 1)
      end

      output = case type.tag
               when BinaryDataType::TAG_DYNAMIC
                 max_types = type.dynamic_max_types.not_nil!
                 if max_types == 32_u8
                   7_u64
                 else
                   add(19_u64, digits(max_types.to_u64))
                 end
               when BinaryDataType::TAG_ARRAY
                 add(7_u64, children[0][0])
               when BinaryDataType::TAG_NESTED
                 # Replacing the implicit Tuple prefix with Nested adds one
                 # display byte; the shared fields and child names are equal.
                 add(children[0][0], 1_u64)
               when BinaryDataType::TAG_NULLABLE
                 add(10_u64, children[0][0])
               when BinaryDataType::TAG_LOW_CARDINALITY
                 # `LowCardinality(` is 15 bytes and the closing parenthesis
                 # adds one more byte. Keep this recursive rather than
                 # teaching each parent consumer about another wrapper.
                 add(16_u64, children[0][0])
               when BinaryDataType::TAG_SIMPLE_AGGREGATE
                 function_name_bytes = type.simple_aggregate_type.not_nil!.function_name.bytesize.to_u64
                 add(27_u64, add(function_name_bytes, children[0][0]))
               when BinaryDataType::TAG_AGGREGATE_COUNT
                 case type.aggregate_count_type.not_nil!.argument
                 when BinaryAggregateCountType::Argument::None
                   24_u64
                 when BinaryAggregateCountType::Argument::UInt64
                   32_u64
                 when BinaryAggregateCountType::Argument::NullableUInt64
                   42_u64
                 else
                   raise UnsupportedFormatError.new("AggregateFunction(count) name is outside the admitted profile")
                 end
               when BinaryDataType::TAG_MAP
                 add(7_u64, add(children[0][0], children[1][0]))
               when BinaryDataType::TAG_VARIANT
                 total = 9_u64 # "Variant(" plus closing parenthesis
                 type.child_count.times do |index|
                   total = add(total, children[index][0])
                   total = add(total, 2_u64) if index > 0
                 end
                 total
               when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
                 total = 7_u64
                 type.child_count.times do |index|
                   total = add(total, children[index][0])
                   total = add(total, 2_u64) if index > 0
                   if type.named_tuple?
                     field_bytes = type.field_name_byte_size(index).to_u64
                     escaped_field = add(multiply(field_bytes, 2_u64), 2_u64)
                     total = add(total, add(escaped_field, 1_u64))
                   end
                 end
                 total
               when BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
                 enum_name_bound(type.enum_definition.not_nil!)
               when BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
                    BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
                    BinaryDataType::TAG_TIME64
                 zone_size = type.temporal_type.not_nil!.time_zone?.nil? ? 0_u64 : TimezoneName::MAX_NAME_BYTES.to_u64
                 add(48_u64, zone_size)
               when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
                    BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256
                 32_u64
               when BinaryDataType::TAG_INTERVAL
                 type.interval_type.not_nil!.name_byte_size
               when BinaryDataType::TAG_FIXED_STRING
                 add(13_u64, digits(type.fixed_size.not_nil!.to_u64))
               else
                 16_u64
               end

      child_allocations = 0_u64
      children.each { |bounds| child_allocations = add(child_allocations, bounds[1]) }
      if argument_bounds = aggregate_count_argument_bounds
        child_allocations = add(child_allocations, argument_bounds[1])
      end
      field_temporaries = 0_u64
      if type.named_tuple?
        type.child_count.times do |index|
          field_bytes = type.field_name_byte_size(index).to_u64
          # format_field_name may create a lowercased probe and an escaped
          # result, each bounded by the raw bytes and doubled output size.
          field_temporaries = add(field_temporaries, add(multiply(field_bytes, 3_u64), 2_u64))
        end
      end
      # String.build and parameter interpolation can hold a builder/final
      # pair; primitive descriptors are cheaper, but retaining the same
      # conservative output bound keeps the metadata path simple and bounded.
      output_copies = multiply(output, 2_u64)
      temporary = add(child_allocations, field_temporaries)
      if type.tag == BinaryDataType::TAG_DATETIME_ZONE || type.tag == BinaryDataType::TAG_DATETIME64_ZONE
        temporary = add(temporary, TimezoneName::MAX_NAME_BYTES.to_u64)
      end
      {output, add(output_copies, temporary)}
    end

    def self.materialize(type : BinaryDataType, budget : BinaryCodecBudget, bounds : Bounds? = nil) : String
      measured = bounds || measure(type, budget)
      budget.ensure_wire_bytes(measured[1])
      name = type.name
      if name.bytesize.to_u64 > measured[0]
        raise UnsupportedFormatError.new("SQL display name exceeded its metadata preflight bound")
      end
      budget.charge_wire_bytes(measured[1])
      name
    end

    def self.add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("SQL display-name size overflows UInt64")
      end
      left + right
    end

    def self.multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("SQL display-name size overflows UInt64")
      end
      left * right
    end

    private def self.enum_name_bound(definition : BinaryEnumDefinition) : UInt64
      total = definition.width_bits == 8 ? 7_u64 : 8_u64 # prefix plus closing parenthesis
      definition.size.times do |index|
        total = add(total, 2_u64) if index > 0
        total = add(total, 5_u64) # quotes and " = "
        total = add(total, multiply(definition.label_byte_size(index).to_u64, 2_u64))
        total = add(total, signed_digits(definition.code_at(index)))
      end
      total
    end

    private def self.signed_digits(code : Int16) : UInt64
      value = code.to_i32
      count = value < 0 ? 1_u64 : 0_u64
      value = -value if value < 0
      count += digits(value.to_u64)
      count
    end

    private def self.digits(value : UInt64) : UInt64
      count = 1_u64
      remaining = value
      while remaining >= 10_u64
        remaining //= 10_u64
        count += 1_u64
      end
      count
    end
  end
end
