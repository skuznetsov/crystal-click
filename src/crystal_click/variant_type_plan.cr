module CrystalClick
  # Public typed value surfaces for the bounded Variant codecs. NULL is
  # implicit and represented by Nil; it is not a declared Variant arm.
  alias VariantStringUInt64Value = String | UInt64 | Nil
  alias VariantBoolStringUInt64Value = Bool | String | UInt64 | Nil

  # One exact physical arm in a bounded Variant profile. Each child stream is
  # declared with its metadata suffix and plain mark element width so the
  # physical substream order and stream-width checks share the same plan.
  struct WideVariantArmPlan
    @type_name : String
    getter tag : UInt8
    @child_streams : Array(Tuple(String, Int32))

    def initialize(type_name : String, @tag : UInt8, child_streams : Array(Tuple(String, Int32)))
      @type_name = type_name.dup
      @child_streams = child_streams.map { |suffix, width| {suffix.dup, width} }
    end

    def type_name : String
      @type_name.dup
    end

    def child_streams : Array(Tuple(String, Int32))
      @child_streams.map { |suffix, width| {suffix.dup, width} }
    end
  end

  # Exact descriptor for one admitted Variant spelling. This is intentionally
  # a closed list: adding a type string requires a separately measured arm/tag
  # order and physical stream plan.
  class WideVariantTypePlanDescriptor
    DISCRIMINATOR_SUFFIX = ".variant_discr"
    TAG_NULL             = 255_u8
    MODE_BASIC           =  0_u64
    MODE_COMPACT         =  1_u64
    FORMAT_ROW_TAGS      =   0_u8
    FORMAT_UNIFORM_TAG   =   1_u8

    @type : String
    @arms : Array(WideVariantArmPlan)

    def initialize(type : String, arms : Array(WideVariantArmPlan))
      @type = type.dup
      @arms = arms.map { |arm| WideVariantArmPlan.new(arm.type_name, arm.tag, arm.child_streams) }
    end

    def type : String
      @type.dup
    end

    def arms : Array(WideVariantArmPlan)
      @arms.map { |arm| WideVariantArmPlan.new(arm.type_name, arm.tag, arm.child_streams) }
    end

    def self.for_type(type : String) : WideVariantTypePlanDescriptor?
      case type
      when WideVariantStringUInt64TypePlan::TYPE
        WideVariantStringUInt64TypePlan::DESCRIPTOR
      when WideVariantBoolStringUInt64TypePlan::TYPE
        WideVariantBoolStringUInt64TypePlan::DESCRIPTOR
      else
        nil
      end
    end

    def admitted?(candidate : String) : Bool
      candidate == @type
    end

    def discriminator_stream(column : String) : String
      "#{column}#{DISCRIMINATOR_SUFFIX}"
    end

    def physical_streams(column : String) : Array(String)
      streams = [discriminator_stream(column)]
      @arms.each do |arm|
        arm.child_streams.each do |suffix, _width|
          streams << "#{column}#{suffix}"
        end
      end
      streams
    end

    def child_streams(column : String, arm_type : String) : Array(String)
      arm = @arms.find { |candidate| candidate.type_name == arm_type } ||
            raise UnsupportedFormatError.new("Variant arm is not admitted by its exact type plan")
      arm.child_streams.map { |suffix, _width| "#{column}#{suffix}" }
    end

    def stream_width(column : String, stream_name : String) : Int32?
      return 1 if stream_name == discriminator_stream(column)
      @arms.each do |arm|
        arm.child_streams.each do |suffix, width|
          return width if stream_name == "#{column}#{suffix}"
        end
      end
      nil
    end

    def tag_for(arm_type : String) : UInt8?
      @arms.find { |arm| arm.type_name == arm_type }.try(&.tag)
    end

    def arm_type_for(tag : UInt8) : String?
      @arms.find { |arm| arm.tag == tag }.try(&.type_name)
    end

    def valid_tag?(tag : UInt8) : Bool
      tag == TAG_NULL || !arm_type_for(tag).nil?
    end
  end

  # Exact physical contract observed for Variant(String, UInt64) in the pinned
  # Wide/LZ4 producer. Keep its public constants and helpers stable for W56.
  class WideVariantStringUInt64TypePlan
    TYPE = "Variant(String, UInt64)"

    DISCRIMINATOR_SUFFIX = WideVariantTypePlanDescriptor::DISCRIMINATOR_SUFFIX
    STRING_SIZE_SUFFIX   = ".String.size"
    STRING_SUFFIX        = ".String"
    UINT64_SUFFIX        = ".UInt64"

    TAG_STRING = 0_u8
    TAG_UINT64 = 1_u8
    TAG_NULL   = WideVariantTypePlanDescriptor::TAG_NULL

    MODE_BASIC   = WideVariantTypePlanDescriptor::MODE_BASIC
    MODE_COMPACT = WideVariantTypePlanDescriptor::MODE_COMPACT

    FORMAT_ROW_TAGS    = WideVariantTypePlanDescriptor::FORMAT_ROW_TAGS
    FORMAT_UNIFORM_TAG = WideVariantTypePlanDescriptor::FORMAT_UNIFORM_TAG

    DESCRIPTOR = WideVariantTypePlanDescriptor.new(
      TYPE,
      [
        WideVariantArmPlan.new("String", TAG_STRING, [{STRING_SIZE_SUFFIX, 8_i32}, {STRING_SUFFIX, 1_i32}]),
        WideVariantArmPlan.new("UInt64", TAG_UINT64, [{UINT64_SUFFIX, 8_i32}]),
      ] of WideVariantArmPlan
    )

    def self.admitted?(type : String) : Bool
      type == TYPE
    end

    def self.discriminator_stream(column : String) : String
      DESCRIPTOR.discriminator_stream(column)
    end

    def self.string_size_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "String")[0]
    end

    def self.string_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "String")[1]
    end

    def self.uint64_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "UInt64")[0]
    end

    def self.physical_streams(column : String) : Array(String)
      DESCRIPTOR.physical_streams(column)
    end
  end

  # W57 adds one exact canonical Bool/String/UInt64 profile. Its tag and child
  # order come from the pinned stock producer; this does not make Variant
  # planning open-ended.
  class WideVariantBoolStringUInt64TypePlan
    TYPE = "Variant(Bool, String, UInt64)"

    DISCRIMINATOR_SUFFIX = WideVariantTypePlanDescriptor::DISCRIMINATOR_SUFFIX
    BOOL_SUFFIX          = ".Bool"
    STRING_SIZE_SUFFIX   = ".String.size"
    STRING_SUFFIX        = ".String"
    UINT64_SUFFIX        = ".UInt64"

    TAG_BOOL   = 0_u8
    TAG_STRING = 1_u8
    TAG_UINT64 = 2_u8
    TAG_NULL   = WideVariantTypePlanDescriptor::TAG_NULL

    MODE_BASIC   = WideVariantTypePlanDescriptor::MODE_BASIC
    MODE_COMPACT = WideVariantTypePlanDescriptor::MODE_COMPACT

    FORMAT_ROW_TAGS    = WideVariantTypePlanDescriptor::FORMAT_ROW_TAGS
    FORMAT_UNIFORM_TAG = WideVariantTypePlanDescriptor::FORMAT_UNIFORM_TAG

    DESCRIPTOR = WideVariantTypePlanDescriptor.new(
      TYPE,
      [
        WideVariantArmPlan.new("Bool", TAG_BOOL, [{BOOL_SUFFIX, 1_i32}]),
        WideVariantArmPlan.new("String", TAG_STRING, [{STRING_SIZE_SUFFIX, 8_i32}, {STRING_SUFFIX, 1_i32}]),
        WideVariantArmPlan.new("UInt64", TAG_UINT64, [{UINT64_SUFFIX, 8_i32}]),
      ] of WideVariantArmPlan
    )

    def self.admitted?(type : String) : Bool
      type == TYPE
    end

    def self.discriminator_stream(column : String) : String
      DESCRIPTOR.discriminator_stream(column)
    end

    def self.bool_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "Bool")[0]
    end

    def self.string_size_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "String")[0]
    end

    def self.string_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "String")[1]
    end

    def self.uint64_stream(column : String) : String
      DESCRIPTOR.child_streams(column, "UInt64")[0]
    end

    def self.physical_streams(column : String) : Array(String)
      DESCRIPTOR.physical_streams(column)
    end
  end
end
