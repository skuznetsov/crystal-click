module CrystalClick
  class OfflineTable
    # Offline .values retains each state as its immutable nominal BinaryValue.
    # This materializer does not expose the UInt64 carrier or finalize Count.
    private class AggregateCountOfflineValuesMaterializer
      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        expected_type : BinaryDataType,
        expected_rows : UInt64,
      ) : Array(OfflineColumnValue)
        plan = WideAggregateCountStoragePlan.require(expected_type)
        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        observed_rows = 0_u64

        unless candidates.empty?
          table.scan_typed([column]) do |batch|
            states = batch.aggregate_count_states_for(column, expected_type)
            batch_rows = states.size.to_u64
            if observed_rows > expected_rows || batch_rows > expected_rows - observed_rows
              raise CorruptPartError.new("observed offline Count state rows exceed the preflight count")
            end
            states.each do |state|
              unless state.type == plan.data_type
                raise CorruptPartError.new("offline Count state lost its nominal descriptor")
              end
              values << state
            end
            observed_rows += batch_rows
            nil
          end
        end

        unless observed_rows == expected_rows && values.size.to_u64 == expected_rows
          raise CorruptPartError.new("offline Count values row count differs from preflight count")
        end
        values
      end
    end
  end
end
