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
