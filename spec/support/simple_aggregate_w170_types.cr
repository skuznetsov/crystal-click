# Independent W170 temporal SimpleAggregateFunction roster and raw carrier
# fixtures. Do not derive this oracle from production admission helpers.

W170_SIMPLE_AGGREGATE_TEMPORAL_FUNCTIONS = [
  {"any", "any", CrystalClick::BinarySimpleAggregateType::Function::Any},
  {"anyLast", "any_last", CrystalClick::BinarySimpleAggregateType::Function::AnyLast},
  {"min", "min", CrystalClick::BinarySimpleAggregateType::Function::Min},
  {"max", "max", CrystalClick::BinarySimpleAggregateType::Function::Max},
] of Tuple(String, String, CrystalClick::BinarySimpleAggregateType::Function)

W170_TEMPORAL_LONGEST_ZONE = "America/Argentina/ComodRivadavia"
W170_TEMPORAL_ZONES        = ["UTC", "Europe/Berlin", W170_TEMPORAL_LONGEST_ZONE] of String
W170_TEMPORAL_KEYS         = [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]

struct W170TemporalLeaf
  getter key : String
  getter family : String
  getter storage_type_name : String
  getter carrier_type_name : String
  getter scale : Int32?
  getter timezone : String?

  def initialize(
    @key : String,
    @family : String,
    @storage_type_name : String,
    @carrier_type_name : String,
    @scale : Int32? = nil,
    @timezone : String? = nil,
  )
  end

  def build_type : CrystalClick::BinaryDataType
    case @family
    when "Date", "Date32", "Time"
      CrystalClick::BinaryDataType.primitive(@storage_type_name)
    when "DateTime"
      CrystalClick::BinaryDataType.datetime(@timezone)
    when "DateTime64"
      CrystalClick::BinaryDataType.datetime64(@scale.not_nil!, @timezone)
    when "Time64"
      CrystalClick::BinaryDataType.time64(@scale.not_nil!)
    else
      raise ArgumentError.new("unknown independent W170 temporal family")
    end
  end
end

struct W170TemporalProfile
  getter function_name : String
  getter function_suffix : String
  getter function : CrystalClick::BinarySimpleAggregateType::Function
  getter leaf : W170TemporalLeaf
  getter nullable : Bool
  getter ordinal : Int32

  def initialize(
    @function_name : String,
    @function_suffix : String,
    @function : CrystalClick::BinarySimpleAggregateType::Function,
    @leaf : W170TemporalLeaf,
    @nullable : Bool,
    @ordinal : Int32,
  )
  end

  def storage_type_name : String
    @leaf.storage_type_name
  end

  def type_name : String
    inner = "SimpleAggregateFunction(#{@function_name}, #{@leaf.storage_type_name})"
    @nullable ? "Nullable(#{inner})" : inner
  end

  def column_name : String
    "c#{@ordinal.to_s.rjust(4, '0')}"
  end

  def id : String
    "#{@function_suffix}_#{@leaf.key}_#{@nullable ? "nullable" : "scalar"}"
  end

  def part_label : String
    id
  end

  def part_path(root : String) : String
    File.join(root, part_label, "all_1_1_0")
  end
end

