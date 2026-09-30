module CrystalClick
  module WidePartWriter
    # The bounded W81 serializer consumes the plan's declared stream order,
    # roles, semantic paths, widths, and cardinality axes. Key and nullable
    # variants share one plan shape; absent streams are rejected when built.
    private struct ArrayMapNumericPhysicalPlan
      getter shadow : WideTypePlan::WidePhysicalPlanShadow
      getter streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream)
      getter string_keys : Bool
      getter nullable_values : Bool

      def initialize(
        @shadow : WideTypePlan::WidePhysicalPlanShadow,
        @streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        @string_keys : Bool,
        @nullable_values : Bool,
      )
      end

      def self.build(
        value_name : String,
        key_type : String,
        value_type : String,
        nullable_values : Bool,
        expected_leaf_width : Int32,
      ) : ArrayMapNumericPhysicalPlan
        key_string = key_type == "String"
        leaf_type = value_type
        value_type = "Nullable(#{leaf_type})" if nullable_values
        full_type = "Array(Map(#{key_type}, #{value_type}))"
        shadow = WideTypePlan::WidePhysicalPlanShadow.for_type(full_type, value_name) ||
                 raise UnsupportedFormatError.new("#{full_type} has no bounded physical plan")
        build(shadow, shadow.streams, value_name, key_type, leaf_type, nullable_values, expected_leaf_width)
      end

      def self.build(
        shadow : WideTypePlan::WidePhysicalPlanShadow,
        streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        value_name : String,
        key_type : String,
        leaf_type : String,
        nullable_values : Bool,
        expected_leaf_width : Int32,
      ) : ArrayMapNumericPhysicalPlan
        key_string = key_type == "String"
        value_type = nullable_values ? "Nullable(#{leaf_type})" : leaf_type
        full_type = "Array(Map(#{key_type}, #{value_type}))"
        raise UnsupportedFormatError.new("#{full_type} physical plan has an unexpected declared type") unless shadow.column_type == full_type
        expected_names = ["#{value_name}.size0", "#{value_name}.size1"]
        if key_string
          expected_names << "#{value_name}%2Ekeys.size"
          expected_names << "#{value_name}%2Ekeys"
        else
          expected_names << "#{value_name}%2Ekeys"
        end
        expected_names << "#{value_name}%2Evalues.null" if nullable_values
        expected_names << "#{value_name}%2Evalues"
        unless streams.map(&.name) == expected_names
          raise UnsupportedFormatError.new("#{full_type} physical plan has unexpected serializer order")
        end

        rows_axis = shadow.mark_row_axis
        size0 = streams[0]
        unless size0.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize0 &&
               size0.semantic_type == full_type && size0.semantic_path.empty? && size0.element_width == 8 &&
               size0.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(size0.storage_axis, rows_axis) &&
               size0.cardinality_parent_axis.try(&.id) == rows_axis.id &&
               size0.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements
          raise UnsupportedFormatError.new("#{full_type} outer-size plan axes differ")
        end
        outer_axis = size0.cardinality_child_axis.not_nil!

        size1 = streams[1]
        map_type = "Map(#{key_type}, #{value_type})"
        unless size1.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1 &&
               size1.semantic_type == map_type && size1.semantic_path.empty? && size1.element_width == 8 &&
               size1.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(size1.storage_axis, outer_axis) &&
               size1.cardinality_parent_axis.try(&.id) == outer_axis.id &&
               size1.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::MapEntries
          raise UnsupportedFormatError.new("#{full_type} map-size plan axes differ")
        end
        map_axis = size1.cardinality_child_axis.not_nil!

        key_index = 2
        if key_string
          key_sizes = streams[key_index]
          unless key_sizes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize &&
                 key_sizes.semantic_type == "String" && key_sizes.semantic_path == ["keys"] &&
                 key_sizes.element_width == 8 &&
                 key_sizes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
                 same_plan_axis?(key_sizes.storage_axis, map_axis) &&
                 key_sizes.cardinality_parent_axis.try(&.id) == map_axis.id &&
                 key_sizes.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::StringBytes
            raise UnsupportedFormatError.new("#{full_type} key-size plan axes differ")
          end
          bytes_axis = key_sizes.cardinality_child_axis.not_nil!
          key_bytes = streams[key_index + 1]
          unless key_bytes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
                 key_bytes.semantic_type == "String" && key_bytes.semantic_path == ["keys"] &&
                 key_bytes.element_width == 1 &&
                 key_bytes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes &&
                 same_plan_axis?(key_bytes.storage_axis, bytes_axis) &&
                 key_bytes.cardinality_parent_axis.nil? && key_bytes.cardinality_child_axis.nil?
            raise UnsupportedFormatError.new("#{full_type} key-byte plan axes differ")
          end
          key_index += 2
        else
          key_values = streams[key_index]
          unless key_values.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
                 key_values.semantic_type == "UInt64" && key_values.semantic_path == ["keys"] &&
                 key_values.element_width == 8 &&
                 key_values.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues &&
                 same_plan_axis?(key_values.storage_axis, map_axis) &&
                 key_values.cardinality_parent_axis.nil? && key_values.cardinality_child_axis.nil?
            raise UnsupportedFormatError.new("#{full_type} UInt64-key plan axes differ")
          end
          key_index += 1
        end

        if nullable_values
          nulls = streams[key_index]
          unless nulls.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::NullMap &&
                 nulls.semantic_type == value_type && nulls.semantic_path == ["values"] &&
                 nulls.element_width == 1 &&
                 nulls.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::NullMapBytes &&
                 same_plan_axis?(nulls.storage_axis, map_axis) &&
                 nulls.cardinality_parent_axis.nil? && nulls.cardinality_child_axis.nil?
            raise UnsupportedFormatError.new("#{full_type} null-map plan axes differ")
          end
          key_index += 1
        end

        value_stream = streams[key_index]
        unless value_stream.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
               value_stream.semantic_type == value_type && value_stream.semantic_path == ["values"] &&
               value_stream.element_width == expected_leaf_width &&
               value_stream.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues &&
               same_plan_axis?(value_stream.storage_axis, map_axis) &&
               value_stream.cardinality_parent_axis.nil? && value_stream.cardinality_child_axis.nil?
          raise UnsupportedFormatError.new("#{full_type} value plan axes differ")
        end

        streams.each do |stream|
          raise UnsupportedFormatError.new("#{full_type} stream mark axis differs") unless same_plan_axis?(stream.mark_row_axis, rows_axis)
        end
        ArrayMapNumericPhysicalPlan.new(shadow, streams, key_string, nullable_values)
      end

      private def self.same_plan_axis?(left : WideTypePlan::WidePhysicalPlanShadow::Axis, right : WideTypePlan::WidePhysicalPlanShadow::Axis) : Bool
        left.id == right.id && left.kind == right.kind
      end
    end
  end
end
