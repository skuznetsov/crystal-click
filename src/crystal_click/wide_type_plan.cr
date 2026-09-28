module CrystalClick
  # A bounded syntax tree for ClickHouse type expressions. Parsing describes
  # syntax only; callers must use `admitted` before selecting physical codecs.
  class WideTypePlan
    TYPE_ARRAY_TUPLE_UINT64_STRING          = "Array(Tuple(a UInt64, b String))"
    TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING = "Array(Tuple(a Nullable(UInt64), b String))"
    TYPE_ARRAY_TUPLE_UINT64_UINT64          = "Array(Tuple(a UInt64, b UInt64))"
    TYPE_ARRAY_ARRAY_STRING                 = "Array(Array(String))"

    enum Shape
      ArrayTupleUInt64String
      ArrayTupleNullableUInt64String
      ArrayTupleUInt64UInt64
      ArrayArrayString
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
    # covered by W51, W55, and W59. Syntax parsing never acts as a broad
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
