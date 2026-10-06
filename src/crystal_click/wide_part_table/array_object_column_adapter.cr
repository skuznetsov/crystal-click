module CrystalClick
  class WidePartTable
    # The narrow admitted Array(Object) bridge. The reader validates the full
    # size0 schedule independently of payload access; this adapter adds only
    # parent/child container accounting and materializes BASIC child JSON.
    private class ArrayObjectColumnAdapter
      def self.inner_schema(source_declaration : String) : ObjectDocumentSchema
        ArrayObjectColumnReader.schema_for_source_declaration(source_declaration) ||
          raise(UnsupportedFormatError.new("selected column is not an admitted Array(JSON) declaration"))
      end

      def self.type?(declaration : String) : Bool
        schema = ArrayObjectColumnReader.schema_for_source_declaration(declaration)
        !!schema && declaration == "Array(#{schema.not_nil!.declaration})"
      end

      def self.open(part_path : String, column : String, source_declaration : String) : ArrayObjectColumnReader
        schema = inner_schema(source_declaration)
        reader = ArrayObjectColumnReader.open(part_path, column, schema)
        expected = "Array(#{schema.declaration})"
        unless reader.schema_declaration == expected && reader.source_declaration == source_declaration
          raise CorruptPartError.new("selected Array(Object) schema changed while opening the reader")
        end
        reader
      end

      # Must run for the complete grid before callbacks, even if the caller's
      # selected window is empty. It checks schedule cardinality while leaving
      # unselected typed/shared payload streams under their normal contract.
      def self.validate_complete_schedule(reader : ArrayObjectColumnReader) : Nil
        counts = reader.child_occurrence_row_counts(0, reader.mark_count)
        unless counts.size == reader.mark_count
          raise CorruptPartError.new("selected Array(Object) child schedule differs from the complete mark grid")
        end
        nil
      end

      def self.preflight_owner(
        reader : ArrayObjectColumnReader,
        mark_index : Int32,
        outer_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : UInt64
        child_rows = child_count(reader, mark_index)
        budget = budget_for(outer_rows, child_rows, remaining_mark_bytes)
        budget.retained_logical_bytes
      rescue ex : BoundsError
        raise CorruptPartError.new("selected Array(Object) mark exceeds aggregate materialization limit")
      end

      def self.materialize_mark(
        reader : ArrayObjectColumnReader,
        mark_index : Int32,
        expected_outer_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {Array(Array(ObjectDocument)), UInt64}
        expected_children = child_count(reader, mark_index)
        budget = budget_for(expected_outer_rows, expected_children, remaining_mark_bytes)

        selected = reader.read_marks(mark_index, 1)
        raise CorruptPartError.new("selected Array(Object) mark count changed") unless selected.size == 1
        rows = selected[0]
        unless rows.size.to_u64 == expected_outer_rows
          raise CorruptPartError.new("selected Array(Object) parent row count changed")
        end

        observed_children = 0_u64
        rows.each do |children|
          count = children.size.to_u64
          if count > UInt64::MAX - observed_children
            raise CorruptPartError.new("selected Array(Object) child occurrence count overflows")
          end
          observed_children += count
        end
        unless observed_children == expected_children
          raise CorruptPartError.new("selected Array(Object) child rows differ from size0 schedule")
        end

        rows.each do |children|
          children.each do |document|
            begin
              budget.charge_document(document)
            rescue ex : BoundsError
              raise CorruptPartError.new("selected Array(Object) mark exceeds aggregate materialization limit")
            end
          end
        end
        {rows, budget.retained_logical_bytes}
      end

      private def self.child_count(reader : ArrayObjectColumnReader, mark_index : Int32) : UInt64
        counts = reader.child_occurrence_row_counts(mark_index, 1)
        unless counts.size == 1
          raise CorruptPartError.new("selected Array(Object) child schedule is missing a mark")
        end
        counts[0]
      end

      private def self.budget_for(
        outer_rows : UInt64,
        child_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : ObjectValuesMaterializationBudget
        # reserve_base accounts the outer row array; descriptor bytes cover a
        # nested child Array header per parent and every child document slot.
        header_bytes = instance_sizeof(Array(ObjectDocument)).to_u64
        if outer_rows != 0_u64 && header_bytes > UInt64::MAX // outer_rows
          raise BoundsError.new("Array(Object) nested array header charge overflows")
        end
        child_header_bytes = header_bytes * outer_rows
        slot_bytes = sizeof(Pointer(ObjectDocument)).to_u64
        if child_rows != 0_u64 && slot_bytes > UInt64::MAX // child_rows
          raise BoundsError.new("Array(Object) child slot charge overflows")
        end
        child_slot_bytes = slot_bytes * child_rows
        if child_slot_bytes > UInt64::MAX - child_header_bytes
          raise BoundsError.new("Array(Object) container charge overflows")
        end

        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_base(
          outer_rows,
          child_header_bytes + child_slot_bytes,
          descriptor_nodes: outer_rows,
          descriptor_elements: child_rows
        )
        budget
      end
    end
  end
end
