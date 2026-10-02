require "json"

module CrystalClick
  # Exact bounded serialization.json profile for the paired UInt64-key and
  # Geometry physical streams. This is not a generic seven-arm Variant profile.
  class GeometrySerializationProfile
    EXPECTED_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }
    DEFAULT_ENTRY_FIELDS       = Set{"kind", "name", "num_defaults", "num_rows"}
    EXACT_DEFAULT_ENTRY_FIELDS = Set{"kind", "name", "num_defaults", "num_rows", "exact_num_defaults"}

    def self.validate!(
      text : String,
      columns : Array(Tuple(String, String)),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      raise UnsupportedFormatError.new("Geometry requires one UInt64 primary-key column") unless columns.size == 2
      selected = columns.find { |name, type| name == selected_column && !GeometryColumnType.for_type(type).nil? }
      raise UnsupportedFormatError.new("Geometry serialization requires an exact Geometry declaration") unless selected
      key = columns.find { |name, type| name != selected_column && type == "UInt64" }
      raise UnsupportedFormatError.new("Geometry requires one UInt64 primary-key column") unless key

      info = JSON.parse(text).as_h
      raise UnsupportedFormatError.new("unsupported Geometry serialization.json fields") unless info.keys.to_set == EXPECTED_FIELDS
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("Geometry serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for Geometry") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Geometry nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("Geometry serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("Geometry requires nested String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Geometry column serializers are missing or malformed"))
      return nil if serializers.empty?

      raise UnsupportedFormatError.new("Geometry serialization permits only the primary-key Default record") unless serializers.size == 1
      entry = serializers.first.as_h
      entry_keys = entry.keys.to_set
      has_exact_defaults = entry_keys.includes?("exact_num_defaults")
      expected_keys = has_exact_defaults ? EXACT_DEFAULT_ENTRY_FIELDS : DEFAULT_ENTRY_FIELDS
      raise UnsupportedFormatError.new("unsupported Geometry primary-key serializer fields") unless entry_keys == expected_keys
      if has_exact_defaults && entry["exact_num_defaults"].raw != true
        raise UnsupportedFormatError.new("Geometry primary-key exact-default flag must be true when present")
      end
      raise UnsupportedFormatError.new("only Default Geometry primary-key serializers are supported") unless entry["kind"]?.try(&.as_s) == "Default"
      raise UnsupportedFormatError.new("Geometry serializer record does not name its primary key") unless entry["name"]?.try(&.as_s) == key[0]
      rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Geometry primary-key row count is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Geometry primary-key default count is missing or malformed"))
      unless rows >= 0 && rows.to_u64 == row_count
        raise CorruptPartError.new("Geometry primary-key serializer row count does not match part")
      end
      unless defaults >= 0 && defaults <= rows
        raise CorruptPartError.new("Geometry primary-key serializer default count is invalid")
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("Geometry serialization.json is malformed")
    end
  end
end
