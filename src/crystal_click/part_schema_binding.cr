module CrystalClick
  # Immutable ordered key-plus-value schema snapshot shared by caller-run
  # Wide and Compact transforms. It retains canonical declarations without
  # reparsing them or serializing another metadata representation.
  class PartSchemaBinding
    @key_name : String
    @columns : Array(Tuple(String, String))

    def initialize(key_name : String, columns : Array(Tuple(String, String)), context : String = "part")
      unless columns.size >= 2 && columns.size <= WidePart::MAX_METADATA_COLUMNS
        raise ArgumentError.new("bound #{context} schema must contain a key and bounded value columns")
      end

      first = columns.first
      unless first[0] == key_name && first[1] == "UInt64"
        raise ArgumentError.new("bound #{context} schema must begin with its UInt64 key column")
      end

      names = Set(String).new
      retained = Array(Tuple(String, String)).new(columns.size)
      columns.each do |name, declaration|
        if name.empty? || declaration.empty?
          raise ArgumentError.new("bound #{context} schema names and declarations must be nonempty")
        end
        unless names.add?(name)
          raise ArgumentError.new("bound #{context} schema column names must be unique")
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

    # Refuses publication unless the already-materialized Compact metadata
    # roster exactly matches this target snapshot.
    def validate_compact!(metadata_columns : Array(Tuple(String, String))) : Nil
      unless metadata_columns.size == @columns.size
        raise UnsupportedFormatError.new("prepared Compact columns do not match the bound target schema")
      end

      metadata_columns.each_with_index do |(name, declaration), index|
        target_name, target_declaration = @columns[index]
        unless name == target_name && declaration == target_declaration
          raise UnsupportedFormatError.new("prepared Compact columns do not match the bound target schema")
        end
      end
      nil
    end

    # Validates an ordered key plus already-prepared value roster. The block
    # exposes one canonical owner tuple at a time, avoiding a second roster
    # serialization or copy.
    def validate_values!(key_name : String, value_count : Int32, context : String, &value_at : Int32 -> Tuple(String, String)) : Nil
      unless key_name == @key_name && value_count + 1 == @columns.size
        raise UnsupportedFormatError.new("prepared #{context} columns do not match the bound target schema")
      end

      value_count.times do |index|
        name, declaration = yield index
        target_name, target_declaration = @columns[index + 1]
        unless name == target_name && declaration == target_declaration
          raise UnsupportedFormatError.new("prepared #{context} columns do not match the bound target schema")
        end
      end
      nil
    end
  end
end
