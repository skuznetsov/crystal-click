module CrystalClick
  # Proves the bounded common SerializationInfo profile for one already
  # admitted selected static type. A false result leaves the existing family
  # validator as the sole legacy admission path; corruption is never retried.
  class SelectedColumnSerializationMetadata
    ENVELOPE_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }
    DEFAULT_FIELDS = Set{"kind", "name", "num_defaults", "num_rows"}

    private def initialize
    end

    def self.proven?(
      part_path : String,
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
      row_count : UInt64,
    ) : Bool
      physical_types = Hash(String, String).new(initial_capacity: columns.size)
      columns.each do |name, type|
        raise CorruptPartError.new("duplicate physical column name") if physical_types.has_key?(name)
        physical_types[name] = type
      end
      unless physical_types[selected_column]? == selected_type
        raise CorruptPartError.new("selected type does not match the physical schema")
      end

      path = File.join(part_path, "serialization.json")
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(path)
      return false unless File.file?(path)
      size = File.size(path)
      return false if size > WidePart::MAX_METADATA_FILE_BYTES
      text = File.read(path)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize.to_i64 == size

      info = JSON.parse(text).as_h
      version = info["version"]?.try(&.as_i)
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      versions = info["types_serialization_versions"]?.try(&.as_h)
      if versions
        versions.each_value { |value| value.as_i }
      end
      serializers = info["columns"]?.try(&.as_a)
      return false unless serializers
      raise CorruptPartError.new("serialization column metadata exceeds limit") if serializers.size > WidePart::MAX_METADATA_COLUMNS

      records = Array({String, String, String, Hash(String, JSON::Any)}).new(serializers.size)
      seen_names = Set(String).new
      serializers.each do |value|
        entry = value.as_h
        kind = entry["kind"]?.try(&.as_s) ||
               raise(CorruptPartError.new("serializer kind is missing or malformed"))
        name = entry["name"]?.try(&.as_s) ||
               raise(CorruptPartError.new("serializer name is missing or malformed"))
        defaults = entry["num_defaults"]?.try(&.as_i) ||
                   raise(CorruptPartError.new("serializer default count is missing or malformed"))
        rows = entry["num_rows"]?.try(&.as_i) ||
               raise(CorruptPartError.new("serializer row count is missing or malformed"))
        if exact = entry["exact_num_defaults"]?
          exact.as_bool
        end

        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES ||
           seen_names.includes?(name)
          raise CorruptPartError.new("serializer name is invalid or duplicated")
        end
        column_type = physical_types[name]?
        raise CorruptPartError.new("serializer name is not in the physical schema") unless column_type
        seen_names << name
        unless defaults >= 0 && rows >= 0 && defaults <= rows &&
               rows.to_u64 <= WidePart::MAX_ROWS && rows.to_u64 == row_count
          raise CorruptPartError.new("serializer default or row count does not match the part")
        end
        records << {name, column_type, kind, entry}
      end

      # Validate common fields throughout every explicitly recorded, known
      # Tuple tree before any envelope, serializer-kind, or shape rejection can
      # return an unproven result. The traversal is bounded by each admitted
      # WideTupleTypePlan and only follows positional child arrays.
      records.each do |_, column_type, _, entry|
        tuple_plan = WideTupleTypePlan.for_type(column_type)
        next unless tuple_plan
        next unless child_value = entry["subcolumns"]?
        TupleSerializationMetadataValidator.prevalidate_subcolumns_common_fields!(
          child_value.as_a,
          tuple_plan.root_fields,
          row_count,
        )
      end

      envelope_proven = info.keys.to_set == ENVELOPE_FIELDS &&
                        version == 1 && propagated == true &&
                        versions.try(&.size) == 1 &&
                        versions.try { |entries| entries["string"]?.try(&.as_i) } == 1
      return false unless envelope_proven

      records.each do |_, column_type, kind, entry|
        return false unless kind == "Default"

        tuple_plan = WideTupleTypePlan.for_type(column_type)
        tuple_type = !tuple_plan.nil?
        # Keep unsupported Tuple declarations outside the shallow base-info
        # proof, even when the bounded Tuple parser cannot build a plan.
        return false if !tuple_type && column_type.lstrip.starts_with?("Tuple")

        expected_fields = if tuple_type
                            Set{"kind", "name", "num_defaults", "num_rows", "subcolumns"}
                          else
                            DEFAULT_FIELDS
                          end
        extended_fields = expected_fields.dup
        extended_fields << "exact_num_defaults"
        fields = entry.keys.to_set
        return false unless fields == expected_fields || fields == extended_fields

        next unless tuple_type
        subcolumns = entry["subcolumns"]?.try(&.as_a) || return false
        begin
          TupleSerializationMetadataValidator.validate_subcolumns!(
            subcolumns,
            tuple_plan.not_nil!.root_fields,
            row_count,
            WidePart.supports_tuple_uint64_string_type?(column_type),
          )
        rescue ex : UnsupportedFormatError
          # Keep the pre-existing family validator responsible for its bounded
          # legacy rejection and diagnostic when this recursive shape is not
          # proven here.
          return false
        end
      end
      true
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end
  end
end
