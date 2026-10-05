module CrystalClick
  # Bounded decoder for selected Wide-part Count state rows. The lane stores
  # canonical ClickHouse VarUInt values; BinaryValue owns a distinct UInt64
  # little-endian carrier after decoding.
  class WideAggregateCountStateReader
    def self.read(bytes : Bytes, row_count : UInt64, type : BinaryDataType) : Array(BinaryValue)
      plan = WideAggregateCountStoragePlan.require(type)
      maximum_bytes = plan.maximum_state_bytes(row_count)
      if bytes.size > maximum_bytes
        raise CorruptPartError.new("AggregateFunction(count) state range exceeds its byte bound")
      end
      if row_count > bytes.size.to_u64
        raise CorruptPartError.new("AggregateFunction(count) state range is too short for its rows")
      end

      limits = BinaryCodecLimits.new(
        max_depth: 1,
        max_nodes: row_count.to_i64,
        max_elements: row_count.to_i64,
        max_bytes: maximum_bytes.to_i64
      )
      context = BinaryCodecContext.new(limits, bytes)
      context.charge_elements(row_count)
      context.ensure_future_nodes(row_count)

      values = Array(BinaryValue).new(row_count.to_i)
      row_count.times do
        context.visit_node(1)
        count = BinaryAggregateCountStateCodec.read(context)
        values << BinaryValue.aggregate_count_state(plan.data_type, count)
      end
      context.ensure_consumed
      values
    end
  end
end
