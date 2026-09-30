module CrystalClick
  # Exact Decimal leaf identity shared by Tuple, standalone columns and
  # composites. The value is intentionally only P/S; width and canonical name
  # are derived so embedding it does not add a retained String allocation.
  struct DecimalType
    MAX_LEAF_BYTES = 64

    getter precision : Int32
    getter scale : Int32

    def initialize(@precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal precision must be between 1 and 76") unless @precision >= 1 && @precision <= 76
      raise ArgumentError.new("Decimal scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
    end

    def storage_width : Int32
      if @precision <= 9
        4
      elsif @precision <= 18
        8
      elsif @precision <= 38
        16
      else
        32
      end
    end

    def width : Int32
      storage_width
    end

    def type_name : String
      "Decimal(#{@precision}, #{@scale})"
    end

    # Parse only the canonical persisted leaf spelling. DDL shorthands and
    # aliases belong to DecimalColumnType so writer/part metadata stays exact.
    def self.parse(type_name : String) : DecimalType?
      return nil if type_name.bytesize > MAX_LEAF_BYTES
      match = /\ADecimal\(([0-9]+), ([0-9]+)\)\z/.match(type_name) || return nil

      precision = canonical_integer(match[1], allow_zero: false) || return nil
      scale = canonical_integer(match[2], allow_zero: true) || return nil
      return nil unless precision <= 76 && scale <= precision

      new(precision, scale)
    end

    def ==(other : self) : Bool
      @precision == other.precision && @scale == other.scale
    end

    def hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @scale.hash(hasher)
      hasher
    end

    private def self.canonical_integer(source : String, allow_zero : Bool) : Int32?
      return nil unless source == "0" || source.matches?(/\A[1-9][0-9]*\z/)
      return nil if !allow_zero && source == "0"
      source.to_i?
    end
  end
end
