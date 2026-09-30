module CrystalClick
  enum DecimalColumnShape
    Scalar
    NullableScalar
    Array
    ArrayNullable
    ArrayArray
    ArrayArrayNullable
  end

  # Bounded owner for the six admitted standalone Decimal column shapes.
  # Canonical part metadata and catalog DDL are parsed separately so aliases
  # can normalize at the catalog boundary without weakening persisted spelling.
  struct DecimalColumnType
    MAX_TYPE_BYTES = 128

    @decimal_type : DecimalType
    @shape : DecimalColumnShape

    def initialize(@decimal_type : DecimalType, @shape : DecimalColumnShape)
      case @shape
      when DecimalColumnShape::Scalar, DecimalColumnShape::NullableScalar, DecimalColumnShape::Array,
           DecimalColumnShape::ArrayNullable, DecimalColumnShape::ArrayArray, DecimalColumnShape::ArrayArrayNullable
      else
        raise ArgumentError.new("Unsupported Decimal column shape")
      end
    end

    def decimal_type : DecimalType
      @decimal_type
    end

    def shape : DecimalColumnShape
      @shape
    end

    def precision : Int32
      @decimal_type.precision
    end

    def scale : Int32
      @decimal_type.scale
    end

    def storage_width : Int32
      @decimal_type.storage_width
    end

    def nullable_leaf? : Bool
      @shape == DecimalColumnShape::NullableScalar || @shape == DecimalColumnShape::ArrayNullable ||
        @shape == DecimalColumnShape::ArrayArrayNullable
    end

    def array_depth : Int32
      case @shape
      when DecimalColumnShape::Scalar, DecimalColumnShape::NullableScalar
        0
      when DecimalColumnShape::Array, DecimalColumnShape::ArrayNullable
        1
      when DecimalColumnShape::ArrayArray, DecimalColumnShape::ArrayArrayNullable
        2
      else
        raise ArgumentError.new("Unsupported Decimal column shape")
      end
    end

    def type_name : String
      leaf = @decimal_type.type_name
      case @shape
      when DecimalColumnShape::Scalar
        leaf
      when DecimalColumnShape::NullableScalar
        "Nullable(#{leaf})"
      when DecimalColumnShape::Array
        "Array(#{leaf})"
      when DecimalColumnShape::ArrayNullable
        "Array(Nullable(#{leaf}))"
      when DecimalColumnShape::ArrayArray
        "Array(Array(#{leaf}))"
      when DecimalColumnShape::ArrayArrayNullable
        "Array(Array(Nullable(#{leaf})))"
      else
        raise ArgumentError.new("Unsupported Decimal column shape")
      end
    end

    # Strict persisted metadata parser: only canonical Decimal(P, S) leaves in
    # the six bounded shapes are admitted. Invalid or unsupported strings fail
    # closed without constructing a wider expression tree.
    def self.parse(type_name : String) : DecimalColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES
      shape, leaf = shape_and_leaf(type_name)
      decimal_type = DecimalType.parse(leaf) || return nil
      new(decimal_type, shape)
    end

    # Catalog-only grammar. The result is already normalized to the exact
    # canonical P/S descriptor while the caller retains the source DDL spelling.
    def self.parse_catalog(type_name : String) : DecimalColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES
      shape, leaf = shape_and_leaf(type_name)
      decimal_type = parse_catalog_leaf(leaf) || return nil
      new(decimal_type, shape)
    end

    def self.catalog_type(type_name : String) : String?
      parsed = parse_catalog(type_name) || return nil
      parsed.type_name
    end

    def ==(other : self) : Bool
      @decimal_type == other.decimal_type && @shape == other.shape
    end

    def hash(hasher)
      hasher = @decimal_type.hash(hasher)
      hasher = @shape.hash(hasher)
      hasher
    end

    private def self.shape_and_leaf(type_name : String) : Tuple(DecimalColumnShape, String)
      if leaf = unwrap(type_name, "Array(Array(Nullable(", 3)
        return {DecimalColumnShape::ArrayArrayNullable, leaf}
      elsif leaf = unwrap(type_name, "Array(Array(", 2)
        return {DecimalColumnShape::ArrayArray, leaf}
      elsif leaf = unwrap(type_name, "Array(Nullable(", 2)
        return {DecimalColumnShape::ArrayNullable, leaf}
      elsif leaf = unwrap(type_name, "Nullable(", 1)
        return {DecimalColumnShape::NullableScalar, leaf}
      elsif leaf = unwrap(type_name, "Array(", 1)
        return {DecimalColumnShape::Array, leaf}
      end

      {DecimalColumnShape::Scalar, type_name}
    end

    private def self.unwrap(type_name : String, prefix : String, closing_bytes : Int32) : String?
      return nil unless type_name.starts_with?(prefix) && type_name.ends_with?(")" * closing_bytes)
      leaf_bytes = type_name.bytesize - prefix.bytesize - closing_bytes
      return nil if leaf_bytes <= 0
      type_name.byte_slice(prefix.bytesize, leaf_bytes)
    end

    private def self.parse_catalog_leaf(leaf : String) : DecimalType?
      return DecimalType.new(10, 0) if leaf == "Decimal"
      if parsed = DecimalType.parse(leaf)
        return parsed
      end

      if match = /\ADecimal\(([0-9]+)\)\z/.match(leaf)
        precision = canonical_integer(match[1], allow_zero: false) || return nil
        return nil unless precision <= 76
        return DecimalType.new(precision, 0)
      end

      match = /\ADecimal(32|64|128|256)\(([0-9]+)\)\z/.match(leaf) || return nil
      family = match[1]
      scale = canonical_integer(match[2], allow_zero: true) || return nil
      precision = case family
                  when "32"  then 9
                  when "64"  then 18
                  when "128" then 38
                  when "256" then 76
                  else            return nil
                  end
      return nil if scale > precision
      DecimalType.new(precision, scale)
    end

    private def self.canonical_integer(source : String, allow_zero : Bool) : Int32?
      return nil unless source == "0" || source.matches?(/\A[1-9][0-9]*\z/)
      return nil if !allow_zero && source == "0"
      source.to_i?
    end
  end
end
