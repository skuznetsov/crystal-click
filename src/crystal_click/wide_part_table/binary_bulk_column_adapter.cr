module CrystalClick
  class WidePartTable
    # Adapts one exact nominal static BinaryBulk type, including recursive
    # AggregateFunction state trees, to the generic reader and table budget.
    # Family admission remains owned by its declaration.
    private class BinaryBulkColumnAdapter
      def self.open(
        part_path : String,
        column : String,
        source_declaration : String,
      ) : {BinaryBulkColumnReader, BinaryDataType}
        expected_type = SimpleAggregateBulkColumnDeclaration.parse(source_declaration)
        expected_type ||= BinaryAggregateFunctionBulkColumnDeclaration.parse(source_declaration)
        expected_type ||= BinaryQBitBulkColumnDeclaration.parse(source_declaration)
        expected_type ||= BinaryCustomGeoBulkColumnDeclaration.parse(source_declaration)
        expected_type ||= StaticBinaryBulkColumnDeclaration.parse(source_declaration)
        unless expected_type && WidePart.supports_static_binary_bulk_type?(source_declaration)
          raise UnsupportedFormatError.new("selected declaration is outside the admitted static BinaryBulk profile")
        end

        reader = BinaryBulkColumnReader.open(part_path, column, expected_type)
        unless reader.schema_declaration == source_declaration &&
               reader.source_declaration == source_declaration
          raise CorruptPartError.new("selected static BinaryBulk declaration changed while opening the reader")
        end
        {reader, expected_type}
      end

      def self.validate_complete_schedule(
        reader : BinaryBulkColumnReader,
        expected_row_count : UInt64,
        expected_mark_rows : Array(UInt64),
      ) : Nil
        mark_rows = reader.mark_row_counts
        unless reader.row_count == expected_row_count &&
               reader.mark_count == expected_mark_rows.size &&
               mark_rows == expected_mark_rows
          raise CorruptPartError.new("selected static BinaryBulk grid differs from its part")
        end

        rows = 0_u64
        mark_rows.each do |count|
          if count > UInt64::MAX - rows
            raise CorruptPartError.new("selected static BinaryBulk row count overflows")
          end
          rows += count
        end
        unless rows == reader.row_count
          raise CorruptPartError.new("selected static BinaryBulk schedule differs from its row count")
        end
        nil
      end

      # Include the active reader's retained physical grid alongside the
      # returned BinaryValue array and descendant owners in the table mark
      # budget. This is logical ownership accounting, not an RSS bound.
      def self.preflight_owner(
        reader : BinaryBulkColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : UInt64
        validate_mark_rows!(reader, mark_index, expected_rows)
        workspace = reader.retained_grid_workspace_bytes
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_binary_values_base(expected_rows, workspace)
        checked_add(budget.retained_logical_bytes, workspace)
      rescue ex : BoundsError
        raise CorruptPartError.new("selected static BinaryBulk mark exceeds aggregate materialization limit")
      end

      # Decode one physical parent mark, verify the full nominal descriptor
      # for every row, and commit descendant-owner charges before exposure.
      def self.materialize_mark(
        reader : BinaryBulkColumnReader,
        expected_type : BinaryDataType,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {Array(BinaryValue), UInt64}
        validate_mark_rows!(reader, mark_index, expected_rows)
        workspace = reader.retained_grid_workspace_bytes
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        begin
          budget.reserve_binary_values_base(expected_rows, workspace)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected static BinaryBulk mark exceeds aggregate materialization limit")
        end

        selected = reader.read_marks(mark_index, 1)
        raise CorruptPartError.new("selected static BinaryBulk mark count changed") unless selected.size == 1
        values = selected[0]
        unless values.size.to_u64 == expected_rows
          raise CorruptPartError.new("selected static BinaryBulk mark row count changed")
        end
        values.each do |value|
          unless value.type == expected_type
            raise CorruptPartError.new("selected static BinaryBulk value type differs from its declaration")
          end
        end

        begin
          budget.charge_binary_values(values, workspace)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected static BinaryBulk mark exceeds aggregate materialization limit")
        end
        {values, checked_add(budget.retained_logical_bytes, workspace)}
      end

      private def self.validate_mark_rows!(
        reader : BinaryBulkColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
      ) : Nil
        mark_rows = reader.mark_row_counts[mark_index]?
        unless mark_rows && mark_rows == expected_rows
          raise CorruptPartError.new("selected static BinaryBulk mark row count differs from its part grid")
        end
        nil
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("static BinaryBulk logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end
    end
  end
end
