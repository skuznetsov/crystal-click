module CrystalClick
  # Closed storage plan for bounded named, nonempty Tuple schemas with
  # compositional named-Tuple children and scalar terminal leaves.
  # Parsing and admission stay Tuple-local; the shared expression AST and its
  # other physical profiles are intentionally unchanged.
  class WideTupleTypePlan
    MAX_FIELD_NAME_BYTES   = 128
    MAX_MATERIALIZED_BYTES = 64_u64 * 1024_u64 * 1024_u64

    RESULT_CONTAINER_ACCOUNTING_BYTES = 64_u64
    FIELD_CONTAINER_ACCOUNTING_BYTES  = sizeof(WideTupleField).to_u64
    RESULT_ROW_ACCOUNTING_BYTES       = 8_u64
    UINT64_SLOT_ACCOUNTING_BYTES      = 8_u64
    STRING_SLOT_ACCOUNTING_BYTES      = WideTupleLeafType::STRING_SLOT_ACCOUNTING_BYTES

    @type_name : String
    @root : WideTupleSchemaNode
    @fields : Array(WideTupleField)

    private def initialize(@root : WideTupleSchemaNode)
      @type_name = @root.type_name
      @fields = @root.flattened_fields
    end

    def self.for_type(type : String) : WideTupleTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      root = WideTupleSchemaParser.parse_tree(type) || return nil
      new(root)
    end

    # Build the inner Tuple plan only from a complete bounded Array(Tuple)
    # declaration. Keeping the parser tree out of this public API prevents a
    # caller-built schema node graph from bypassing aggregate parser limits.
    def self.for_array_type(type : String) : WideTupleTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      root = WideTupleSchemaParser.parse_array_tuple_tree(type) || return nil
      new(root)
    end

    # Build the inner Tuple plan from the bounded nominal Nested declaration.
    # Its parser charges the underlying Array and Tuple structural nodes in
    # the same aggregate budget, without synthesizing/reparsing a wrapper.
    def self.for_nested_type(type : String) : WideTupleTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      root = WideTupleSchemaParser.parse_nested_tree(type) || return nil
      new(root)
    end

    # Parse a complete Map(K, Tuple(...)) expression once, retaining one
    # validated nonnullable scalar key descriptor and the recursive value
    # Tuple plan. This is the only Map-to-value-plan admission path.
    def self.for_map_type(type : String) : {WideTupleLeafType, WideTupleTypePlan}?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      key_type, root = WideTupleSchemaParser.parse_map_tuple_tree(type) || return nil
      {key_type, new(root)}
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def fields : Array(WideTupleField)
      @fields.map(&.owned_copy)
    end

    # Immediate top-level schema members. Node exports are immutable; only
    # this array is copied for callers.
    def root_fields : Array(WideTupleSchemaNode)
      @root.children
    end

    def field_count : Int32
      @fields.size.to_i32
    end

    def field_count_under(path : Array(String)) : Int32
      count = 0_i32
      @fields.each do |field|
        count += 1 if field.path_starts_with?(path) && field.path_depth > path.size
      end
      count
    end

    # Canonical physical stream authority. Each tuple edge is encoded
    # separately, so a logical dotted field path can never be confused with a
    # literal stream-name delimiter.
    def leaf_stream_name(column : String, field : WideTupleField) : String
      "#{column}#{field.stream_path_suffix}"
    end

    # Return a schema subtree addressed by local name segments. Empty path
    # denotes the synthetic root.
    def node_at(path : Array(String)) : WideTupleSchemaNode?
      node = @root
      path.each do |segment|
        child = node.children.find { |candidate| candidate.name == segment }
        return nil unless child
        node = child
      end
      node
    end

    def node_at(path : String) : WideTupleSchemaNode?
      return nil if path.empty?
      segments = path.split('.')
      return nil if segments.any?(&.empty?)
      node_at(segments)
    end

    # Flat terminal fields below a subtree, with names relative to that
    # subtree. The returned descriptors are detached snapshots.
    def fields_under(path : Array(String)) : Array(WideTupleField)
      @fields.compact_map do |field|
        segments = field.path_segments
        next unless path_prefix?(segments, path)
        relative = segments[path.size..]
        next if relative.empty?
        relative_name = relative.join(".")
        WideTupleField.new(relative_name, field.leaf_type, relative)
      end
    end

    def field_index(path : Array(String), field_name : String) : Int32?
      relative = field_name.split('.')
      return nil if relative.empty? || relative.any?(&.empty?)
      full_path = path + relative
      @fields.each_with_index do |field, index|
        return index.to_i32 if field.path_equals?(full_path)
      end
      nil
    end

    def field_under?(index : Int32, path : Array(String)) : Bool
      field = @fields[index]?
      !!field && field.path_starts_with?(path)
    end

    def type_name_at(path : Array(String)) : String?
      node_at(path).try(&.type_name)
    end

    def physical_streams(column : String) : Array(String)
      streams = Array(String).new
      @fields.each do |field|
        leaf_stream = leaf_stream_name(column, field)
        streams << "#{leaf_stream}.null" if field.leaf_type.nullable?
        streams << "#{leaf_stream}.size" if field.leaf_type.base_type_name == "String"
        streams << leaf_stream
      end
      streams
    end

    def raw_string_stream?(column : String, stream_name : String) : Bool
      @fields.any? do |field|
        field.leaf_type.base_type_name == "String" && leaf_stream_name(column, field) == stream_name
      end
    end

    def stream_width(column : String, stream_name : String) : Int32?
      @fields.each do |field|
        leaf_stream = leaf_stream_name(column, field)
        leaf_type = field.leaf_type
        return 1 if leaf_type.nullable? && stream_name == "#{leaf_stream}.null"
        if leaf_type.base_type_name == "String"
          return 8 if stream_name == "#{leaf_stream}.size"
          return 1 if stream_name == leaf_stream
        elsif leaf_type.base_type_name == "Bool"
          return 1 if stream_name == leaf_stream
        elsif parameterized_type = field.parameterized_type
          width = case parameterized_type
                  when WideTupleFixedStringType then parameterized_type.width
                  when WideTupleEnumType        then parameterized_type.width
                  when WideTupleDecimalType     then parameterized_type.storage_width
                  end
          return width if stream_name == leaf_stream
        elsif identifier_width = WideTupleIdentifierType.width(leaf_type.base_type_name)
          return identifier_width if stream_name == leaf_stream
        elsif datetime_type = field.datetime_type
          return datetime_type.raw_width if stream_name == leaf_stream
        elsif temporal_width = WideTupleTemporalType.width(leaf_type.base_type_name)
          return temporal_width if stream_name == leaf_stream
        elsif numeric_width = WideTupleNumericType.width(leaf_type.base_type_name)
          return numeric_width if stream_name == leaf_stream
        end
      end
      nil
    end

    # Declared logical container/slot budget plus materialized rows.
    # Descriptor storage is included once per field, wrapper slots use actual
    # inline sizes, and caller-supplied variable/padded payload is included
    # once. Retained schema nodes, local names and flattened paths are included;
    # canonical/exported schema Strings and transient allocation storage are
    # excluded. This is not a complete allocation, peak-RSS or GC estimate.
    def materialization_charge(rows : UInt64, string_payload_bytes : UInt64) : UInt64?
      fixed_bytes = RESULT_CONTAINER_ACCOUNTING_BYTES
      tree_charge = @root.logical_charge
      return nil if tree_charge > UInt64::MAX - fixed_bytes
      fixed_bytes += tree_charge
      field_bytes = @fields.size.to_u64 * FIELD_CONTAINER_ACCOUNTING_BYTES
      return nil if field_bytes > UInt64::MAX - fixed_bytes
      fixed_bytes += field_bytes

      row_bytes = RESULT_ROW_ACCOUNTING_BYTES
      @fields.each do |field|
        path_charge = field.path_metadata_charge
        return nil if path_charge > UInt64::MAX - fixed_bytes
        fixed_bytes += path_charge

        leaf_type = field.leaf_type
        leaf_charge = leaf_type.logical_charge
        return nil if leaf_charge > UInt64::MAX - fixed_bytes
        fixed_bytes += leaf_charge
        if leaf_type.nullable?
          null_map_owner_bytes = instance_sizeof(ScalarNullMap).to_u64
          return nil if null_map_owner_bytes > UInt64::MAX - fixed_bytes
          fixed_bytes += null_map_owner_bytes
        end
        if parameterized_type = field.parameterized_type
          descriptor_charge = parameterized_type.logical_charge
          return nil if descriptor_charge > UInt64::MAX - fixed_bytes
          fixed_bytes += descriptor_charge
        end
        if datetime_type = field.datetime_type
          descriptor_charge = datetime_type.logical_charge
          return nil if descriptor_charge > UInt64::MAX - fixed_bytes
          fixed_bytes += descriptor_charge
        end

        slot_bytes = leaf_type.owned_slot_bytes
        slot_bytes += 1_u64 if leaf_type.nullable?
        return nil if slot_bytes > UInt64::MAX - row_bytes
        row_bytes += slot_bytes
      end

      return nil if rows > (UInt64::MAX - fixed_bytes) // row_bytes
      fixed_bytes += rows * row_bytes
      return nil if string_payload_bytes > UInt64::MAX - fixed_bytes
      fixed_bytes + string_payload_bytes
    end

    private def path_prefix?(segments : Array(String), prefix : Array(String)) : Bool
      return false if prefix.size >= segments.size
      prefix.each_with_index.all? { |segment, index| segments[index] == segment }
    end
  end
end
