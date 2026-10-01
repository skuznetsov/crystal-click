module CrystalClick
  class WideTypePlan
    struct WidePhysicalPlanShadow
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
          when "Bool"
            leaf_type = logical_leaf_type || render_type(node)
            append_stream(
              stream_path, leaf_type, semantic_path,
              StreamRole::Value, 1, StorageMode::FixedWidthValues, storage_axis
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
          raise UnsupportedFormatError.new("shadow Array nesting exceeds its bound") if array_depth > 2

          child_axis = add_axis(
            axis_id(semantic_path, "array#{array_depth}_elements"), AxisKind::ArrayElements
          )
          role = case array_depth
                 when 0 then StreamRole::ArraySize0
                 when 1 then StreamRole::ArraySize1
                 when 2 then StreamRole::ArraySize2
                 else
                   raise UnsupportedFormatError.new("shadow Array nesting exceeds its bound")
                 end
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
  end
end
