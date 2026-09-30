module CrystalClick
  module WidePartWriter
    # W84 serializes Array(Map(K, Array(V))) through the plan's third count
    # axis. The exact four admitted K/V combinations share this physical shape.
    private struct ArrayMapArrayPhysicalPlan
      getter shadow : WideTypePlan::WidePhysicalPlanShadow
      getter streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream)
      getter string_keys : Bool
      getter string_values : Bool

      def initialize(
        @shadow : WideTypePlan::WidePhysicalPlanShadow,
        @streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        @string_keys : Bool,
        @string_values : Bool,
      )
      end

      def self.build(
        value_name : String,
        key_type : String,
        value_type : String,
      ) : ArrayMapArrayPhysicalPlan
        string_keys = key_type == "String"
        string_values = value_type == "String"
        full_type = "Array(Map(#{key_type}, Array(#{value_type})))"
        shadow = WideTypePlan::WidePhysicalPlanShadow.for_type(full_type, value_name) ||
                 raise UnsupportedFormatError.new("#{full_type} has no bounded physical plan")
        build(shadow, shadow.streams, value_name, key_type, value_type)
      end

      def self.build(
        shadow : WideTypePlan::WidePhysicalPlanShadow,
        streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        value_name : String,
        key_type : String,
        value_type : String,
      ) : ArrayMapArrayPhysicalPlan
        string_keys = key_type == "String"
        string_values = value_type == "String"
        full_type = "Array(Map(#{key_type}, Array(#{value_type})))"
        raise UnsupportedFormatError.new("#{full_type} physical plan has an unexpected declared type") unless shadow.column_type == full_type
        expected_names = ["#{value_name}.size0", "#{value_name}.size1"]
        if string_keys
          expected_names << "#{value_name}%2Ekeys.size"
        end
        expected_names << "#{value_name}%2Ekeys" << "#{value_name}%2Evalues.size2"
        expected_names << "#{value_name}%2Evalues.size" if string_values
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
        map_type = "Map(#{key_type}, Array(#{value_type}))"
        unless size1.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1 &&
               size1.semantic_type == map_type && size1.semantic_path.empty? && size1.element_width == 8 &&
               size1.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(size1.storage_axis, outer_axis) &&
               size1.cardinality_parent_axis.try(&.id) == outer_axis.id &&
               size1.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::MapEntries
          raise UnsupportedFormatError.new("#{full_type} Map-size plan axes differ")
        end
        map_axis = size1.cardinality_child_axis.not_nil!

        key_index = 2
        if string_keys
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
          key_bytes_axis = key_sizes.cardinality_child_axis.not_nil!
          key_bytes = streams[key_index + 1]
          unless key_bytes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
                 key_bytes.semantic_type == "String" && key_bytes.semantic_path == ["keys"] &&
                 key_bytes.element_width == 1 &&
                 key_bytes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes &&
                 same_plan_axis?(key_bytes.storage_axis, key_bytes_axis) &&
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

        values_type = "Array(#{value_type})"
        value_sizes = streams[key_index]
        unless value_sizes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize2 &&
               value_sizes.semantic_type == values_type && value_sizes.semantic_path == ["values"] &&
               value_sizes.element_width == 8 &&
               value_sizes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(value_sizes.storage_axis, map_axis) &&
               value_sizes.cardinality_parent_axis.try(&.id) == map_axis.id &&
               value_sizes.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements
          raise UnsupportedFormatError.new("#{full_type} values.size2 plan axes differ")
        end
        values_axis = value_sizes.cardinality_child_axis.not_nil!
        key_index += 1

        if string_values
          value_string_sizes = streams[key_index]
          unless value_string_sizes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize &&
                 value_string_sizes.semantic_type == "String" && value_string_sizes.semantic_path == ["values"] &&
                 value_string_sizes.element_width == 8 &&
                 value_string_sizes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
                 same_plan_axis?(value_string_sizes.storage_axis, values_axis) &&
                 value_string_sizes.cardinality_parent_axis.try(&.id) == values_axis.id &&
                 value_string_sizes.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::StringBytes
            raise UnsupportedFormatError.new("#{full_type} value-size plan axes differ")
          end
          value_bytes_axis = value_string_sizes.cardinality_child_axis.not_nil!
          value_bytes = streams[key_index + 1]
          unless value_bytes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
                 value_bytes.semantic_type == "String" && value_bytes.semantic_path == ["values"] &&
                 value_bytes.element_width == 1 &&
                 value_bytes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes &&
                 same_plan_axis?(value_bytes.storage_axis, value_bytes_axis) &&
                 value_bytes.cardinality_parent_axis.nil? && value_bytes.cardinality_child_axis.nil?
            raise UnsupportedFormatError.new("#{full_type} value-byte plan axes differ")
          end
        else
          value_data = streams[key_index]
          unless value_data.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
                 value_data.semantic_type == "UInt64" && value_data.semantic_path == ["values"] &&
                 value_data.element_width == 8 &&
                 value_data.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues &&
                 same_plan_axis?(value_data.storage_axis, values_axis) &&
                 value_data.cardinality_parent_axis.nil? && value_data.cardinality_child_axis.nil?
            raise UnsupportedFormatError.new("#{full_type} UInt64-value plan axes differ")
          end
        end

        streams.each do |stream|
          raise UnsupportedFormatError.new("#{full_type} stream mark axis differs") unless same_plan_axis?(stream.mark_row_axis, rows_axis)
        end
        ArrayMapArrayPhysicalPlan.new(shadow, streams, string_keys, string_values)
      end

      private def self.same_plan_axis?(left : WideTypePlan::WidePhysicalPlanShadow::Axis, right : WideTypePlan::WidePhysicalPlanShadow::Axis) : Bool
        left.id == right.id && left.kind == right.kind
      end
    end
  end
end
