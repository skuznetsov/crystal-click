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
    getter profile : BinaryBulkProfile

    @name : String
    @key_name : String
    @keys : Array(UInt64)
    @columns : Array(CompactPartColumn)
    @schema_binding : PartSchemaBinding?
    @count_total : UInt128?

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
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("a count projection requires a bounded nonempty UInt64 key stream")
      end
      unless counts.size == keys.size
        raise ArgumentError.new("count projection keys and counts must have equal lengths")
      end

      retained_keys = Array(UInt64).new(keys.size)
      retained_counts = Array(UInt64).new(counts.size)
      total = 0_u128
      keys.each_with_index do |key, index|
        if index > 0 && key <= retained_keys[index - 1]
          raise ArgumentError.new("count projection keys must be strictly increasing")
        end
        retained_keys << key

        count = counts[index]
        if count == 0_u64
          raise ArgumentError.new("count projection values must be positive")
        end
        count128 = count.to_u128
        if count128 > UInt128::MAX - total
          raise ArgumentError.new("count projection total overflows UInt128")
        end
        retained_counts << count
        total += count128
      end

      count_type = BinaryDataType.aggregate_count
      mark_count = (retained_counts.size - 1) // rows_per_mark + 1
      count_granules = Array(Array(BinaryValue)).new(mark_count)
      offset = 0
      while offset < retained_counts.size
        rows = {rows_per_mark, retained_counts.size - offset}.min
        granule = Array(BinaryValue).new(rows)
        rows.times do |row|
          granule << BinaryValue.aggregate_count_state(count_type, retained_counts[offset + row])
        end
        count_granules << granule
        offset += rows
      end
      count_column = CompactPartColumn.binary_bulk("count()", count_type, count_granules)

      new(
        String.new(name.to_slice), String.new(key_name.to_slice), retained_keys,
        [count_column] of CompactPartColumn, rows_per_mark, frame_bytes.to_i32,
        CompactMarkFormat::Mrk4, CompactVariantDiscriminatorMode::Compact,
        compress_marks, BinaryBulkProfile.with_size_stream, nil, total,
      )
    end

    def name : String
      String.new(@name.to_slice)
    end

    def key_name : String
      String.new(@key_name.to_slice)
    end

    def keys : Array(UInt64)
      @keys.dup
    end

    def columns : Array(CompactPartColumn)
      @columns.dup
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
        binding, source.@count_total,
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
  end
end
