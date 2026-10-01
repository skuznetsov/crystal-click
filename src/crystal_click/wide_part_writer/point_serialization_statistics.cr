module CrystalClick
  module WidePartWriter
    # Builds the pinned version-1 Point SerializationInfo envelope from the
    # raw Float64 default predicate shared with Tuple numeric leaves.
    private class PointSerializationStatistics
      def self.build(
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        values : Slice(WidePointValue),
      ) : String
        raise ArgumentError.new("Point statistics require equal nonzero row counts") if keys.empty? || keys.size != values.size

        key_defaults = 0
        x_defaults = 0
        y_defaults = 0
        point_defaults = 0
        values.each do |value|
          x_default = WideTupleNumericType.is_default?(value.x)
          y_default = WideTupleNumericType.is_default?(value.y)
          x_defaults += 1 if x_default
          y_defaults += 1 if y_default
          point_defaults += 1 if x_default && y_default
        end
        keys.each { |key| key_defaults += 1 if key.zero? }

        point_record = String.build do |json|
          json << "{\"kind\":\"Default\",\"name\":\"" << value_name
          json << "\",\"num_defaults\":" << point_defaults
          json << ",\"num_rows\":" << values.size
          json << ",\"subcolumns\":["
          append_coordinate_record(json, x_defaults, values.size)
          json << ","
          append_coordinate_record(json, y_defaults, values.size)
          json << "]}"
        end
        key_record = String.build do |json|
          json << "{\"kind\":\"Default\",\"name\":\"" << key_name
          json << "\",\"num_defaults\":" << key_defaults
          json << ",\"num_rows\":" << keys.size << "}"
        end
        records = [{key_name, key_record}, {value_name, point_record}].sort_by(&.[0])

        String.build do |json|
          json << "{\"columns\":[" << records.map(&.[1]).join(",")
          json << "],\"propagate_types_serialization_versions_to_nested_types\":true,"
          json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        end
      end

      private def self.append_coordinate_record(json : String::Builder, defaults : Int32, rows : Int32) : Nil
        json << "{\"kind\":\"Default\",\"num_defaults\":" << defaults
        json << ",\"num_rows\":" << rows << "}"
        nil
      end
    end
  end
end
