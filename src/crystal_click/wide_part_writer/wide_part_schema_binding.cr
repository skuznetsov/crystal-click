module CrystalClick
  # Exact target-schema snapshot for a caller-produced Wide part. The key is
  # the first roster entry; value declarations are compared to prepared owners
  # without aliases or a second type-name parser.
  class WidePartSchemaBinding
    @key_name : String
    @columns : Array(Tuple(String, String))

    def initialize(key_name : String, columns : Array(Tuple(String, String)))
      unless columns.size >= 2 && columns.size <= WidePart::MAX_METADATA_COLUMNS
        raise ArgumentError.new("bound Wide schema must contain a key and bounded value columns")
      end

      first = columns.first
      unless first[0] == key_name && first[1] == "UInt64"
        raise ArgumentError.new("bound Wide schema must begin with its UInt64 key column")
      end

      names = Set(String).new
      retained = Array(Tuple(String, String)).new(columns.size)
      columns.each do |name, declaration|
        if name.empty? || declaration.empty?
          raise ArgumentError.new("bound Wide schema names and declarations must be nonempty")
        end
        unless names.add?(name)
          raise ArgumentError.new("bound Wide schema column names must be unique")
        end
        retained << {String.new(name.to_slice), String.new(declaration.to_slice)}
      end

      @key_name = String.new(key_name.to_slice)
      @columns = retained
    end

    def key_name : String
      String.new(@key_name.to_slice)
    end

    # Returns a detached, ordered key-plus-value roster.
    def columns : Array(Tuple(String, String))
      @columns.map do |name, declaration|
        {String.new(name.to_slice), String.new(declaration.to_slice)}
      end
    end

    # Refuses publication unless the already-prepared owner roster is exactly
    # the target's ordered value-column suffix.
    def validate!(key_name : String, prepared : Array(WidePartWriter::WidePartPreparedColumn)) : Nil
      unless key_name == @key_name && prepared.size + 1 == @columns.size
        raise UnsupportedFormatError.new("prepared Wide columns do not match the bound target schema")
      end

      prepared.each_with_index do |column, index|
        target_name, target_declaration = @columns[index + 1]
        unless column.column_name == target_name && column.declaration == target_declaration
          raise UnsupportedFormatError.new(
            "prepared Wide columns do not match the bound target schema"
          )
        end
      end
      nil
    end
  end
end
