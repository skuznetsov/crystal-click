module CrystalClick
  # Immutable, owned bytes for a ClickHouse FixedString(N) value. The raw
  # Slice is never exposed; callers receive a defensive copy instead.
  struct FixedStringValue
    @width : Int32
    @bytes : Bytes

    def initialize(width : Int32, value : String)
      raise ArgumentError.new("FixedString width must be between 1 and 65536") unless width >= 1 && width <= 65_536
      raise ArgumentError.new("FixedString value exceeds declared width") if value.bytesize > width

      @width = width
      @bytes = Bytes.new(width, 0_u8)
      value.to_slice.copy_to(@bytes[0, value.bytesize])
    end

    private def initialize(@width : Int32, @bytes : Bytes)
    end

    def self.from_raw(width : Int32, bytes : Bytes) : self
      validate_width!(width)
      raise ArgumentError.new("FixedString raw bytes do not match declared width") unless bytes.size == width
      new(width, bytes.dup)
    end

    def width : Int32
      @width
    end

    def raw_bytes : Bytes
      @bytes.dup
    end

    def ==(other : self) : Bool
      return false unless @width == other.width && @bytes.size == other.raw_bytes.size
      other_bytes = other.raw_bytes
      @bytes.each_with_index.all? { |byte, index| byte == other_bytes[index] }
    end

    def hash(hasher)
      hasher = @width.hash(hasher)
      @bytes.each { |byte| hasher = byte.hash(hasher) }
      hasher
    end

    private def self.validate_width!(width : Int32) : Nil
      raise ArgumentError.new("FixedString width must be between 1 and 65536") unless width >= 1 && width <= 65_536
    end
  end
end
