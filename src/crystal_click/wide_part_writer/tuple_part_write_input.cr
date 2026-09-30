module CrystalClick
  module WidePartWriter
    private alias TupleLeafBuffers = Array(UInt64) | Array(String)

    # Immutable snapshot of validated writer inputs and their canonical
    # metadata/budget schedule. The owner creates this only after preflight.
    private class TuplePartWriteInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter type_plan : WideTupleTypePlan
      getter leaf_buffers : Array(TupleLeafBuffers)
      getter logical_streams : Array(String)
      getter compressed_sizes : Array(Int64)
      getter raw_sizes : Array(UInt64)
      getter mark_count : Int32
      getter rows_per_mark : Int32
      getter columns_metadata : String
      getter substreams_metadata : String
      getter serialization_metadata : String

      def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @keys : Array(UInt64),
        @value_name : String,
        @type_plan : WideTupleTypePlan,
        @leaf_buffers : Array(TupleLeafBuffers),
        @logical_streams : Array(String),
        @compressed_sizes : Array(Int64),
        @raw_sizes : Array(UInt64),
        @mark_count : Int32,
        @rows_per_mark : Int32,
        @columns_metadata : String,
        @substreams_metadata : String,
        @serialization_metadata : String,
      )
      end
    end
  end
end
