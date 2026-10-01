module CrystalClick
  module WidePartWriter
    # Preflighted, owned inputs for one Array(Tuple) part write. Outer sizes
    # and leaf payloads are deliberately retained on separate axes.
    private class ArrayTuplePartWriteInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter type_plan : WideArrayTupleTypePlan
      getter row_sizes : Array(UInt64)
      getter leaf_buffers : Array(TupleLeafBuffers)
      getter leaf_null_maps : Array(Array(UInt8)?)
      getter logical_streams : Array(String)
      getter compressed_sizes : Array(Int64)
      getter raw_sizes : Array(UInt64)
      getter mark_count : Int32
      getter rows_per_mark : Int32
      getter schedule : TupleLeafMarkSchedule
      getter columns_metadata : String
      getter substreams_metadata : String
      getter serialization_metadata : String

      def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @keys : Array(UInt64),
        @value_name : String,
        @type_plan : WideArrayTupleTypePlan,
        @row_sizes : Array(UInt64),
        @leaf_buffers : Array(TupleLeafBuffers),
        @leaf_null_maps : Array(Array(UInt8)?),
        @logical_streams : Array(String),
        @compressed_sizes : Array(Int64),
        @raw_sizes : Array(UInt64),
        @mark_count : Int32,
        @rows_per_mark : Int32,
        @schedule : TupleLeafMarkSchedule,
        @columns_metadata : String,
        @substreams_metadata : String,
        @serialization_metadata : String,
      )
      end
    end
  end
end
