module CrystalClick
  # Exact persisted identity and raw storage shape for DateTime and DateTime64.
  # Timezone provenance is column metadata: value wrappers remain raw instants.
  class DateTimeColumnType
    MAX_TYPE_BYTES = 128

    enum Family
      DateTime
      DateTime64
    end

    enum Shape
      Scalar
      Nullable
      Array
      ArrayNullable
      ArrayArray
      ArrayArrayNullable
    end

    @family : Family
    @precision : UInt8?
    @time_zone : TimezoneName?
    @shape : Shape

    def initialize(
      @family : Family,
      @precision : UInt8?,
      @time_zone : TimezoneName?,
      @shape : Shape,
    )
      case @family
      when Family::DateTime
        raise ArgumentError.new("DateTime cannot carry a precision") unless @precision.nil?
      when Family::DateTime64
        scale = @precision || raise(ArgumentError.new("DateTime64 requires a precision"))
        raise ArgumentError.new("DateTime64 precision must be between 0 and 9") unless scale <= 9_u8
      else
        raise ArgumentError.new("unsupported DateTime family")
      end
      case @shape
      when Shape::Scalar, Shape::Nullable, Shape::Array, Shape::ArrayNullable,
           Shape::ArrayArray, Shape::ArrayArrayNullable
      else
        raise ArgumentError.new("unsupported DateTime column shape")
      end
    end

    def self.datetime(time_zone : String? = nil) : DateTimeColumnType
      new(Family::DateTime, nil, parse_time_zone(time_zone), Shape::Scalar)
    end

    def self.datetime64(scale : Int32, time_zone : String? = nil) : DateTimeColumnType
      raise ArgumentError.new("DateTime64 precision must be between 0 and 9") unless scale >= 0 && scale <= 9
      new(Family::DateTime64, scale.to_u8, parse_time_zone(time_zone), Shape::Scalar)
    end

    def self.parse(type_name : String) : DateTimeColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES
      shape, leaf = shape_and_leaf(type_name)
      parsed = parse_leaf(leaf) || return nil
      new(parsed.family, parsed.precision?, parsed.time_zone?, shape)
    end

    # Parse only a scalar leaf. Persisted type strings must use the exact
    # canonical ClickHouse spelling; catalog DDL normalization is separate.
    def self.parse_leaf(type_name : String) : DateTimeColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES

      if type_name == "DateTime"
        return new(Family::DateTime, nil, nil, Shape::Scalar)
      end

      if match = /\ADateTime\('([^']+)'\)\z/.match(type_name)
        zone = TimezoneName.parse(match[1]) || return nil
        return new(Family::DateTime, nil, zone, Shape::Scalar)
      end

      if match = /\ADateTime64\(([0-9])\)\z/.match(type_name)
        return new(Family::DateTime64, match[1].to_u8, nil, Shape::Scalar)
      end

      if match = /\ADateTime64\(([0-9]), '([^']+)'\)\z/.match(type_name)
        zone = TimezoneName.parse(match[2]) || return nil
        return new(Family::DateTime64, match[1].to_u8, zone, Shape::Scalar)
      end

      nil
    end

    # Catalog-only normalization for harmless SQL parameter whitespace and
    # compact commas. The returned name is canonical and preserves the exact
    # timezone token; this path must never parse persisted columns.txt text.
    def self.parse_catalog(type_name : String) : DateTimeColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES
      shape, leaf = shape_and_leaf(type_name)
      parsed = parse_catalog_leaf(leaf) || return nil
      new(parsed.family, parsed.precision?, parsed.time_zone?, shape)
    end

    def self.catalog_type(type_name : String) : String?
      parse_catalog(type_name).try(&.type_name)
    end

    def family : Family
      @family
    end

    def precision? : UInt8?
      @precision
    end

    def time_zone? : TimezoneName?
      @time_zone
    end

    def shape : Shape
      @shape
    end

    def array_depth : Int32
      case @shape
      when Shape::Scalar, Shape::Nullable
        0
      when Shape::Array, Shape::ArrayNullable
        1
      when Shape::ArrayArray, Shape::ArrayArrayNullable
        2
      else
        raise ArgumentError.new("unsupported DateTime column shape")
      end
    end

    def nullable_leaf? : Bool
      @shape == Shape::Nullable || @shape == Shape::ArrayNullable ||
        @shape == Shape::ArrayArrayNullable
    end

    def raw_width : Int32
      @family == Family::DateTime ? 4 : 8
    end

    def leaf_type_name : String
      zone = @time_zone
      case @family
      when Family::DateTime
        zone ? "DateTime('#{zone.name}')" : String.new("DateTime".to_slice)
      when Family::DateTime64
        scale = @precision.not_nil!
        zone ? "DateTime64(#{scale}, '#{zone.name}')" : "DateTime64(#{scale})"
      else
        raise ArgumentError.new("unsupported DateTime family")
      end
    end

    def type_name : String
      leaf = leaf_type_name
      case @shape
      when Shape::Scalar
        leaf
      when Shape::Nullable
        "Nullable(#{leaf})"
      when Shape::Array
        "Array(#{leaf})"
      when Shape::ArrayNullable
        "Array(Nullable(#{leaf}))"
      when Shape::ArrayArray
        "Array(Array(#{leaf}))"
      when Shape::ArrayArrayNullable
        "Array(Array(Nullable(#{leaf})))"
      else
        raise ArgumentError.new("unsupported DateTime column shape")
      end
    end

    def with_shape(shape : Shape) : DateTimeColumnType
      DateTimeColumnType.new(@family, @precision, @time_zone, shape)
    end

    # Logical descriptor storage includes the descriptor object. The timezone
    # owner is charged once by this descriptor; computed type-name Strings are
    # intentionally never retained.
    def logical_charge : UInt64
      charge = instance_sizeof(DateTimeColumnType).to_u64
      if zone = @time_zone
        charge += zone.logical_charge
      end
      charge
    end

    def ==(other : self) : Bool
      @family == other.@family &&
        @precision == other.@precision &&
        @time_zone == other.@time_zone &&
        @shape == other.@shape
    end

    def hash(hasher)
      hasher = @family.hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @time_zone.hash(hasher)
      hasher = @shape.hash(hasher)
      hasher
    end

    private def self.parse_time_zone(time_zone : String?) : TimezoneName?
      return nil unless time_zone
      TimezoneName.parse(time_zone) || raise(ArgumentError.new("timezone name is not admitted by the pinned ClickHouse catalog"))
    end

    private def self.parse_catalog_leaf(type_name : String) : DateTimeColumnType?
      if parsed = parse_leaf(type_name)
        return parsed
      end

      if type_name == "DateTime"
        return new(Family::DateTime, nil, nil, Shape::Scalar)
      end

      if match = /\ADateTime\s*\(\s*'([^']+)'\s*\)\z/.match(type_name)
        zone = TimezoneName.parse(match[1]) || return nil
        return new(Family::DateTime, nil, zone, Shape::Scalar)
      end

      if match = /\ADateTime64\s*\(\s*([0-9])\s*\)\z/.match(type_name)
        return new(Family::DateTime64, match[1].to_u8, nil, Shape::Scalar)
      end

      if match = /\ADateTime64\s*\(\s*([0-9])\s*,\s*'([^']+)'\s*\)\z/.match(type_name)
        zone = TimezoneName.parse(match[2]) || return nil
        return new(Family::DateTime64, match[1].to_u8, zone, Shape::Scalar)
      end

      nil
    end

    private def self.shape_and_leaf(type_name : String) : {Shape, String}
      if leaf = unwrap(type_name, "Array(Array(Nullable(", 3)
        {Shape::ArrayArrayNullable, leaf}
      elsif leaf = unwrap(type_name, "Array(Array(", 2)
        {Shape::ArrayArray, leaf}
      elsif leaf = unwrap(type_name, "Array(Nullable(", 2)
        {Shape::ArrayNullable, leaf}
      elsif leaf = unwrap(type_name, "Nullable(", 1)
        {Shape::Nullable, leaf}
      elsif leaf = unwrap(type_name, "Array(", 1)
        {Shape::Array, leaf}
      else
        {Shape::Scalar, type_name}
      end
    end

    private def self.unwrap(type_name : String, prefix : String, closing_bytes : Int32) : String?
      return nil unless type_name.starts_with?(prefix) && type_name.ends_with?(")" * closing_bytes)
      leaf_bytes = type_name.bytesize - prefix.bytesize - closing_bytes
      return nil if leaf_bytes <= 0
      type_name.byte_slice(prefix.bytesize, leaf_bytes)
    end
  end
end
