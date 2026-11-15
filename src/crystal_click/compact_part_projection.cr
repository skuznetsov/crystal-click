module CrystalClick
  # Caller-materialized Compact projection part input. Its mark layout and
  # profile are explicit because Compact children do not inherit Wide-only
  # parent settings.
  class CompactPartProjection
    getter rows_per_mark : Int32
    getter frame_bytes : Int32
    getter mark_format : CompactMarkFormat
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode
    getter compress_marks : Bool
    getter compress_primary_key : Bool
    getter profile : BinaryBulkProfile

    @name : String
    @key_name : String
    @keys : Array(UInt64)
    @columns : Array(CompactPartColumn)
    @aggregate_columns : Array(WidePartProjectionAggregate)
    @schema_binding : PartSchemaBinding?
    @count_total : UInt128?
    @additional_key_names : Array(String)
    @additional_key_columns : Array(Array(UInt64))

    private def initialize(
      @name : String,
      @key_name : String,
      @keys : Array(UInt64),
      @columns : Array(CompactPartColumn),
      @rows_per_mark : Int32,
      @frame_bytes : Int32,
      @mark_format : CompactMarkFormat,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode,
      @compress_marks : Bool,
      @profile : BinaryBulkProfile,
      @schema_binding : PartSchemaBinding? = nil,
      @count_total : UInt128? = nil,
      @aggregate_columns : Array(WidePartProjectionAggregate) = [] of WidePartProjectionAggregate,
      @additional_key_names : Array(String) = [] of String,
      @additional_key_columns : Array(Array(UInt64)) = [] of Array(UInt64),
      @compress_primary_key : Bool = false,
    )
    end

    # Retains detached keys and a detached column roster. Column owners already
    # retain their immutable values and callback contexts.
    def self.precomputed(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      mark_format : CompactMarkFormat = CompactMarkFormat::Mrk3,
      variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
      compress_marks : Bool = false,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : CompactPartProjection
      validate_projection_name!(name)
      validate_column_name!(key_name)
      unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK &&
             rows_per_mark <= WidePartTable::MAX_MARK_ROWS
        raise ArgumentError.new("projection rows_per_mark is outside the Compact reader limit")
      end
      unless frame_bytes > 0 && frame_bytes <= Int32::MAX
        raise ArgumentError.new("projection frame_bytes is outside the Compact writer limit")
      end
      unless mark_format.mrk3? || mark_format.mrk4?
        raise UnsupportedFormatError.new("unsupported Compact projection mark format")
      end
      variant_discriminator_mode.wire_value
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("a projection requires a bounded nonempty UInt64 key stream")
      end
      if columns.empty? || columns.size >= WidePartTable::MAX_COLUMNS
        raise ArgumentError.new("projection column count is outside the Compact reader limit")
      end

      retained_keys = Array(UInt64).new(keys.size)
      keys.each { |key| retained_keys << key }
      new(
        String.new(name.to_slice), String.new(key_name.to_slice), retained_keys,
        columns.dup, rows_per_mark, frame_bytes.to_i32, mark_format,
        variant_discriminator_mode, compress_marks, profile,
      )
    end

    # Retains sorted distinct group keys and positive caller-computed states
    # for one nominal AggregateFunction(count) output. This profile fixes the
    # Compact child to MRK4 and String serialization version 1.
    def self.precomputed_count(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      counts : Slice(UInt64),
      *,
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      compress_marks : Bool = false,
      compress_primary_key : Bool = false,
    ) : CompactPartProjection
      unless counts.size == keys.size
        raise ArgumentError.new("count projection keys and counts must have equal lengths")
      end

      precomputed_aggregate(
        name, key_name, keys,
        [WidePartProjectionAggregate.count(counts)] of WidePartProjectionAggregate,
        rows_per_mark: rows_per_mark,
        frame_bytes: frame_bytes,
        compress_marks: compress_marks,
        compress_primary_key: compress_primary_key,
      )
    end

    # Retains strictly ordered key pairs and caller-computed count states for
    # the Compact MRK4 projection profile.
    def self.precomputed_count(
      name : String,
      key_names : Tuple(String, String),
      keys : Tuple(Slice(UInt64), Slice(UInt64)),
      counts : Slice(UInt64),
      *,
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      compress_marks : Bool = false,
      compress_primary_key : Bool = false,
    ) : CompactPartProjection
      unless counts.size == keys[0].size
        raise ArgumentError.new("count projection keys and counts must have equal lengths")
      end

      precomputed_aggregate(
        name, key_names, keys,
        [WidePartProjectionAggregate.count(counts)] of WidePartProjectionAggregate,
        rows_per_mark: rows_per_mark,
        frame_bytes: frame_bytes,
        compress_marks: compress_marks,
        compress_primary_key: compress_primary_key,
      )
    end

    # Retains sorted distinct group keys and one to four caller-computed
    # AggregateFunction states in SELECT order. Compact aggregate children use
    # the pinned MRK4, compact Variant, and String serialization version 1
    # profile; ordinary Compact AggregateFunction columns remain unadmitted.
    def self.precomputed_aggregate(
      name : String,
      key_name : String,
      keys : Slice(UInt64),
      aggregates : Array(WidePartProjectionAggregate),
      *,
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      compress_marks : Bool = false,
      compress_primary_key : Bool = false,
    ) : CompactPartProjection
      validate_aggregate_projection_options!(name, rows_per_mark, frame_bytes)
      validate_column_name!(key_name)
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("an aggregate projection requires a bounded nonempty UInt64 key stream")
      end
      retained_aggregates, count_total = retain_aggregate_columns(aggregates, keys.size)

      retained_keys = Array(UInt64).new(keys.size)
      previous_key = 0_u64
      keys.each_with_index do |key, index|
        if index > 0 && key <= previous_key
          raise ArgumentError.new("aggregate projection keys must be strictly increasing")
        end
        retained_keys << key
        previous_key = key
      end
      retained_columns = build_aggregate_columns(retained_aggregates, rows_per_mark)

      new(
        String.new(name.to_slice), String.new(key_name.to_slice),
        retained_keys, retained_columns, rows_per_mark, frame_bytes.to_i32,
        CompactMarkFormat::Mrk4, CompactVariantDiscriminatorMode::Compact,
        compress_marks, BinaryBulkProfile.with_size_stream, nil, count_total,
        retained_aggregates, compress_primary_key: compress_primary_key)
    end

    # Retains two detached key columns in GROUP BY order and caller-computed
    # aggregate states in SELECT order. Ordered pairs may repeat their first
    # key, and the second key may reset when the first key increases.
    def self.precomputed_aggregate(
      name : String,
      key_names : Tuple(String, String),
      keys : Tuple(Slice(UInt64), Slice(UInt64)),
      aggregates : Array(WidePartProjectionAggregate),
      *,
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      compress_marks : Bool = false,
      compress_primary_key : Bool = false,
    ) : CompactPartProjection
      validate_aggregate_projection_options!(name, rows_per_mark, frame_bytes)
      validate_column_name!(key_names[0])
      validate_column_name!(key_names[1])
      if key_names[0] == key_names[1]
        raise ArgumentError.new("aggregate projection key names must be distinct")
      end
      first_keys = keys[0]
      second_keys = keys[1]
      if first_keys.empty? || first_keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("a two-key aggregate projection requires a bounded nonempty UInt64 key stream")
      end
      unless second_keys.size == first_keys.size
        raise ArgumentError.new("two-key aggregate projection key columns must have equal lengths")
      end
      validate_compound_index_size!(first_keys.size, rows_per_mark)
      retained_aggregates, count_total = retain_aggregate_columns(aggregates, first_keys.size)

      retained_first_keys = Array(UInt64).new(first_keys.size)
      retained_second_keys = Array(UInt64).new(second_keys.size)
      previous_first = 0_u64
      previous_second = 0_u64
      first_keys.each_with_index do |first, index|
        second = second_keys[index]
        if index > 0 && (first < previous_first || (first == previous_first && second <= previous_second))
          raise ArgumentError.new("aggregate projection key pairs must be strictly increasing lexicographically")
        end
        retained_first_keys << first
        retained_second_keys << second
        previous_first = first
        previous_second = second
      end

      retained_columns = Array(CompactPartColumn).new(retained_aggregates.size + 1)
      retained_columns << build_uint64_key_column(key_names[1], retained_second_keys, rows_per_mark)
      build_aggregate_columns(retained_aggregates, rows_per_mark).each { |column| retained_columns << column }

      new(
        String.new(name.to_slice), String.new(key_names[0].to_slice),
        retained_first_keys, retained_columns, rows_per_mark, frame_bytes.to_i32,
        CompactMarkFormat::Mrk4, CompactVariantDiscriminatorMode::Compact,
        compress_marks, BinaryBulkProfile.with_size_stream, nil, count_total,
        retained_aggregates, [String.new(key_names[1].to_slice)] of String,
        [retained_second_keys] of Array(UInt64), compress_primary_key,
      )
    end

    # Retains ordered UInt64 group-key columns and caller-computed aggregate
    # states in the Compact MRK4 projection profile.
    def self.precomputed_aggregate(
      name : String,
      key_names : Array(String),
      keys : Array(Slice(UInt64)),
      aggregates : Array(WidePartProjectionAggregate),
      *,
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      compress_marks : Bool = false,
      compress_primary_key : Bool = false,
    ) : CompactPartProjection
      validate_aggregate_projection_options!(name, rows_per_mark, frame_bytes)
      key_names.each { |key_name| validate_column_name!(key_name) }
      unless key_names.size > 0 && key_names.size == keys.size && !keys.empty?
        raise ArgumentError.new("aggregate projection key names and columns must share one nonempty roster")
      end
      if keys[0].empty? || keys[0].size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("an aggregate projection requires a bounded nonempty UInt64 key stream")
      end

      retained_aggregates, count_total = retain_aggregate_columns(aggregates, keys[0].size)
      if keys.size > 2
        ProjectionUInt64Keys.preflight_additional_key_carriers!(
          keys[0].size, keys.size - 1, rows_per_mark, WidePartTable::MAX_MARKS_PER_READER
        )
      end
      retained_names, retained_key_columns = ProjectionUInt64Keys.snapshot(
        key_names,
        keys,
        rows_per_mark,
        retained_aggregates.size,
        WidePartTable::MAX_COLUMNS,
        WidePartTable::MAX_MARKS_PER_READER,
      )
      additional_names = Array(String).new(retained_names.size - 1) do |index|
        retained_names[index + 1]
      end
      additional_keys = Array(Array(UInt64)).new(retained_key_columns.size - 1) do |index|
        retained_key_columns[index + 1]
      end

      retained_columns = Array(CompactPartColumn).new(additional_keys.size + retained_aggregates.size)
      additional_keys.each_with_index do |key_values, index|
        retained_columns << build_uint64_key_column(
          retained_names[index + 1], key_values, rows_per_mark, "compound aggregate"
        )
      end
      build_aggregate_columns(retained_aggregates, rows_per_mark).each do |column|
        retained_columns << column
      end

      new(
        String.new(name.to_slice), retained_names[0], retained_key_columns[0],
        retained_columns, rows_per_mark, frame_bytes.to_i32,
        CompactMarkFormat::Mrk4, CompactVariantDiscriminatorMode::Compact,
        compress_marks, BinaryBulkProfile.with_size_stream, nil, count_total,
        retained_aggregates, additional_names, additional_keys, compress_primary_key,
      )
    end

    def name : String
      String.new(@name.to_slice)
    end

    def key_name : String
      String.new(@key_name.to_slice)
    end

    # Returns the physical group-key order. Existing projections continue to
    # report their original one-key roster.
    def key_names : Array(String)
      names = [String.new(@key_name.to_slice)] of String
      @additional_key_names.each { |name| names << String.new(name.to_slice) }
      names
    end

    def additional_key_columns : Array(Array(UInt64))
      @additional_key_columns.map(&.dup)
    end

    # :nodoc:
    def secondary_key_name : String?
      @additional_key_names.first?.try { |name| String.new(name.to_slice) }
    end

    # :nodoc:
    def secondary_keys : Array(UInt64)?
      @additional_key_columns.first?.try(&.dup)
    end

    def keys : Array(UInt64)
      @keys.dup
    end

    def columns : Array(CompactPartColumn)
      @columns.dup
    end

    # Retains caller aggregate order while detaching the roster. The state
    # owners already hold detached UInt64 vectors.
    def aggregate_columns : Array(WidePartProjectionAggregate)
      @aggregate_columns.dup
    end

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
    def with_schema_binding(binding : PartSchemaBinding) : CompactPartProjection
      self.class.with_schema_binding(self, binding)
    end

    # :nodoc:
    protected def self.with_schema_binding(
      source : CompactPartProjection,
      binding : PartSchemaBinding,
    ) : CompactPartProjection
      new(
        source.@name, source.@key_name, source.@keys, source.@columns,
        source.@rows_per_mark, source.@frame_bytes, source.@mark_format,
        source.@variant_discriminator_mode, source.@compress_marks, source.@profile,
        binding, source.@count_total, source.@aggregate_columns,
        source.@additional_key_names, source.@additional_key_columns,
        source.@compress_primary_key,
      )
    end

    # :nodoc:
    def schema_binding : PartSchemaBinding?
      @schema_binding
    end

    # :nodoc:
    def count_total : UInt128?
      @count_total
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

    private def self.validate_aggregate_projection_options!(
      name : String,
      rows_per_mark : Int32,
      frame_bytes : Int,
    ) : Nil
      validate_projection_name!(name)
      unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK &&
             rows_per_mark <= WidePartTable::MAX_MARK_ROWS
        raise ArgumentError.new("projection rows_per_mark is outside the Compact reader limit")
      end
      unless frame_bytes > 0 && frame_bytes <= Int32::MAX
        raise ArgumentError.new("projection frame_bytes is outside the Compact writer limit")
      end
      nil
    end

    private def self.retain_aggregate_columns(
      aggregates : Array(WidePartProjectionAggregate),
      expected_rows : Int,
    ) : Tuple(Array(WidePartProjectionAggregate), UInt128?)
      unless aggregates.size > 0 && aggregates.size <= 4
        raise ArgumentError.new("an aggregate projection requires one to four aggregate columns")
      end
      retained = aggregates.dup
      count_total : UInt128? = nil
      seen_functions = Set(WidePartProjectionAggregateDescriptor::Function).new
      retained.each do |aggregate|
        unless aggregate.value_count == expected_rows
          raise ArgumentError.new("aggregate projection keys and values must have equal lengths")
        end
        unless seen_functions.add?(aggregate.descriptor.function)
          raise ArgumentError.new("aggregate projection may contain each admitted function only once")
        end
        count_total = aggregate.count_total if aggregate.count?
      end
      {retained, count_total}
    end

    private def self.build_aggregate_columns(
      aggregates : Array(WidePartProjectionAggregate),
      rows_per_mark : Int32,
    ) : Array(CompactPartColumn)
      columns = Array(CompactPartColumn).new(aggregates.size)
      aggregates.each do |aggregate|
        descriptor = aggregate.descriptor
        granules = aggregate.state_granules(rows_per_mark, WidePartTable::MAX_MARKS_PER_READER)
        columns << CompactPartColumn.binary_bulk(descriptor.column_name, descriptor.type, granules)
      end
      columns
    end

    private def self.build_uint64_key_column(
      name : String,
      keys : Array(UInt64),
      rows_per_mark : Int32,
      aggregate_name : String = "two-key aggregate",
    ) : CompactPartColumn
      type = BinaryDataType.primitive("UInt64")
      granules = ProjectionUInt64Keys.uint64_granules(
        keys, rows_per_mark, WidePartTable::MAX_MARKS_PER_READER, type, aggregate_name
      )
      CompactPartColumn.binary_bulk(name, type, granules)
    end

    private def self.validate_compound_index_size!(row_count : Int, rows_per_mark : Int32) : Nil
      mark_count = (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      entries = mark_count + 1_i64
      if entries > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_i64 ||
         entries > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES // 16_i64 ||
         entries * 16_i64 > Int32::MAX
        raise ArgumentError.new("compound primary index exceeds reader limit")
      end
      nil
    end
  end
end
