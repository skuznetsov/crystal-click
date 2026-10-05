module CrystalClick
  # Bounded owner for Count state batches. Count is decoded as nominal
  # BinaryValue state, never as its UInt64 payload carrier. The charge is a
  # fixed policy accounting charge used alongside String-like selected columns.
  # It is not a measured heap or RSS ceiling; profiling is deferred.
  class WideAggregateCountTableMaterializer
    ROW_ACCOUNTING_BYTES = 64_u64

    def self.materialization_charge(rows : UInt64) : UInt64
      if rows > UInt64::MAX // ROW_ACCOUNTING_BYTES
        raise CorruptPartError.new("AggregateFunction(count) table charge overflows")
      end
      rows * ROW_ACCOUNTING_BYTES
    end

    def self.preflight(rows : UInt64, remaining_bytes : UInt64) : UInt64
      charge = materialization_charge(rows)
      if charge > remaining_bytes
        raise CorruptPartError.new("selected AggregateFunction(count) mark exceeds aggregate materialization limit")
      end
      charge
    end

    def self.materialize(
      reader : WidePart,
      column : String,
      mark_index : Int,
      expected_rows : UInt64,
      expected_type : BinaryDataType,
      expected_charge : UInt64,
      remaining_bytes : UInt64,
    ) : {Array(BinaryValue), UInt64}
      plan = WideAggregateCountStoragePlan.require(expected_type)
      unless reader.column_type == plan.type_name
        raise CorruptPartError.new("AggregateFunction(count) materializer received a mismatched declaration")
      end

      charge = preflight(expected_rows, remaining_bytes)
      raise CorruptPartError.new("AggregateFunction(count) charge changed after preflight") unless charge == expected_charge
      values = reader.read_aggregate_count_mark_range(column, mark_index, 1, plan.data_type)
      raise CorruptPartError.new("AggregateFunction(count) mark row count changed") unless values.size.to_u64 == expected_rows
      values.each do |value|
        raise CorruptPartError.new("AggregateFunction(count) state type differs from column declaration") unless value.type == plan.data_type
      end
      {values, charge}
    end
  end
end
