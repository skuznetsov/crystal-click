module CrystalClick
  # Exact precision/scale descriptor for a raw signed Decimal Tuple leaf.
  class WideTupleDecimalType
    alias Buffer = Array(Decimal32Value) | Array(Decimal64Value) |
                   Array(Decimal128Value) | Array(Decimal256TupleValue)

    @decimal_type : DecimalType
    @type_name : String

    def initialize(precision : Int32, scale : Int32)
      @decimal_type = DecimalType.new(precision, scale)
      @type_name = @decimal_type.type_name
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

    def width : Int32
      @decimal_type.storage_width
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def logical_charge : UInt64
      instance_sizeof(WideTupleDecimalType).to_u64 +
        instance_sizeof(String).to_u64 + @type_name.bytesize.to_u64 + 1_u64
    end

    def validate_buffer!(buffer : Buffer) : Nil
      case storage_width
      when 4
        raise ArgumentError.new("Decimal buffer does not match exact storage width") unless buffer.is_a?(Array(Decimal32Value))
        buffer.each { |value| validate_value!(value.precision, value.scale) }
      when 8
        raise ArgumentError.new("Decimal buffer does not match exact storage width") unless buffer.is_a?(Array(Decimal64Value))
        buffer.each { |value| validate_value!(value.precision, value.scale) }
      when 16
        raise ArgumentError.new("Decimal buffer does not match exact storage width") unless buffer.is_a?(Array(Decimal128Value))
        buffer.each { |value| validate_value!(value.precision, value.scale) }
      else
        raise ArgumentError.new("Decimal buffer does not match exact storage width") unless buffer.is_a?(Array(Decimal256TupleValue))
        buffer.each { |value| validate_value!(value.precision, value.scale) }
      end
      nil
    end

    def ==(other : self) : Bool
      precision == other.precision && scale == other.scale
    end

    def hash(hasher)
      @decimal_type.hash(hasher)
    end

    private def validate_value!(precision : Int32, scale : Int32) : Nil
      unless precision == @decimal_type.precision && scale == @decimal_type.scale
        raise ArgumentError.new("Decimal Tuple value precision/scale does not match exact type")
      end
      nil
    end
  end
end
