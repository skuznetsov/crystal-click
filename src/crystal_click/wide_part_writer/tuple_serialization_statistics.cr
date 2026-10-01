module CrystalClick
  module WidePartWriter
    # Builds ClickHouse's recursive Tuple SerializationInfo from one owned
    # snapshot of each physical leaf. Leaf order is supplied by the plan; the
    # schema tree, never a dotted name, determines the recursive structure.
    private class TupleSerializationStatistics
      def self.build(
        key_name : String,
        keys : Array(UInt64),
        value_name : String,
        plan : WideTupleTypePlan,
        leaf_buffers : Array(WideTupleLeafColumn::Buffer),
        leaf_null_maps : Array(Array(UInt8)?),
        fields : Array(WideTupleField),
      ) : String
        unless leaf_buffers.size == fields.size && leaf_null_maps.size == fields.size
          raise ArgumentError.new("Tuple statistics inputs do not match the leaf plan")
        end

        rows = keys.size
        root_fields = plan.root_fields
        nodes = [] of TupleSerializationNodeStatistics
        top_nodes = [] of TupleSerializationNodeStatistics
        next_leaf_index = 0
        root_fields.each do |field|
          node, next_leaf_index = append_node(field, nodes, next_leaf_index)
          top_nodes << node
        end
        unless next_leaf_index == fields.size
          raise ArgumentError.new("Tuple schema tree does not match its flattened leaf plan")
        end

        fields.each_with_index do |field, index|
          if field.leaf_type.nullable?
            raise ArgumentError.new("Nullable Tuple statistics require a null map") unless leaf_null_maps[index]
          elsif leaf_null_maps[index]
            raise ArgumentError.new("non-Nullable Tuple statistics cannot have a null map")
          end

          if WideTupleTemporalType.width(field.type_name)
            temporal_buffer = leaf_buffers[index].as?(WideTupleTemporalType::Buffer) ||
                              raise ArgumentError.new("Tuple temporal buffer does not match declared field type")
            WideTupleTemporalType.validate_buffer!(field.type_name, temporal_buffer)
          end
        end

        leaf_defaults = Array(Bool).new(fields.size, false)
        node_defaults = Array(Bool).new(nodes.size, false)
        payload_default_count = 0
        rows.times do |row|
          fields.each_with_index do |field, index|
            leaf_defaults[index] = if field.leaf_type.nullable?
                                     # ClickHouse Nullable defaults are nulls;
                                     # masked physical payload is intentionally
                                     # irrelevant to both leaf and Tuple stats.
                                     leaf_null_maps[index].not_nil![row] == 1_u8
                                   else
                                     leaf_default_at(leaf_buffers[index], row)
                                   end
          end

          nodes.each do |node|
            is_default = if leaf_index = node.leaf_index
                           leaf_defaults[leaf_index]
                         else
                           node.children.all? { |child| node_defaults[child.index] }
                         end
            node_defaults[node.index] = is_default
            node.record_default if is_default
          end
          payload_default_count += 1 if top_nodes.all? { |node| node_defaults[node.index] }
        end

        key_record = "{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{keys.count(&.zero?)},\"num_rows\":#{rows}}"
        subcolumns = top_nodes.map { |node| node_record(node, rows) }.join(",")
        payload_record = "{\"kind\":\"Default\",\"name\":\"#{value_name}\",\"num_defaults\":#{payload_default_count},\"num_rows\":#{rows},\"subcolumns\":[#{subcolumns}]}"
        records = [{key_name, key_record}, {value_name, payload_record}].sort_by(&.[0])

        String.build do |json|
          json << "{\"columns\":["
          json << records.map(&.[1]).join(",")
          json << "],\"propagate_types_serialization_versions_to_nested_types\":true,"
          json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        end
      end

      private def self.append_node(
        schema_node : WideTupleSchemaNode,
        nodes : Array(TupleSerializationNodeStatistics),
        next_leaf_index : Int32,
      ) : {TupleSerializationNodeStatistics, Int32}
        if leaf = schema_node.leaf_field?
          node = TupleSerializationNodeStatistics.new(
            nodes.size, next_leaf_index, [] of TupleSerializationNodeStatistics
          )
          nodes << node
          {node, next_leaf_index + 1}
        else
          children = [] of TupleSerializationNodeStatistics
          schema_node.children.each do |schema_child|
            child, next_leaf_index = append_node(schema_child, nodes, next_leaf_index)
            children << child
          end
          node = TupleSerializationNodeStatistics.new(nodes.size, nil, children)
          nodes << node
          {node, next_leaf_index}
        end
      end

      private def self.node_record(node : TupleSerializationNodeStatistics, rows : Int32) : String
        record = "{\"kind\":\"Default\",\"num_defaults\":#{node.default_count},\"num_rows\":#{rows}"
        if node.tuple?
          record += ",\"subcolumns\":[#{node.children.map { |child| node_record(child, rows) }.join(",")}]"
        end
        record + "}"
      end

      private def self.leaf_default_at(buffer : WideTupleLeafColumn::Buffer, row : Int32) : Bool
        case buffer
        when Array(DateValue), Array(Date32Value), Array(DateTimeValue),
             Array(DateTime64Value), Array(TimeValue), Array(Time64Value)
          WideTupleTemporalType.is_default?(buffer[row])
        when Array(String)
          buffer[row].empty?
        when Array(Bool)
          !buffer[row]
        when Array(UUIDValue), Array(IPv4Value), Array(IPv6Value)
          WideTupleIdentifierType.is_default?(buffer[row])
        when Array(FixedStringValue)
          value = buffer[row]
          all_zero = true
          value.raw_bytes.each { |byte| all_zero = false unless byte.zero? }
          all_zero
        when Array(Enum8Value), Array(Enum16Value)
          # SerializationInfo's default predicate is the raw-zero storage
          # default, not Enum's smallest-code SQL/Nullable default.
          buffer[row].code == 0
        when Array(Decimal32Value), Array(Decimal64Value), Array(Decimal128Value), Array(Decimal256TupleValue)
          decimal_storage_default?(buffer[row])
        else
          WideTupleNumericType.is_default?(buffer[row])
        end
      end

      private def self.decimal_storage_default?(value : Decimal32Value) : Bool
        value.raw == 0
      end

      private def self.decimal_storage_default?(value : Decimal64Value) : Bool
        value.raw == 0
      end

      private def self.decimal_storage_default?(value : Decimal128Value) : Bool
        value.raw == 0
      end

      private def self.decimal_storage_default?(value : Decimal256TupleValue) : Bool
        value.raw.low == 0_u128 && value.raw.high == 0_u128
      end
    end
  end
end
