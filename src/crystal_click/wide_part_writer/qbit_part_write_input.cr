module CrystalClick
  module WidePartWriter
    # Preflighted QBit batch and its canonical physical schedule. Each copied
    # QBitValue is an immutable owned value whose raw-byte storage is itself
    # owned; copying the batch array does not create per-plane row matrices.
    private class QBitPartWriteInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter column_type : QBitColumnType
      getter values : Array(QBitValue?)
      getter logical_streams : Array(String)
      getter stream_widths : Array(Int32)
      getter compressed_sizes : Array(Int64)
      getter raw_sizes : Array(UInt64)
      getter mark_count : Int32
      getter mark_file_size : Int64
      getter index_size : Int64
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
        @column_type : QBitColumnType,
        @values : Array(QBitValue?),
        @logical_streams : Array(String),
        @stream_widths : Array(Int32),
        @compressed_sizes : Array(Int64),
        @raw_sizes : Array(UInt64),
        @mark_count : Int32,
        @mark_file_size : Int64,
        @index_size : Int64,
        @rows_per_mark : Int32,
        @columns_metadata : String,
        @substreams_metadata : String,
        @serialization_metadata : String,
      )
      end
    end
  end
end
