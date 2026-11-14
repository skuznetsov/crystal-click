module CrystalClick
  # Compatibility-facing Wide binding retains its concrete type and existing
  # validation API while delegating to the shared detached schema snapshot.
  class WidePartSchemaBinding
    @binding : PartSchemaBinding

    def initialize(key_name : String, columns : Array(Tuple(String, String)))
      @binding = PartSchemaBinding.new(key_name, columns, "Wide")
    end

    def initialize(@binding : PartSchemaBinding)
    end

    def key_name : String
      @binding.key_name
    end

    def columns : Array(Tuple(String, String))
      @binding.columns
    end

    # Refuses publication unless the already-prepared owner roster is exactly
    # the target's ordered value-column suffix.
    def validate!(key_name : String, prepared : Array(WidePartWriter::WidePartPreparedColumn)) : Nil
      @binding.validate_values!(key_name, prepared.size, "Wide") do |index|
        column = prepared[index]
        {column.column_name, column.declaration}
      end
    end

    def validate!(key_names : Array(String), prepared : Array(WidePartWriter::WidePartPreparedColumn)) : Nil
      value_offset = 0
      if key_names.size == 2
        if prepared.empty? || prepared.first.column_name != key_names[1] || prepared.first.declaration != "UInt64"
          raise UnsupportedFormatError.new("prepared Wide columns do not begin with the bound second UInt64 key")
        end
        value_offset = 1
      end
      value_count = prepared.size - value_offset
      @binding.validate_values!(key_names, value_count, "Wide") do |index|
        column = prepared[index + value_offset]
        {column.column_name, column.declaration}
      end
    end
  end
end
