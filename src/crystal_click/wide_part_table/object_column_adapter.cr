module CrystalClick
  class WidePartTable
    # Keeps normalized JSON/Object admission, per-mark decoding, and logical
    # owner accounting out of the scalar reader dispatch.
    private class ObjectColumnAdapter
      def self.open(part_path : String, column : String, source_declaration : String) : ObjectColumnReader
        schema = ObjectDocumentSchema.parse_declaration(source_declaration)
        reader = ObjectColumnReader.open(part_path, column, schema)
        unless reader.schema_declaration == schema.declaration
          raise CorruptPartError.new("selected Object schema changed while opening the reader")
        end
        reader
      end

      # Reserve a conservative row-handle base before the decoder allocates a
      # pending mark. Document ownership is charged separately after decoding.
      def self.preflight_owner(
        rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : UInt64
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        budget.reserve_base(rows, 0_u64)
        budget.retained_logical_bytes
      rescue ex : BoundsError
        raise CorruptPartError.new("selected Object mark exceeds aggregate materialization limit")
      end

      # Return one full physical mark. This charge bounds callback-exposed
      # logical ownership; it is not a pre-decode transient-memory/RSS bound.
      def self.materialize_mark(
        reader : ObjectColumnReader,
        mark_index : Int32,
        expected_rows : UInt64,
        remaining_mark_bytes : UInt64,
      ) : {Array(ObjectDocument), UInt64}
        budget = ObjectValuesMaterializationBudget.new(logical_limit: remaining_mark_bytes)
        begin
          budget.reserve_base(expected_rows, 0_u64)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected Object mark exceeds aggregate materialization limit")
        end

        selected = reader.read_marks(mark_index, 1)
        raise CorruptPartError.new("selected Object mark count changed") unless selected.size == 1

        documents = selected[0]
        unless documents.size.to_u64 == expected_rows
          raise CorruptPartError.new("selected Object mark row count changed")
        end

        begin
          budget.charge_documents(documents)
        rescue ex : BoundsError
          raise CorruptPartError.new("selected Object mark exceeds aggregate materialization limit")
        end
        {documents, budget.retained_logical_bytes}
      end
    end
  end
end
