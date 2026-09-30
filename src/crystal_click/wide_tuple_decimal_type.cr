module CrystalClick
  # Exact precision/scale descriptor for a raw signed Decimal Tuple leaf.
  class WideTupleDecimalType
    alias Buffer = Array(Decimal32Value) | Array(Decimal64Value) |
                   Array(Decimal128Value) | Array(Decimal256TupleValue)

    @precision : Int32
    @scale : Int32
    @storage_width : Int32
    @type_name : String

    def initialize(@precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal precision must be between 1 and 76") unless @precision >= 1 && @precision <= 76
      raise ArgumentError.new("Decimal scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
      @storage_width = if @precision <= 9
                         4
                       elsif @precision <= 18
                         8
                       elsif @precision <= 38
                         16
                       else
                         32
                       end
      @type_name = "Decimal(#{@precision}, #{@scale})"
    end

    def precision : Int32
      @precision
    end

    def scale : Int32
      @scale
    end

    def storage_width : Int32
      @storage_width
    end

    def width : Int32
      @storage_width
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def logical_charge : UInt64
      instance_sizeof(WideTupleDecimalType).to_u64 +
        instance_sizeof(String).to_u64 + @type_name.bytesize.to_u64 + 1_u64
    end

    def validate_buffer!(buffer : Buffer) : Nil
      case @storage_width
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
      @precision == other.precision && @scale == other.scale
    end

    def hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @scale.hash(hasher)
      hasher
    end

    private def validate_value!(precision : Int32, scale : Int32) : Nil
      unless precision == @precision && scale == @scale
        raise ArgumentError.new("Decimal Tuple value precision/scale does not match exact type")
      end
      nil
    end
  end
end
