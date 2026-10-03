module CrystalClick
  # Binds the recursive binary bulk role grammar to ClickHouse physical names.
  # Default LowCardinality stop-sites and BASIC Map are explicit profiles;
  # no serializer specialization is inferred.
  class BinaryBulkPhysicalPlan
    private struct EscapedPrefix
      getter value : String

      private def initialize(value : String)
        PhysicalStreamName.validate_escaped_prefix(value)
        @value = String.new(value.to_slice)
      end

      def self.validated(value : String) : EscapedPrefix
        new(value)
      end
    end

    @profile : BinaryBulkProfile
    @names : Hash(String, String)
    @context : PhysicalStreamPlanContext

    def initialize(
      type : BinaryDataType,
      column_name : String,
      @profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      context : PhysicalStreamPlanContext? = nil,
    )
      @context = context || PhysicalStreamPlanContext.new(limits)
      @context.preflight_name_bytes(PhysicalStreamName.escaped_size(column_name))
      prefix = PhysicalStreamName.escape(column_name)
      @names = build_bindings(type, prefix)
    end

    private def initialize(
      type : BinaryDataType,
      escaped_prefix : EscapedPrefix,
      @profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      context : PhysicalStreamPlanContext?,
    )
      @context = context || PhysicalStreamPlanContext.new(limits)
      @context.preflight_name_bytes(escaped_prefix.value.bytesize.to_u64)
      @names = build_bindings(type, escaped_prefix.value)
    end

    private def build_bindings(type : BinaryDataType, prefix : String) : Hash(String, String)
      validate_type(type, 0)
      role_plan = BinaryBulkTypePlan.new(type, @profile)
      role_count = role_plan.role_count
      @context.record_elements(role_count)
      role_bytes, rendered_name_bytes = measure_bindings(type, 4_u64, prefix.bytesize.to_u64, 0_u64)
      @context.preflight_name_bytes(add_size(role_bytes, rendered_name_bytes))

      roles = role_plan.roles
      names = Hash(String, String).new
      append_bindings(type, "root", prefix, 0_u64, names)
      unless names.keys.sort == roles
        raise UnsupportedFormatError.new("binary bulk physical roles do not match the admitted role grammar")
      end
      if names.size.to_u64 != role_count
        raise UnsupportedFormatError.new("binary bulk physical lane count does not match the admitted role grammar")
      end

      seen_names = Hash(String, Bool).new
      names.each_value do |name|
        if seen_names.has_key?(name)
          raise UnsupportedFormatError.new("binary bulk roles collide on a physical stream name")
        end
        seen_names[name] = true
      end

      actual_name_bytes = 0_u64
      names.each do |role, name|
        actual_name_bytes = add_size(actual_name_bytes, role.bytesize.to_u64)
        actual_name_bytes = add_size(actual_name_bytes, name.bytesize.to_u64)
      end
      @context.charge_name_bytes(actual_name_bytes)
      names
    end

    # Internal composition entry point. `escaped_prefix` is validated as a
    # rendered prefix; a raw '%' must use the ordinary constructor and becomes
    # `%25` instead of being trusted as syntax.
    def self.from_escaped_prefix(
      type : BinaryDataType,
      escaped_prefix : String,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      context : PhysicalStreamPlanContext? = nil,
    ) : BinaryBulkPhysicalPlan
      selected_context = context || PhysicalStreamPlanContext.new(limits)
      selected_context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      new(type, EscapedPrefix.validated(escaped_prefix), profile, limits, selected_context)
    end

    # A detached role-to-basename snapshot. Neither keys nor values alias the
    # retained bindings, including for callers that mutate String bytes.
    def stream_names : Hash(String, String)
      detached = Hash(String, String).new
      @names.each do |role, name|
        detached[String.new(role.to_slice)] = String.new(name.to_slice)
      end
      detached
    end

    def stream_name_for(role : String) : String
      name = @names[role]? || raise(KeyError.new("binary bulk role not found: #{role.inspect}"))
      String.new(name.to_slice)
    end

    def data_file_for(role : String, hashed : Bool = false) : String
      file_for(role, ".bin", hashed)
    end

    def marks_file_for(role : String, hashed : Bool = false) : String
      file_for(role, ".mrk2", hashed)
    end

    private def file_for(role : String, extension : String, hashed : Bool) : String
      name = stream_name_for(role)
      basename = hashed ? StreamName.hash(name) : name
      PhysicalStreamName.append_literal(basename, extension)
    end

    private def validate_type(type : BinaryDataType, depth : Int) : Nil
      @context.record_type_node(depth)
      metadata = type.metadata_entry_count
      @context.record_elements(metadata.to_u64) if metadata > 0
      child_count = type.child_count
      @context.record_elements(child_count.to_u64) if child_count > 0
      child_count.times do |index|
        validate_type(type.child_at(index), depth + 1)
      end
      nil
    end

    # Exact preflight sizes for role IDs and physical basenames; this traverses
    # descriptors without creating either String roster.
    private def measure_bindings(
      type : BinaryDataType,
      role_length : UInt64,
      name_length : UInt64,
      array_level : UInt64,
    ) : {UInt64, UInt64}
      role_bytes = 0_u64
      name_bytes = 0_u64
      case type.tag
      when BinaryDataType::TAG_STRING
        role_bytes = add_size(role_bytes, add_size(role_length, 5_u64))
        name_bytes = add_size(name_bytes, name_length)
        if @profile.with_size_stream?
          role_bytes = add_size(role_bytes, add_size(role_length, 13_u64))
          name_bytes = add_size(name_bytes, add_size(name_length, 5_u64))
        end
      when BinaryDataType::TAG_ARRAY
        role_bytes = add_size(role_bytes, add_size(role_length, 6_u64))
        name_bytes = add_size(name_bytes, add_size(name_length, add_size(5_u64, digit_count(array_level))))
        nested_roles, nested_names = measure_bindings(type.child_at(0), add_size(role_length, 9_u64), name_length, array_level + 1_u64)
        role_bytes = add_size(role_bytes, nested_roles)
        name_bytes = add_size(name_bytes, nested_names)
      when BinaryDataType::TAG_NULLABLE
        role_bytes = add_size(role_bytes, add_size(role_length, 6_u64))
        name_bytes = add_size(name_bytes, add_size(name_length, 5_u64))
        nested_roles, nested_names = measure_bindings(type.child_at(0), add_size(role_length, 7_u64), name_length, array_level)
        role_bytes = add_size(role_bytes, nested_roles)
        name_bytes = add_size(name_bytes, nested_names)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          role_bytes = add_size(role_length, 5_u64)
          name_bytes = name_length
        else
          type.child_count.times do |index|
            field_role_length = add_size(role_length, add_size(7_u64, digit_count(index.to_u64)))
            field_name_length = if type.named_tuple?
                                  add_size(name_length, escaped_field_suffix_size(type, index))
                                else
                                  add_size(name_length, add_size(3_u64, digit_count(index.to_u64 + 1_u64)))
                                end
            nested_roles, nested_names = measure_bindings(type.child_at(index), field_role_length, field_name_length, array_level)
            role_bytes = add_size(role_bytes, nested_roles)
            name_bytes = add_size(name_bytes, nested_names)
          end
        end
      when BinaryDataType::TAG_MAP
        role_bytes = add_size(role_bytes, add_size(role_length, 6_u64))
        name_bytes = add_size(name_bytes, add_size(name_length, add_size(5_u64, digit_count(array_level))))
        keys_roles, keys_names = measure_bindings(type.child_at(0), add_size(role_length, 17_u64), add_size(name_length, 7_u64), array_level + 1_u64)
        values_roles, values_names = measure_bindings(type.child_at(1), add_size(role_length, 17_u64), add_size(name_length, 9_u64), array_level + 1_u64)
        role_bytes = add_size(role_bytes, add_size(keys_roles, values_roles))
        name_bytes = add_size(name_bytes, add_size(keys_names, values_names))
      when BinaryDataType::TAG_LOW_CARDINALITY
        # LC owns exactly two physical stop-sites. Its logical child is used
        # by the dictionary codec, not recursively enumerated as ordinary lanes.
        role_bytes = add_size(role_bytes, add_size(role_length, 11_u64)) # .dictionary
        role_bytes = add_size(role_bytes, add_size(role_length, 8_u64))  # .indexes
        name_bytes = add_size(name_bytes, add_size(name_length, 5_u64))  # .dict
        name_bytes = add_size(name_bytes, name_length)                   # indexes own prefix
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        role_bytes = add_size(role_length, 5_u64)
        name_bytes = name_length
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("unsupported binary bulk DataType")
        end
        role_bytes = add_size(role_length, 5_u64)
        name_bytes = name_length
      end
      {role_bytes, name_bytes}
    end

    private def append_bindings(
      type : BinaryDataType,
      role : String,
      prefix : String,
      array_level : UInt64,
      names : Hash(String, String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        names["#{role}.data"] = String.new(prefix.to_slice)
        if @profile.with_size_stream?
          names["#{role}.string_sizes"] = PhysicalStreamName.append_literal(prefix, ".size")
        end
      when BinaryDataType::TAG_ARRAY
        names["#{role}.sizes"] = PhysicalStreamName.append_literal(prefix, ".size#{array_level}")
        append_bindings(type.child_at(0), "#{role}.elements", prefix, array_level + 1_u64, names)
      when BinaryDataType::TAG_NULLABLE
        names["#{role}.nulls"] = PhysicalStreamName.append_literal(prefix, ".null")
        append_bindings(type.child_at(0), "#{role}.nested", prefix, array_level, names)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          names["#{role}.data"] = String.new(prefix.to_slice)
        else
          type.child_count.times do |index|
            field_name = if type.named_tuple?
                           type.field_name_at(index)
                         else
                           (index + 1).to_s
                         end
            field_prefix = PhysicalStreamName.append_escaped_field(prefix, field_name)
            append_bindings(type.child_at(index), "#{role}.field.#{index}", field_prefix, array_level, names)
          end
        end
      when BinaryDataType::TAG_MAP
        names["#{role}.sizes"] = PhysicalStreamName.append_literal(prefix, ".size#{array_level}")
        keys_prefix = PhysicalStreamName.append_escaped_field(prefix, "keys")
        values_prefix = PhysicalStreamName.append_escaped_field(prefix, "values")
        append_bindings(type.child_at(0), "#{role}.elements.field.0", keys_prefix, array_level + 1_u64, names)
        append_bindings(type.child_at(1), "#{role}.elements.field.1", values_prefix, array_level + 1_u64, names)
      when BinaryDataType::TAG_LOW_CARDINALITY
        # Match the default LC serializer's physical names. Do not recurse into
        # the dictionary type; LC's paired codec owns the complete lane grammar.
        names["#{role}.dictionary"] = PhysicalStreamName.append_literal(prefix, ".dict")
        names["#{role}.indexes"] = String.new(prefix.to_slice)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        names["#{role}.data"] = String.new(prefix.to_slice)
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("unsupported binary bulk DataType")
        end
        names["#{role}.data"] = String.new(prefix.to_slice)
      end
      nil
    end

    private def digit_count(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    # Measure the fully escaped `%2E` + Tuple field without obtaining the
    # detached raw field String. That copy is made only after aggregate
    # expansion preflight succeeds.
    private def escaped_field_suffix_size(type : BinaryDataType, index : Int) : UInt64
      size = 3_u64
      type.field_name_byte_size(index).times do |byte_index|
        byte = type.field_name_byte_at(index, byte_index)
        size = add_size(size, escaped_word_byte?(byte) ? 1_u64 : 3_u64)
      end
      size
    end

    private def escaped_word_byte?(byte : UInt8) : Bool
      (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) || byte == '_'.ord.to_u8
    end

    private def add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("physical stream roster size overflows UInt64")
      end
      left + right
    end
  end
end
