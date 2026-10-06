module CrystalClick
  class WidePartTable
    # Keeps the closed Tuple-with-JSON admission and row-owner accounting out
    # of the scalar reader dispatch. Tuple wrapper shape is predictable from
    # the schema; JSON/BinaryBulk payload ownership is charged after decoding.
    private class RecursiveColumnAdapter
      private struct WrapperShape
        getter nodes : UInt64
        getter tuple_cells : UInt64
        getter bytes : UInt64

        def initialize(@nodes : UInt64, @tuple_cells : UInt64, @bytes : UInt64)
        end
      end

      def self.schema_for_source_declaration(source_declaration : String) : StorageColumnSchema
        schema = StorageColumnSchema.parse(source_declaration)
        unless schema.tuple? && schema.has_json?
          raise UnsupportedFormatError.new("selected column is not an admitted recursive Tuple JSON declaration")
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
          raise CorruptPartError.new("selected recursive Tuple schema changed while opening the reader")
        end
        reader
      end

      # Validate the complete parent mark grid before callbacks, including
      # scans that select no marks. JSON leaves in this Tuple profile share
      # the parent's row grid; there is no Array(JSON) occurrence schedule.
      def self.validate_complete_schedule(reader : RecursiveStorageColumnReader) : Nil
        counts = reader.mark_row_counts
        unless counts.size == reader.mark_count
          raise CorruptPartError.new("selected recursive Tuple schedule differs from the complete mark grid")
        end

        rows = 0_u64
        counts.each do |count|
          if count > UInt64::MAX - rows
            raise CorruptPartError.new("selected recursive Tuple row count overflows")
          end
          rows += count
        end
        unless rows == reader.row_count
          raise CorruptPartError.new("selected recursive Tuple schedule differs from its row count")
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
        budget, wrapper_bytes = budget_for(schema, outer_rows, remaining_mark_bytes)
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
        begin
          budget, _wrapper_bytes = budget_for(schema, expected_rows, remaining_mark_bytes)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected recursive Tuple mark exceeds aggregate materialization limit")
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
          raise CorruptPartError.new("selected recursive Tuple mark exceeds aggregate materialization limit")
        end
        {rows, budget.retained_logical_bytes}
      end

      private def self.budget_for(
        schema : StorageColumnSchema,
        outer_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {ObjectValuesMaterializationBudget, UInt64}
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_base(outer_rows, 0_u64)

        shape = wrapper_shape(schema)
        wrapper_nodes = checked_multiply(shape.nodes, outer_rows)
        wrapper_cells = checked_multiply(shape.tuple_cells, outer_rows)
        wrapper_bytes = checked_multiply(shape.bytes, outer_rows)

        unless wrapper_nodes <= budget.max_nodes - budget.node_count
          raise BoundsError.new("Object recursive node limit exceeded")
        end
        unless wrapper_cells <= budget.max_tuple_cells - budget.tuple_cells
          raise BoundsError.new("Object Tuple cell limit exceeded")
        end
        unless wrapper_cells <= budget.max_elements - budget.element_count
          raise BoundsError.new("Object recursive element limit exceeded")
        end

        # Check the statically known result-tree shape before asking the reader
        # to decode the mark. Variable JSON and BinaryBulk payloads are checked
        # by charge_storage_values immediately after decoding.
        budget.ensure_workspace(wrapper_bytes)
        {budget, wrapper_bytes}
      end

      private def self.wrapper_shape(schema : StorageColumnSchema) : WrapperShape
        bytes = checked_add(
          instance_sizeof(StorageColumnValue).to_u64,
          instance_sizeof(Array(StorageColumnValue)).to_u64,
        )
        nodes = 1_u64
        tuple_cells = 0_u64

        if schema.tuple?
          child_count = schema.child_count.to_u64
          bytes = checked_add(
            bytes,
            checked_multiply(child_count, sizeof(Pointer(StorageColumnValue)).to_u64),
          )
          tuple_cells = child_count
          schema.child_count.times do |index|
            child = wrapper_shape(schema.child_at(index))
            nodes = checked_add(nodes, child.nodes)
            tuple_cells = checked_add(tuple_cells, child.tuple_cells)
            bytes = checked_add(bytes, child.bytes)
          end
        end

        WrapperShape.new(nodes, tuple_cells, bytes)
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
          raise CorruptPartError.new("selected recursive Tuple value shape differs from its declaration")
        end

        if schema.tuple?
          unless value.child_count == schema.child_count
            raise CorruptPartError.new("selected recursive Tuple arity differs from its declaration")
          end
          schema.child_count.times do |index|
            validate_value!(schema.child_at(index), value.child_at(index))
          end
        elsif schema.bulk?
          unless value.bulk_value.type == schema.bulk_type
            raise CorruptPartError.new("selected recursive Tuple BinaryBulk leaf type differs from its declaration")
          end
        end
        nil
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("recursive Tuple owner accounting overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("recursive Tuple owner accounting overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
