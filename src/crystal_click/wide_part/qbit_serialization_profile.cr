module CrystalClick
  module QBitSerializationProfile
    EXPECTED_FIELDS = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}

    def self.validate!(text : String) : Nil
      info = JSON.parse(text).as_h
      raise UnsupportedFormatError.new("unsupported QBit serialization.json fields") unless info.keys.to_set == EXPECTED_FIELDS

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for QBit") unless version == 1

      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("QBit nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("QBit requires nested String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("serialization column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("QBit per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end
  end
end
