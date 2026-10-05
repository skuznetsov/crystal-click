module CrystalClick
  # Exact Default serializer envelope observed for unflattened Nested paired
  # with one UInt64 key. Nested itself has no root/leaf statistics record.
  class NestedSerializationProfile
    EXPECTED_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }
    KEY_SERIALIZER_FIELDS = Set{
      "kind",
      "name",
      "num_defaults",
      "num_rows",
      "exact_num_defaults",
    }

    def self.validate!(
      text : String,
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
      row_count : UInt64,
    ) : Nil
      raise UnsupportedFormatError.new("Nested requires one UInt64 primary-key column") unless columns.size == 2
      nested = columns.find do |name, type|
        name == selected_column && type == selected_type && !WideNestedTypePlan.for_type(type).nil?
      end
      raise UnsupportedFormatError.new("Nested serialization requires an exact Nested declaration") unless nested
      key = columns.find { |name, type| name != selected_column && type == "UInt64" }
      raise UnsupportedFormatError.new("Nested requires one UInt64 primary-key column") unless key

      info = JSON.parse(text).as_h
      raise UnsupportedFormatError.new("unsupported Nested serialization.json fields") unless info.keys.to_set == EXPECTED_FIELDS
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for Nested") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Nested child serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("Nested requires child String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Nested column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("Nested permits only its primary-key Default record") unless serializers.size == 1
      entry = serializers.first.as_h
      raise UnsupportedFormatError.new("unsupported Nested primary-key serializer fields") unless entry.keys.to_set == KEY_SERIALIZER_FIELDS
      raise UnsupportedFormatError.new("only Default Nested primary-key serializers are supported") unless entry["kind"]?.try(&.as_s) == "Default"
      raise UnsupportedFormatError.new("Nested serializer record does not name its primary key") unless entry["name"]?.try(&.as_s) == key[0]
      raise UnsupportedFormatError.new("Nested primary-key exact-default flag must be true") unless entry["exact_num_defaults"]?.try(&.as_bool) == true
      rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Nested primary-key row count is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Nested primary-key default count is missing or malformed"))
      raise CorruptPartError.new("Nested primary-key row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
      raise CorruptPartError.new("Nested primary-key default count is invalid") unless defaults >= 0 && defaults <= rows
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("Nested serialization.json is malformed")
    end
  end
end
