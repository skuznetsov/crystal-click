module CrystalClick
  # Caller-materialized, non-nested projection part input. This value records
  # physical rows only; it makes no claim about a SQL SELECT or freshness.
  class WidePartProjection
    getter rows_per_mark : Int32

    @name : String
    @key_name : String
    @keys : Array(UInt64)
    @columns : Array(WidePartColumn)
    @schema_binding : WidePartSchemaBinding?

    private def initialize(
      @name : String,
      @key_name : String,
      @keys : Array(UInt64),
      @columns : Array(WidePartColumn),
      @rows_per_mark : Int32,
      @schema_binding : WidePartSchemaBinding? = nil,
    )
    end

    # Retains an independent key snapshot and the typed value-column owners.
    # WidePartColumn itself is immutable and already retains its input values.
    def self.precomputed(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      columns : Array(WidePartColumn),
      rows_per_mark : Int32 = 8192,
    ) : WidePartProjection
      validate_projection_name!(name)
      validate_column_name!(key_name)
      unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK
        raise ArgumentError.new("projection rows_per_mark is outside the admitted range")
      end
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("a projection requires a bounded nonempty UInt64 key stream")
      end
      if columns.empty?
        raise ArgumentError.new("a projection requires at least one typed value column")
      end
      if columns.size + 1 > WidePart::MAX_METADATA_COLUMNS
        raise UnsupportedFormatError.new("projection column count is outside the metadata limit")
      end

      retained_keys = Array(UInt64).new(keys.size)
      keys.each { |key| retained_keys << key }
      new(
        String.new(name.to_slice), String.new(key_name.to_slice),
        retained_keys, columns.dup, rows_per_mark
      )
    end

    # Public accessors return detached containers and strings; callers cannot
    # mutate the retained projection identity or key schedule through them.
    def name : String
      String.new(@name.to_slice)
    end

    def key_name : String
      String.new(@key_name.to_slice)
    end

    def keys : Array(UInt64)
      @keys.dup
    end

    def columns : Array(WidePartColumn)
      @columns.dup
    end

    # :nodoc:
    def row_count : UInt64
      @keys.size.to_u64
    end

    # Internal transform bridge: binds the already-detached inputs to a
    # catalog-derived schema without copying their keys or column owners.
    # :nodoc:
    def with_schema_binding(binding : PartSchemaBinding) : WidePartProjection
      self.class.with_schema_binding(self, binding)
    end

    # :nodoc:
    protected def self.with_schema_binding(
      source : WidePartProjection,
      binding : PartSchemaBinding,
    ) : WidePartProjection
      new(
        source.@name, source.@key_name, source.@keys, source.@columns,
        source.@rows_per_mark, WidePartSchemaBinding.new(binding),
      )
    end

    # :nodoc:
    def schema_binding : WidePartSchemaBinding?
      @schema_binding
    end

    private def self.validate_projection_name!(name : String) : Nil
      max_bytes = WidePartTable::MAX_PART_NAME_BYTES - ".proj".bytesize
      unless name.bytesize > 0 && name.bytesize <= max_bytes &&
             /\A[A-Za-z0-9_]+\z/.matches?(name)
        raise ArgumentError.new("projection name must be a bounded ASCII identifier")
      end
      nil
    end

    private def self.validate_column_name!(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES &&
             /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("column name must be a bounded ASCII identifier")
      end
      nil
    end
  end
end
