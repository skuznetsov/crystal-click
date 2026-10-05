# Independent W168 roster and literal text/fixed-string fixtures. Keep this
# fixture source separate from production type admission and the Ruby oracle.
W168_SIMPLE_AGGREGATE_FUNCTIONS = [
  {"any", "any", CrystalClick::BinarySimpleAggregateType::Function::Any},
  {"anyLast", "any_last", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
  {"min", "min", CrystalClick::BinarySimpleAggregateType::Function::Min},
  {"max", "max", CrystalClick::BinarySimpleAggregateType::Function::Max},
] of Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function)

W168_SIMPLE_AGGREGATE_WIDTHS               = [1, 3, 130] of Int32
W168_SIMPLE_AGGREGATE_CARRIERS             = ["String", "FixedString(1)", "FixedString(3)", "FixedString(130)"]
W168_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER = W168_SIMPLE_AGGREGATE_CARRIERS.to_h do |carrier|
  {carrier, W168_SIMPLE_AGGREGATE_FUNCTIONS.map { |profile| profile[0] }}
end
W168_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES = 16
W168_SIMPLE_AGGREGATE_KEYS                     = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]

# Native-authored bare String values include empty, UTF-8, NUL, 0xff, and
# mixed binary rows. String remains length-prefixed and is never padded.
W168_STOCK_STRING_VALUES = [
  "",
  "A",
  String.new(Bytes[0xc3_u8, 0xa9_u8]),
  String.new(Bytes[0x00_u8, 0xff_u8, 0x41_u8]),
  "click",
  String.new(Bytes[0xff_u8]),
]

# Independently authored library values differ from the native source values.
W168_LIBRARY_STRING_VALUES = [
  "L",
  "",
  String.new(Bytes[0x00_u8, 0xff_u8, 0x01_u8]),
  "é",
  "the-end",
  String.new(Bytes[0xfe_u8]),
]

module W168SimpleAggregateTestSupport
  private def self.pattern(length : Int32, seed : Int32) : String
    String.new(Bytes.new(length) { |index| ((index * 37 + seed) & 0xff).to_u8 })
  end

  private def self.fixed_stock_values(width : Int32) : Array(String)
    seeds = case width
            when 1
              [String.new(Bytes[0x00_u8]), "A", String.new(Bytes[0xff_u8]), String.new(Bytes[0xc3_u8]), "z", String.new(Bytes[0xfe_u8])]
            when 3
              ["", "a", "é", String.new(Bytes[0x61_u8, 0x00_u8, 0x62_u8]), String.new(Bytes[0xff_u8]), "XYZ"]
            when 130
              ["", String.new(Bytes[0x00_u8]), "a\0b", pattern(129, 11), pattern(130, 23), pattern(17, 47)]
            else
              raise ArgumentError.new("unsupported W168 FixedString fixture width")
            end
    seeds.map do |seed|
      raise "W168 fixture exceeds FixedString width" if seed.bytesize > width
      bytes = Bytes.new(width, 0_u8)
      seed.to_slice.copy_to(bytes) unless seed.empty?
      String.new(bytes)
    end
  end

  private def self.fixed_library_values(width : Int32) : Array(String)
    seeds = case width
            when 1
              ["", "x", String.new(Bytes[0x80_u8]), "y", String.new(Bytes[0xff_u8]), "z"]
            when 3
              ["x", "", String.new(Bytes[0x00_u8, 0xfe_u8]), "é", "abc", String.new(Bytes[0xff_u8])]
            when 130
              ["", "q", String.new(Bytes[0x00_u8, 0xff_u8]), pattern(128, 5), pattern(130, 91), pattern(1, 173)]
            else
              raise ArgumentError.new("unsupported W168 FixedString fixture width")
            end
    seeds.each do |seed|
      raise "W168 fixture exceeds FixedString width" if seed.bytesize > width
    end
    seeds
  end

  def self.nullable_values(values : Array(T)) : Array(T?) forall T
    result = Array(T?).new(values.size) { |index| values[index].as(T?) }
    result[3] = nil
    result
  end

  def self.profiles : Array(Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function))
    W168_SIMPLE_AGGREGATE_FUNCTIONS
  end

  def self.width_for(carrier : String) : Int32?
    return nil if carrier == "String"
    W168_SIMPLE_AGGREGATE_WIDTHS.find { |width| carrier == "FixedString(#{width})" }
  end

  def self.values(carrier : String, *, native : Bool) : Array(String)
    if carrier == "String"
      return native ? W168_STOCK_STRING_VALUES : W168_LIBRARY_STRING_VALUES
    end
    width = width_for(carrier) || raise ArgumentError.new("unknown W168 carrier: #{carrier}")
    native ? fixed_stock_values(width) : fixed_library_values(width)
  end

  def self.total_profile_count : Int32
    W168_SIMPLE_AGGREGATE_CARRIERS.size * W168_SIMPLE_AGGREGATE_FUNCTIONS.size
  end
end
