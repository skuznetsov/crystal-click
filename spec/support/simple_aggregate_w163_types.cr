# Independent W163 profile roster. Keep this separate from production dispatch:
# ClickHouse rejects small-integer/Float32/BFloat16 sum result widening and all
# floating bitwise combinations for this exact storage declaration.
W163_SIMPLE_AGGREGATE_FUNCTIONS = [
  {"any", "any", CrystalClick::BinarySimpleAggregateType::Function::Any},
  {"anyLast", "any_last", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
  {"min", "min", CrystalClick::BinarySimpleAggregateType::Function::Min},
  {"max", "max", CrystalClick::BinarySimpleAggregateType::Function::Max},
  {"sum", "sum", CrystalClick::BinarySimpleAggregateType::Function::Sum},
  {"sumWithOverflow", "sum_with_overflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow},
  {"groupBitAnd", "group_bit_and", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd},
  {"groupBitOr", "group_bit_or", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr},
  {"groupBitXor", "group_bit_xor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor},
] of Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function)

# Literal eligible function names by exact child carrier; do not derive this
# matrix from the library's supported-carrier predicate.
W163_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER = {
  "UInt8"   => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "UInt16"  => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "UInt32"  => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "UInt64"  => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int8"    => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int16"   => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int32"   => ["any", "anyLast", "min", "max", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int64"   => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Float32" => ["any", "anyLast", "min", "max", "sumWithOverflow"],
  "Float64" => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow"],
}

W163_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES = 77
W163_SIMPLE_AGGREGATE_KEYS                     = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]

# Stock-authored values are deliberately different from the library-authored
# values. Integer extrema and sign/high-bit boundaries are included.
W163_STOCK_UINT8_VALUES   = [0_u8, 1_u8, 0x7f_u8, 0x80_u8, 0xfe_u8, 0xff_u8]
W163_STOCK_UINT16_VALUES  = [0_u16, 1_u16, 0x7fff_u16, 0x8000_u16, 0xfffe_u16, 0xffff_u16]
W163_STOCK_UINT32_VALUES  = [0_u32, 1_u32, 0x7fff_ffff_u32, 0x8000_0000_u32, 0xffff_fffe_u32, 0xffff_ffff_u32]
W163_STOCK_UINT64_VALUES  = [0_u64, 1_u64, 0x7fff_ffff_ffff_ffff_u64, 0x8000_0000_0000_0000_u64, 0xffff_ffff_ffff_fffe_u64, 0xffff_ffff_ffff_ffff_u64]
W163_STOCK_INT8_VALUES    = [Int8::MIN, -1_i8, 0_i8, 1_i8, 126_i8, Int8::MAX]
W163_STOCK_INT16_VALUES   = [Int16::MIN, -1_i16, 0_i16, 1_i16, 32_766_i16, Int16::MAX]
W163_STOCK_INT32_VALUES   = [Int32::MIN, -1_i32, 0_i32, 1_i32, 2_147_483_646_i32, Int32::MAX]
W163_STOCK_INT64_VALUES   = [Int64::MIN, -1_i64, 0_i64, 1_i64, 9_223_372_036_854_775_806_i64, Int64::MAX]
W163_STOCK_FLOAT32_VALUES = [
  0x8000_0000_u32.unsafe_as(Float32),
  0x3fc0_0000_u32.unsafe_as(Float32),
  0xc010_0000_u32.unsafe_as(Float32),
  0x7f7f_ffff_u32.unsafe_as(Float32),
  0xff7f_ffff_u32.unsafe_as(Float32),
  0x0000_0001_u32.unsafe_as(Float32),
]
W163_STOCK_FLOAT64_VALUES = [
  0x8000_0000_0000_0000_u64.unsafe_as(Float64),
  0x3ff8_0000_0000_0000_u64.unsafe_as(Float64),
  0xc002_0000_0000_0000_u64.unsafe_as(Float64),
  0x7fef_ffff_ffff_ffff_u64.unsafe_as(Float64),
  0xffef_ffff_ffff_ffff_u64.unsafe_as(Float64),
  0x0000_0000_0000_0001_u64.unsafe_as(Float64),
]

# Library-authored values use a separate asymmetric literal set. Float values
# are bitcasts of finite IEEE encodings (including negative zero); no NaNs or
# text-based float conversion are involved.
W163_LIBRARY_UINT8_VALUES  = [0x11_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8]
W163_LIBRARY_UINT16_VALUES = [0x0102_u16, 0x1234_u16, 0x2345_u16, 0x789a_u16, 0xabcd_u16, 0xfedc_u16]
W163_LIBRARY_UINT32_VALUES = [0x0102_0304_u32, 0x1234_5678_u32, 0x2345_6789_u32, 0x789a_bcde_u32, 0xabcd_ef01_u32, 0xfedc_ba98_u32]
W163_LIBRARY_UINT64_VALUES = [
  0x0123_4567_89ab_cdef_u64,
  0x1020_3040_5060_7080_u64,
  0x2345_6789_abcdef01_u64,
  0x9876_5432_10fe_dcba_u64,
  0xaaaaaaaa_55555555_u64,
  0xfedc_ba98_7654_3210_u64,
]
W163_LIBRARY_INT8_VALUES  = [-127_i8, -42_i8, -7_i8, 3_i8, 58_i8, 126_i8]
W163_LIBRARY_INT16_VALUES = [-32_767_i16, -12_345_i16, -257_i16, 42_i16, 12_345_i16, 32_766_i16]
W163_LIBRARY_INT32_VALUES = [-2_147_483_647_i32, -123_456_789_i32, -257_i32, 42_i32, 123_456_789_i32, 2_147_483_646_i32]
W163_LIBRARY_INT64_VALUES = [
  -9_223_372_036_854_775_807_i64,
  -1_234_567_890_123_456_789_i64,
  -257_i64,
  42_i64,
  1_234_567_890_123_456_789_i64,
  9_223_372_036_854_775_806_i64,
]
W163_LIBRARY_FLOAT32_VALUES = [
  0x8000_0000_u32.unsafe_as(Float32),
  0x3fc0_0000_u32.unsafe_as(Float32),
  0xc010_0000_u32.unsafe_as(Float32),
  0x7f7f_fffe_u32.unsafe_as(Float32),
  0xff7f_fffe_u32.unsafe_as(Float32),
  0x0000_0002_u32.unsafe_as(Float32),
]
W163_LIBRARY_FLOAT64_VALUES = [
  0x8000_0000_0000_0000_u64.unsafe_as(Float64),
  0x3ff8_0000_0000_0000_u64.unsafe_as(Float64),
  0xc002_0000_0000_0000_u64.unsafe_as(Float64),
  0x7fef_ffff_ffff_fffe_u64.unsafe_as(Float64),
  0xffef_ffff_ffff_fffe_u64.unsafe_as(Float64),
  0x0000_0000_0000_0002_u64.unsafe_as(Float64),
]

W163_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT64 = [
  0x0123_4567_89ab_cdee_u64,
  0x1020_3040_5060_7080_u64,
  0x2345_6789_abcdef01_u64,
  0x9876_5432_10fe_dcba_u64,
  0xaaaaaaaa_55555555_u64,
  0xfedc_ba98_7654_3210_u64,
]

module W163SimpleAggregateTestSupport
  def self.nullable_values(values : Array(T)) : Array(T?) forall T
    result = Array(T?).new(values.size) { |index| values[index].as(T?) }
    result[3] = nil
    result
  end

  def self.profiles_for(carrier : String) : Array(Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function))
    allowed = W163_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.fetch(carrier) { raise "unknown W163 carrier: #{carrier}" }
    W163_SIMPLE_AGGREGATE_FUNCTIONS.select { |function| allowed.includes?(function[0]) }
  end

  def self.total_profile_count : Int32
    W163_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.keys.sum do |carrier|
      profiles_for(carrier).size
    end
  end
end
