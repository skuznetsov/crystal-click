module CrystalClick
  # Borrowed-slice grammar, preflight, and delayed materialization for Object
  # recursive declarations. It owns no descriptor policy beyond asking the
  # scalar owner to resolve leaves and the Tuple-name codec to validate names.
  module ObjectRecursiveDeclarationText
    private struct Range
      getter first : Int32
      getter after : Int32

      def initialize(@first : Int32, @after : Int32)
      end
    end

    private class TopLevelCursor
      @index : Int32
      @valid : Bool

      def initialize(@bytes : Bytes, @first : Int32, @after : Int32)
        @index = @first
        @valid = @first <= @after
      end

      def valid? : Bool
        @valid
      end

      def next_range : Range?
        return nil unless @valid && @index <= @after
        return nil if @index == @after

        start = @index
        depth = 0
        backtick = false
        backtick_escape = false
        label = false
        label_escape = false
        while @index < @after
          byte = @bytes[@index]
          if label
            if label_escape
              label_escape = false
            elsif byte == '\\'.ord.to_u8
              label_escape = true
            elsif byte == '\''.ord.to_u8
              label = false
            end
          elsif backtick
            if backtick_escape
              backtick_escape = false
            elsif byte == '\\'.ord.to_u8
              backtick_escape = true
            elsif byte == '`'.ord.to_u8
              backtick = false
            end
          else
            case byte
            when '`'.ord.to_u8
              backtick = true
            when '\''.ord.to_u8
              label = true
            when '('.ord.to_u8
              depth += 1
            when ')'.ord.to_u8
              depth -= 1
              if depth < 0
                @valid = false
                return nil
              end
            when ','.ord.to_u8
              if depth == 0
                range_after = @index
                unless @index + 1 < @after && @bytes[@index + 1] == ' '.ord.to_u8 && @index + 2 < @after
                  @valid = false
                  return nil
                end
                @index += 2
                return Range.new(start, range_after)
              end
            end
          end
          @index += 1
        end
        unless depth == 0 && !backtick && !label && !backtick_escape && !label_escape
          @valid = false
          return nil
        end
        @index = @after
        Range.new(start, @after)
      end
    end

    def self.preflight_slice(
      bytes : Bytes,
      first : Int32,
      after : Int32,
      limits : BinaryCodecLimits = ObjectRecursiveDeclaration::DEFAULT_LIMITS,
      root_depth : Int = 1,
    ) : ObjectRecursiveDeclaration::Preflight?
      return nil if first < 0 || after < first || after > bytes.size
      if root_depth <= 0 || root_depth > Int32::MAX
        raise UnsupportedFormatError.new("binary codec depth limit exceeded")
      end
      if (after - first).to_u64 > limits.max_bytes.to_u64
        raise UnsupportedFormatError.new("binary codec byte limit exceeded")
      end

      totals = ObjectRecursiveDeclaration::ScanTotals.new
      byte_size = scan_type(bytes, first, after, root_depth.to_i32, limits, totals, true) || return nil
      # Only exactly canonical source survives: the measured rendered size is
      # the borrowed slice size and Tuple-name spellings have already been
      # proven byte-canonical by ObjectTupleFieldName.shape.
      return nil unless byte_size == (after - first).to_u64

      metadata_bytes = ObjectRecursiveDeclaration.checked_add(
        totals.tuple_name_bytes,
        ObjectRecursiveDeclaration.checked_add(totals.label_bytes, totals.zone_bytes),
      )
      retained_bytes = ObjectRecursiveDeclaration.checked_add(
        byte_size,
        ObjectRecursiveDeclaration.checked_multiply(metadata_bytes, 2_u64),
      )
      if retained_bytes > limits.max_bytes.to_u64
        raise UnsupportedFormatError.new("binary codec byte limit exceeded")
      end

      metrics = totals.metrics(byte_size)
      ObjectRecursiveDeclaration::Preflight.new(
        metrics.byte_size,
        metrics.descriptor_node_count,
        metrics.child_edge_count,
        metrics.metadata_edge_count,
        metrics.enum_entry_count,
        metrics.decoded_label_bytes,
        metrics.explicit_zone_bytes,
        metrics.tuple_name_count,
        metrics.tuple_name_bytes,
        metrics.max_depth,
        root_depth.to_i32,
        bytes,
        first,
        after,
        limits,
      )
    end

    private def self.scan_type(
      bytes : Bytes,
      first : Int32,
      after : Int32,
      depth : Int32,
      limits : BinaryCodecLimits,
      totals : ObjectRecursiveDeclaration::ScanTotals,
      allow_declared_dynamic : Bool,
    ) : UInt64?
      totals.visit_node(depth, limits)
      if allow_declared_dynamic
        if dynamic = ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, first, after)
          return dynamic.byte_size.to_u64
        end
      end
      if leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after)
        totals.enum_metadata(leaf.enum_entry_count, leaf.decoded_label_bytes, depth, limits) if leaf.enum_entry_count > 0_u64
        totals.add_zone_bytes(leaf.explicit_zone_bytes)
        return leaf.byte_size.to_u64
      end

      if slice_equals?(bytes, first, first + "Array(".bytesize, "Array(") &&
         after > first + "Array()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        child_first = first + "Array(".bytesize
        child_after = after - 1
        return nil if child_first >= child_after
        totals.child_edge(limits)
        child_size = scan_type(bytes, child_first, child_after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
        return ObjectRecursiveDeclaration.checked_add("Array(".bytesize.to_u64 + 1_u64, child_size)
      end

      if slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(") &&
         after > first + "Nullable()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        child_first = first + "Nullable(".bytesize
        child_after = after - 1
        return nil if child_first >= child_after
        child_tag = tag_for_slice(bytes, child_first, child_after) || return nil
        return nil if child_tag == BinaryDataType::TAG_ARRAY || child_tag == BinaryDataType::TAG_MAP || child_tag == BinaryDataType::TAG_NULLABLE || child_tag == BinaryDataType::TAG_LOW_CARDINALITY || child_tag == BinaryDataType::TAG_VARIANT || child_tag == BinaryDataType::TAG_DYNAMIC
        totals.child_edge(limits)
        child_size = scan_type(bytes, child_first, child_after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
        return ObjectRecursiveDeclaration.checked_add("Nullable(".bytesize.to_u64 + 1_u64, child_size)
      end

      if slice_equals?(bytes, first, first + "LowCardinality(".bytesize, "LowCardinality(") &&
         after > first + "LowCardinality()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        child_first = first + "LowCardinality(".bytesize
        child_after = after - 1
        return nil if child_first >= child_after
        return nil unless admitted_low_cardinality_child_slice?(bytes, child_first, child_after)
        totals.child_edge(limits)
        child_size = scan_type(bytes, child_first, child_after, depth + 1, limits, totals, false) || return nil
        return ObjectRecursiveDeclaration.checked_add("LowCardinality(".bytesize.to_u64 + 1_u64, child_size)
      end

      if slice_equals?(bytes, first, first + "Variant(".bytesize, "Variant(") &&
         after > first + "Variant()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        body_first = first + "Variant(".bytesize
        body_after = after - 1
        variant_cursor = TopLevelCursor.new(bytes, body_first, body_after)
        current : Range? = variant_cursor.next_range
        return nil unless current
        previous : Range? = nil
        arm_count = 0
        total_size = "Variant(".bytesize.to_u64 + 1_u64
        while variant_arm_range = current
          arm_count += 1
          return nil if arm_count > BinaryVariantRoster::MAX_ARMS
          return nil unless admitted_variant_arm_slice?(bytes, variant_arm_range.first, variant_arm_range.after)
          if prior = previous
            return nil if compare_slices(bytes, prior.first, prior.after, variant_arm_range.first, variant_arm_range.after) >= 0
            total_size = ObjectRecursiveDeclaration.checked_add(total_size, 2_u64)
          end
          totals.child_edge(limits)
          arm_size = scan_type(bytes, variant_arm_range.first, variant_arm_range.after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
          total_size = ObjectRecursiveDeclaration.checked_add(total_size, arm_size)
          previous = variant_arm_range
          current = variant_cursor.next_range
          return nil unless variant_cursor.valid?
        end
        return nil if arm_count == 0
        return total_size
      end

      if slice_equals?(bytes, first, first + "Map(".bytesize, "Map(") &&
         after > first + "Map()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        body_first = first + "Map(".bytesize
        body_after = after - 1
        separator = top_level_separator(bytes, body_first, body_after) || return nil
        comma, second_comma = separator
        return nil if second_comma
        return nil unless slice_equals?(bytes, body_first, comma, "String")
        value_first = comma + 2
        return nil if value_first >= body_after
        totals.child_edge(limits)
        key_size = scan_type(bytes, body_first, comma, depth + 1, limits, totals, false) || return nil
        return nil unless key_size == "String".bytesize
        totals.child_edge(limits)
        value_size = scan_type(bytes, value_first, body_after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
        prefix_size = ObjectRecursiveDeclaration.checked_add("Map(".bytesize.to_u64, key_size)
        middle_size = ObjectRecursiveDeclaration.checked_add(", ".bytesize.to_u64, value_size)
        return ObjectRecursiveDeclaration.checked_add(ObjectRecursiveDeclaration.checked_add(prefix_size, middle_size), 1_u64)
      end

      if slice_equals?(bytes, first, first + "Tuple(".bytesize, "Tuple(") &&
         after >= first + "Tuple()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        body_first = first + "Tuple(".bytesize
        body_after = after - 1
        return "Tuple()".bytesize.to_u64 if body_first == body_after

        cursor = TopLevelCursor.new(bytes, body_first, body_after)
        first_range = cursor.next_range || return nil
        named_mode = ObjectTupleFieldName.prefix(bytes, first_range.first, first_range.after) != nil
        total_size = "Tuple(".bytesize.to_u64 + 1_u64
        field_count = 0_u64
        current_range : Range? = first_range
        while range = current_range
          if named_mode
            prefix = ObjectTupleFieldName.prefix(bytes, range.first, range.after) || return nil
            name_first, name_after, child_first = prefix
            decoded_size, rendered_size = ObjectTupleFieldName.shape(bytes, name_first, name_after) || return nil
            return nil if decoded_size == 0_u64 || ObjectTupleFieldName.null?(bytes, name_first, name_after)
            totals.tuple_metadata(1_u64, decoded_size, depth, limits)
            totals.child_edge(limits)
            child_size = scan_type(bytes, child_first, range.after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
            total_size = ObjectRecursiveDeclaration.checked_add(total_size, rendered_size)
            total_size = ObjectRecursiveDeclaration.checked_add(total_size, 1_u64)
            total_size = ObjectRecursiveDeclaration.checked_add(total_size, child_size)
          else
            return nil if ObjectTupleFieldName.prefix(bytes, range.first, range.after)
            totals.child_edge(limits)
            child_size = scan_type(bytes, range.first, range.after, depth + 1, limits, totals, allow_declared_dynamic) || return nil
            total_size = ObjectRecursiveDeclaration.checked_add(total_size, child_size)
          end
          total_size = ObjectRecursiveDeclaration.checked_add(total_size, 2_u64) if field_count > 0_u64
          field_count += 1_u64
          current_range = cursor.next_range
          return nil unless cursor.valid?
        end
        return total_size
      end

      nil
    end

    def self.account_slice(preflight : ObjectRecursiveDeclaration::Preflight, budget : BinaryCodecBudget) : Nil
      current = revalidate_preflight(preflight)
      account_admitted_slice(current, budget)
      nil
    end

    private def self.revalidate_preflight(preflight : ObjectRecursiveDeclaration::Preflight) : ObjectRecursiveDeclaration::Preflight
      current = preflight_slice(
        preflight.source,
        preflight.first,
        preflight.after,
        preflight.limits,
        preflight.root_depth,
      ) || raise ArgumentError.new("recursive Object declaration changed after preflight")
      unless ObjectRecursiveDeclaration.same_metrics?(current.metrics, preflight.metrics) &&
             current.first == preflight.first && current.after == preflight.after &&
             current.root_depth == preflight.root_depth
        raise ArgumentError.new("recursive Object declaration metadata changed after preflight")
      end
      current
    end

    private def self.account_admitted_slice(preflight : ObjectRecursiveDeclaration::Preflight, budget : BinaryCodecBudget) : Nil
      metrics = preflight.metrics
      total_edges = metrics.total_edge_count
      budget.preflight_children(total_edges) if total_edges > 0_u64
      charge_slice_nodes(preflight.source, preflight.first, preflight.after, preflight.root_depth, budget)
      budget.charge_wire_bytes(ObjectRecursiveDeclaration.checked_add(preflight.byte_size, 1_u64))
      budget.charge_wire_bytes(ObjectRecursiveDeclaration.checked_multiply(preflight.explicit_zone_bytes, 2_u64))
      budget.charge_wire_bytes(ObjectRecursiveDeclaration.checked_multiply(preflight.decoded_label_bytes, 2_u64))
      budget.charge_wire_bytes(ObjectRecursiveDeclaration.checked_multiply(preflight.tuple_name_bytes, 2_u64))
      nil
    end

    private def self.charge_slice_nodes(bytes : Bytes, first : Int32, after : Int32, depth : Int32, budget : BinaryCodecBudget) : Nil
      return nil if ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, first, after)
      if leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after)
        leaf.enum_entry_count.times { budget.visit_node(depth) }
        return nil
      end
      if slice_equals?(bytes, first, first + "Array(".bytesize, "Array(")
        prefix = "Array("
        charge_slice_child(bytes, first + prefix.bytesize, after - 1, depth, budget)
      elsif slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(")
        prefix = "Nullable("
        charge_slice_child(bytes, first + prefix.bytesize, after - 1, depth, budget)
      elsif slice_equals?(bytes, first, first + "LowCardinality(".bytesize, "LowCardinality(")
        prefix = "LowCardinality("
        charge_slice_child(bytes, first + prefix.bytesize, after - 1, depth, budget)
      elsif slice_equals?(bytes, first, first + "Map(".bytesize, "Map(")
        body_first = first + "Map(".bytesize
        body_after = after - 1
        comma, _ = top_level_separator(bytes, body_first, body_after).not_nil!
        charge_slice_child(bytes, body_first, comma, depth, budget)
        charge_slice_child(bytes, comma + 2, body_after, depth, budget)
      elsif slice_equals?(bytes, first, first + "Variant(".bytesize, "Variant(")
        variant_cursor = TopLevelCursor.new(bytes, first + "Variant(".bytesize, after - 1)
        while variant_arm_range = variant_cursor.next_range
          charge_slice_child(bytes, variant_arm_range.first, variant_arm_range.after, depth, budget)
        end
      else
        body_first = first + "Tuple(".bytesize
        body_after = after - 1
        return nil if body_first == body_after
        cursor = TopLevelCursor.new(bytes, body_first, body_after)
        while range = cursor.next_range
          if prefix = ObjectTupleFieldName.prefix(bytes, range.first, range.after)
            budget.visit_node(depth) # Tuple field-name metadata.
            charge_slice_child(bytes, prefix[2], range.after, depth, budget)
          else
            charge_slice_child(bytes, range.first, range.after, depth, budget)
          end
        end
      end
      nil
    end

    private def self.charge_slice_child(bytes : Bytes, first : Int32, after : Int32, depth : Int32, budget : BinaryCodecBudget) : Nil
      child_depth = depth + 1
      budget.visit_node(child_depth)
      charge_slice_nodes(bytes, first, after, child_depth, budget)
      nil
    end

    def self.validate_tuple_names(bytes : Bytes, first : Int32, after : Int32, depth : Int32, limits : BinaryCodecLimits) : Nil
      preflight_slice(bytes, first, after, limits, depth) ||
        raise UnsupportedFormatError.new("typed JSON schema admits only supported Object recursive types")
      validate_tuple_names_admitted(bytes, first, after, depth, limits)
      nil
    end

    private def self.validate_tuple_names_admitted(bytes : Bytes, first : Int32, after : Int32, depth : Int32, limits : BinaryCodecLimits) : Nil
      return nil if ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, first, after)
      return nil if ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after)
      if depth > limits.max_depth
        raise UnsupportedFormatError.new("binary codec depth limit exceeded")
      end
      if slice_equals?(bytes, first, first + "Array(".bytesize, "Array(")
        prefix = "Array("
        validate_tuple_names_admitted(bytes, first + prefix.bytesize, after - 1, depth + 1, limits)
      elsif slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(")
        prefix = "Nullable("
        validate_tuple_names_admitted(bytes, first + prefix.bytesize, after - 1, depth + 1, limits)
      elsif slice_equals?(bytes, first, first + "LowCardinality(".bytesize, "LowCardinality(")
        prefix = "LowCardinality("
        validate_tuple_names_admitted(bytes, first + prefix.bytesize, after - 1, depth + 1, limits)
      elsif slice_equals?(bytes, first, first + "Map(".bytesize, "Map(")
        body_first = first + "Map(".bytesize
        comma, _ = top_level_separator(bytes, body_first, after - 1).not_nil!
        validate_tuple_names_admitted(bytes, body_first, comma, depth + 1, limits)
        validate_tuple_names_admitted(bytes, comma + 2, after - 1, depth + 1, limits)
      elsif slice_equals?(bytes, first, first + "Variant(".bytesize, "Variant(")
        variant_cursor = TopLevelCursor.new(bytes, first + "Variant(".bytesize, after - 1)
        while variant_arm_range = variant_cursor.next_range
          validate_tuple_names_admitted(bytes, variant_arm_range.first, variant_arm_range.after, depth + 1, limits)
        end
      else
        body_first = first + "Tuple(".bytesize
        body_after = after - 1
        return nil if body_first == body_after
        cursor = TopLevelCursor.new(bytes, body_first, body_after)
        first_range = cursor.next_range || return nil
        named = ObjectTupleFieldName.prefix(bytes, first_range.first, first_range.after) != nil
        names = Set(String).new
        range : Range? = first_range
        while current = range
          if depth >= limits.max_depth
            raise UnsupportedFormatError.new("binary codec depth limit exceeded")
          end
          if named
            prefix = ObjectTupleFieldName.prefix(bytes, current.first, current.after) || return nil
            name_first, name_after, child_first = prefix
            name = ObjectTupleFieldName.decode(bytes, name_first, name_after)
            raise ArgumentError.new("duplicate Tuple field name") if names.includes?(name)
            names.add(name)
            validate_tuple_names_admitted(bytes, child_first, current.after, depth + 1, limits)
          else
            validate_tuple_names_admitted(bytes, current.first, current.after, depth + 1, limits)
          end
          range = cursor.next_range
          return nil unless cursor.valid?
        end
      end
      nil
    end

    def self.materialize_slice(bytes : Bytes, first : Int32, after : Int32, depth : Int32, limits : BinaryCodecLimits) : BinaryDataType
      preflight_slice(bytes, first, after, limits, depth) ||
        raise UnsupportedFormatError.new("typed JSON schema admits only supported Object recursive types")
      validate_tuple_names_admitted(bytes, first, after, depth, limits)
      materialize_admitted_slice(bytes, first, after, depth, limits, true)
    end

    def self.materialize_preflight(preflight : ObjectRecursiveDeclaration::Preflight) : BinaryDataType
      current = revalidate_preflight(preflight)
      validate_tuple_names_admitted(current.source, current.first, current.after, current.root_depth, current.limits)
      materialize_admitted_slice(current.source, current.first, current.after, current.root_depth, current.limits, true)
    end

    private def self.materialize_admitted_slice(
      bytes : Bytes,
      first : Int32,
      after : Int32,
      depth : Int32,
      limits : BinaryCodecLimits,
      allow_declared_dynamic : Bool,
    ) : BinaryDataType
      raise UnsupportedFormatError.new("binary codec depth limit exceeded") if depth > limits.max_depth
      if allow_declared_dynamic
        if dynamic = ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, first, after)
          return dynamic.materialize
        end
      end
      if leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after)
        return leaf.materialize
      end
      if slice_equals?(bytes, first, first + "Array(".bytesize, "Array(")
        BinaryDataType.array(materialize_admitted_slice(bytes, first + "Array(".bytesize, after - 1, depth + 1, limits, allow_declared_dynamic))
      elsif slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(")
        BinaryDataType.nullable(materialize_admitted_slice(bytes, first + "Nullable(".bytesize, after - 1, depth + 1, limits, allow_declared_dynamic))
      elsif slice_equals?(bytes, first, first + "LowCardinality(".bytesize, "LowCardinality(")
        BinaryDataType.low_cardinality(materialize_admitted_slice(bytes, first + "LowCardinality(".bytesize, after - 1, depth + 1, limits, false))
      elsif slice_equals?(bytes, first, first + "Map(".bytesize, "Map(")
        body_first = first + "Map(".bytesize
        comma, _ = top_level_separator(bytes, body_first, after - 1).not_nil!
        key = materialize_admitted_slice(bytes, body_first, comma, depth + 1, limits, false)
        value = materialize_admitted_slice(bytes, comma + 2, after - 1, depth + 1, limits, allow_declared_dynamic)
        BinaryDataType.map(key, value)
      elsif slice_equals?(bytes, first, first + "Variant(".bytesize, "Variant(")
        variant_cursor = TopLevelCursor.new(bytes, first + "Variant(".bytesize, after - 1)
        arms = Array(BinaryDataType).new
        while variant_arm_range = variant_cursor.next_range
          arms << materialize_admitted_slice(bytes, variant_arm_range.first, variant_arm_range.after, depth + 1, limits, allow_declared_dynamic)
        end
        BinaryDataType.variant_from_canonical_object_declaration(arms)
      else
        body_first = first + "Tuple(".bytesize
        body_after = after - 1
        return BinaryDataType.tuple([] of BinaryDataType) if body_first == body_after
        cursor = TopLevelCursor.new(bytes, body_first, body_after)
        first_range = cursor.next_range || raise ArgumentError.new("invalid Tuple declaration")
        named = ObjectTupleFieldName.prefix(bytes, first_range.first, first_range.after) != nil
        children = Array(BinaryDataType).new
        names = Array(String).new if named
        range : Range? = first_range
        while current = range
          if named
            name_first, name_after, child_first = ObjectTupleFieldName.prefix(bytes, current.first, current.after).not_nil!
            names.not_nil! << ObjectTupleFieldName.decode(bytes, name_first, name_after)
            children << materialize_admitted_slice(bytes, child_first, current.after, depth + 1, limits, allow_declared_dynamic)
          else
            children << materialize_admitted_slice(bytes, current.first, current.after, depth + 1, limits, allow_declared_dynamic)
          end
          range = cursor.next_range
        end
        BinaryDataType.tuple(children, names)
      end
    end

    private def self.top_level_separator(bytes : Bytes, first : Int32, after : Int32) : {Int32, Int32?}?
      cursor = TopLevelCursor.new(bytes, first, after)
      first_range = cursor.next_range || return nil
      separator = first_range.after
      return nil unless cursor.valid?
      return nil unless cursor.next_range
      extra_separator = cursor.next_range.try(&.after)
      return nil unless cursor.valid?
      {separator, extra_separator}
    end

    private def self.tag_for_slice(bytes : Bytes, first : Int32, after : Int32) : UInt8?
      if leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after)
        leaf.tag
      elsif slice_equals?(bytes, first, first + "Array(".bytesize, "Array(")
        BinaryDataType::TAG_ARRAY
      elsif slice_equals?(bytes, first, first + "Map(".bytesize, "Map(")
        BinaryDataType::TAG_MAP
      elsif slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(")
        BinaryDataType::TAG_NULLABLE
      elsif slice_equals?(bytes, first, first + "LowCardinality(".bytesize, "LowCardinality(")
        BinaryDataType::TAG_LOW_CARDINALITY
      elsif slice_equals?(bytes, first, first + "Variant(".bytesize, "Variant(")
        BinaryDataType::TAG_VARIANT
      elsif slice_equals?(bytes, first, first + "Tuple(".bytesize, "Tuple(")
        BinaryDataType::TAG_UNNAMED_TUPLE
      elsif ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, first, after)
        BinaryDataType::TAG_DYNAMIC
      else
        nil
      end
    end

    # A LowCardinality declaration may wrap only one Object scalar leaf, or
    # Nullable of that leaf. Resolve leaf metadata without materializing a
    # descriptor so the whole borrowed declaration remains preflight-only.
    private def self.admitted_low_cardinality_child_slice?(bytes : Bytes, first : Int32, after : Int32) : Bool
      if slice_equals?(bytes, first, first + "Nullable(".bytesize, "Nullable(") &&
         after > first + "Nullable()".bytesize && bytes[after - 1] == ')'.ord.to_u8
        leaf_first = first + "Nullable(".bytesize
        leaf_after = after - 1
        return false if leaf_first >= leaf_after
        leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, leaf_first, leaf_after) || return false
        ObjectRecursiveDeclaration.low_cardinality_leaf_tag_admitted?(leaf.tag)
      else
        leaf = ObjectTypedFieldType.resolve_leaf_slice(bytes, first, after) || return false
        ObjectRecursiveDeclaration.low_cardinality_leaf_tag_admitted?(leaf.tag)
      end
    end

    private def self.admitted_variant_arm_slice?(bytes : Bytes, first : Int32, after : Int32) : Bool
      tag = tag_for_slice(bytes, first, after) || return false
      return false if tag == BinaryDataType::TAG_NOTHING || tag == BinaryDataType::TAG_NULLABLE || tag == BinaryDataType::TAG_VARIANT || tag == BinaryDataType::TAG_DYNAMIC
      if tag == BinaryDataType::TAG_LOW_CARDINALITY
        child_first = first + "LowCardinality(".bytesize
        child_after = after - 1
        return false if tag_for_slice(bytes, child_first, child_after) == BinaryDataType::TAG_NULLABLE
      end
      true
    end

    private def self.compare_slices(bytes : Bytes, left_first : Int32, left_after : Int32, right_first : Int32, right_after : Int32) : Int32
      left_size = left_after - left_first
      right_size = right_after - right_first
      shared_size = Math.min(left_size, right_size)
      index = 0
      while index < shared_size
        left = bytes[left_first + index]
        right = bytes[right_first + index]
        return -1 if left < right
        return 1 if left > right
        index += 1
      end
      return -1 if left_size < right_size
      return 1 if left_size > right_size
      0
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected.to_slice.each_with_index.all? { |byte, index| bytes[first + index] == byte }
    end
  end
end
