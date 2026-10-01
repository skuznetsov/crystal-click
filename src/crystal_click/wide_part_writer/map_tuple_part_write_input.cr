module CrystalClick
  module WidePartWriter
    # Owned, fully preflighted inputs for one Map(K, Tuple(...)) part. The
    # primary-key row axis, Map outer-size axis and flattened entry axis stay
    # distinct; the retained physical leaf buffers are the exact snapshots
    # that staged readback must reproduce.
    private class MapTuplePartWriteInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter type_plan : WideMapTupleTypePlan
      getter row_sizes : Array(UInt64)
      getter map_key_buffer : TupleLeafBuffers
      getter value_leaf_buffers : Array(TupleLeafBuffers)
      getter value_leaf_null_maps : Array(Array(UInt8)?)
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
        @type_plan : WideMapTupleTypePlan,
        @row_sizes : Array(UInt64),
        @map_key_buffer : TupleLeafBuffers,
        @value_leaf_buffers : Array(TupleLeafBuffers),
        @value_leaf_null_maps : Array(Array(UInt8)?),
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
