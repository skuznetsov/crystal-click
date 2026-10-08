module CrystalClick
  # Physical location of one JSON leaf beneath an inferred Object Dynamic
  # actual arm. The prefix is the ordinary physical prefix before Object
  # suffixes; descriptor depth is absolute in the enclosing storage tree.
  struct ObjectRootDynamicJsonCoordinates
    getter escaped_prefix : String
    getter array_level : UInt64
    getter json_type : BinaryDataType
    getter json_depth : Int32

    def initialize(
      escaped_prefix : String,
      @array_level : UInt64,
      @json_type : BinaryDataType,
      @json_depth : Int32,
      name_context : PhysicalStreamPlanContext,
    )
      PhysicalStreamName.validate_canonical_escaped_prefix(escaped_prefix)
      unless @json_depth > 0 && @json_depth <= name_context.limits.max_depth
        raise CorruptPartError.new("inferred Dynamic JSON descriptor depth exceeds the configured limit")
      end
      bytes = escaped_prefix.bytesize.to_u64
      name_context.preflight_name_bytes(bytes)
      name_context.charge_name_bytes(bytes)
      @escaped_prefix = String.new(escaped_prefix.to_slice)
    end
  end
end
