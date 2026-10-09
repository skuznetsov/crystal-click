module CrystalClick
  # Builds the complete Dynamic structure-site roster for one advanced shared
  # path from its declared descriptor and values. Descriptor-only sites are
  # retained even when their enclosing containers are empty or NULL.
  class ObjectSharedDynamicSiteCensus
    getter structures : Hash(String, DynamicStructure)
    getter leaf_bindings : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))

    def self.build(
      root_values : Array(BinaryValue?),
      root_types : Array(BinaryDataType),
      policy : ObjectSharedAdvancedJsonWritePolicy,
      budget : BinaryCodecBudget,
    ) : ObjectSharedDynamicSiteCensus
      new(root_values, root_types, policy, budget)
    end

    private def initialize(
      root_values : Array(BinaryValue?),
      root_types : Array(BinaryDataType),
      @policy : ObjectSharedAdvancedJsonWritePolicy,
      @budget : BinaryCodecBudget,
    )
      @structures = {} of String => DynamicStructure
      @leaf_bindings = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)

      unless @budget.writing?
        raise ArgumentError.new("Dynamic site census requires a write-direction budget")
      end

      preflight_child_roster(root_types.size)
      root_structure = DynamicStructure.new(root_types)
      add_site("root", root_structure)
      add_bindings("root", root_structure)

      root_structure.type_count.times do |index|
        actual_type = root_structure.type_at(index)
        canonical_index = root_structure.canonical_index_for(actual_type)
        selected = values_of_type(root_values, actual_type)
        walk_type(
          actual_type,
          selected,
          site_arm_path("root", canonical_index),
          2,
        )
      end
    end

    private def add_site(path : String, structure : DynamicStructure) : Nil
      if @structures.has_key?(path)
        raise UnsupportedFormatError.new("Dynamic site census produced a duplicate descriptor path")
      end
      @budget.charge_node
      @budget.charge_elements(1_u64)
      @structures[path] = structure
    end

    private def add_bindings(path : String, structure : DynamicStructure) : Nil
      prepared = @policy.leaf_bindings_for(path, structure, @budget)
      preflight_child_roster(prepared.size)
      prepared.each { |binding| @leaf_bindings << binding }
    end

    private def walk_type(
      type : BinaryDataType,
      values : Array(BinaryValue),
      path : String,
      depth : Int32,
    ) : Nil
      @budget.visit_node(depth)
      values.each do |value|
        unless value.type == type
          raise UnsupportedFormatError.new("Dynamic site census value does not match its descriptor")
        end
      end

      case type.tag
      when BinaryDataType::TAG_JSON
        # Typed paths are handled by their prepared Object child plan. Runtime
        # JSON payloads are fenced by BinaryCodecContext's JSON ancestry.
        return nil
      when BinaryDataType::TAG_DYNAMIC
        walk_dynamic_site(type, values, path, depth)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        child_count = 0_u64
        values.each do |value|
          next if value.is_null?
          child_count = checked_add(child_count, value.element_count.to_u64)
        end
        preflight_child_roster(child_count)
        children = Array(BinaryValue).new(child_count.to_i)
        values.each do |value|
          next if value.is_null?
          value.element_count.times { |index| children << value.element_at(index) }
        end
        walk_type(type.child_at(0), children, append_path(path, ".elements"), depth + 1)
      when BinaryDataType::TAG_NULLABLE
        child_count = 0_u64
        values.each do |value|
          next if value.is_null?
          unless value.child_count == 1
            raise UnsupportedFormatError.new("non-NULL Nullable census value has an invalid child count")
          end
          child_count = checked_add(child_count, 1_u64)
        end
        preflight_child_roster(child_count)
        children = Array(BinaryValue).new(child_count.to_i)
        values.each do |value|
          next if value.is_null?
          unless value.child_count == 1
            raise UnsupportedFormatError.new("non-NULL Nullable census value has an invalid child count")
          end
          children << value.child_at(0)
        end
        walk_type(type.child_at(0), children, append_path(path, ".nested"), depth + 1)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        child_count = 0_u64
        values.each do |value|
          next if value.is_null?
          unless value.child_count == 1
            raise UnsupportedFormatError.new("SimpleAggregateFunction census value has an invalid child count")
          end
          child_count = checked_add(child_count, 1_u64)
        end
        preflight_child_roster(child_count)
        children = Array(BinaryValue).new(child_count.to_i)
        values.each do |value|
          next if value.is_null?
          unless value.child_count == 1
            raise UnsupportedFormatError.new("SimpleAggregateFunction census value has an invalid child count")
          end
          children << value.child_at(0)
        end
        walk_type(type.child_at(0), children, path, depth + 1)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |field_index|
          child_count = 0_u64
          values.each do |value|
            next if value.is_null?
            unless value.element_count == type.child_count
              raise UnsupportedFormatError.new("Tuple census value has an invalid field count")
            end
            child_count = checked_add(child_count, 1_u64)
          end
          preflight_child_roster(child_count)
          children = Array(BinaryValue).new(child_count.to_i)
          values.each do |value|
            next if value.is_null?
            children << value.element_at(field_index)
          end
          walk_type(
            type.child_at(field_index),
            children,
            append_index_path(path, ".field.", field_index),
            depth + 1,
          )
        end
      when BinaryDataType::TAG_MAP
        pair_count = 0_u64
        values.each do |value|
          next if value.is_null?
          unless value.element_count.even?
            raise UnsupportedFormatError.new("Map census value has an incomplete key/value pair")
          end
          pair_count = checked_add(pair_count, (value.element_count / 2).to_u64)
        end
        preflight_child_roster(checked_multiply(pair_count, 2_u64))
        key_values = Array(BinaryValue).new(pair_count.to_i)
        mapped_values = Array(BinaryValue).new(pair_count.to_i)
        values.each do |value|
          next if value.is_null?
          value.element_count.times do |index|
            (index.even? ? key_values : mapped_values) << value.element_at(index)
          end
        end
        elements_path = append_path(path, ".elements")
        walk_type(type.child_at(0), key_values, append_path(elements_path, ".field.0"), depth + 1)
        walk_type(type.child_at(1), mapped_values, append_path(elements_path, ".field.1"), depth + 1)
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |arm_index|
          child_count = 0_u64
          values.each do |value|
            next if value.is_null?
            selected_index = value.variant_index? || raise UnsupportedFormatError.new("non-NULL Variant census value has no discriminator")
            next unless selected_index.to_i == arm_index
            value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant census value has no child")
            child_count = checked_add(child_count, 1_u64)
          end
          preflight_child_roster(child_count)
          children = Array(BinaryValue).new(child_count.to_i)
          values.each do |value|
            next if value.is_null?
            next unless value.variant_index?.not_nil!.to_i == arm_index
            children << value.variant_child?.not_nil!
          end
          walk_type(
            type.child_at(arm_index),
            children,
            append_index_path(path, ".arm.", arm_index),
            depth + 1,
          )
        end
      else
        if type.contains_dynamic?
          raise UnsupportedFormatError.new("Dynamic site census does not admit this descriptor owner")
        end
      end
      nil
    end

    private def walk_dynamic_site(
      type : BinaryDataType,
      values : Array(BinaryValue),
      path : String,
      depth : Int32,
    ) : Nil
      preflight_child_roster(values.size)
      observed = Array(BinaryDataType).new(values.size)
      values.each do |value|
        next if value.is_null?
        unless value.child_count == 1
          raise UnsupportedFormatError.new("non-NULL Dynamic census value has an invalid child count")
        end
        actual_type = value.child_at(0).type
        observed << actual_type unless observed.any? { |existing| existing == actual_type }
      end
      local_cap = type.dynamic_max_types.not_nil!.to_i
      ordinary_types = @policy.ordinary_types_for_dynamic_site(observed, local_cap, @budget)
      structure = DynamicStructure.new(ordinary_types)
      add_site(path, structure)
      add_bindings(path, structure)

      structure.type_count.times do |index|
        actual_type = structure.type_at(index)
        canonical_index = structure.canonical_index_for(actual_type)
        child_count = 0_u64
        values.each do |value|
          next if value.is_null?
          child = value.child_at(0)
          child_count = checked_add(child_count, 1_u64) if child.type == actual_type
        end
        preflight_child_roster(child_count)
        children = Array(BinaryValue).new(child_count.to_i)
        values.each do |value|
          next if value.is_null?
          child = value.child_at(0)
          children << child if child.type == actual_type
        end
        walk_type(actual_type, children, site_arm_path(path, canonical_index), depth + 1)
      end
      nil
    end

    private def values_of_type(values : Array(BinaryValue?), type : BinaryDataType) : Array(BinaryValue)
      matching_count = values.count { |value| value && value.type == type }
      preflight_child_roster(matching_count)
      selected = Array(BinaryValue).new(matching_count)
      values.each do |value|
        next unless actual = value
        selected << actual if actual.type == type
      end
      selected
    end

    private def preflight_child_roster(count : Int) : Nil
      preflight_child_roster(count.to_u64)
    end

    private def preflight_child_roster(count : UInt64) : Nil
      @budget.preflight_children(count) if count > 0_u64
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Dynamic site census child count overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left != 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Dynamic site census child count overflows UInt64")
      end
      left * right
    end

    private def append_path(path : String, suffix : String) : String
      @budget.charge_elements(suffix.bytesize.to_u64) unless suffix.empty?
      String.build(path.bytesize + suffix.bytesize) do |io|
        io << path << suffix
      end
    end

    private def append_index_path(path : String, prefix : String, index : Int) : String
      append_path(path, "#{prefix}#{index}")
    end

    private def site_arm_path(path : String, canonical_index : Int32) : String
      append_index_path(path, ".arm.", canonical_index)
    end
  end
end
