module CrystalClick
  # Closed declaration spelling for a direct Dynamic child of a JSON/Object
  # typed path. Recursive containers intentionally do not inherit this leaf
  # admission.
  module ObjectDeclaredDynamicDeclaration
    DEFAULT_MAX_TYPES =  32
    MAX_TYPES         = 254
    PREFIX            = "Dynamic(max_types="

    struct Resolution
      getter max_types : Int32
      getter byte_size : Int32

      def initialize(@max_types : Int32, @byte_size : Int32)
      end

      def materialize : BinaryDataType
        BinaryDataType.dynamic(@max_types)
      end
    end

    def self.resolve_slice(bytes : Bytes, first : Int32, after : Int32) : Resolution?
      return nil if first < 0 || after < first || after > bytes.size
      return Resolution.new(DEFAULT_MAX_TYPES, "Dynamic".bytesize) if slice_equals?(bytes, first, after, "Dynamic")
      return nil unless after - first > PREFIX.bytesize + 1
      return nil unless slice_equals?(bytes, first, first + PREFIX.bytesize, PREFIX)
      return nil unless bytes[after - 1] == ')'.ord.to_u8

      number_first = first + PREFIX.bytesize
      number_after = after - 1
      return nil if number_first >= number_after
      return nil if number_after - number_first > 3
      return nil if number_after - number_first > 1 && bytes[number_first] == '0'.ord.to_u8

      value = 0
      index = number_first
      while index < number_after
        byte = bytes[index]
        return nil unless '0'.ord.to_u8 <= byte <= '9'.ord.to_u8
        value = value * 10 + (byte - '0'.ord.to_u8).to_i
        return nil if value > MAX_TYPES
        index += 1
      end
      # The default has a unique short spelling, just like FixedString and
      # the other canonical Object declaration leaves.
      return nil if value == DEFAULT_MAX_TYPES
      Resolution.new(value, after - first)
    end

    def self.max_types_for(type : BinaryDataType) : Int32?
      return nil unless type.tag == BinaryDataType::TAG_DYNAMIC && type.child_count == 0
      value = type.dynamic_max_types.try(&.to_i) || return nil
      return nil unless 0 <= value <= MAX_TYPES
      value
    end

    def self.byte_size_for(type : BinaryDataType) : UInt64?
      max_types = max_types_for(type) || return nil
      if max_types == DEFAULT_MAX_TYPES
        "Dynamic".bytesize.to_u64
      else
        digit_count = max_types < 10 ? 1_u64 : (max_types < 100 ? 2_u64 : 3_u64)
        PREFIX.bytesize.to_u64 + digit_count + 1_u64
      end
    end

    def self.append_name(io : IO, type : BinaryDataType) : Nil
      max_types = max_types_for(type) || raise ArgumentError.new("typed JSON Dynamic must be a direct canonical descriptor")
      if max_types == DEFAULT_MAX_TYPES
        io << "Dynamic"
      else
        io << PREFIX << max_types << ')'
      end
      nil
    end

    # Object's typed Dynamic slice reuses the existing Object declared-arm
    # domain, not the full generic Dynamic arm domain.
    def self.validate_actual_structure!(structure : DynamicStructure, limits : BinaryCodecLimits, root_depth : Int = 3) : Nil
      structure.type_count.times do |index|
        validate_actual_type!(structure.type_at(index), limits, root_depth)
      end
      nil
    end

    # Prepares the one-root generic Dynamic plan used by a declared Object
    # child. Supplied statistics are deliberately not forwarded to the V3
    # child metadata; the normalized value roster remains explicit.
    def self.prepare_write_plan(
      type : BinaryDataType,
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryDynamicBulkPlan
      maximum = max_types_for(type) || raise UnsupportedFormatError.new("typed Object Dynamic must be a direct canonical descriptor")
      if structure.type_count > maximum
        raise UnsupportedFormatError.new("typed Object Dynamic roster exceeds its declared max_types cap")
      end
      fresh_structure = without_statistics(structure, budget, 3)
      BinaryDynamicBulkPlan.new_with_budget(type, {"root" => fresh_structure}, budget, profile)
    end

    # Parses an exact one-root child structure stream once, under the caller's
    # shared read budget, and applies the narrower Object declared-arm domain.
    def self.prepare_read_plan(
      type : BinaryDataType,
      structures : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryDynamicBulkPlan
      maximum = max_types_for(type) || raise CorruptPartError.new("typed Object Dynamic schema is not a direct canonical descriptor")
      plan = begin
        BinaryDynamicBulkPlan.decode_structure_streams(type, structures, budget, profile)
      rescue ex : UnsupportedFormatError
        raise CorruptPartError.new("invalid typed Object Dynamic structure: #{ex.message}")
      end
      unless plan.site_count == 1 && plan.has_site?("root")
        raise CorruptPartError.new("typed Object Dynamic structure must contain exactly its root site")
      end
      structure = plan.structure_for("root")
      if structure.type_count > maximum
        raise CorruptPartError.new("typed Object Dynamic roster exceeds its declared max_types cap")
      end
      begin
        validate_actual_structure!(structure, budget.limits, 3)
      rescue ex : UnsupportedFormatError
        raise CorruptPartError.new("invalid typed Object Dynamic actual roster: #{ex.message}")
      end
      plan
    end

    def self.validate_actual_type!(type : BinaryDataType, limits : BinaryCodecLimits, root_depth : Int = 3) : Nil
      if type.contains_dynamic? || type.contains_variant? || BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
        raise UnsupportedFormatError.new("typed Object Dynamic actual arms exclude Dynamic, Variant, and LowCardinality")
      end
      unless ObjectRecursiveDeclaration.measure_descriptor(type, limits, root_depth)
        raise UnsupportedFormatError.new("typed Object Dynamic actual arm is outside the recursive declaration grammar")
      end
      nil
    end

    # Fresh typed-child metadata intentionally omits supplied statistics.
    # Bound descriptor/name work before the new roster or its canonical names
    # are allocated; the caller retains the same consumptive operation budget.
    def self.without_statistics(structure : DynamicStructure, budget : BinaryCodecBudget, root_depth : Int = 3) : DynamicStructure
      count = structure.type_count.to_u64
      budget.ensure_future_nodes(count)
      budget.preflight_children(count) if count > 0_u64
      variant_count = checked_add(count, 1_u64)
      budget.preflight_children(variant_count)
      maximum_copy_bytes = 0_u64
      structure.type_count.times do |index|
        type = structure.type_at(index)
        validate_actual_type!(type, budget.limits, root_depth)
        bound = BinaryTypeNameBudget.measure(type, budget, root_depth)
        maximum_copy_bytes = checked_add(maximum_copy_bytes, checked_add(bound[0], bound[1]))
      end
      maximum_copy_bytes = checked_add(maximum_copy_bytes, DynamicStructure::SHARED_VARIANT_NAME.bytesize.to_u64)
      budget.ensure_wire_bytes(maximum_copy_bytes)
      budget.charge_wire_bytes(maximum_copy_bytes)
      variant_count.times { budget.charge_node }
      types = Array(BinaryDataType).new(structure.type_count)
      structure.type_count.times do |index|
        types << structure.type_at(index)
      end
      DynamicStructure.new(types)
    end

    # Validate the selected concrete child, not merely the explicit roster.
    # This includes values spilled through Dynamic's implicit SharedVariant
    # arm, whose generic envelope decoder would otherwise admit a wider tree.
    def self.validate_selected_value!(
      value : BinaryValue,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      unless value.type == expected_type && expected_type.tag == BinaryDataType::TAG_DYNAMIC
        selected_value_error!(writing, "typed Object Dynamic value does not match its declared descriptor")
      end
      if value.is_null?
        unless value.child_count == 0
          selected_value_error!(writing, "typed Object Dynamic NULL value has a selected child")
        end
        return nil
      end
      unless value.child_count == 1
        selected_value_error!(writing, "typed Object Dynamic value does not contain exactly one selected child")
      end
      begin
        validate_actual_type!(value.child_at(0).type, limits, 3)
      rescue ex : UnsupportedFormatError
        selected_value_error!(writing, "typed Object Dynamic selected child is outside the Object recursive arm domain")
      end
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed Object Dynamic metadata size overflows UInt64")
      end
      left + right
    end

    private def self.selected_value_error!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected.to_slice.each_with_index.all? { |byte, index| bytes[first + index] == byte }
    end
  end
end
