# Independent W161 fixture roster. Keep this literal and separate from the
# production function table so identity drift can fail the oracle.
W161_SIMPLE_AGGREGATE_TYPES = [
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

W161_SIMPLE_AGGREGATE_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]

# Library-authored payloads deliberately include the high bit and both UInt64
# endpoints. The nullable fixture places NULL in the second row of the middle
# two-row mark.
W161_SIMPLE_AGGREGATE_LIBRARY_VALUES = [
  0_u64,
  1_u64,
  0x0123_4567_89ab_cdef_u64,
  0x8000_0000_0000_0000_u64,
  0xffff_ffff_ffff_fffe_u64,
  0xffff_ffff_ffff_ffff_u64,
]
W161_SIMPLE_AGGREGATE_LIBRARY_NULLABLE_VALUES = [
  0_u64.as(UInt64?),
  1_u64.as(UInt64?),
  0x0123_4567_89ab_cdef_u64.as(UInt64?),
  nil.as(UInt64?),
  0xffff_ffff_ffff_fffe_u64.as(UInt64?),
  0xffff_ffff_ffff_ffff_u64.as(UInt64?),
]

# Separate literal stock values mean the native reader path does not merely
# read back the writer fixture.
W161_SIMPLE_AGGREGATE_STOCK_VALUES = [
  0_u64,
  1_u64,
  0x7fff_ffff_ffff_ffff_u64,
  0x8000_0000_0000_0000_u64,
  0xffff_ffff_ffff_fffe_u64,
  0xffff_ffff_ffff_ffff_u64,
]
W161_SIMPLE_AGGREGATE_STOCK_NULLABLE_VALUES = [
  0_u64.as(UInt64?),
  1_u64.as(UInt64?),
  0x7fff_ffff_ffff_ffff_u64.as(UInt64?),
  nil.as(UInt64?),
  0xffff_ffff_ffff_fffe_u64.as(UInt64?),
  0xffff_ffff_ffff_ffff_u64.as(UInt64?),
]

module W161SimpleAggregateTestSupport
  # Literal BinaryTypeIndex::SimpleAggregateFunction grammar from the pinned
  # ClickHouse source: 0x2e, VarUInt String, Field parameter roster,
  # VarUInt argument roster, then recursive argument descriptors.
  def self.descriptor(
    function : String,
    arguments : Array(UInt8) = [0x04_u8],
    argument_count : UInt8 = 1_u8,
    parameter_count : UInt8 = 0_u8,
    parameter_bytes : Array(UInt8) = [] of UInt8,
  ) : Array(UInt8)
    bytes = [0x2e_u8, function.bytesize.to_u8]
    bytes.concat(function.to_slice.to_a)
    bytes << parameter_count
    bytes.concat(parameter_bytes)
    bytes << argument_count
    bytes.concat(arguments)
    bytes
  end

  # Independent UInt64 little-endian fixture encoding. This intentionally does
  # not call BinaryValue or any production encoder.
  def self.u64_le(value : UInt64) : Array(UInt8)
    Array(UInt8).new(8) do |index|
      ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end

  def self.u64_rows_le(values : Array(UInt64)) : Array(UInt8)
    bytes = [] of UInt8
    values.each { |value| bytes.concat(u64_le(value)) }
    bytes
  end

  def self.u64_nullable_rows_le(values : Array(UInt64?)) : Array(UInt8)
    bytes = [] of UInt8
    values.each do |value|
      bytes.concat(u64_le(value || 0_u64))
    end
    bytes
  end

  def self.null_map(values : Array(UInt64?)) : Array(UInt8)
    values.map { |value| value.nil? ? 1_u8 : 0_u8 }
  end
end
