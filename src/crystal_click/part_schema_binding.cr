module CrystalClick
  # Immutable ordered key-plus-value schema snapshot shared by caller-run
  # Wide and Compact transforms. It retains canonical declarations without
  # reparsing them or serializing another metadata representation.
  class PartSchemaBinding
    @key_names : Array(String)
    @columns : Array(Tuple(String, String))

    def initialize(key_name : String, columns : Array(Tuple(String, String)), context : String = "part")
      initialize([key_name] of String, columns, context)
    end

    def initialize(key_names : Tuple(String, String), columns : Array(Tuple(String, String)), context : String = "part")
      initialize([key_names[0], key_names[1]], columns, context)
    end

    def initialize(key_names : Array(String), columns : Array(Tuple(String, String)), context : String)
      raise ArgumentError.new("bound #{context} schema must contain UInt64 keys") if key_names.empty?
      if columns.size <= key_names.size || columns.size > WidePart::MAX_METADATA_COLUMNS
        message = key_names.size == 1 ? "bound #{context} schema must contain a key and bounded value columns" : "bound #{context} schema must contain keys and bounded value columns"
        raise ArgumentError.new(message)
      end

      retained_keys = Array(String).new(key_names.size)
      key_seen = Set(String).new
      key_names.each do |name|
        if name.empty? || !key_seen.add?(name)
          raise ArgumentError.new("bound #{context} key names must be nonempty and unique")
        end
        retained_keys << String.new(name.to_slice)
      end

      column_seen = Set(String).new
      retained = Array(Tuple(String, String)).new(columns.size)
      columns.each_with_index do |(name, declaration), index|
        if name.empty? || declaration.empty?
          raise ArgumentError.new("bound #{context} schema names and declarations must be nonempty")
        end
        unless column_seen.add?(name)
          raise ArgumentError.new("bound #{context} schema column names must be unique")
        end
        if index < retained_keys.size && (name != retained_keys[index] || declaration != "UInt64")
          message = if retained_keys.size == 1
                      "bound #{context} schema must begin with its UInt64 key column"
                    else
                      "bound #{context} schema must begin with its ordered UInt64 key columns"
                    end
          raise ArgumentError.new(message)
        end
        retained << {String.new(name.to_slice), String.new(declaration.to_slice)}
      end

      @key_names = retained_keys
      @columns = retained
    end

    def key_name : String
      String.new(@key_names.first.to_slice)
    end

    def key_names : Array(String)
      @key_names.map { |name| String.new(name.to_slice) }
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
      validate_values!([key_name] of String, value_count, context) { |index| yield index }
    end

    def validate_values!(key_names : Array(String), value_count : Int32, context : String, &value_at : Int32 -> Tuple(String, String)) : Nil
      unless key_names == @key_names && value_count + key_names.size == @columns.size
        raise UnsupportedFormatError.new("prepared #{context} columns do not match the bound target schema")
      end

      value_count.times do |index|
        name, declaration = yield index
        target_name, target_declaration = @columns[index + key_names.size]
        unless name == target_name && declaration == target_declaration
          raise UnsupportedFormatError.new("prepared #{context} columns do not match the bound target schema")
        end
      end
      nil
    end
  end
end
