module CrystalClick
  # Narrow serializer-metadata law for ordinary Count parts and exact
  # Count-bearing projection children. This does not widen generic raw-integer
  # or Object serializer profiles.
  class WideAggregateCountSerializationProfile
    REQUIRED_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }

    STOCK_DEFAULT_FIELDS = Set{
      "kind",
      "name",
      "num_defaults",
      "num_rows",
      "exact_num_defaults",
    }

    def self.validate!(
      text : String,
      part_columns : Array({String, String}),
      count_column : String,
      count_type_name : String,
      row_count : UInt64,
      allow_projection_aggregate_roster : Bool = false,
    ) : String
      plan = WideAggregateCountStoragePlan.for_type_name(count_type_name) ||
             raise(UnsupportedFormatError.new("unsupported AggregateFunction(count) descriptor"))
      key_column = if part_columns.size == 2
                     matching_count = part_columns.count { |name, type| name == count_column && type == plan.type_name }
                     raise CorruptPartError.new("AggregateFunction(count) column does not match its exact part declaration") unless matching_count == 1
                     key_columns = part_columns.select { |name, _type| name != count_column }
                     unless key_columns.size == 1 && key_columns[0][1] == "UInt64" && key_columns[0][0] != count_column
                       raise UnsupportedFormatError.new("AggregateFunction(count) requires exactly one UInt64 key column")
                     end
                     raise CorruptPartError.new("AggregateFunction(count) part column names are not unique") unless part_columns.map(&.[0]).to_set.size == 2
                     key_columns[0][0]
                   elsif allow_projection_aggregate_roster
                     validate_projection_aggregate_roster!(part_columns, count_column, count_type_name)
                   else
                     raise UnsupportedFormatError.new("AggregateFunction(count) requires one UInt64 key and one state column")
                   end

      info = JSON.parse(text).as_h
      unless info.keys.to_set == REQUIRED_FIELDS
        raise UnsupportedFormatError.new("unsupported AggregateFunction(count) serialization.json fields")
      end

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported for AggregateFunction(count)") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("AggregateFunction(count) nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("AggregateFunction(count) requires only String serialization version 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("serialization column metadata is missing or malformed"))
      # The paired Crystal writer emits this exact normalized empty-list form.
      # Stock ClickHouse emits a pk-only Default statistics record; it does
      # not emit an AggregateFunction(count) serializer record.
      return key_column if serializers.empty?
      unless serializers.size == 1
        raise UnsupportedFormatError.new("AggregateFunction(count) serializer metadata must be empty or one stock UInt64-key record")
      end

      serializer = serializers[0].as_h
      unless serializer.keys.to_set == STOCK_DEFAULT_FIELDS
        raise UnsupportedFormatError.new("unsupported AggregateFunction(count) stock serializer fields")
      end
      kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("serializer kind is missing or malformed"))
      name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("serializer name is missing or malformed"))
      defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("serializer default count is missing or malformed"))
      rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("serializer row count is missing or malformed"))
      exact = serializer["exact_num_defaults"]?.try(&.as_bool) || raise(CorruptPartError.new("serializer exact-default flag is missing or malformed"))

      unless kind == "Default" && name == key_column && exact
        raise UnsupportedFormatError.new("AggregateFunction(count) accepts only the stock UInt64-key Default serializer")
      end
      if defaults < 0 || rows < 0 || defaults > rows || rows.to_u64 != row_count
        raise CorruptPartError.new("AggregateFunction(count) stock serializer counts differ from the part")
      end
      key_column
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def self.validate_projection_aggregate_roster!(
      part_columns : Array({String, String}),
      count_column : String,
      count_type_name : String,
    ) : String
      unless part_columns.size >= 3 && part_columns.size <= 5 && part_columns[0][1] == "UInt64"
        raise UnsupportedFormatError.new("projection AggregateFunction(count) requires a first UInt64 key and one to four aggregate columns")
      end
      unless part_columns.map(&.[0]).to_set.size == part_columns.size
        raise CorruptPartError.new("AggregateFunction(count) part column names are not unique")
      end
      unless count_column == "count()" && count_type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME
        raise UnsupportedFormatError.new("projection aggregate roster requires the exact count() state")
      end

      aggregates = part_columns[1..]
      seen_functions = Set(WidePartProjectionAggregateDescriptor::Function).new
      count_seen = false
      aggregates.each do |name, type|
        descriptor = WidePartProjectionAggregateDescriptor.for_column(name, type)
        unless descriptor
          raise UnsupportedFormatError.new("projection AggregateFunction(count) roster contains an unsupported aggregate declaration")
        end
        unless seen_functions.add?(descriptor.function)
          raise UnsupportedFormatError.new("projection AggregateFunction(count) roster repeats an aggregate function")
        end
        count_seen ||= descriptor.count?
      end
      unless count_seen
        raise UnsupportedFormatError.new("projection AggregateFunction(count) roster requires one count() and at most one of each admitted function")
      end
      part_columns[0][0]
    end
  end
end
