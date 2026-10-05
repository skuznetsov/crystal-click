# Independent W169 construction roster and literal raw coefficient fixtures.
# Keep this separate from production admission so the qualification suite can
# compare the public writer/reader APIs with independently authored values.

W169_SIMPLE_AGGREGATE_FUNCTIONS = [
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

W169_DECIMAL_PRECISIONS            = [1, 9, 10, 18, 19, 38, 39, 76] of Int32
W169_DECIMAL_PRECISION_SCALE_PAIRS = W169_DECIMAL_PRECISIONS.flat_map do |precision|
  scale_roster = [0, precision < 3 ? precision : 3, precision].uniq
  scale_roster.map { |scale| {precision, scale} }
end
W169_SIMPLE_AGGREGATE_KEYS = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64, 66_u64]

struct W169DecimalProfile
  getter function_name : String
  getter function_suffix : String
  getter function : CrystalClick::BinarySimpleAggregateType::Function
  getter precision : Int32
  getter scale : Int32
  getter nullable : Bool

  def initialize(
    @function_name : String,
    @function_suffix : String,
    @function : CrystalClick::BinarySimpleAggregateType::Function,
    @precision : Int32,
    @scale : Int32,
    @nullable : Bool,
  )
  end

  def storage_width : Int32
    case @precision
    when 1..9   then 4
    when 10..18 then 8
    when 19..38 then 16
    when 39..76 then 32
    else
      raise ArgumentError.new("W169 precision is outside Decimal32/64/128/256")
    end
  end

  def width_bits : Int32
    storage_width * 8
  end

  def decimal_type_name : String
    "Decimal(#{@precision}, #{@scale})"
  end

  def aggregate_type_name(function_name : String = @function_name) : String
    "SimpleAggregateFunction(#{function_name}, #{decimal_type_name})"
  end

  def type_name(function_name : String = @function_name) : String
    inner = aggregate_type_name(function_name)
    @nullable ? "Nullable(#{inner})" : inner
  end

  def id : String
    "#{@function_suffix}_decimal#{width_bits}_p#{@precision}_s#{@scale}"
  end

  def column_name : String
    "#{@nullable ? "n" : "s"}_#{id}"
  end

  def part_label : String
    "#{@nullable ? "nullable" : "scalar"}_#{id}"
  end

  def part_path(root : String) : String
    File.join(root, part_label, "all_1_1_0")
  end
end

module W169SimpleAggregateTestSupport
  def self.candidate_profiles : Array(W169DecimalProfile)
    W169_SIMPLE_AGGREGATE_FUNCTIONS.flat_map do |function_name, function_suffix, function|
      W169_DECIMAL_PRECISION_SCALE_PAIRS.map do |precision, scale|
        W169DecimalProfile.new(function_name, function_suffix, function, precision, scale, false)
      end
    end
  end

  def self.candidate_cases : Array(W169DecimalProfile)
    candidate_profiles.flat_map do |profile|
      [
        profile,
        W169DecimalProfile.new(
          profile.function_name, profile.function_suffix, profile.function,
          profile.precision, profile.scale, true,
        ),
      ]
    end
  end

  def self.accepted?(profile : W169DecimalProfile) : Bool
    case profile.function_name
    when "any", "anyLast", "min", "max", "sumWithOverflow"
      true
    when "sum"
      profile.precision >= 19
    when "groupBitAnd", "groupBitOr", "groupBitXor"
      false
    else
      raise ArgumentError.new("unknown canonical W169 function spelling")
    end
  end

  def self.accepted_profiles : Array(W169DecimalProfile)
    candidate_cases.select { |profile| accepted?(profile) }
  end

  def self.rejected_profiles : Array(W169DecimalProfile)
    candidate_cases.reject { |profile| accepted?(profile) }
  end

  def self.nullable_values(values : Array(T)) : Array(T?) forall T
    result = Array(T?).new(values.size) { |index| values[index].as(T?) }
    result[3] = nil
    result
  end

  # Native RowBinary literals are independent of the library-authored values.
  # They include zero, -1, both signed extrema and asymmetric odd patterns.
  def self.native_values32 : Array(Int32)
    [0_i32, -1_i32, Int32::MAX, Int32::MIN, 0x1234_5671_i32, -0x1234_567f_i32]
  end

  def self.library_values32 : Array(Int32)
    [0_i32, -1_i32, Int32::MIN, Int32::MAX, -0x1234_567f_i32, 0x1234_5671_i32]
  end

  def self.native_values64 : Array(Int64)
    [0_i64, -1_i64, Int64::MAX, Int64::MIN, 0x1234_5678_9abc_def1_i64, -0x1234_5678_9abc_deff_i64]
  end

  def self.library_values64 : Array(Int64)
    [0_i64, -1_i64, Int64::MIN, Int64::MAX, -0x1234_5678_9abc_deff_i64, 0x1234_5678_9abc_def1_i64]
  end

  def self.native_values128 : Array(Int128)
    [
      0_i128,
      -1_i128,
      Int128::MAX,
      Int128::MIN,
      0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_i128,
      -0x0123_4567_89ab_cdef_0123_4567_89ab_cdf1_i128,
    ]
  end

  def self.library_values128 : Array(Int128)
    [
      0_i128,
      -1_i128,
      Int128::MIN,
      Int128::MAX,
      -0x0123_4567_89ab_cdef_0123_4567_89ab_cdf1_i128,
      0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_i128,
    ]
  end

  def self.native_values256 : Array(CrystalClick::Decimal256Value)
    [
      CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
      CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
      CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fff_ffff_ffff_ffff_u64),
      CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000_0000_0000_0000_u64),
      CrystalClick::Decimal256Value.from_words(0xfedc_ba98_7654_3211_u64, 0x0123_4567_89ab_cdef_u64, 0x1357_9bdf_2468_ace0_u64, 0x0123_4567_89ab_cdef_u64),
      CrystalClick::Decimal256Value.from_words(0x1020_3040_5060_7081_u64, 0x2345_6789_abcd_ef01_u64, 0x3579_bdf0_2468_ace1_u64, 0xfedc_ba98_7654_3210_u64),
    ]
  end

  def self.library_values256 : Array(CrystalClick::Decimal256Value)
    [
      CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
      CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
      CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000_0000_0000_0000_u64),
      CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fff_ffff_ffff_ffff_u64),
      CrystalClick::Decimal256Value.from_words(0x1020_3040_5060_7081_u64, 0x2345_6789_abcd_ef01_u64, 0x3579_bdf0_2468_ace1_u64, 0xfedc_ba98_7654_3210_u64),
      CrystalClick::Decimal256Value.from_words(0xfedc_ba98_7654_3211_u64, 0x0123_4567_89ab_cdef_u64, 0x1357_9bdf_2468_ace0_u64, 0x0123_4567_89ab_cdef_u64),
    ]
  end
end
