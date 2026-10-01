require "json"

module CrystalClick
  # W110's bounded Default-statistics envelope for the exact paired Geo Array
  # plus UInt64 primary-key profile. Geo payload statistics are not recursively
  # inferred from the scalar Point profile.
  class GeoArraySerializationProfile
    EXPECTED_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }

    def self.validate!(
      text : String,
      columns : Array(Tuple(String, String)),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      raise UnsupportedFormatError.new("Geo Array requires one UInt64 primary-key column") unless columns.size == 2
      selected = columns.find { |name, type| name == selected_column && !GeoArrayColumnType.for_type(type).nil? }
      raise UnsupportedFormatError.new("Geo Array serialization requires an exact Geo declaration") unless selected
      key = columns.find { |name, type| name != selected_column && type == "UInt64" }
      raise UnsupportedFormatError.new("Geo Array requires one UInt64 primary-key column") unless key

      info = JSON.parse(text).as_h
      raise UnsupportedFormatError.new("unsupported Geo Array serialization.json fields") unless info.keys.to_set == EXPECTED_FIELDS
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for Geo Array") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Geo Array nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("Geo Array requires nested String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Geo Array column serializers are missing or malformed"))
      if serializers.empty?
        return nil
      end
      raise UnsupportedFormatError.new("Geo Array serialization permits only the primary-key Default record") unless serializers.size == 1
      entry = serializers.first.as_h
      expected_keys = Set{"kind", "name", "num_defaults", "num_rows"}
      raise UnsupportedFormatError.new("unsupported Geo Array primary-key serializer fields") unless entry.keys.to_set == expected_keys
      raise UnsupportedFormatError.new("only Default Geo Array primary-key serializers are supported") unless entry["kind"]?.try(&.as_s) == "Default"
      raise UnsupportedFormatError.new("Geo Array serializer record does not name its primary key") unless entry["name"]?.try(&.as_s) == key[0]
      rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Geo Array primary-key row count is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Geo Array primary-key default count is missing or malformed"))
      unless rows >= 0 && rows.to_u64 == row_count
        raise CorruptPartError.new("Geo Array primary-key serializer row count does not match part")
      end
      unless defaults >= 0 && defaults <= rows
        raise CorruptPartError.new("Geo Array primary-key serializer default count is invalid")
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("Geo Array serialization.json is malformed")
    end
  end
end
