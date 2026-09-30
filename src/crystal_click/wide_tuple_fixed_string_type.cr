module CrystalClick
  # Exact Tuple-local descriptor for FixedString(N). It is intentionally
  # separate from String and from physical numeric identities.
  class WideTupleFixedStringType
    alias Buffer = Array(FixedStringValue)

    @width : Int32
    @type_name : String

    def initialize(width : Int32)
      raise ArgumentError.new("FixedString width must be between 1 and 65536") unless width >= 1 && width <= 65_536
      @width = width
      @type_name = "FixedString(#{width})"
    end

    def width : Int32
      @width
    end

    def storage_width : Int32
      @width
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    # Logical storage retained by this descriptor: its class instance and the
    # separately owned canonical String header, bytes, and terminator.
    def logical_charge : UInt64
      instance_sizeof(WideTupleFixedStringType).to_u64 +
        instance_sizeof(String).to_u64 + @type_name.bytesize.to_u64 + 1_u64
    end

    def validate_buffer!(buffer : Buffer) : Nil
      raise ArgumentError.new("FixedString buffer does not match exact family") unless buffer.is_a?(Array(FixedStringValue))
      buffer.each do |value|
        raise ArgumentError.new("FixedString value width does not match exact type") unless value.width == @width
      end
      nil
    end

    def ==(other : self) : Bool
      @width == other.width
    end

    def hash(hasher)
      hasher = @width.hash(hasher)
      hasher
    end
  end
end
