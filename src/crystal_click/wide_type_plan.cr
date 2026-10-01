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

    getter root : Node
    getter column_type : String
    getter shape : Shape

    private def initialize(@root : Node, @column_type : String, @shape : Shape)
    end

    # Parse a bounded recursive type-expression grammar. A nil result means
    # malformed or over-limit syntax; it does not imply codec support.
    def self.parse(type : String) : Node?
      WideTypeExpression.parse(type)
    end

    # W84 is an exact family, not general recursive-type admission. Keep its
    # only legal key/value combinations explicit even though the shadow plan
    # below is capable of describing the third offset axis.
    def self.array_map_array_leaf_shape(type : String) : {String, String}?
      case type
      when "Array(Map(UInt64, Array(UInt64)))" then {"UInt64", "UInt64"}
      when "Array(Map(UInt64, Array(String)))" then {"UInt64", "String"}
      when "Array(Map(String, Array(UInt64)))" then {"String", "UInt64"}
      when "Array(Map(String, Array(String)))" then {"String", "String"}
      else
        nil
      end
    end

    # W85 admits one exact Array(Map(K, Array(N))) declaration matrix. This
    # helper is shared with the part admission dispatcher, but it remains
    # distinct from W84's UInt64/String leaf matrix.
    def self.array_map_array_numeric_leaf_shape(type : String) : {String, String}?
      root = parse(type) || return nil
      return nil unless root.name == "Array" && root.children.size == 1
      map = root.child(0)
      return nil unless map.name == "Map" && map.children.size == 2
      key = map.child(0)
      return nil unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
      values = map.child(1)
      return nil unless values.name == "Array" && values.children.size == 1
      value = values.child(0)
      return nil unless value.children.empty? && primitive_array_map_numeric_leaf?(value.name)
      return nil unless type == "Array(Map(#{key.name}, Array(#{value.name})))"

      {key.name, value.name}
    end

    private def self.primitive_array_map_numeric_leaf?(type : String) : Bool
      case type
      when "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"
        true
      else
        false
      end
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
  end
end

require "./wide_type_plan/physical_substream"
require "./wide_type_plan/wide_physical_plan_shadow"
require "./wide_type_plan/wide_physical_plan_shadow/axis"
require "./wide_type_plan/wide_physical_plan_shadow/stream"
require "./wide_type_plan/wide_physical_plan_shadow/builder"
