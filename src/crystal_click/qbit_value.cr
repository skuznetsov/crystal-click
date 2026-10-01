module CrystalClick
  # Owned row of exact little-endian QBit element bits. No Float conversion is
  # performed, so NaN payloads, infinities, and signed zero remain bitwise.
  struct QBitValue
    @type : QBitType
    @raw : Bytes

    def initialize(base_type : QBitType, raw : Bytes)
      raise ArgumentError.new("QBit raw row width does not match exact dimension and element type") unless raw.size == base_type.raw_row_bytes
      @type = base_type
      @raw = Bytes.new(raw.size) { |index| raw[index] }
    end

    def type : QBitType
      @type
    end

    def size : UInt64
      @type.dimension
    end

    def raw_bytesize : Int32
      @raw.size
    end

    # A defensive export. Codec internals use checked byte access/copy methods
    # below so a plane callback never allocates a full raw-row copy.
    def raw_bytes : Bytes
      Bytes.new(@raw.size) { |index| @raw[index] }
    end

    def raw_byte_at(index : Int32) : UInt8
      raise IndexError.new("QBit raw byte index is outside the row") if index < 0 || index >= @raw.size
      @raw[index]
    end

    def copy_raw_to(destination : Bytes, offset : Int32 = 0) : Nil
      raise IndexError.new("QBit raw copy destination is too small") if offset < 0 || offset > destination.size - @raw.size
      @raw.copy_to(destination[offset, @raw.size])
      nil
    end

    def ==(other : self) : Bool
      return false unless @type == other.@type && @raw.size == other.@raw.size
      @raw.size.times { |index| return false unless @raw[index] == other.@raw[index] }
      true
    end

    def hash(hasher)
      hasher = @type.hash(hasher)
      @raw.each { |byte| hasher = byte.hash(hasher) }
      hasher
    end

    def to_s(io : IO) : Nil
      io << "QBitValue(" << @type.type_name << ", " << @raw.size << " raw bytes)"
    end
  end
end
