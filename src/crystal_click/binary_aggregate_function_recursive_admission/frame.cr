module CrystalClick
  module BinaryAggregateFunctionRecursiveAdmission
    private class Frame
      getter type : BinaryDataType
      property next_child : Int32

      def initialize(@type : BinaryDataType)
        @next_child = 0
      end
    end
  end
end
