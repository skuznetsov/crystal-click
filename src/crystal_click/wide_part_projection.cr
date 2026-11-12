module CrystalClick
  # Caller-materialized, non-nested projection part input. This value records
  # physical rows only; it makes no claim about a SQL SELECT or freshness.
  class WidePartProjection
    getter rows_per_mark : Int32

    @name : String
    @key_name : String
    @keys : Array(UInt64)
    @columns : Array(WidePartColumn)
    @count_total : UInt128?
    @aggregate_columns : Array(WidePartProjectionAggregate)
    @schema_binding : WidePartSchemaBinding?

    private def initialize(
      @name : String,
      @key_name : String,
      @keys : Array(UInt64),
      @columns : Array(WidePartColumn),
      @rows_per_mark : Int32,
      @count_total : UInt128? = nil,
      @schema_binding : WidePartSchemaBinding? = nil,
      @aggregate_columns : Array(WidePartProjectionAggregate) = [] of WidePartProjectionAggregate,
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

    # Retains sorted distinct group keys and positive caller-computed counts
    # for the stock `count()` AggregateFunction projection column.
    def self.precomputed_count(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      counts : Slice(UInt64),
      *,
      rows_per_mark : Int32 = 8192,
    ) : WidePartProjection
      validate_projection_name!(name)
      validate_column_name!(key_name)
      unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK
        raise ArgumentError.new("projection rows_per_mark is outside the admitted range")
      end
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("a count projection requires a bounded nonempty UInt64 key stream")
      end
      unless counts.size == keys.size
        raise ArgumentError.new("count projection keys and counts must have equal lengths")
      end

      count_aggregate = WidePartProjectionAggregate.count(counts)
      retained_keys = Array(UInt64).new(keys.size)
      keys.each_with_index do |key, index|
        if index > 0 && key <= retained_keys[index - 1]
          raise ArgumentError.new("count projection keys must be strictly increasing")
        end
        retained_keys << key
      end

      new(
        String.new(name.to_slice), String.new(key_name.to_slice),
        retained_keys, [] of WidePartColumn, rows_per_mark,
        count_aggregate.count_total, nil, [count_aggregate] of WidePartProjectionAggregate,
      )
    end

    # Retains strictly sorted distinct group keys and caller-computed Count
    # and/or UInt64 Sum states for the corresponding aggregate groups.
    def self.precomputed_aggregate(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      aggregate_columns : Array(WidePartProjectionAggregate),
      *,
      rows_per_mark : Int32 = 8192,
    ) : WidePartProjection
      validate_projection_name!(name)
      validate_column_name!(key_name)
      unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK
        raise ArgumentError.new("projection rows_per_mark is outside the admitted range")
      end
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("an aggregate projection requires a bounded nonempty UInt64 key stream")
      end
      unless aggregate_columns.size > 0 && aggregate_columns.size <= 2
        raise ArgumentError.new("an aggregate projection requires one or two aggregate columns")
      end

      retained_aggregates = aggregate_columns.dup
      retained_keys = Array(UInt64).new(keys.size)
      previous_key = 0_u64
      count_total : UInt128? = nil
      seen_count = false
      seen_sum = false
      retained_aggregates.each do |aggregate|
        unless aggregate.value_count == keys.size
          raise ArgumentError.new("aggregate projection keys and values must have equal lengths")
        end
        if aggregate.count?
          if seen_count
            raise ArgumentError.new("aggregate projection count column must be unique")
          end
          seen_count = true
          count_total = aggregate.count_total
        else
          raise ArgumentError.new("aggregate projection may contain one sum column") if seen_sum
          seen_sum = true
        end
      end

      keys.each_with_index do |key, index|
        if index > 0 && key <= previous_key
          raise ArgumentError.new("aggregate projection keys must be strictly increasing")
        end
        retained_keys << key
        previous_key = key
      end

      new(
        String.new(name.to_slice), String.new(key_name.to_slice),
        retained_keys, [] of WidePartColumn, rows_per_mark,
        count_total, nil, retained_aggregates,
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
    def count_total : UInt128?
      @count_total
    end

    # :nodoc:
    def count_values : Array(UInt64)?
      @aggregate_columns.find(&.count?).try(&.values)
    end

    # Retains the caller-supplied aggregate order while detaching the roster.
    def aggregate_columns : Array(WidePartProjectionAggregate)
      @aggregate_columns.dup
    end

    # :nodoc:
    def aggregate_projection? : Bool
      !@aggregate_columns.empty?
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
        source.@rows_per_mark, source.@count_total,
        WidePartSchemaBinding.new(binding), source.@aggregate_columns,
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
