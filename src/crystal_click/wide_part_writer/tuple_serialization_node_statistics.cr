module CrystalClick
  module WidePartWriter
    # One immutable-position recursive stats node. Its children precede it in
    # the plan's postorder scratch array so one row's defaults are evaluated
    # exactly once per node.
    private class TupleSerializationNodeStatistics
      getter index : Int32
      getter leaf_index : Int32?
      getter children : Array(TupleSerializationNodeStatistics)

      @default_count : Int32

      def initialize(
        @index : Int32,
        @leaf_index : Int32?,
        @children : Array(TupleSerializationNodeStatistics),
      )
        @default_count = 0
      end

      def default_count : Int32
        @default_count
      end

      def record_default : Nil
        @default_count += 1
      end

      def tuple? : Bool
        @leaf_index.nil?
      end
    end
  end
end
