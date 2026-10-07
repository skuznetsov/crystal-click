module CrystalClick
  # Immutable owner for one flattened structured-JSON row. Typed paths are
  # required explicitly; runtime Nothing NULLs are normalized to absence.
  # This is scalar RowBinary state, not persisted Object/MergeTree storage.
  class BinaryJsonRow
    getter type : BinaryDataType

    @entries : Array(Tuple(String, BinaryValue))

    def initialize(
      type : BinaryDataType,
      values : Array(Tuple(String, BinaryValue)),
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    )
      @type = type
      @entries = build_entries(type, values, BinaryCodecBudget.new(limits, true), 1)
    end

    def initialize(
      type : BinaryDataType,
      values : Array(Tuple(String, BinaryValue)),
      budget : BinaryCodecBudget,
      depth : Int = 1,
    )
      @type = type
      @entries = build_entries(type, values, budget, depth)
    end

    private def build_entries(
      type : BinaryDataType,
      values : Array(Tuple(String, BinaryValue)),
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Array(Tuple(String, BinaryValue))
      unless type.tag == BinaryDataType::TAG_JSON
        raise ArgumentError.new("JSON row requires a root JSON descriptor")
      end
      descriptor = type.json_type.not_nil!
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.validate_type_tree(type, depth)
      context.visit_node(depth) # structured row root
      count = values.size.to_u64
      checked_count = context.checked_count(count, "JSON row path count")
      context.preflight_children(count) if count > 0_u64
      context.visit_metadata_nodes(count, depth) if count > 0_u64
      context.preflight_children(count) if count > 0_u64
      context.ensure_depth(depth + 1) if count > 0_u64

      seen = Set(String).new
      supplied_typed = Set(String).new

      # Validate the complete roster against one budget before allocating any
      # retained path/value records. The caller's rows and values are borrowed
      # read-only during this pass.
      values.each do |path, value|
        BinaryJsonType.validate_path!(path)
        unless seen.add?(path)
          raise ArgumentError.new("JSON row contains a duplicate raw path")
        end
        context.budget.charge_wire_bytes(BinaryJsonType.path_wire_size(path.bytesize.to_u64))

        if declared = descriptor.typed_type_for(path)
          # Exact structural equality can itself recursively inspect an
          # untrusted caller-owned graph. The root descriptor covers a shared
          # declared type; a distinct graph must be bounded first.
          context.validate_type_tree(value.type, depth + 1) unless value.type.same?(declared)
          unless value.type == declared
            raise ArgumentError.new("JSON typed path value does not match its exact declared type")
          end
          supplied_typed.add(path)
        else
          context.validate_type_tree(value.type, depth + 1)
          if value.type.tag == BinaryDataType::TAG_NOTHING
            unless value.is_null?
              raise ArgumentError.new("JSON runtime Nothing value must be NULL")
            end
          else
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              raise ArgumentError.new("top-level Nullable is outside the admitted JSON runtime-value profile")
            end
            # Bound traversal before recursively inspecting a caller-owned
            # graph. The closed grammar check below must not multiply work on
            # a wide/deep shared DAG before the operation limits can reject it.
            begin
              BinaryJsonType.validate_runtime_type!(value.type)
            rescue ex : ArgumentError
              raise ArgumentError.new("JSON runtime value type is outside the admitted scalar/container profile")
            end
          end
        end
        preflight_value_tree!(value, context, depth + 1)
      end

      descriptor.typed_path_count.times do |index|
        path = descriptor.typed_path_at(index)
        unless supplied_typed.includes?(path)
          raise ArgumentError.new("JSON row is missing an explicitly declared typed path")
        end
      end
      entries = Array(Tuple(String, BinaryValue)).new(checked_count)
      values.each do |path, value|
        # Keep typed Nullable(NULL), but omit only the untyped Nothing sentinel.
        next if descriptor.typed_type_for(path).nil? && value.type.tag == BinaryDataType::TAG_NOTHING
        entries << {String.new(path.to_slice), value}
      end
      entries.sort! { |left, right| left[0] <=> right[0] }
      entries
    end

    # Charge this immutable row's descriptor, path metadata, and complete
    # value subtree to a caller-owned bridge operation before that bridge
    # copies any path names. This is accounting/preflight only: it neither
    # constructs another row nor materializes retained path strings.
    def preflight_for_object!(budget : BinaryCodecBudget, depth : Int = 1) : Nil
      unless @type.tag == BinaryDataType::TAG_JSON
        raise ArgumentError.new("JSON row requires a root JSON descriptor")
      end
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.validate_type_tree(@type, depth)
      context.visit_node(depth)

      count = @entries.size.to_u64
      context.checked_count(count, "JSON row path count")
      if count > 0_u64
        context.preflight_children(count)
        context.visit_metadata_nodes(count, depth)
        context.preflight_children(count)
        context.ensure_depth(depth + 1)
      end

      path_wire_bytes = 0_u64
      @entries.each_with_index do |entry, index|
        next_bytes = BinaryJsonType.path_wire_size(path_byte_size(index).to_u64)
        if path_wire_bytes > UInt64::MAX - next_bytes
          context.unsupported!("JSON row path metadata size overflows UInt64")
        end
        path_wire_bytes += next_bytes
      end
      context.budget.charge_wire_bytes(path_wire_bytes) if path_wire_bytes > 0_u64

      descriptor = @type.json_type.not_nil!
      @entries.each_with_index do |entry, index|
        value = entry[1]
        declared = typed_type_for_path_bytes(descriptor, index)
        if declared
          context.validate_type_tree(value.type, depth + 1) unless value.type.same?(declared)
        else
          context.validate_type_tree(value.type, depth + 1)
        end
        preflight_value_tree!(value, context, depth + 1)
      end
      nil
    end

    def path_count : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    def path_at(index : Int) : String
      String.new(@entries[index][0].to_slice)
    end

    def path_byte_size(index : Int) : Int32
      @entries[index][0].bytesize
    end

    def path_byte_at(index : Int, byte_index : Int) : UInt8
      @entries[index][0].to_slice[byte_index]
    end

    def value_at(index : Int) : BinaryValue
      @entries[index][1]
    end

    def value_for(path : String) : BinaryValue?
      index = lower_bound(path)
      return nil if index >= @entries.size || @entries[index][0] != path
      @entries[index][1]
    end

    def entries : Array(Tuple(String, BinaryValue))
      @entries.map { |entry| {String.new(entry[0].to_slice), entry[1]} }
    end

    def ==(other : BinaryJsonRow) : Bool
      return false unless @type == other.@type && @entries.size == other.@entries.size
      @entries.each_with_index do |entry, index|
        other_entry = other.@entries[index]
        return false unless entry[0] == other_entry[0] && entry[1] == other_entry[1]
      end
      true
    end

    def hash(hasher)
      hasher = @type.hash(hasher)
      @entries.hash(hasher)
    end

    private def lower_bound(path : String) : Int32
      low = 0
      high = @entries.size
      while low < high
        middle = low + (high - low) // 2
        if @entries[middle][0] < path
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end

    private def preflight_value_tree!(value : BinaryValue, context : BinaryCodecContext, depth : Int) : Nil
      context.visit_node(depth)
      type = value.type
      if type.tag == BinaryDataType::TAG_JSON
        row = value.json_row
        descriptor = type.json_type || context.unsupported!("JSON descriptor metadata is missing")
        count = row.path_count.to_u64
        if count > 0_u64
          context.preflight_children(count) # flattened path metadata records
          context.visit_metadata_nodes(count, depth)
          context.preflight_children(count) # one value edge per path
          context.ensure_depth(depth + 1)

          # Bound the complete nested path roster before any bridge materializes
          # retained-name copies. Values are immutable, so this pass can inspect
          # byte sizes without escaping the row owner.
          path_wire_bytes = 0_u64
          row.path_count.times do |index|
            next_bytes = BinaryJsonType.path_wire_size(row.path_byte_size(index).to_u64)
            if path_wire_bytes > UInt64::MAX - next_bytes
              context.unsupported!("JSON row path metadata size overflows UInt64")
            end
            path_wire_bytes += next_bytes
          end
          context.budget.charge_wire_bytes(path_wire_bytes)
        end

        row.path_count.times do |index|
          child = row.value_at(index)
          declared = typed_type_for_path_bytes(descriptor, row, index)
          if declared
            context.validate_type_tree(child.type, depth + 1) unless child.type.same?(declared)
            unless child.type == declared
              context.unsupported!("JSON typed path value does not match its exact declared type")
            end
          else
            # Typed child descriptors were traversed from the enclosing JSON
            # type tree. Untyped paths carry an inline runtime descriptor and
            # must consume this same budget at the row's rebased depth.
            context.validate_type_tree(child.type, depth + 1)
            unless child.type.tag == BinaryDataType::TAG_NOTHING
              begin
                BinaryJsonType.validate_runtime_type!(child.type)
              rescue ex : ArgumentError
                raise ArgumentError.new("JSON runtime value type is outside the admitted scalar/container profile")
              end
            end
          end
          preflight_value_tree!(child, context, depth + 1)
        end
        return nil
      end

      if type.tag == BinaryDataType::TAG_DYNAMIC
        if value.is_null?
          # A NULL Dynamic still carries the descriptor-only Nothing sentinel.
          context.preflight_children(1_u64)
          context.validate_type_tree(BinaryDataType.primitive("Nothing"), depth + 1)
        else
          selected = value.child_at(0)
          context.preflight_children(1_u64) # inline actual-type descriptor
          context.validate_type_tree(selected.type, depth + 1)
          begin
            BinaryJsonType.validate_runtime_type!(selected.type)
          rescue ex : ArgumentError
            raise ArgumentError.new("JSON Dynamic actual type is outside the admitted runtime profile")
          end
          context.preflight_children(1_u64) # selected actual value
          context.ensure_depth(depth + 1)
          preflight_value_tree!(selected, context, depth + 1)
        end
        return nil
      end

      count = case type.tag
              when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_UNNAMED_TUPLE,
                   BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP,
                   BinaryDataType::TAG_NESTED
                value.element_count
              when BinaryDataType::TAG_NULLABLE
                value.is_null? ? 0 : value.element_count
              when BinaryDataType::TAG_LOW_CARDINALITY,
                   BinaryDataType::TAG_SIMPLE_AGGREGATE
                value.element_count
              when BinaryDataType::TAG_VARIANT
                value.is_null? ? 0 : 1
              when BinaryDataType::TAG_NOTHING
                0
              else
                0
              end
      if count > 0
        context.preflight_children(count.to_u64)
        context.ensure_depth(depth + 1)
        count.times do |index|
          preflight_value_tree!(value.element_at(index), context, depth + 1)
        end
      end
      nil
    end

    private def typed_type_for_path_bytes(descriptor : BinaryJsonType, index : Int) : BinaryDataType?
      typed_type_for_path_bytes(descriptor, self, index)
    end

    private def typed_type_for_path_bytes(
      descriptor : BinaryJsonType,
      row : BinaryJsonRow,
      row_index : Int,
    ) : BinaryDataType?
      low = 0
      high = descriptor.typed_path_count
      while low < high
        middle = low + (high - low) // 2
        comparison = compare_row_path_to_typed_path(row, row_index, descriptor, middle)
        if comparison > 0
          low = middle + 1
        elsif comparison < 0
          high = middle
        else
          return descriptor.typed_type_at(middle)
        end
      end
      nil
    end

    private def compare_row_path_to_typed_path(
      row : BinaryJsonRow,
      row_index : Int,
      descriptor : BinaryJsonType,
      typed_index : Int,
    ) : Int32
      row_size = row.path_byte_size(row_index)
      typed_size = descriptor.typed_path_byte_size(typed_index)
      common_size = Math.min(row_size, typed_size)
      common_size.times do |byte_index|
        row_byte = row.path_byte_at(row_index, byte_index)
        typed_byte = descriptor.typed_path_byte_at(typed_index, byte_index)
        return -1 if row_byte < typed_byte
        return 1 if row_byte > typed_byte
      end
      row_size <=> typed_size
    end
  end
end
