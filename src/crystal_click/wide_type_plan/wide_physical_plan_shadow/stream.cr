module CrystalClick
  class WideTypePlan
    struct WidePhysicalPlanShadow
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
    end
  end
end
