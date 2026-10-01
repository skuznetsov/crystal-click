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

    private def self.canonical_fixed_offset?(name : String) : Bool
      bytes = name.to_slice
      return false unless bytes.size == 18
      return false unless name.starts_with?("Fixed/UTC")
      return false unless bytes[9] == '+'.ord.to_u8 || bytes[9] == '-'.ord.to_u8
      return false unless bytes[12] == ':'.ord.to_u8 && bytes[15] == ':'.ord.to_u8
      return false unless bytes[16] == '0'.ord.to_u8 && bytes[17] == '0'.ord.to_u8
      return false unless digit?(bytes[10]) && digit?(bytes[11]) &&
                          digit?(bytes[13]) && digit?(bytes[14])

      hours = (bytes[10] - '0'.ord.to_u8).to_i32 * 10 + (bytes[11] - '0'.ord.to_u8).to_i32
      minutes = (bytes[13] - '0'.ord.to_u8).to_i32 * 10 + (bytes[14] - '0'.ord.to_u8).to_i32
      hours <= 14 && (hours < 14 || minutes == 0) && minutes <= 59 && minutes % 15 == 0
    end

    private def self.digit?(byte : UInt8) : Bool
      byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
    end

    # Public so direct construction enforces the same admission boundary as
    # parsing and factories; the mutable manifest itself remains private.
    def self.admitted?(name : String) : Bool
      return false if name.empty? || name.bytesize > MAX_NAME_BYTES
      # The catalog is line-delimited. Restrict names to visible ASCII so a
      # caller cannot inject line boundaries into the membership probe.
      name.to_slice.each do |byte|
        return false unless byte >= 0x21_u8 && byte <= 0x7e_u8
      end
      ClickHouseTimezoneCatalog26_7_1_1315.includes?(name) || canonical_fixed_offset?(name)
    end
  end
end
