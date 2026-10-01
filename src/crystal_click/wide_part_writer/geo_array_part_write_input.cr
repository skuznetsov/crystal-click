module CrystalClick
  module WidePartWriter
    # Owned and fully preflighted snapshots for one exact Geo Array part.
    # The caller's ragged size vectors and Points are copied only after every
    # schema, cardinality, schedule, frame and combined-materialization bound
    # has passed.
    private class GeoArrayPartWriteInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter type_plan : GeoArrayColumnType
      getter level_sizes : Array(Array(UInt64))
      getter x_values : Array(Float64)
      getter y_values : Array(Float64)
      getter logical_streams : Array(String)
      getter compressed_sizes : Array(Int64)
      getter raw_sizes : Array(UInt64)
      getter mark_count : Int32
      getter mark_file_size : Int64
      getter index_size : Int64
      getter rows_per_mark : Int32
      getter size_schedules : Array(TupleLeafMarkSchedule)
      getter point_schedule : TupleLeafMarkSchedule
      getter columns_metadata : String
      getter substreams_metadata : String
      getter serialization_metadata : String

      def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @keys : Array(UInt64),
        @value_name : String,
        @type_plan : GeoArrayColumnType,
        @level_sizes : Array(Array(UInt64)),
        @x_values : Array(Float64),
        @y_values : Array(Float64),
        @logical_streams : Array(String),
        @compressed_sizes : Array(Int64),
        @raw_sizes : Array(UInt64),
        @mark_count : Int32,
        @mark_file_size : Int64,
        @index_size : Int64,
        @rows_per_mark : Int32,
        @size_schedules : Array(TupleLeafMarkSchedule),
        @point_schedule : TupleLeafMarkSchedule,
        @columns_metadata : String,
        @substreams_metadata : String,
        @serialization_metadata : String,
      )
      end
    end
  end
end
