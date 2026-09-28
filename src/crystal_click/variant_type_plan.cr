module CrystalClick
  # Public typed value surface for the bounded W56 Variant reader and writer.
  # NULL is represented by Nil; it is not a declared Variant alternative.
  alias VariantStringUInt64Value = String | UInt64 | Nil

  # Exact physical contract observed for Variant(String, UInt64) in the pinned
  # Wide/LZ4 producer. This is deliberately not a general Variant planner.
  class WideVariantStringUInt64TypePlan
    TYPE = "Variant(String, UInt64)"

    DISCRIMINATOR_SUFFIX = ".variant_discr"
    STRING_SIZE_SUFFIX   = ".String.size"
    STRING_SUFFIX        = ".String"
    UINT64_SUFFIX        = ".UInt64"

    TAG_STRING =   0_u8
    TAG_UINT64 =   1_u8
    TAG_NULL   = 255_u8

    MODE_BASIC   = 0_u64
    MODE_COMPACT = 1_u64

    FORMAT_ROW_TAGS    = 0_u8
    FORMAT_UNIFORM_TAG = 1_u8

    def self.admitted?(type : String) : Bool
      type == TYPE
    end

    def self.discriminator_stream(column : String) : String
      "#{column}#{DISCRIMINATOR_SUFFIX}"
    end

    def self.string_size_stream(column : String) : String
      "#{column}#{STRING_SIZE_SUFFIX}"
    end

    def self.string_stream(column : String) : String
      "#{column}#{STRING_SUFFIX}"
    end

    def self.uint64_stream(column : String) : String
      "#{column}#{UINT64_SUFFIX}"
    end

    def self.physical_streams(column : String) : Array(String)
      [discriminator_stream(column), string_size_stream(column), string_stream(column), uint64_stream(column)]
    end
  end
end
