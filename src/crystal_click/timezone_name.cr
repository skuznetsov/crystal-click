module CrystalClick
  # Exact, immutable owner for one name admitted by the pinned ClickHouse
  # system.time_zones manifest or its canonical fixed-offset extension.
  class TimezoneName
    CATALOG_VERSION    = "ClickHouse 26.7.1.1315 system.time_zones"
    CATALOG_NAME_COUNT = 597
    FIXED_OFFSET_COUNT = 114
    MAX_NAME_BYTES     =  32

    @name : String

    def initialize(name : String)
      raise ArgumentError.new("timezone name is not admitted by the pinned ClickHouse catalog") unless self.class.admitted?(name)
      @name = String.new(name.to_slice)
    end

    def self.parse(name : String) : TimezoneName?
      return nil unless admitted?(name)
      new(name)
    end

    def self.catalog_version : String
      String.new(CATALOG_VERSION.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    def name_byte_size : Int32
      @name.bytesize
    end

    # Do not hand an IO the owned String's mutable byte slice. Apart from
    # preserving ownership, the byte-at-a-time seam avoids a detached zone
    # String during schema preflight/rendering.
    def append_name(io : IO) : Nil
      @name.to_slice.each { |byte| io.write_byte(byte) }
      nil
    end

    # Logical retained-object charge: this owner, the String object it owns,
    # and its exact UTF-8 bytes plus terminator.
    def logical_charge : UInt64
      instance_sizeof(TimezoneName).to_u64 +
        instance_sizeof(String).to_u64 +
        @name.bytesize.to_u64 + 1_u64
    end

    def ==(other : self) : Bool
      @name == other.@name
    end

    def hash(hasher)
      @name.hash(hasher)
    end

    private def self.canonical_fixed_offset?(bytes : Bytes, first : Int32, after : Int32) : Bool
      return false unless after - first == 18
      return false unless slice_equals?(bytes, first, first + 9, "Fixed/UTC")
      return false unless bytes[first + 9] == '+'.ord.to_u8 || bytes[first + 9] == '-'.ord.to_u8
      return false unless bytes[first + 12] == ':'.ord.to_u8 && bytes[first + 15] == ':'.ord.to_u8
      return false unless bytes[first + 16] == '0'.ord.to_u8 && bytes[first + 17] == '0'.ord.to_u8
      return false unless digit?(bytes[first + 10]) && digit?(bytes[first + 11]) &&
                          digit?(bytes[first + 13]) && digit?(bytes[first + 14])

      hours = (bytes[first + 10] - '0'.ord.to_u8).to_i32 * 10 + (bytes[first + 11] - '0'.ord.to_u8).to_i32
      minutes = (bytes[first + 13] - '0'.ord.to_u8).to_i32 * 10 + (bytes[first + 14] - '0'.ord.to_u8).to_i32
      hours <= 14 && (hours < 14 || minutes == 0) && minutes <= 59 && minutes % 15 == 0
    end

    private def self.digit?(byte : UInt8) : Bool
      byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
    end

    # Public so direct construction enforces the same admission boundary as
    # parsing and factories; the mutable manifest itself remains private.
    def self.admitted?(name : String) : Bool
      admitted_slice?(name.to_slice, 0, name.bytesize)
    end

    # Nonallocating admission for a borrowed token range. The range is checked
    # before either catalog or fixed-offset matching reads from it.
    def self.admitted_slice?(bytes : Bytes, first : Int32, after : Int32) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false if after == first || after - first > MAX_NAME_BYTES
      bytes[first, after - first].each do |byte|
        return false unless byte >= 0x21_u8 && byte <= 0x7e_u8
      end
      ClickHouseTimezoneCatalog26_7_1_1315.includes_slice?(bytes, first, after) ||
        canonical_fixed_offset?(bytes, first, after)
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless bytes[first + index] == expected_bytes[index]
      end
      true
    end
  end
end
