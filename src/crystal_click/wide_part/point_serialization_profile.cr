module CrystalClick
  # Validates the bounded version-1 Default serialization profile observed for
  # a Point payload paired with one UInt64 primary-key column.
  class PointSerializationProfile
    EXPECTED_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }

    def self.validate!(
      text : String,
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      raise UnsupportedFormatError.new("Point requires one UInt64 primary-key column") unless columns.size == 2
      key = columns.find { |name, type| name != selected_column && type == "UInt64" }
      raise UnsupportedFormatError.new("Point requires one UInt64 primary-key column") unless key
      unless columns.any? { |name, type| name == selected_column && type == "Point" }
        raise UnsupportedFormatError.new("Point serialization requires an exact Point column")
      end

      info = JSON.parse(text).as_h
      raise UnsupportedFormatError.new("unsupported Point serialization.json fields") unless info.keys.to_set == EXPECTED_FIELDS
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for Point") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Point nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("Point requires nested String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Point column serializers are missing or malformed"))
      # ClickHouse omits per-column statistics under its always-Default
      # serialization setting. The physical schema and Point streams are validated
      # independently above and by the part reader.
      return nil if serializers.empty?
      raise UnsupportedFormatError.new("Point serialization requires exact payload and key records") unless serializers.size == 2
      serializer_names = serializers.map do |serializer|
        serializer.as_h["name"]?.try(&.as_s) ||
          raise(CorruptPartError.new("Point serializer name is missing or malformed"))
      end
      expected_names = columns.map(&.[0]).sort
      unless serializer_names.uniq.size == serializer_names.size && serializer_names.sort == expected_names
        raise UnsupportedFormatError.new("Point serialization records do not match the selected columns")
      end

      point = serializers.find { |serializer| serializer.as_h["name"]?.try(&.as_s) == selected_column }
        .try(&.as_h) || raise(CorruptPartError.new("Point serializer record is missing"))
      key_serializer = serializers.find { |serializer| serializer.as_h["name"]?.try(&.as_s) == key[0] }
        .try(&.as_h) || raise(CorruptPartError.new("Point primary-key serializer record is missing"))

      validate_record!(
        point,
        Set{"kind", "name", "num_defaults", "num_rows", "subcolumns"},
        row_count,
        "Point root"
      )
      coordinate_records = point["subcolumns"]?.try(&.as_a) ||
                           raise(UnsupportedFormatError.new("Point coordinate serializer metadata is required"))
      raise UnsupportedFormatError.new("Point requires exactly two coordinate serializers") unless coordinate_records.size == 2
      coordinate_records.each do |record|
        validate_record!(record.as_h, Set{"kind", "num_defaults", "num_rows"}, row_count, "Point coordinate")
      end
      validate_record!(
        key_serializer,
        Set{"kind", "name", "num_defaults", "num_rows"},
        row_count,
        "Point primary key"
      )
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def self.validate_record!(
      entry : Hash(String, JSON::Any),
      expected_keys : Set(String),
      row_count : UInt64,
      label : String,
    ) : Nil
      raise UnsupportedFormatError.new("unsupported #{label} serializer fields") unless entry.keys.to_set == expected_keys
      kind = entry["kind"]?.try(&.as_s) || raise(CorruptPartError.new("#{label} serializer kind is missing or malformed"))
      raise UnsupportedFormatError.new("only Default #{label} serializers are supported") unless kind == "Default"
      rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("#{label} serializer row count is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("#{label} serializer default count is missing or malformed"))
      raise CorruptPartError.new("#{label} serializer row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
      raise CorruptPartError.new("#{label} serializer default count is invalid") unless defaults >= 0 && defaults <= rows
      nil
    end
  end
end
