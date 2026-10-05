require "./flattened_nested_table_context"

module CrystalClick
  # Validates the narrow DDL surface admitted by the offline flattened-Nested
  # view and retains its detached caller binding. Physical part validation is
  # delegated to FlattenedNestedTableContext and the W173 reader plan.
  class OfflineFlattenedNestedBinding
    @context : FlattenedNestedTableContext

    private def initialize(@context : FlattenedNestedTableContext)
    end

    def self.from_table(
      kind : Symbol,
      engine : String,
      columns : Array(OfflineColumn),
      primary_key_column : String?,
      group_name : String,
    ) : OfflineFlattenedNestedBinding
      raise UnsupportedFormatError.new("flattened Nested binding requires an ordinary table") unless kind == :table
      raise UnsupportedFormatError.new("flattened Nested binding requires exact MergeTree engine") unless engine == "MergeTree"
      raise UnsupportedFormatError.new("flattened Nested binding requires exactly a key and one Nested column") unless columns.size == 2

      key_column = columns[0]
      root_column = columns[1]
      raise UnsupportedFormatError.new("flattened Nested key must be the supported ORDER BY column") unless primary_key_column == key_column.name
      unless key_column.type == "UInt64" && !key_column.alias_column && key_column.key_candidate_column
        raise UnsupportedFormatError.new("flattened Nested table key must be a non-ALIAS UInt64 column")
      end
      unless root_column.name == group_name && !root_column.alias_column && WideNestedTypePlan.for_type(root_column.type)
        raise UnsupportedFormatError.new("flattened Nested table DDL must declare the requested nominal Nested root")
      end

      context = FlattenedNestedTableContext.new(
        key_column.name,
        root_column.name,
        root_column.type
      )
      new(context)
    end

    def context : FlattenedNestedTableContext
      @context
    end
  end
end
