module CrystalClick
  class WideTypePlan
    struct WidePhysicalPlanShadow
      struct Axis
        getter id : String
        getter kind : AxisKind

        def initialize(@id : String, @kind : AxisKind)
        end
      end
    end
  end
end