module W170SimpleAggregateTemporalTestSupport
  def self.temporal_leaves : Array(W170TemporalLeaf)
    leaves = [
      W170TemporalLeaf.new("date", "Date", "Date", "UInt16"),
      W170TemporalLeaf.new("date32", "Date32", "Date32", "Int32"),
      W170TemporalLeaf.new("datetime_bare", "DateTime", "DateTime", "UInt32"),
    ] of W170TemporalLeaf

    W170_TEMPORAL_ZONES.each do |zone|
      suffix = case zone
               when "UTC"                      then "utc"
               when "Europe/Berlin"            then "europe_berlin"
               when W170_TEMPORAL_LONGEST_ZONE then "america_argentina_comodrivadavia"
               else                                 raise ArgumentError.new("unknown independent W170 timezone witness")
               end
      leaves << W170TemporalLeaf.new(
        "datetime_#{suffix}", "DateTime", "DateTime('#{zone}')", "UInt32", timezone: zone)
    end

    (0..9).each do |scale|
      leaves << W170TemporalLeaf.new(
        "datetime64_s#{scale}", "DateTime64", "DateTime64(#{scale})", "Int64", scale: scale)
    end
    [0, 3, 9].each do |scale|
      W170_TEMPORAL_ZONES.each do |zone|
        suffix = case zone
                 when "UTC"                      then "utc"
                 when "Europe/Berlin"            then "europe_berlin"
                 when W170_TEMPORAL_LONGEST_ZONE then "america_argentina_comodrivadavia"
                 else                                 raise ArgumentError.new("unknown independent W170 timezone witness")
                 end
        leaves << W170TemporalLeaf.new(
          "datetime64_s#{scale}_#{suffix}", "DateTime64",
          "DateTime64(#{scale}, '#{zone}')", "Int64", scale: scale, timezone: zone)
      end
    end

    leaves << W170TemporalLeaf.new("time", "Time", "Time", "Int32")
    (0..9).each do |scale|
      leaves << W170TemporalLeaf.new(
        "time64_s#{scale}", "Time64", "Time64(#{scale})", "Int64", scale: scale)
    end
    leaves
  end

  def self.candidate_profiles : Array(W170TemporalProfile)
    ordinal = 0
    W170_SIMPLE_AGGREGATE_TEMPORAL_FUNCTIONS.flat_map do |function_name, function_suffix, function|
      temporal_leaves.flat_map do |leaf|
        [false, true].map do |nullable|
          ordinal += 1
          W170TemporalProfile.new(function_name, function_suffix, function, leaf, nullable, ordinal)
        end
      end
    end
  end

  def self.accepted_profiles : Array(W170TemporalProfile)
    candidate_profiles
  end

  def self.library_values(profile : W170TemporalProfile, type : T.class) : Array(T) forall T
    case profile.leaf.carrier_type_name
    when "UInt16"
      {% if T == UInt16 %}
        [0_u16, UInt16::MAX, 1_u16, 0xabcd_u16, 0x1234_u16]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match UInt16 raw type")
      {% end %}
    when "Int32"
      {% if T == Int32 %}
        [0_i32, -1_i32, Int32::MAX, Int32::MIN, -0x0123_4567_i32]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match Int32 raw type")
      {% end %}
    when "UInt32"
      {% if T == UInt32 %}
        [0_u32, 1_u32, 0x89ab_cdef_u32, UInt32::MAX, 0x1234_5678_u32]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match UInt32 raw type")
      {% end %}
    when "Int64"
      {% if T == Int64 %}
        [0_i64, -1_i64, Int64::MAX, Int64::MIN, 0x0fed_cba9_8765_4321_i64]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match Int64 raw type")
      {% end %}
    else
      raise ArgumentError.new("unknown independent W170 raw carrier")
    end
  end

  def self.native_values(profile : W170TemporalProfile, type : T.class) : Array(T) forall T
    case profile.leaf.carrier_type_name
    when "UInt16"
      {% if T == UInt16 %}
        [0_u16, 1_u16, UInt16::MAX, 0x1234_u16, 0xabcd_u16]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match UInt16 raw type")
      {% end %}
    when "Int32"
      {% if T == Int32 %}
        [0_i32, -1_i32, Int32::MIN, Int32::MAX, 0x0123_4567_i32]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match Int32 raw type")
      {% end %}
    when "UInt32"
      {% if T == UInt32 %}
        [0_u32, 1_u32, UInt32::MAX, 0x1234_5678_u32, 0x89ab_cdef_u32]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match UInt32 raw type")
      {% end %}
    when "Int64"
      {% if T == Int64 %}
        [0_i64, -1_i64, Int64::MIN, Int64::MAX, 0x0123_4567_89ab_cdef_i64]
      {% else %}
        raise ArgumentError.new("W170 profile carrier does not match Int64 raw type")
      {% end %}
    else
      raise ArgumentError.new("unknown independent W170 raw carrier")
    end
  end

  def self.nullable_values(values : Array(T)) : Array(T?) forall T
    result = values.map { |value| value.as(T?) }
    result[2] = nil
    result
  end
end
