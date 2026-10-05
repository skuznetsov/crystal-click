module CrystalClick
  # Nominal Nested declaration paired with the shared Array(Tuple) physical
  # storage plan. This owner admits only the bounded unflattened shape; the
  # storage adapter never changes the retained column identity to Array.
  class WideNestedTypePlan
    @storage_plan : WideArrayTupleTypePlan

    private def initialize(@storage_plan : WideArrayTupleTypePlan)
    end

    def self.for_type(type : String) : WideNestedTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      storage_plan = WideArrayTupleTypePlan.for_storage_type(type) || return nil
      return nil unless storage_plan.nested?
      new(storage_plan)
    end

    def type_name : String
      @storage_plan.column_type
    end

    def tuple_plan : WideTupleTypePlan
      @storage_plan.tuple_plan
    end

    def storage_plan : WideArrayTupleTypePlan
      @storage_plan
    end
  end
end
