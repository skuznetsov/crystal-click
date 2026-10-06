module CrystalClick
  class WidePartTable
    # Keeps the closed Tuple/Array-with-JSON admission and row-owner accounting
    # out of the scalar reader dispatch. Array wrapper shape is derived from
    # the complete occurrence frames; payload ownership is charged after decode.
    private class RecursiveColumnAdapter
      def self.schema_for_source_declaration(source_declaration : String) : StorageColumnSchema
        schema = StorageColumnSchema.parse(source_declaration)
        unless (schema.tuple? || schema.array?) && schema.has_json?
          raise UnsupportedFormatError.new("selected column is not an admitted recursive Tuple/Array JSON declaration")
        end
        schema
      end

      def self.open(
        part_path : String,
        column : String,
        schema : StorageColumnSchema,
        source_declaration : String,
      ) : RecursiveStorageColumnReader
        reader = RecursiveStorageColumnReader.open(part_path, column, schema)
        unless reader.schema_declaration == schema.declaration &&
               reader.source_declaration == source_declaration
          raise CorruptPartError.new("selected recursive Tuple/Array schema changed while opening the reader")
        end
        reader
      end

      # Validate the complete parent and Array occurrence grids before
      # callbacks, including scans that select no marks.
      def self.validate_complete_schedule(reader : RecursiveStorageColumnReader) : Nil
        counts = reader.mark_row_counts
        unless counts.size == reader.mark_count
          raise CorruptPartError.new("selected recursive schedule differs from the complete mark grid")
        end

        rows = 0_u64
        counts.each do |count|
          if count > UInt64::MAX - rows
            raise CorruptPartError.new("selected recursive row count overflows")
          end
          rows += count
        end
        unless rows == reader.row_count
          raise CorruptPartError.new("selected recursive schedule differs from its row count")
        end
        nil
      end

      def self.preflight_owner(
        reader : RecursiveStorageColumnReader,
        schema : StorageColumnSchema,
        mark_index : Int32,
        outer_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : UInt64
        validate_mark_rows!(reader, mark_index, outer_rows)
        shape = reader.storage_value_shape_for_mark(mark_index)
        budget, wrapper_bytes = budget_for(shape, outer_rows, remaining_mark_bytes)
        checked_add(budget.retained_logical_bytes, wrapper_bytes)
      rescue ex : BoundsError
        raise CorruptPartError.new("selected recursive Tuple mark exceeds aggregate materialization limit")
      end

      # Return one physical parent mark. The common Object budget charges all
      # recursive wrappers and leaf owners atomically before callback exposure.
      # Its limit is logical ownership accounting, not a transient RSS bound.
      def self.materialize_mark(
        reader : RecursiveStorageColumnReader,
        schema : StorageColumnSchema,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {Array(StorageColumnValue), UInt64}
        validate_mark_rows!(reader, mark_index, expected_rows)
        shape = reader.storage_value_shape_for_mark(mark_index)
        begin
          budget, _wrapper_bytes = budget_for(shape, expected_rows, remaining_mark_bytes)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected recursive mark exceeds aggregate materialization limit")
        end

        selected = reader.read_marks(mark_index, 1)
        raise CorruptPartError.new("selected recursive Tuple mark count changed") unless selected.size == 1
        rows = selected[0]
        unless rows.size.to_u64 == expected_rows
          raise CorruptPartError.new("selected recursive Tuple parent row count changed")
        end

        rows.each do |value|
          validate_value!(schema, value)
        end

        begin
          budget.charge_storage_values(rows)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected recursive mark exceeds aggregate materialization limit")
        end
        {rows, budget.retained_logical_bytes}
      end

      private def self.budget_for(
        shape : StorageValueShape,
        outer_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {ObjectValuesMaterializationBudget, UInt64}
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_base(outer_rows, 0_u64)

        wrapper_nodes = shape.nodes
        wrapper_cells = shape.tuple_cells
        wrapper_elements = shape.elements
        wrapper_bytes = shape.bytes

        unless wrapper_nodes <= budget.max_nodes - budget.node_count
          raise BoundsError.new("Object recursive node limit exceeded")
        end
        unless wrapper_cells <= budget.max_tuple_cells - budget.tuple_cells
          raise BoundsError.new("Object Tuple cell limit exceeded")
        end
        unless wrapper_elements <= budget.max_elements - budget.element_count
          raise BoundsError.new("Object recursive element limit exceeded")
        end

        # The reader derives this exact selected-mark shape from complete Array
        # schedules before payload reads. Variable JSON and BinaryBulk payloads
        # are checked by charge_storage_values immediately after decoding.
        budget.ensure_workspace(wrapper_bytes)
        {budget, wrapper_bytes}
      end

      private def self.validate_mark_rows!(
        reader : RecursiveStorageColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
      ) : Nil
        mark_rows = reader.mark_row_counts[mark_index]?
        unless mark_rows && mark_rows == expected_rows
          raise CorruptPartError.new("selected recursive Tuple mark row count differs from its part grid")
        end
        nil
      end

      private def self.validate_value!(schema : StorageColumnSchema, value : StorageColumnValue) : Nil
        unless schema.kind == value.kind
          raise CorruptPartError.new("selected recursive value shape differs from its declaration")
        end

        if schema.tuple?
          unless value.child_count == schema.child_count
            raise CorruptPartError.new("selected recursive Tuple arity differs from its declaration")
          end
          schema.child_count.times do |index|
            validate_value!(schema.child_at(index), value.child_at(index))
          end
        elsif schema.array?
          value.child_count.times do |index|
            validate_value!(schema.child_at(0), value.child_at(index))
          end
        elsif schema.bulk?
          unless value.bulk_value.type == schema.bulk_type
            raise CorruptPartError.new("selected recursive BinaryBulk leaf type differs from its declaration")
          end
        end
        nil
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("recursive owner accounting overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("recursive owner accounting overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
