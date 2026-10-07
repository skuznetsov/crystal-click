module CrystalClick
  # Physical coordinates for one JSON leaf beneath a Dynamic actual arm.
  # `escaped_prefix` names the full leaf prefix before Object suffixes;
  # `array_level` is inherited from the same storage walk as the parent site.
  struct DynamicJsonObjectSiteCoordinates
    getter escaped_prefix : String
    getter array_level : UInt64
    getter json_type : BinaryDataType

    def initialize(escaped_prefix : String, @array_level : UInt64, @json_type : BinaryDataType)
      PhysicalStreamName.validate_escaped_prefix(escaped_prefix)
      @escaped_prefix = String.new(escaped_prefix.to_slice)
    end
  end
end
