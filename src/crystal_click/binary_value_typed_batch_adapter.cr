module CrystalClick
  # Converts values produced by the recursive Compact BinaryBulk decoder into
  # the exact legacy typed carriers already exposed by WidePartTableBatch.
  # Generic-static declarations retain the existing strict BinaryValue route;
  # legacy-only declarations are admitted here only when an exact carrier
  # conversion is implemented below.
  module BinaryValueTypedBatchAdapter
    private CARRIER_NODE_ACCOUNTING_BYTES  =  128_u64
    private CARRIER_BASE_ACCOUNTING_BYTES  = 1024_u64
    private CARRIER_STRING_COPY_MULTIPLIER =    3_u64

    def self.admitted?(type : BinaryDataType) : Bool
      type_name = type.name
      return true if WidePart.supports_generic_static_binary_bulk_type?(type_name)
      return true if type_name == "UInt64" || type_name == "String" ||
                     type_name == "Nullable(UInt64)" ||
                     type_name == "Array(Nullable(UInt64))" ||
                     type_name == "LowCardinality(String)" ||
                     type_name == WideVariantStringUInt64TypePlan::TYPE ||
                     type_name == "Map(String, UInt64)" ||
                     type_name == "Map(String, Array(Nullable(UInt64)))"
      return true if type_name == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING

      if tuple_plan = WideTupleTypePlan.for_type(type_name)
        return supported_tuple_leaves?(tuple_plan)
      end

      if array_tuple_plan = WideArrayTupleTypePlan.for_type(type_name)
        # These exact W51/W55 profiles have established specialized carriers;
        # only the UInt64/String carrier is converted above. Do not admit the
        # others through generic row handles, whose installer rejects them.
        return false if WideTypePlan.admitted(type_name)
        return supported_tuple_leaves?(array_tuple_plan.tuple_plan)
      end

      false
    rescue ex : ArgumentError | BoundsError | UnsupportedFormatError
      false
    end

    # Conservative descriptor-directed logical charge for carrier storage
    # created by #install. The decoded BinaryValue tree is owned and charged by
    # the Compact decoder separately. This adds container/slot overhead and
    # accounts up to three copies of String payload bytes, covering temporary
    # conversion arrays and the existing Tuple leaf-copy constructors.
    # `nil` means unsupported shape or arithmetic overflow and must fail closed.
    def self.estimated_materialization_bytes(type : BinaryDataType, values : Slice(BinaryValue)) : UInt64?
      return 0_u64 if WidePart.supports_generic_static_binary_bulk_type?(type.name)
      return nil unless admitted?(type)

      nodes = 0_u64
      string_bytes = 0_u64
      values.each do |value|
        return nil unless value.type == type
        metrics = value_metrics(value, 0)
        return nil unless metrics
        node_count, payload_bytes = metrics
        return nil if node_count > UInt64::MAX - nodes
        nodes += node_count
        return nil if payload_bytes > UInt64::MAX - string_bytes
        string_bytes += payload_bytes
      end

      node_charge = checked_multiply(nodes, CARRIER_NODE_ACCOUNTING_BYTES) || return nil
      string_charge = checked_multiply(string_bytes, CARRIER_STRING_COPY_MULTIPLIER) || return nil
      total = CARRIER_BASE_ACCOUNTING_BYTES
      return nil if node_charge > UInt64::MAX - total
      total += node_charge
      return nil if string_charge > UInt64::MAX - total
      total += string_charge
      total
    rescue ex : ArgumentError | BoundsError | UnsupportedFormatError
      nil
    end

    def self.install(
      batch : WidePartTableBatch,
      column : String,
      type : BinaryDataType,
      values : Slice(BinaryValue),
      expected_rows : Int32,
    ) : Nil
      raise CorruptPartError.new("typed Compact carrier row count is negative") if expected_rows < 0
      type_name = type.name
      unless batch.column_type_for(column) == type_name
        raise CorruptPartError.new("typed Compact value descriptor differs from selected column")
      end
      raise CorruptPartError.new("typed Compact carrier row count mismatch") unless values.size == expected_rows
      values.each do |value|
        raise CorruptPartError.new("typed Compact BinaryValue differs from selected column type") unless value.type == type
      end

      # Keep generic static values on their established installer. Do not
      # widen its type gate to make legacy-only columns appear generic.
      if WidePart.supports_generic_static_binary_bulk_type?(type_name)
        batch.install_binary_bulk_values(column, values, expected_rows)
        return nil
      end

      case type_name
      when "UInt64"
        converted = Array(UInt64).new(values.size) { |index| values[index].as_uint64 }
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "String", "LowCardinality(String)"
        converted = Array(String).new(values.size) do |index|
          value = values[index]
          if type_name == "String"
            value.as_string
          else
            unless value.child_count == 1 && value.child_at(0).type == type.child_at(0)
              raise CorruptPartError.new("Compact LowCardinality(String) row has an invalid nested value")
            end
            value.child_at(0).as_string
          end
        end
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_string_values(column, type_name, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "Nullable(UInt64)"
        converted = Array(UInt64?).new(values.size) { |index| nullable_uint64(values[index]) }
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_nullable_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "Array(Nullable(UInt64))"
        converted = Array(Array(UInt64?)).new(values.size) do |index|
          array_nullable_uint64(values[index], type)
        end
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_array_nullable_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when WideVariantStringUInt64TypePlan::TYPE
        converted = Array(VariantStringUInt64Value).new(values.size) do |index|
          variant_string_uint64(values[index], type)
        end
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_variant_string_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "Tuple(a UInt64, b String)"
        converted = tuple_uint64_string_values(values, type)
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_tuple_uint64_string_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
        converted = array_tuple_uint64_string_values(values, type)
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_array_tuple_uint64_string_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "Map(String, Array(Nullable(UInt64)))"
        converted = Array(Array(Tuple(String, Array(UInt64?)))).new(values.size) do |index|
          map_string_array_nullable_uint64(values[index], type)
        end
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_map_string_array_nullable_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      when "Map(String, UInt64)"
        converted = Array(Array(Tuple(String, UInt64))).new(values.size) do |index|
          map_string_uint64(values[index], type)
        end
        batch.retain_binary_value_typed_owner(converted)
        batch.install_compact_map_string_uint64_values(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
      else
        if tuple_plan = WideTupleTypePlan.for_type(type_name)
          converted = tuple_rows(tuple_plan, type, values)
          batch.retain_binary_value_typed_owner(converted)
          batch.install_compact_tuple_rows(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
        elsif array_tuple_plan = WideArrayTupleTypePlan.for_type(type_name)
          converted = array_tuple_rows(array_tuple_plan, type, values)
          batch.retain_binary_value_typed_owner(converted)
          batch.install_compact_array_tuple_rows(column, Slice.new(converted.to_unsafe, converted.size), expected_rows)
        else
          raise UnsupportedFormatError.new("Compact typed carrier has no exact legacy materializer")
        end
      end
      nil
    end

    private def self.supported_tuple_leaves?(plan : WideTupleTypePlan) : Bool
      return false if plan.field_count == 0
      plan.fields.all? do |field|
        case field.type_name
        when "String", "UInt64", "Nullable(UInt64)"
          true
        else
          false
        end
      end
    end

    private def self.value_metrics(value : BinaryValue, depth : Int32) : Tuple(UInt64, UInt64)?
      return nil if depth > BinaryBulkCodec::DEFAULT_LIMITS.max_depth
      node_count = 1_u64
      string_bytes = value.type.tag == BinaryDataType::TAG_STRING ? value.byte_size.to_u64 : 0_u64
      value.child_count.times do |index|
        child_metrics = value_metrics(value.child_at(index), depth + 1) || return nil
        child_nodes, child_bytes = child_metrics
        return nil if child_nodes > UInt64::MAX - node_count
        node_count += child_nodes
        return nil if child_bytes > UInt64::MAX - string_bytes
        string_bytes += child_bytes
      end
      {node_count, string_bytes}
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64?
      return nil if right != 0_u64 && left > UInt64::MAX // right
      left * right
    end

    private def self.nullable_uint64(value : BinaryValue) : UInt64?
      unless value.type.name == "Nullable(UInt64)"
        raise CorruptPartError.new("Compact nullable UInt64 value has a different type")
      end
      return nil if value.is_null?
      unless value.child_count == 1 && value.child_at(0).type.name == "UInt64"
        raise CorruptPartError.new("Compact non-NULL Nullable(UInt64) has an invalid child")
      end
      value.child_at(0).as_uint64
    end

    private def self.array_nullable_uint64(value : BinaryValue, type : BinaryDataType) : Array(UInt64?)
      unless value.type == type && value.type.tag == BinaryDataType::TAG_ARRAY &&
             type.child_at(0).name == "Nullable(UInt64)"
        raise CorruptPartError.new("Compact Array(Nullable(UInt64)) has an invalid descriptor")
      end
      Array(UInt64?).new(value.element_count) do |index|
        nullable_uint64(value.element_at(index))
      end
    end

    private def self.variant_string_uint64(value : BinaryValue, type : BinaryDataType) : VariantStringUInt64Value
      unless value.type == type && type.name == WideVariantStringUInt64TypePlan::TYPE
        raise CorruptPartError.new("Compact Variant(String, UInt64) has an invalid descriptor")
      end
      return nil if value.is_null?
      index = value.variant_index? || raise(CorruptPartError.new("non-NULL Compact Variant has no arm index"))
      child = value.variant_child? || raise(CorruptPartError.new("non-NULL Compact Variant has no arm value"))
      raise CorruptPartError.new("Compact Variant discriminator is outside the declared arm roster") if index.to_i >= type.child_count
      raise CorruptPartError.new("Compact Variant arm value type differs from its index") unless child.type == type.child_at(index.to_i)
      case index
      when 0_u8
        child.as_string
      when 1_u8
        child.as_uint64
      else
        raise CorruptPartError.new("Compact Variant discriminator is outside the admitted arm roster")
      end
    end

    private def self.tuple_uint64_string_values(
      values : Slice(BinaryValue),
      type : BinaryDataType,
    ) : Array(Tuple(UInt64, String))
      unless WidePart.supports_tuple_uint64_string_type?(type.name) && type.tag == BinaryDataType::TAG_NAMED_TUPLE && type.child_count == 2
        raise CorruptPartError.new("Compact Tuple(UInt64, String) has an invalid descriptor")
      end
      Array(Tuple(UInt64, String)).new(values.size) do |index|
        row = values[index]
        unless row.type == type && row.child_count == 2
          raise CorruptPartError.new("Compact Tuple(UInt64, String) row has an invalid shape")
        end
        uint64_value = row.child_at(0)
        string_value = row.child_at(1)
        unless uint64_value.type == type.child_at(0) && string_value.type == type.child_at(1)
          raise CorruptPartError.new("Compact Tuple(UInt64, String) child differs from its declaration")
        end
        {uint64_value.as_uint64, string_value.as_string}
      end
    end

    private def self.array_tuple_uint64_string_values(
      values : Slice(BinaryValue),
      type : BinaryDataType,
    ) : Array(Array(Tuple(UInt64, String)))
      unless type.name == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING && type.tag == BinaryDataType::TAG_ARRAY
        raise CorruptPartError.new("Compact Array(Tuple(UInt64, String)) has an invalid descriptor")
      end
      tuple_type = type.child_at(0)
      unless tuple_type.tag == BinaryDataType::TAG_NAMED_TUPLE && tuple_type.child_count == 2
        raise CorruptPartError.new("Compact Array(Tuple(UInt64, String)) has an invalid Tuple descriptor")
      end
      Array(Array(Tuple(UInt64, String))).new(values.size) do |index|
        row = values[index]
        unless row.type == type && row.type.tag == BinaryDataType::TAG_ARRAY
          raise CorruptPartError.new("Compact Array(Tuple(UInt64, String)) row has an invalid shape")
        end
        Array(Tuple(UInt64, String)).new(row.element_count) do |element_index|
          tuple = row.element_at(element_index)
          unless tuple.type == tuple_type && tuple.child_count == 2
            raise CorruptPartError.new("Compact Array(Tuple(UInt64, String)) element has an invalid shape")
          end
          uint64_value = tuple.child_at(0)
          string_value = tuple.child_at(1)
          unless uint64_value.type == tuple_type.child_at(0) && string_value.type == tuple_type.child_at(1)
            raise CorruptPartError.new("Compact Array(Tuple(UInt64, String)) child differs from its declaration")
          end
          {uint64_value.as_uint64, string_value.as_string}
        end
      end
    end

    private def self.map_string_array_nullable_uint64(value : BinaryValue, type : BinaryDataType) : Array(Tuple(String, Array(UInt64?)))
      unless value.type == type && type.name == "Map(String, Array(Nullable(UInt64)))"
        raise CorruptPartError.new("Compact Map(String, Array(Nullable(UInt64))) has an invalid descriptor")
      end
      raise CorruptPartError.new("Compact Map value has an incomplete key/value pair") unless value.element_count.even?
      entries = Array(Tuple(String, Array(UInt64?))).new(value.element_count // 2)
      index = 0
      while index < value.element_count
        key = value.element_at(index)
        child_array = value.element_at(index + 1)
        raise CorruptPartError.new("Compact Map key is not String") unless key.type.name == "String"
        entries << {key.as_string, array_nullable_uint64(child_array, type.child_at(1))}
        index += 2
      end
      entries
    end

    private def self.map_string_uint64(value : BinaryValue, type : BinaryDataType) : Array(Tuple(String, UInt64))
      unless value.type == type && type.name == "Map(String, UInt64)" &&
             type.tag == BinaryDataType::TAG_MAP && type.child_count == 2
        raise CorruptPartError.new("Compact Map(String, UInt64) has an invalid descriptor")
      end
      key_type = type.child_at(0)
      value_type = type.child_at(1)
      unless key_type.name == "String" && key_type.tag == BinaryDataType::TAG_STRING &&
             value_type.name == "UInt64" && value_type.tag == BinaryDataType::TAG_UINT64
        raise CorruptPartError.new("Compact Map(String, UInt64) has invalid key/value types")
      end
      unless value.element_count.even?
        raise CorruptPartError.new("Compact Map value has an incomplete key/value pair")
      end

      entries = Array(Tuple(String, UInt64)).new(value.element_count // 2)
      index = 0
      while index < value.element_count
        key = value.element_at(index)
        mapped_value = value.element_at(index + 1)
        unless key.type == key_type && mapped_value.type == value_type
          raise CorruptPartError.new("Compact Map entry differs from its exact key/value declaration")
        end
        entries << {key.as_string, mapped_value.as_uint64}
        index += 2
      end
      entries
    end

    private def self.tuple_rows(
      plan : WideTupleTypePlan,
      type : BinaryDataType,
      values : Slice(BinaryValue),
    ) : Array(WideTupleRow)
      tuple_data = tuple_column_data(plan, type, values)
      Array(WideTupleRow).new(values.size) { |index| tuple_data.row(index) }
    end

    private def self.array_tuple_rows(
      plan : WideArrayTupleTypePlan,
      type : BinaryDataType,
      values : Slice(BinaryValue),
    ) : Array(WideArrayTupleRow)
      tuple_type = type.child_at(0)
      flat_values = [] of BinaryValue
      row_sizes = Array(UInt64).new(values.size)
      values.each do |row|
        unless row.type == type && row.type.tag == BinaryDataType::TAG_ARRAY
          raise CorruptPartError.new("Compact Array(Tuple) row has an invalid descriptor")
        end
        row_sizes << row.element_count.to_u64
        row.element_count.times do |index|
          flat_values << row.element_at(index)
        end
      end
      flat_slice = Slice.new(flat_values.to_unsafe, flat_values.size)
      tuple_data = tuple_column_data(plan.tuple_plan, tuple_type, flat_slice)
      array_data = WideArrayTupleColumnData.new(plan, row_sizes, tuple_data)
      Array(WideArrayTupleRow).new(values.size) { |index| array_data.row(index) }
    end

    private def self.tuple_column_data(
      plan : WideTupleTypePlan,
      tuple_type : BinaryDataType,
      rows : Slice(BinaryValue),
    ) : WideTupleColumnData
      columns = Array(WideTupleLeafColumn).new(plan.field_count)
      plan.fields.each do |field|
        case field.type_name
        when "String"
          leaf_values = Array(String).new(rows.size) do |index|
            tuple_path_value(rows[index], tuple_type, field.path_segments).as_string
          end
          columns << WideTupleLeafColumn.new(field.name, leaf_values)
        when "UInt64"
          leaf_values = Array(UInt64).new(rows.size) do |index|
            tuple_path_value(rows[index], tuple_type, field.path_segments).as_uint64
          end
          columns << WideTupleLeafColumn.new(field.name, leaf_values)
        when "Nullable(UInt64)"
          physical_values = Array(UInt64).new(rows.size, 0_u64)
          null_flags = Array(UInt8).new(rows.size, 0_u8)
          rows.each_with_index do |row, index|
            field_value = tuple_path_value(row, tuple_type, field.path_segments)
            nullable = nullable_uint64(field_value)
            if child = nullable
              physical_values[index] = child
            else
              null_flags[index] = 1_u8
            end
          end
          null_map = ScalarNullMap.new(Bytes.new(null_flags.size) { |index| null_flags[index] }, rows.size.to_u64)
          columns << WideTupleLeafColumn.new(field.name, field.leaf_type, physical_values, null_map)
        else
          raise UnsupportedFormatError.new("Compact Tuple leaf has no exact legacy carrier")
        end
      end
      WideTupleColumnData.new(plan, columns)
    end

    private def self.tuple_path_value(
      value : BinaryValue,
      tuple_type : BinaryDataType,
      path : Array(String),
    ) : BinaryValue
      raise CorruptPartError.new("Compact Tuple row differs from its declared type") unless value.type == tuple_type
      current_value = value
      current_type = tuple_type
      path.each do |segment|
        unless current_type.tag == BinaryDataType::TAG_NAMED_TUPLE
          raise CorruptPartError.new("Compact Tuple path descends through a non-Tuple node")
        end
        child_index = -1
        current_type.child_count.times do |index|
          if current_type.field_name_at(index) == segment
            child_index = index
            break
          end
        end
        raise CorruptPartError.new("Compact Tuple field is missing from its declaration") if child_index < 0
        current_value = current_value.child_at(child_index)
        current_type = current_type.child_at(child_index)
      end
      raise CorruptPartError.new("Compact Tuple field value differs from its declaration") unless current_value.type == current_type
      current_value
    end
  end
end
