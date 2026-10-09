module CrystalClick
  # Physical coordinates for one JSON leaf beneath a Dynamic actual arm.
  # `escaped_prefix` is the canonical physical-plan prefix before Object
  # suffixes. `callback_prefix` is the source-exact callback name; Variant
  # type-name components are raw there while Tuple/Object fields remain
  # escaped. `array_level` is inherited from the same storage walk.
  struct DynamicJsonObjectSiteCoordinates
    getter escaped_prefix : String
    getter callback_prefix : String
    getter array_level : UInt64
    getter json_type : BinaryDataType

    def initialize(
      escaped_prefix : String,
      callback_prefix : String,
      @array_level : UInt64,
      @json_type : BinaryDataType,
    )
      PhysicalStreamName.validate_escaped_prefix(escaped_prefix)
      @escaped_prefix = String.new(escaped_prefix.to_slice)
      @callback_prefix = String.new(callback_prefix.to_slice)
    end
  end
end
