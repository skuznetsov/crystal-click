# Independent W164 matrix and literal raw-value fixtures. Do not derive this
# roster from production carrier admission or from the Ruby stock oracle.
W164_SIMPLE_AGGREGATE_FUNCTIONS = [
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

# Source-derived identity-result law: all nine functions preserve the four
# wide integer carriers; BFloat16 preserves identity for five and rejects
# widening sum plus integer-only bitwise functions.
W164_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER = {
  "UInt128"  => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int128"   => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "UInt256"  => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "Int256"   => ["any", "anyLast", "min", "max", "sum", "sumWithOverflow", "groupBitAnd", "groupBitOr", "groupBitXor"],
  "BFloat16" => ["any", "anyLast", "min", "max", "sumWithOverflow"],
}

W164_SIMPLE_AGGREGATE_EXPECTED_SCALAR_PROFILES = 41
W164_SIMPLE_AGGREGATE_KEYS                     = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]

# Stock-authored wide integer boundaries: zero/one, sign boundary, and both
# extrema. Int256 fixtures are raw two's-complement words (low limb first).
W164_STOCK_UINT128_VALUES = [
  0_u128,
  1_u128,
  0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128,
  0x8000_0000_0000_0000_0000_0000_0000_0000_u128,
  UInt128::MAX - 1_u128,
  UInt128::MAX,
]
W164_STOCK_INT128_VALUES  = [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX - 1_i128, Int128::MAX]
W164_STOCK_UINT256_VALUES = [
  CrystalClick::UInt256Value.new(0_u128, 0_u128),
  CrystalClick::UInt256Value.new(1_u128, 0_u128),
  CrystalClick::UInt256Value.new(
    0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_u128,
    0x2345_6789_abcdef01_2345_6789_abcdef01_u128
  ),
  CrystalClick::UInt256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
  CrystalClick::UInt256Value.new(UInt128::MAX - 1_u128, UInt128::MAX),
  CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
]
W164_STOCK_INT256_VALUES = [
  CrystalClick::Int256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
  CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX),
  CrystalClick::Int256Value.new(0_u128, 0_u128),
  CrystalClick::Int256Value.new(1_u128, 0_u128),
  CrystalClick::Int256Value.new(UInt128::MAX - 1_u128, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
  CrystalClick::Int256Value.new(UInt128::MAX, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
]

# BFloat16 is carried as its exact 16-bit representation; fixtures include
# signed zero, finite positive/negative values, the finite extreme, and the
# least subnormal. No fixture passes through Float32 or decimal conversion.
W164_STOCK_BFLOAT16_VALUES = [
  CrystalClick::BFloat16Value.new(0x8000_u16),
  CrystalClick::BFloat16Value.new(0x3fc0_u16),
  CrystalClick::BFloat16Value.new(0xc010_u16),
  CrystalClick::BFloat16Value.new(0x7f7f_u16),
  CrystalClick::BFloat16Value.new(0xff7f_u16),
  CrystalClick::BFloat16Value.new(0x0001_u16),
]

# Library-authored values are independent, asymmetric literals, with distinct
# limb patterns and finite raw BFloat16 payloads.
W164_LIBRARY_UINT128_VALUES = [
  0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_u128,
  0x1020_3040_5060_7080_90a0_b0c0_d0e0_f000_u128,
  0x2345_6789_abcdef01_2345_6789_abcdef01_u128,
  0x9876_5432_10fe_dcba_9876_5432_10fe_dcba_u128,
  UInt128::MAX - 1_u128,
  UInt128::MAX,
]
W164_LIBRARY_INT128_VALUES = [
  Int128::MIN + 1_i128,
  -0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_i128,
  -257_i128,
  42_i128,
  0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_i128,
  Int128::MAX - 1_i128,
]
W164_LIBRARY_UINT256_VALUES = [
  CrystalClick::UInt256Value.new(
    0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_u128,
    0xfedc_ba98_7654_3210_fedc_ba98_7654_3210_u128
  ),
  CrystalClick::UInt256Value.new(
    0x2345_6789_abcdef01_2345_6789_abcdef01_u128,
    0x9876_5432_10fe_dcba_9876_5432_10fe_dcba_u128
  ),
  CrystalClick::UInt256Value.new(
    0xaaaa_aaaa_5555_5555_aaaa_aaaa_5555_5555_u128,
    0x5555_5555_aaaa_aaaa_5555_5555_aaaa_aaaa_u128
  ),
  CrystalClick::UInt256Value.new(
    0xdead_beef_0123_4567_89ab_cdef_7654_3210_u128,
    0x1020_3040_5060_7080_90a0_b0c0_d0e0_f001_u128
  ),
  CrystalClick::UInt256Value.new(UInt128::MAX - 1_u128, UInt128::MAX),
  CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX - 1_u128),
]
W164_LIBRARY_INT256_VALUES = [
  CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0x8000_0000_0000_0000_u64),
  CrystalClick::Int256Value.from_words(0xfedc_ba98_7654_3210_u64, 0x0123_4567_89ab_cdef_u64, 0x9876_5432_10fe_dcba_u64, 0x9234_5678_9abc_def0_u64),
  CrystalClick::Int256Value.from_words(0xffff_ffff_ffff_feff_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX),
  CrystalClick::Int256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64),
  CrystalClick::Int256Value.from_words(0x0123_4567_89ab_cdef_u64, 0x2345_6789_abcdef01_u64, 0x4567_89ab_cdef_0123_u64, 0x7fff_ffff_ffff_ffff_u64),
  CrystalClick::Int256Value.new(UInt128::MAX, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
]
W164_LIBRARY_BFLOAT16_VALUES = [
  CrystalClick::BFloat16Value.new(0x0000_u16),
  CrystalClick::BFloat16Value.new(0x3fa0_u16),
  CrystalClick::BFloat16Value.new(0xc020_u16),
  CrystalClick::BFloat16Value.new(0x7f7e_u16),
  CrystalClick::BFloat16Value.new(0xff7e_u16),
  CrystalClick::BFloat16Value.new(0x0002_u16),
]

W164_SIMPLE_AGGREGATE_VALUE_MUTANT_UINT128 = [
  0x0123_4567_89ab_cdef_0123_4567_89ab_cdee_u128,
  0x1020_3040_5060_7080_90a0_b0c0_d0e0_f000_u128,
  0x2345_6789_abcdef01_2345_6789_abcdef01_u128,
  0x9876_5432_10fe_dcba_9876_5432_10fe_dcba_u128,
  UInt128::MAX - 1_u128,
  UInt128::MAX,
]

module W164SimpleAggregateTestSupport
  def self.nullable_values(values : Array(T)) : Array(T?) forall T
    result = Array(T?).new(values.size) { |index| values[index].as(T?) }
    result[3] = nil
    result
  end

  def self.profiles_for(carrier : String) : Array(Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function))
    allowed = W164_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.fetch(carrier) { raise "unknown W164 carrier: #{carrier}" }
    W164_SIMPLE_AGGREGATE_FUNCTIONS.select { |function| allowed.includes?(function[0]) }
  end

  def self.total_profile_count : Int32
    W164_SIMPLE_AGGREGATE_FUNCTIONS_BY_CARRIER.keys.sum do |carrier|
      profiles_for(carrier).size
    end
  end
end
