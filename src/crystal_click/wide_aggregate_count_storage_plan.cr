module CrystalClick
  # Exact one-lane physical plan for the three admitted top-level
  # AggregateFunction(count) descriptors. Count's state bytes are variable
  # width and must not flow through the fixed-width UInt64 reader.
  class WideAggregateCountStoragePlan
    MAX_MARK_RANGE_ROWS     = 65_536_u64
    MAX_STATE_BYTES_PER_ROW =     10_u64

    getter data_type : BinaryDataType

    def self.for_type_name(type_name : String) : WideAggregateCountStoragePlan?
      type = case type_name
             when "AggregateFunction(count)"
               BinaryDataType.aggregate_count
             when "AggregateFunction(count, UInt64)"
               BinaryDataType.aggregate_count(BinaryDataType.primitive("UInt64"))
             when "AggregateFunction(count, Nullable(UInt64))"
               BinaryDataType.aggregate_count(BinaryDataType.nullable(BinaryDataType.primitive("UInt64")))
             else
               return nil
             end
      new(type)
    end

    def self.for_type(type : BinaryDataType) : WideAggregateCountStoragePlan?
      return nil unless type.tag == BinaryDataType::TAG_AGGREGATE_COUNT
      descriptor = type.aggregate_count_type || return nil
      plan = for_type_name(descriptor.type_name) || return nil
      plan.data_type == type ? plan : nil
    end

    def self.require(type : BinaryDataType) : WideAggregateCountStoragePlan
      for_type(type) || raise(UnsupportedFormatError.new("AggregateFunction(count) requires one exact admitted descriptor"))
    end

    private def initialize(@data_type : BinaryDataType)
      unless @data_type.tag == BinaryDataType::TAG_AGGREGATE_COUNT && @data_type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) storage plan requires its nominal descriptor")
      end
    end

    def type_name : String
      @data_type.name
    end

    def physical_streams(column : String) : Array(String)
      [column]
    end

    def stream_width(column : String, stream_name : String) : Int32
      raise UnsupportedFormatError.new("AggregateFunction(count) has one exact value stream") unless stream_name == column
      1
    end

    def maximum_state_bytes(row_count : UInt64) : Int32
      if row_count > MAX_MARK_RANGE_ROWS
        raise CorruptPartError.new("AggregateFunction(count) mark range exceeds row limit")
      end
      (row_count * MAX_STATE_BYTES_PER_ROW).to_i32
    end
  end
end
