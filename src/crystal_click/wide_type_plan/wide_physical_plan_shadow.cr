module CrystalClick
  class WideTypePlan
    # A correctness-only shadow of the known W51/W55/W59/W61/W63/W69/W70/W71/W83 physical
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
        ArraySize2
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
        return true if exact_array_map_numeric_array_shape?(type, root)
        return true if exact_array_map_string_shape?(type, root)
        return true if exact_array_map_bool_shape?(type, root)
        return true if exact_array_map_string_uint64_shape?(type, root)
        return true if exact_array_map_array_leaf_shape?(type, root)
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

      # W84 admits one exact Array(Map(K, Array(V))) family. The declaration
      # recognizer is intentionally separate from the recursive shadow
      # Builder so adding a reusable third-offset axis does not admit adjacent
      # key/value or nesting types.
      private def self.exact_array_map_array_leaf_shape?(type : String, root : Node) : Bool
        key_type, value_type = WideTypePlan.array_map_array_leaf_shape(type) || return false
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2
        key = map.child(0)
        return false unless key.name == key_type && key.children.empty?
        values = map.child(1)
        return false unless values.name == "Array" && values.children.size == 1
        value = values.child(0)
        value.name == value_type && value.children.empty?
      end

      # W85 extends only the nested Array leaf to the ten primitive numeric
      # types. The exact recognizer stays separate from the recursive Builder
      # so adjacent keys, nullable leaves, and deeper arrays remain rejected.
      private def self.exact_array_map_numeric_array_shape?(type : String, root : Node) : Bool
        key_type, value_type = WideTypePlan.array_map_array_numeric_leaf_shape(type) || return false
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2
        key = map.child(0)
        return false unless key.name == key_type && key.children.empty?
        values = map.child(1)
        return false unless values.name == "Array" && values.children.size == 1
        value = values.child(0)
        value.name == value_type && value.children.empty?
      end

      # W82 adds only String leaves to the already bounded Array(Map) tree.
      # Keep exact declaration spelling as part of admission; the shared
      # recursive Builder supplies stream order and child-axis descriptors.
      private def self.exact_array_map_string_shape?(type : String, root : Node) : Bool
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2

        key = map.child(0)
        return false unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
        value = map.child(1)

        if value.name == "Nullable"
          return false unless value.children.size == 1
          leaf = value.child(0)
          leaf.name == "String" && leaf.children.empty? &&
            type == "Array(Map(#{key.name}, Nullable(String)))"
        else
          value.name == "String" && value.children.empty? &&
            type == "Array(Map(#{key.name}, String))"
        end
      end

      # W83 adds only exact Bool leaves (plain or nullable) to the existing
      # one-Array/one-Map profile. Bool is semantic, not a UInt8 alias.
      private def self.exact_array_map_bool_shape?(type : String, root : Node) : Bool
        return false unless root.name == "Array" && root.children.size == 1
        map = root.child(0)
        return false unless map.name == "Map" && map.children.size == 2

        key = map.child(0)
        return false unless key.children.empty? && (key.name == "UInt64" || key.name == "String")
        value = map.child(1)
        if value.name == "Nullable"
          return false unless value.children.size == 1
          leaf = value.child(0)
          leaf.name == "Bool" && leaf.children.empty? &&
            type == "Array(Map(#{key.name}, Nullable(Bool)))"
        else
          value.name == "Bool" && value.children.empty? &&
            type == "Array(Map(#{key.name}, Bool))"
        end
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
    end
  end
end
