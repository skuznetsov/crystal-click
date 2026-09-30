module CrystalClick
  module WidePartWriter
    # The W80 serializer consumes the bounded physical plan directly. Keeping
    # its role-selected streams and axes together prevents the writer from
    # silently drifting to a separately hard-coded stream layout.
    private struct ArrayMapStringUInt64PhysicalPlan
      getter shadow : WideTypePlan::WidePhysicalPlanShadow
      getter streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream)
      getter size0 : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter size1 : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_bytes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @shadow : WideTypePlan::WidePhysicalPlanShadow,
        @streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        @size0 : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @size1 : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_bytes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end

      def self.build(
        value_name : String,
      ) : ArrayMapStringUInt64PhysicalPlan
        shadow = WideTypePlan::WidePhysicalPlanShadow.for_type(
          "Array(Map(String, UInt64))", value_name
        ) || raise UnsupportedFormatError.new("Array(Map(String, UInt64)) has no bounded physical plan")
        build(shadow, shadow.streams, value_name)
      end

      def self.build(
        shadow : WideTypePlan::WidePhysicalPlanShadow,
        streams : Array(WideTypePlan::WidePhysicalPlanShadow::Stream),
        value_name : String,
      ) : ArrayMapStringUInt64PhysicalPlan
        full_type = "Array(Map(String, UInt64))"
        raise UnsupportedFormatError.new("#{full_type} physical plan has an unexpected declared type") unless shadow.column_type == full_type
        expected_names = [
          "#{value_name}.size0",
          "#{value_name}.size1",
          "#{value_name}%2Ekeys.size",
          "#{value_name}%2Ekeys",
          "#{value_name}%2Evalues",
        ]
        raise UnsupportedFormatError.new("Array(Map(String, UInt64)) physical plan has an unexpected stream count") unless streams.size == expected_names.size
        raise UnsupportedFormatError.new("Array(Map(String, UInt64)) physical plan has unexpected serializer order") unless streams.map(&.name) == expected_names

        size0 = streams[0]
        size1 = streams[1]
        key_sizes = streams[2]
        key_bytes = streams[3]
        values = streams[4]
        table_rows = shadow.mark_row_axis

        unless size0.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize0 &&
               size0.semantic_type == "Array(Map(String, UInt64))" &&
               size0.semantic_path.empty? && size0.element_width == 8 &&
               size0.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(size0.storage_axis, table_rows) &&
               size0.cardinality_parent_axis.try(&.id) == table_rows.id &&
               size0.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) outer-size plan axes differ")
        end
        outer_elements = size0.cardinality_child_axis.not_nil!

        unless size1.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1 &&
               size1.semantic_type == "Map(String, UInt64)" &&
               size1.semantic_path.empty? && size1.element_width == 8 &&
               size1.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(size1.storage_axis, outer_elements) &&
               size1.cardinality_parent_axis.try(&.id) == outer_elements.id &&
               size1.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::MapEntries
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) map-size plan axes differ")
        end
        map_entries = size1.cardinality_child_axis.not_nil!

        unless key_sizes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize &&
               key_sizes.semantic_type == "String" && key_sizes.semantic_path == ["keys"] &&
               key_sizes.element_width == 8 &&
               key_sizes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts &&
               same_plan_axis?(key_sizes.storage_axis, map_entries) &&
               key_sizes.cardinality_parent_axis.try(&.id) == map_entries.id &&
               key_sizes.cardinality_child_axis.try(&.kind) == WideTypePlan::WidePhysicalPlanShadow::AxisKind::StringBytes
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) key-size plan axes differ")
        end
        string_bytes = key_sizes.cardinality_child_axis.not_nil!

        unless key_bytes.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
               key_bytes.semantic_type == "String" && key_bytes.semantic_path == ["keys"] &&
               key_bytes.element_width == 1 &&
               key_bytes.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes &&
               same_plan_axis?(key_bytes.storage_axis, string_bytes) &&
               key_bytes.cardinality_parent_axis.nil? && key_bytes.cardinality_child_axis.nil?
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) key-byte plan axes differ")
        end

        unless values.role == WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value &&
               values.semantic_type == "UInt64" && values.semantic_path == ["values"] &&
               values.element_width == 8 &&
               values.storage_mode == WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues &&
               same_plan_axis?(values.storage_axis, map_entries) &&
               values.cardinality_parent_axis.nil? && values.cardinality_child_axis.nil?
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) value plan axes differ")
        end

        streams.each do |stream|
          raise UnsupportedFormatError.new("Array(Map(String, UInt64)) stream mark axis differs") unless same_plan_axis?(stream.mark_row_axis, table_rows)
        end

        ArrayMapStringUInt64PhysicalPlan.new(shadow, streams, size0, size1, key_sizes, key_bytes, values)
      end

      private def self.same_plan_axis?(left : WideTypePlan::WidePhysicalPlanShadow::Axis, right : WideTypePlan::WidePhysicalPlanShadow::Axis) : Bool
        left.id == right.id && left.kind == right.kind
      end
    end
  end
end
