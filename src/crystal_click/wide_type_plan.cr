module CrystalClick
  # A bounded syntax tree for ClickHouse type expressions. Parsing describes
  # syntax only; callers must use `admitted` before selecting physical codecs.
  class WideTypePlan
    TYPE_ARRAY_TUPLE_UINT64_STRING          = "Array(Tuple(a UInt64, b String))"
    TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING = "Array(Tuple(a Nullable(UInt64), b String))"
    TYPE_ARRAY_TUPLE_UINT64_UINT64          = "Array(Tuple(a UInt64, b UInt64))"
    TYPE_ARRAY_ARRAY_STRING                 = "Array(Array(String))"
    TYPE_ARRAY_ARRAY_NULLABLE_STRING        = "Array(Array(Nullable(String)))"
    TYPE_ARRAY_MAP_STRING_UINT64            = "Array(Map(String, UInt64))"

    enum Shape
      ArrayTupleUInt64String
      ArrayTupleNullableUInt64String
      ArrayTupleUInt64UInt64
      ArrayArrayString
      ArrayArrayNullableString
    end

    enum PhysicalSubstreamKind
      ArraySize0
      ArraySize1
      NullMap
      UInt64
      StringSize
      StringData
    end

    struct PhysicalSubstream
      getter name : String
      getter kind : PhysicalSubstreamKind
      @field_path : Array(String)

      def initialize(@name : String, @kind : PhysicalSubstreamKind, field_path : Array(String))
        @field_path = field_path.dup
      end

      def field_path : Array(String)
        @field_path.dup
      end

      def element_width : Int32
        case @kind
        when .array_size0?, .array_size1?, .u_int64?, .string_size?
          8
        when .null_map?, .string_data?
          1
        else
          raise UnsupportedFormatError.new("unsupported planned Array(Tuple) stream kind")
        end
      end
    end

    # A correctness-only shadow of the known W51/W55/W59/W61/W63/W69/W70/W71 physical
    # shapes. This deliberately does not participate in codec admission.
    struct WidePhysicalPlanShadow
      enum AxisKind
        TableRows
        MapEntries
        ArrayElements
        StringBytes
      end

      enum StreamRole
        MapSize0
        ArraySize0
        ArraySize1
        StringSize
        NullMap
        Value
      end

      enum StorageMode
        Counts
        NullMapBytes
        FixedWidthValues
        VariableBytes
      end

      struct Axis
        getter id : String
        getter kind : AxisKind

        def initialize(@id : String, @kind : AxisKind)
        end
      end

      struct Stream
        getter name : String
        getter semantic_type : String
        @semantic_path : Array(String)
        getter role : StreamRole
        getter element_width : Int32
        getter storage_mode : StorageMode
        getter storage_axis : Axis
        getter cardinality_parent_axis : Axis?
        getter cardinality_child_axis : Axis?
        getter mark_row_axis : Axis

        def initialize(
          @name : String,
          @semantic_type : String,
          semantic_path : Array(String),
          @role : StreamRole,
          @element_width : Int32,
          @storage_mode : StorageMode,
          @storage_axis : Axis,
          @cardinality_parent_axis : Axis?,
          @cardinality_child_axis : Axis?,
          @mark_row_axis : Axis,
        )
          @semantic_path = semantic_path.dup
        end

        def semantic_path : Array(String)
          @semantic_path.dup
        end
      end

      @column_type : String
      @streams : Array(Stream)
      @axes : Array(Axis)
      @mark_row_axis : Axis

      private def initialize(
        column_type : String,
        streams : Array(Stream),
        axes : Array(Axis),
        @mark_row_axis : Axis,
      )
        @column_type = column_type.dup
        @streams = streams.dup
        @axes = axes.dup
      end

      def column_type : String
        @column_type.dup
      end

      def streams : Array(Stream)
        @streams.dup
      end

      def axes : Array(Axis)
        @axes.dup
      end

      def mark_row_axis : Axis
        @mark_row_axis
      end

      # Accept only the exact shadowed declarations. Parsing is syntax-only;
      # neither this descriptor nor a successful result widens admission.
      def self.for_type(type : String, column : String = "payload") : WidePhysicalPlanShadow?
        root = WideTypePlan.parse(type) || return nil
        return nil unless shadow_shape?(type, root)

        builder = Builder.new(column)
        builder.append_root(root)
        new(type, builder.streams, builder.axes, builder.mark_row_axis)
      end

      private def self.shadow_shape?(type : String, root : Node) : Bool
        return true if exact_array_map_numeric_shape?(type, root)
        return true if exact_array_map_string_uint64_shape?(type, root)
        return true if exact_numeric_map_array_shape?(type, root)
        return true if exact_nullable_numeric_map_array_shape?(type, root)

        case type
        when TYPE_ARRAY_TUPLE_UINT64_STRING,
             TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING,
             TYPE_ARRAY_TUPLE_UINT64_UINT64,
             TYPE_ARRAY_ARRAY_STRING,
             TYPE_ARRAY_ARRAY_NULLABLE_STRING
          !WideTypePlan.admitted(type).nil?
        when "Map(String, Array(Nullable(UInt64)))"
          exact_map_shape?(root, "String", true)
        when "Map(String, Array(Nullable(String)))"
          exact_map_shape?(root, "String", true, "String")
        when "Map(UInt64, Array(Nullable(UInt64)))"
          exact_map_shape?(root, "UInt64", true)
        when "Map(UInt64, Array(Nullable(String)))"
          exact_map_shape?(root, "UInt64", true, "String")
        when "Map(String, Array(String))"
          exact_map_shape?(root, "String", false, "String")
        when "Map(UInt64, Array(String))"
          exact_map_shape?(root, "UInt64", false, "String")
        else
          false
        end
      end

      private def self.exact_array_map_string_uint64_shape?(type : String, root : Node) : Bool
        return false unless type == TYPE_ARRAY_MAP_STRING_UINT64
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2
        key = map.child(0)
        value = map.child(1)
        key.name == "String" && key.children.empty? && value.name == "UInt64" && value.children.empty?
      end

      # W81's admitted shape is intentionally only Array(Map(K, V)): one
      # outer Array, one Map, a UInt64 or String key, and one primitive
      # numeric value optionally wrapped once in Nullable. Match the original
      # declaration spelling as well as the parsed tree so this shadow never
      # normalizes unsupported aliases or whitespace variants into admission.
      private def self.exact_array_map_numeric_shape?(type : String, root : Node) : Bool
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2

        key = map.child(0)
        return false unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
        value = map.child(1)

        if value.name == "Nullable"
          return false unless value.children.size == 1
          leaf = value.child(0)
          return false unless leaf.children.empty? && numeric_map_array_leaf?(leaf.name)
          type == "Array(Map(#{key.name}, Nullable(#{leaf.name})))"
        else
          return false unless value.children.empty? && numeric_map_array_leaf?(value.name)
          type == "Array(Map(#{key.name}, #{value.name}))"
        end
      end

      private def self.exact_numeric_map_array_shape?(type : String, root : Node) : Bool
        return false unless root.name == "Map" && root.children.size == 2
        key = root.child(0)
        return false unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
        values = root.child(1)
        return false unless values.name == "Array" && values.children.size == 1
        element = values.child(0)
        return false unless element.children.empty?
        return false unless numeric_map_array_leaf?(element.name)

        type == "Map(#{key.name}, Array(#{element.name}))" &&
          exact_map_shape?(root, key.name, false, element.name)
      end

      private def self.exact_nullable_numeric_map_array_shape?(type : String, root : Node) : Bool
        return false unless root.name == "Map" && root.children.size == 2
        key = root.child(0)
        return false unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
        values = root.child(1)
        return false unless values.name == "Array" && values.children.size == 1
        element = values.child(0)
        return false unless element.name == "Nullable" && element.children.size == 1
        leaf = element.child(0)
        return false unless leaf.children.empty? && numeric_map_array_leaf?(leaf.name)

        type == "Map(#{key.name}, Array(Nullable(#{leaf.name})))" &&
          exact_map_shape?(root, key.name, true, leaf.name)
      end

      private def self.numeric_map_array_leaf?(type : String) : Bool
        case type
        when "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"
          true
        else
          false
        end
      end

      private def self.exact_map_shape?(root : Node, key_type : String, nullable_value : Bool, value_type : String = "UInt64") : Bool
        return false unless root.name == "Map" && root.children.size == 2
        key = root.child(0)
        return false unless key.name == key_type && key.children.empty?
        values = root.child(1)
        return false unless values.name == "Array" && values.children.size == 1

        element = values.child(0)
        if nullable_value
          element.name == "Nullable" && element.children.size == 1 &&
            element.child(0).name == value_type && element.child(0).children.empty?
        else
          element.name == value_type && element.children.empty?
        end
      end

      private class Builder
        getter streams : Array(Stream)
        getter axes : Array(Axis)
        getter mark_row_axis : Axis

        @column : String

        def initialize(@column : String)
          @streams = [] of Stream
          @axes = [] of Axis
          @mark_row_axis = add_axis("table_rows", AxisKind::TableRows)
        end

        def append_root(root : Node) : Nil
          append_node(root, @column, [] of String, @mark_row_axis, 0)
        end

        private def append_node(
          node : Node,
          stream_path : String,
          semantic_path : Array(String),
          storage_axis : Axis,
          array_depth : Int32,
          logical_leaf_type : String? = nil,
        ) : Nil
          case node.name
          when "Array"
            append_array(node, stream_path, semantic_path, storage_axis, array_depth)
          when "Tuple"
            node.children.each_with_index do |child, index|
              field = node.field_name(index)
              raise UnsupportedFormatError.new("shadow Tuple member is unnamed") if field.empty?
              child_path = semantic_path.dup
              child_path << field
              append_node(child, "#{stream_path}%2E#{field}", child_path, storage_axis, 0)
            end
          when "Map"
            append_map(node, stream_path, semantic_path, storage_axis, array_depth)
          when "Nullable"
            nullable_type = render_type(node)
            append_stream(
              "#{stream_path}.null", nullable_type, semantic_path,
              StreamRole::NullMap, 1, StorageMode::NullMapBytes, storage_axis
            )
            append_node(
              node.child(0), stream_path, semantic_path, storage_axis,
              array_depth, nullable_type
            )
          when "String"
            leaf_type = logical_leaf_type || render_type(node)
            bytes_axis = add_axis(axis_id(semantic_path, "string_bytes"), AxisKind::StringBytes)
            append_stream(
              "#{stream_path}.size", leaf_type, semantic_path,
              StreamRole::StringSize, 8, StorageMode::Counts, storage_axis,
              storage_axis, bytes_axis
            )
            append_stream(
              stream_path, leaf_type, semantic_path,
              StreamRole::Value, 1, StorageMode::VariableBytes, bytes_axis
            )
          when "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"
            leaf_type = logical_leaf_type || render_type(node)
            append_stream(
              stream_path, leaf_type, semantic_path,
              StreamRole::Value, numeric_leaf_width(node.name), StorageMode::FixedWidthValues, storage_axis
            )
          else
            raise UnsupportedFormatError.new("unsupported node in bounded shadow plan")
          end
          nil
        end

        private def numeric_leaf_width(type : String) : Int32
          case type
          when "UInt8", "Int8"
            1
          when "UInt16", "Int16"
            2
          when "UInt32", "Int32", "Float32"
            4
          when "UInt64", "Int64", "Float64"
            8
          else
            raise UnsupportedFormatError.new("unsupported numeric shadow leaf width")
          end
        end

        private def append_array(
          node : Node,
          stream_path : String,
          semantic_path : Array(String),
          parent_axis : Axis,
          array_depth : Int32,
        ) : Nil
          raise UnsupportedFormatError.new("shadow Array node has invalid arity") unless node.children.size == 1
          raise UnsupportedFormatError.new("shadow Array nesting exceeds its bound") if array_depth > 1

          child_axis = add_axis(
            axis_id(semantic_path, "array#{array_depth}_elements"), AxisKind::ArrayElements
          )
          role = array_depth == 0 ? StreamRole::ArraySize0 : StreamRole::ArraySize1
          append_stream(
            "#{stream_path}.size#{array_depth}", render_type(node), semantic_path,
            role, 8, StorageMode::Counts, parent_axis, parent_axis, child_axis
          )
          append_node(node.child(0), stream_path, semantic_path, child_axis, array_depth + 1)
          nil
        end

        # ClickHouse serializes Map as an Array(Tuple(keys, values)). Lower the
        # two semantic lanes explicitly so their shared entry axis is retained.
        private def append_map(
          node : Node,
          stream_path : String,
          semantic_path : Array(String),
          parent_axis : Axis,
          array_depth : Int32,
        ) : Nil
          raise UnsupportedFormatError.new("shadow Map node has invalid arity") unless node.children.size == 2
          raise UnsupportedFormatError.new("shadow Map nesting exceeds its offset-depth bound") if array_depth > 1
          entries_axis = add_axis(axis_id(semantic_path, "map_entries"), AxisKind::MapEntries)
          role = array_depth == 0 ? StreamRole::MapSize0 : StreamRole::ArraySize1
          append_stream(
            "#{stream_path}.size#{array_depth}", render_type(node), semantic_path,
            role, 8, StorageMode::Counts, parent_axis,
            parent_axis, entries_axis
          )

          key_path = semantic_path.dup
          key_path << "keys"
          append_node(node.child(0), "#{stream_path}%2Ekeys", key_path, entries_axis, 0)

          value_path = semantic_path.dup
          value_path << "values"
          append_node(node.child(1), "#{stream_path}%2Evalues", value_path, entries_axis, array_depth + 1)
          nil
        end

        private def append_stream(
          name : String,
          semantic_type : String,
          semantic_path : Array(String),
          role : StreamRole,
          element_width : Int32,
          storage_mode : StorageMode,
          storage_axis : Axis,
          cardinality_parent_axis : Axis? = nil,
          cardinality_child_axis : Axis? = nil,
        ) : Nil
          @streams << Stream.new(
            name, semantic_type, semantic_path, role, element_width, storage_mode,
            storage_axis, cardinality_parent_axis, cardinality_child_axis, @mark_row_axis
          )
        end

        private def add_axis(id : String, kind : AxisKind) : Axis
          if axis = @axes.find { |existing| existing.id == id }
            raise UnsupportedFormatError.new("shadow axis has inconsistent kinds") unless axis.kind == kind
            axis
          else
            axis = Axis.new(id, kind)
            @axes << axis
            axis
          end
        end

        private def axis_id(semantic_path : Array(String), suffix : String) : String
          scope = semantic_path.empty? ? "root" : semantic_path.join(".")
          "#{@column}:#{scope}:#{suffix}"
        end

        private def render_type(node : Node) : String
          return node.name if node.children.empty?

          arguments = node.children.each_with_index.map do |child, index|
            field = node.name == "Tuple" ? node.field_name(index) : ""
            rendered = render_type(child)
            field.empty? ? rendered : "#{field} #{rendered}"
          end
          "#{node.name}(#{arguments.join(", ")})"
        end
      end
    end

    struct Node
      getter name : String
      @children : Array(Node)
      @field_names : Array(String)

      def initialize(@name : String, children : Array(Node), field_names : Array(String))
        @children = children.dup
        @field_names = field_names.dup
      end

      def children : Array(Node)
        @children.dup
      end

      def child(index : Int) : Node
        @children[index]
      end

      # Tuple members have a name when the corresponding entry is non-empty;
      # generic type arguments and positional Tuple members use an empty name.
      def field_names : Array(String)
        @field_names.dup
      end

      def field_name(index : Int) : String
        @field_names[index]
      end
    end

    getter root : Node
    getter column_type : String
    getter shape : Shape

    private def initialize(@root : Node, @column_type : String, @shape : Shape)
    end

    # Parse a bounded recursive type-expression grammar. A nil result means
    # malformed or over-limit syntax; it does not imply codec support.
    def self.parse(type : String) : Node?
      return nil if type.empty? || type.bytesize > 4_096
      Parser.new(type).parse
    end

    # Keep physical admission intentionally sealed to the exact declarations
    # covered by W51, W55, W59, and W61. Syntax parsing never acts as a broad
    # physical-format allowlist.
    def self.admitted(type : String) : WideTypePlan?
      root = parse(type) || return nil
      if type == TYPE_ARRAY_TUPLE_UINT64_STRING && exact_array_tuple?(root, false)
        new(root, type.dup, Shape::ArrayTupleUInt64String)
      elsif type == TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING && exact_array_tuple?(root, true)
        new(root, type.dup, Shape::ArrayTupleNullableUInt64String)
      elsif type == TYPE_ARRAY_TUPLE_UINT64_UINT64 && exact_array_tuple_uint64_uint64?(root)
        new(root, type.dup, Shape::ArrayTupleUInt64UInt64)
      elsif type == TYPE_ARRAY_ARRAY_STRING && exact_array_array_string?(root)
        new(root, type.dup, Shape::ArrayArrayString)
      elsif type == TYPE_ARRAY_ARRAY_NULLABLE_STRING && exact_array_array_nullable_string?(root)
        new(root, type.dup, Shape::ArrayArrayNullableString)
      else
        nil
      end
    end

    # Return serializer-order stream descriptors from the parsed type tree,
    # including each stream's leaf role and named Tuple path. These are safe
    # to share with readers and writers only after exact admission succeeds.
    def physical_streams(column : String) : Array(PhysicalSubstream)
      streams = [] of PhysicalSubstream
      append_physical_streams(@root, column, [] of String, streams)
      streams
    end

    # Preserve the established API while keeping one recursive stream walk.
    def physical_substreams(column : String) : Array(String)
      physical_streams(column).map(&.name)
    end

    private def append_physical_streams(
      node : Node,
      path : String,
      field_path : Array(String),
      streams : Array(PhysicalSubstream),
      array_depth : Int32 = 0,
    ) : Nil
      case node.name
      when "Array"
        raise UnsupportedFormatError.new("admitted Array node has invalid arity") unless node.children.size == 1
        case array_depth
        when 0
          streams << PhysicalSubstream.new("#{path}.size0", PhysicalSubstreamKind::ArraySize0, field_path)
        when 1
          streams << PhysicalSubstream.new("#{path}.size1", PhysicalSubstreamKind::ArraySize1, field_path)
        else
          raise UnsupportedFormatError.new("admitted nested Array depth is unsupported")
        end
        append_physical_streams(node.child(0), path, field_path, streams, array_depth + 1)
      when "Tuple"
        node.children.each_with_index do |child, index|
          field_name = node.field_name(index)
          raise UnsupportedFormatError.new("admitted Tuple member is unnamed") if field_name.empty?
          child_path = field_path.dup
          child_path << field_name
          append_physical_streams(child, "#{path}%2E#{field_name}", child_path, streams, 0)
        end
      when "Nullable"
        raise UnsupportedFormatError.new("admitted Nullable node has invalid arity") unless node.children.size == 1
        streams << PhysicalSubstream.new("#{path}.null", PhysicalSubstreamKind::NullMap, field_path)
        append_physical_streams(node.child(0), path, field_path, streams, array_depth)
      when "String"
        streams << PhysicalSubstream.new("#{path}.size", PhysicalSubstreamKind::StringSize, field_path)
        streams << PhysicalSubstream.new(path, PhysicalSubstreamKind::StringData, field_path)
      when "UInt64"
        streams << PhysicalSubstream.new(path, PhysicalSubstreamKind::UInt64, field_path)
      else
        raise UnsupportedFormatError.new("admitted type plan contains an unsupported physical leaf")
      end
      nil
    end

    private def self.exact_array_tuple?(root : Node, nullable_first_field : Bool) : Bool
      return false unless root.name == "Array" && root.children.size == 1
      tuple = root.child(0)
      return false unless tuple.name == "Tuple" && tuple.children.size == 2
      return false unless tuple.field_names == ["a", "b"]

      first = tuple.child(0)
      second = tuple.child(1)
      return false unless second.name == "String" && second.children.empty?

      if nullable_first_field
        first.name == "Nullable" && first.children.size == 1 &&
          first.child(0).name == "UInt64" && first.child(0).children.empty?
      else
        first.name == "UInt64" && first.children.empty?
      end
    end

    private def self.exact_array_tuple_uint64_uint64?(root : Node) : Bool
      return false unless root.name == "Array" && root.children.size == 1
      tuple = root.child(0)
      return false unless tuple.name == "Tuple" && tuple.children.size == 2
      return false unless tuple.field_names == ["a", "b"]

      tuple.children.all? { |child| child.name == "UInt64" && child.children.empty? }
    end

    private def self.exact_array_array_string?(root : Node) : Bool
      return false unless root.name == "Array" && root.children.size == 1
      inner = root.child(0)
      return false unless inner.name == "Array" && inner.children.size == 1
      leaf = inner.child(0)
      leaf.name == "String" && leaf.children.empty?
    end

    private def self.exact_array_array_nullable_string?(root : Node) : Bool
      return false unless root.name == "Array" && root.children.size == 1
      inner = root.child(0)
      return false unless inner.name == "Array" && inner.children.size == 1
      nullable = inner.child(0)
      return false unless nullable.name == "Nullable" && nullable.children.size == 1
      leaf = nullable.child(0)
      leaf.name == "String" && leaf.children.empty?
    end

    # Recursive syntax parser kept separate from W51's exact shape admission.
    class Parser
      MAX_DEPTH =  64
      MAX_NODES = 512

      @bytes : Bytes
      @offset : Int32
      @nodes : Int32

      def initialize(source : String)
        @bytes = source.to_slice
        @offset = 0
        @nodes = 0
      end

      def parse : Node?
        begin
          node = parse_type(0)
          skip_whitespace
          @offset == @bytes.size ? node : nil
        rescue ex : ArgumentError
          nil
        end
      end

      private def parse_type(depth : Int32) : Node
        raise ArgumentError.new("type nesting exceeds limit") if depth > MAX_DEPTH
        @nodes += 1
        raise ArgumentError.new("type node count exceeds limit") if @nodes > MAX_NODES

        name = parse_identifier || raise(ArgumentError.new("type name is missing"))
        skip_whitespace
        return Node.new(name, [] of Node, [] of String) unless consume('(')

        children = [] of Node
        field_names = [] of String
        skip_whitespace
        if consume(')')
          return Node.new(name, children, field_names)
        end

        loop do
          skip_whitespace
          field_name, child = if name == "Tuple"
                                parse_tuple_member(depth + 1)
                              else
                                {"", parse_type(depth + 1)}
                              end
          children << child
          field_names << field_name
          skip_whitespace
          break if consume(')')
          raise ArgumentError.new("type argument separator is missing") unless consume(',')
        end

        Node.new(name, children, field_names)
      end

      private def parse_tuple_member(depth : Int32) : {String, Node}
        saved_offset = @offset
        candidate = parse_identifier
        if candidate
          identifier_end = @offset
          skip_whitespace
          if @offset > identifier_end && identifier_start?(@bytes[@offset]?)
            return {candidate, parse_type(depth)}
          end
        end

        @offset = saved_offset
        {"", parse_type(depth)}
      end

      private def parse_identifier : String?
        start = @offset
        return nil unless identifier_start?(@bytes[@offset]?)
        @offset += 1
        while identifier_continue?(@bytes[@offset]?)
          @offset += 1
        end
        String.new(@bytes[start, @offset - start])
      end

      private def identifier_start?(byte : UInt8?) : Bool
        return false unless byte
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
          (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
          byte == '_'.ord.to_u8 || (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
      end

      private def identifier_continue?(byte : UInt8?) : Bool
        identifier_start?(byte)
      end

      private def skip_whitespace : Nil
        while byte = @bytes[@offset]?
          break unless byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
          @offset += 1
        end
      end

      private def consume(character : Char) : Bool
        return false unless @bytes[@offset]? == character.ord.to_u8
        @offset += 1
        true
      end
    end
  end
end
