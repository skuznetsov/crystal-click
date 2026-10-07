module CrystalClick
  class WidePartTable
    # Adapts a schema-bound Dynamic bulk reader to the table's shared
    # per-mark logical materialization budget. The reader owns physical
    # validation; this adapter owns table-grid validation and retained rows.
    private class DynamicBulkColumnAdapter
      def self.open(
        part_path : String,
        column : String,
        source_declaration : String,
      ) : {DynamicBulkColumnReader, BinaryDataType}
        expected_type = DynamicBulkColumnDeclaration.parse(source_declaration) ||
                        raise(UnsupportedFormatError.new("selected column is not an admitted Dynamic-bearing declaration"))
        reader = DynamicBulkColumnReader.open(part_path, column, expected_type)
        unless reader.schema_declaration == source_declaration &&
               reader.source_declaration == source_declaration
          raise CorruptPartError.new("selected Dynamic bulk declaration changed while opening the reader")
        end
        {reader, expected_type}
      end

      # Validate every parent mark and replay any full-domain JSON/LC state
      # required by the physical site plan, even when no marks are selected.
      def self.validate_complete_schedule(
        reader : DynamicBulkColumnReader,
        expected_row_count : UInt64,
        expected_mark_rows : Array(UInt64),
      ) : Nil
        mark_rows = reader.mark_row_counts
        unless reader.row_count == expected_row_count &&
               reader.mark_count == expected_mark_rows.size &&
               mark_rows.size == reader.mark_count &&
               mark_rows == expected_mark_rows
          raise CorruptPartError.new("selected Dynamic bulk grid differs from its part")
        end

        rows = 0_u64
        mark_rows.each do |count|
          if count > UInt64::MAX - rows
            raise CorruptPartError.new("selected Dynamic bulk row count overflows")
          end
          rows += count
        end
        unless rows == reader.row_count
          raise CorruptPartError.new("selected Dynamic bulk schedule differs from its row count")
        end

        # Zero-read is intentionally unconditional: the site reader decides
        # whether bound JSON or LowCardinality requires full-domain replay.
        reader.validate_complete_schedule
        nil
      end

      # Reserve the derivable returned mark-array owner before the reader
      # allocates or decodes the selected Dynamic values.
      def self.preflight_owner(
        reader : DynamicBulkColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : UInt64
        validate_mark_rows!(reader, mark_index, expected_rows)
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_binary_values_base(expected_rows)
        budget.retained_logical_bytes
      rescue ex : BoundsError
        raise CorruptPartError.new("selected Dynamic bulk mark exceeds aggregate materialization limit")
      end

      # Decode one parent mark, verify nominal row descriptors, then charge
      # every BinaryValue owner atomically before table callback exposure.
      # The budget is logical ownership accounting, not a transient RSS bound.
      def self.materialize_mark(
        reader : DynamicBulkColumnReader,
        expected_type : BinaryDataType,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {Array(BinaryValue), UInt64}
        validate_mark_rows!(reader, mark_index, expected_rows)
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        begin
          budget.reserve_binary_values_base(expected_rows)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected Dynamic bulk mark exceeds aggregate materialization limit")
        end

        selected = reader.read_marks(mark_index, 1)
        raise CorruptPartError.new("selected Dynamic bulk mark count changed") unless selected.size == 1
        values = selected[0]
        unless values.size.to_u64 == expected_rows
          raise CorruptPartError.new("selected Dynamic bulk mark row count changed")
        end
        values.each do |value|
          unless value.type == expected_type
            raise CorruptPartError.new("selected Dynamic bulk value type differs from its declaration")
          end
        end

        begin
          budget.charge_binary_values(values)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected Dynamic bulk mark exceeds aggregate materialization limit")
        end
        {values, budget.retained_logical_bytes}
      end

      private def self.validate_mark_rows!(
        reader : DynamicBulkColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
      ) : Nil
        mark_rows = reader.mark_row_counts[mark_index]?
        unless mark_rows && mark_rows == expected_rows
          raise CorruptPartError.new("selected Dynamic bulk mark row count differs from its part grid")
        end
        nil
      end
    end
  end
end
