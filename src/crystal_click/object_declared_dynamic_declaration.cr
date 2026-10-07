module CrystalClick
  # Closed declaration spelling and site policy for declared Dynamic leaves
  # in a JSON/Object typed path. It owns nominal site provenance; actual
  # Dynamic arm values remain constrained by ObjectRecursiveDeclaration.
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
    def self.validate_actual_structure!(
      structure : DynamicStructure,
      limits : BinaryCodecLimits,
      root_depth : Int = 3,
      budget : BinaryCodecBudget? = nil,
    ) : Nil
      structure.type_count.times do |index|
        validate_actual_type!(structure.type_at(index), limits, root_depth, budget)
      end
      nil
    end

    # Prepares every declared Dynamic site under one shared operation budget.
    # Supplied statistics are not forwarded into typed-child V3 metadata.
    def self.prepare_write_sites_plan(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      root_depth : Int = 2,
    ) : BinaryDynamicBulkPlan
      unless budget.writing?
        raise ArgumentError.new("typed Object Dynamic plan requires a writing budget")
      end
      limits = budget.limits
      shape = ObjectDeclaredDynamicSites.shape_for(type, limits, root_depth)
      unless shape.count > 0_u64
        raise UnsupportedFormatError.new("typed Object Dynamic site plan requires a declared Dynamic site")
      end
      unless structures.size.to_u64 == shape.count
        raise UnsupportedFormatError.new("typed Object Dynamic structures must exactly match declared sites")
      end
      if shape.count > 0_u64
        budget.ensure_future_nodes(shape.count)
        budget.preflight_children(shape.count)
      end
      path_work_bytes = checked_multiply(shape.path_bytes, checked_add(limits.max_depth.to_u64, 1_u64))
      budget.ensure_wire_bytes(path_work_bytes)
      budget.charge_wire_bytes(path_work_bytes)

      sites = ObjectDeclaredDynamicSites.for_type(type, limits, root_depth)
      prepared_structures = Hash(String, DynamicStructure).new(initial_capacity: sites.size)
      sites.each do |site|
        structure = structures[site.path]? || raise(UnsupportedFormatError.new("typed Object Dynamic structure is missing site: #{site.path.inspect}"))
        maximum = max_types_for(site.type) || raise(UnsupportedFormatError.new("typed Object Dynamic site is not canonical"))
        if structure.type_count > maximum
          raise UnsupportedFormatError.new("typed Object Dynamic roster exceeds its declared max_types cap")
        end
        structure.type_count.times do |index|
          actual_type = structure.type_at(index)
          validate_actual_type!(actual_type, limits, site.actual_root_depth, budget)
        end
        prepared_structures[site.path] = without_statistics(structure, budget, site.actual_root_depth)
      end

      BinaryDynamicBulkPlan.new_with_budget(type, prepared_structures, budget, profile)
    end

    # Parses every nominal typed-Dynamic metadata site once. The returned
    # generic plan retains each exact per-site statistics offset for the
    # paired selected-value decoder.
    def self.prepare_read_sites_plan(
      type : BinaryDataType,
      structures : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      root_depth : Int = 2,
    ) : BinaryDynamicBulkPlan
      if budget.writing?
        raise ArgumentError.new("typed Object Dynamic plan requires a reading budget")
      end
      limits = budget.limits
      shape = begin
        ObjectDeclaredDynamicSites.shape_for(type, limits, root_depth)
      rescue ex : UnsupportedFormatError
        raise CorruptPartError.new("typed Object Dynamic schema is outside the Object recursive grammar: #{ex.message}")
      end
      unless shape.count > 0_u64
        raise CorruptPartError.new("typed Object Dynamic site plan requires a declared Dynamic site")
      end
      unless structures.site_count.to_u64 == shape.count
        raise CorruptPartError.new("typed Object Dynamic structure site count does not match its declaration")
      end
      if shape.count > 0_u64
        budget.ensure_future_nodes(shape.count)
        budget.preflight_children(shape.count)
      end
      path_work_bytes = checked_multiply(shape.path_bytes, checked_add(limits.max_depth.to_u64, 1_u64))
      budget.ensure_wire_bytes(path_work_bytes)
      budget.charge_wire_bytes(path_work_bytes)
      sites = ObjectDeclaredDynamicSites.for_type(type, limits, root_depth)

      plan = begin
        BinaryDynamicBulkPlan.decode_structure_streams(type, structures, budget, profile)
      rescue ex : UnsupportedFormatError
        raise CorruptPartError.new("invalid typed Object Dynamic structure: #{ex.message}")
      end
      unless plan.site_count == sites.size
        raise CorruptPartError.new("typed Object Dynamic structure contains undeclared nested sites")
      end

      sites.each do |site|
        unless plan.has_site?(site.path)
          raise CorruptPartError.new("typed Object Dynamic structure is missing site: #{site.path.inspect}")
        end
        structure = plan.structure_for(site.path)
        maximum = max_types_for(site.type) || raise(CorruptPartError.new("typed Object Dynamic site is not canonical"))
        if structure.type_count > maximum
          raise CorruptPartError.new("typed Object Dynamic roster exceeds its declared max_types cap")
        end
        begin
          structure.type_count.times do |index|
            actual_type = structure.type_at(index)
            validate_actual_type!(actual_type, limits, site.actual_root_depth, budget)
          end
        rescue ex : UnsupportedFormatError
          raise CorruptPartError.new("invalid typed Object Dynamic actual roster: #{ex.message}")
        end
      end
      plan
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
      unless max_types_for(type)
        raise UnsupportedFormatError.new("typed Object Dynamic must be a direct canonical descriptor")
      end
      prepare_write_sites_plan(type, {"root" => structure}, budget, profile, 2)
    end

    # Parses an exact one-root child structure stream once, under the caller's
    # shared read budget, and applies the narrower Object declared-arm domain.
    def self.prepare_read_plan(
      type : BinaryDataType,
      structures : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryDynamicBulkPlan
      unless max_types_for(type)
        raise CorruptPartError.new("typed Object Dynamic schema is not a direct canonical descriptor")
      end
      prepare_read_sites_plan(type, structures, budget, profile, 2)
    end

    def self.validate_actual_type!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int = 3,
      budget : BinaryCodecBudget? = nil,
    ) : Nil
      validate_actual_descriptor_tree!(type, limits, root_depth, budget)
      validate_actual_type_shape!(type, limits, root_depth, false)
      nil
    end

    # SharedVariant is the only typed Object Dynamic route that may carry a
    # JSON scalar. Keep this private opt-in separate from ordinary actual-arm
    # admission; JSON owns its own bounded typed-path grammar.
    private def self.validate_shared_json_actual_type!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int,
      budget : BinaryCodecBudget?,
    ) : Nil
      validate_actual_descriptor_tree!(type, limits, root_depth, budget)
      validate_actual_type_shape!(type, limits, root_depth, true)
      nil
    end

    private def self.validate_actual_descriptor_tree!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int,
      budget : BinaryCodecBudget?,
    ) : Nil
      if operation_budget = budget
        type_context = BinaryCodecContext.new(limits, nil, operation_budget.writing?, operation_budget, false, false)
        type_context.validate_type_tree(type, root_depth)
      else
        # Keep this standalone public seam finite even when no operation owner
        # is supplied. Callers with an aggregate budget pass it explicitly.
        BinaryCodecContext.new(limits, nil, true, nil, false, false).validate_type_tree(type, root_depth)
      end
      nil
    end

    private def self.validate_actual_type_shape!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int,
      allow_shared_json : Bool,
    ) : Nil
      # The complete descriptor (including JSON metadata) has already passed
      # the shared depth/node/edge budget before these recursive predicates.
      # JSON typed-path metadata remains opaque here and is validated by the
      # existing BinaryJsonType policy.
      if type.contains_json?
        unless allow_shared_json && shared_json_actual_type_admitted?(type, limits, root_depth)
          raise UnsupportedFormatError.new("JSON is not admitted as a typed Object Dynamic actual arm")
        end
      elsif !ObjectRecursiveDeclaration.measure_descriptor(type, limits, root_depth)
        raise UnsupportedFormatError.new("typed Object Dynamic actual arm is outside the recursive declaration grammar")
      end
      if type.contains_dynamic? || type.contains_variant? || BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
        raise UnsupportedFormatError.new("typed Object Dynamic actual arms exclude Dynamic, Variant, and LowCardinality")
      end
      nil
    end

    # Object recursive wrappers with JSON treated as a terminal scalar. This
    # deliberately mirrors only the admitted Object wrapper grammar; all
    # other leaves must still belong to ObjectTypedFieldType's scalar set.
    private def self.shared_json_actual_type_admitted?(type : BinaryDataType, limits : BinaryCodecLimits, depth : Int) : Bool
      return false if depth <= 0 || depth > limits.max_depth

      case type.tag
      when BinaryDataType::TAG_JSON
        type.child_count == 0 && !type.json_type.nil?
      when BinaryDataType::TAG_ARRAY
        type.child_count == 1 && shared_json_actual_type_admitted?(type.child_at(0), limits, depth + 1)
      when BinaryDataType::TAG_NULLABLE
        return false unless type.child_count == 1
        child = type.child_at(0)
        return false if child.tag == BinaryDataType::TAG_ARRAY || child.tag == BinaryDataType::TAG_MAP ||
                        child.tag == BinaryDataType::TAG_NULLABLE || child.tag == BinaryDataType::TAG_LOW_CARDINALITY ||
                        child.tag == BinaryDataType::TAG_VARIANT || child.tag == BinaryDataType::TAG_DYNAMIC
        shared_json_actual_type_admitted?(child, limits, depth + 1)
      when BinaryDataType::TAG_MAP
        type.child_count == 2 && type.child_at(0).tag == BinaryDataType::TAG_STRING &&
          shared_json_actual_type_admitted?(type.child_at(0), limits, depth + 1) &&
          shared_json_actual_type_admitted?(type.child_at(1), limits, depth + 1)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        named = type.tag == BinaryDataType::TAG_NAMED_TUPLE
        return false if named && type.child_count == 0
        type.child_count.times do |index|
          return false if named && type.field_name_byte_size(index) <= 0
          return false unless shared_json_actual_type_admitted?(type.child_at(index), limits, depth + 1)
        end
        true
      else
        !ObjectTypedFieldType.leaf_byte_size_for(type).nil?
      end
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
        validate_actual_type!(type, budget.limits, root_depth, budget)
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
      root_depth : Int = 3,
      budget : BinaryCodecBudget? = nil,
    ) : Nil
      validate_selected_dynamic_value!(value, expected_type, limits, writing, root_depth, budget, false)
    end

    # Checks every selected Dynamic node inside one declared composite value.
    # Depth begins at the Object typed field root (2) and advances through the
    # same wrappers that generate generic site paths.
    def self.validate_selected_values!(
      value : BinaryValue,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      budget = BinaryCodecBudget.new(limits, writing)
      validate_selected_values!(value, expected_type, budget, writing, 2)
    end

    # Borrowed-budget form for paired codec owners. Direction is checked before
    # descriptor scans or value traversal; each Dynamic-bearing wrapper edge
    # and selected site node is preflighted/charged on the same operation
    # budget used by the enclosing bulk lane. Shared JSON remains opt-in.
    def self.validate_selected_values!(
      value : BinaryValue,
      expected_type : BinaryDataType,
      budget : BinaryCodecBudget,
      writing : Bool,
      root_depth : Int = 2,
      allow_shared_json : Bool = false,
    ) : Nil
      unless budget.writing? == writing
        raise ArgumentError.new("typed Object Dynamic selected-value budget direction differs")
      end
      limits = budget.limits
      # Descriptor recursion is bounded before the Dynamic predicate can walk
      # it. This temporary read/write-neutral context is intentionally not the
      # operation budget: the enclosing owner already accounts its schema.
      BinaryCodecContext.new(limits, nil, writing, nil, false, false).validate_type_tree(expected_type, root_depth)
      return nil unless expected_type.contains_dynamic?
      unless ObjectRecursiveDeclaration.measure_descriptor(expected_type, limits, root_depth)
        selected_value_error!(writing, "typed Object Dynamic descriptor is outside the recursive declaration grammar")
      end
      validate_selected_value_tree!(value, expected_type, limits, budget, writing, root_depth, allow_shared_json)
      nil
    end

    private def self.validate_selected_value_tree!(
      value : BinaryValue,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      writing : Bool,
      object_depth : Int,
      allow_shared_json : Bool,
    ) : Nil
      budget.visit_node(object_depth)
      unless value.type == expected_type
        selected_value_error!(writing, "typed Object Dynamic value does not match its declared recursive descriptor")
      end
      case expected_type.tag
      when BinaryDataType::TAG_DYNAMIC
        validate_selected_dynamic_value!(value, expected_type, limits, writing, object_depth + 1, budget, allow_shared_json)
      when BinaryDataType::TAG_ARRAY
        child_type = expected_type.child_at(0)
        if child_type.contains_dynamic?
          child_count = value.element_count.to_u64
          budget.preflight_children(child_count) if child_count > 0_u64
          value.element_count.times do |index|
            validate_selected_value_tree!(value.element_at(index), child_type, limits, budget, writing, object_depth + 1, allow_shared_json)
          end
        end
      when BinaryDataType::TAG_NULLABLE
        child_type = expected_type.child_at(0)
        if !value.is_null? && child_type.contains_dynamic?
          unless value.child_count == 1
            selected_value_error!(writing, "typed Object Dynamic Nullable value does not contain exactly one child")
          end
          budget.preflight_children(1_u64)
          validate_selected_value_tree!(value.child_at(0), child_type, limits, budget, writing, object_depth + 1, allow_shared_json)
        end
      when BinaryDataType::TAG_MAP
        value_type = expected_type.child_at(1)
        if value_type.contains_dynamic?
          if value.element_count % 2 != 0
            selected_value_error!(writing, "typed Object Dynamic Map value has an incomplete key/value pair")
          end
          value_count = (value.element_count // 2).to_u64
          budget.preflight_children(value_count) if value_count > 0_u64
          index = 1
          while index < value.element_count
            validate_selected_value_tree!(value.element_at(index), value_type, limits, budget, writing, object_depth + 1, allow_shared_json)
            index += 2
          end
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        unless value.element_count == expected_type.child_count
          selected_value_error!(writing, "typed Object Dynamic Tuple value does not match its declared fields")
        end
        dynamic_child_count = 0_u64
        expected_type.child_count.times do |index|
          dynamic_child_count += 1_u64 if expected_type.child_at(index).contains_dynamic?
        end
        budget.preflight_children(dynamic_child_count) if dynamic_child_count > 0_u64
        expected_type.child_count.times do |index|
          child_type = expected_type.child_at(index)
          if child_type.contains_dynamic?
            validate_selected_value_tree!(value.element_at(index), child_type, limits, budget, writing, object_depth + 1, allow_shared_json)
          end
        end
      when BinaryDataType::TAG_VARIANT
        unless value.is_null?
          index = value.variant_index?.try(&.to_i) || selected_value_error!(writing, "non-NULL typed Object Variant is missing its selected arm")
          if index >= expected_type.child_count
            selected_value_error!(writing, "typed Object Variant discriminator exceeds its declared arms")
          end
          child_type = expected_type.child_at(index)
          if child_type.contains_dynamic?
            child = value.variant_child? || selected_value_error!(writing, "non-NULL typed Object Variant is missing its selected child")
            budget.preflight_children(1_u64)
            validate_selected_value_tree!(child, child_type, limits, budget, writing, object_depth + 1, allow_shared_json)
          end
        end
      end
      nil
    end

    private def self.validate_selected_dynamic_value!(
      value : BinaryValue,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
      root_depth : Int,
      budget : BinaryCodecBudget?,
      allow_shared_json : Bool,
    ) : Nil
      if operation_budget = budget
        unless operation_budget.writing? == writing
          raise ArgumentError.new("typed Object Dynamic selected-value budget direction differs")
        end
      end
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
        if allow_shared_json
          validate_shared_json_actual_type!(value.child_at(0).type, limits, root_depth, budget)
        else
          validate_actual_type!(value.child_at(0).type, limits, root_depth, budget)
        end
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

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("typed Object Dynamic metadata size overflows UInt64")
      end
      left * right
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
