module CrystalClick
  module WidePartWriter
    # Private implementation owner for Wide-part schema and serialization metadata.
    # This class renders bytes; staged-part validation remains with the writer.
    private class PartSchemaMetadata
      def self.columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` UInt64\n"
      end

      def self.nullable_columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Nullable(UInt64)\n"
      end

      def self.string_columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` String\n"
      end

      def self.dynamic_string_columns_metadata(key_name : String, value_name : String) : String
        typed_columns_metadata(key_name, value_name, "Dynamic")
      end

      def self.tuple_string_columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Tuple(a UInt64, b String)\n"
      end

      def self.json_typed_columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` JSON(a UInt64, b String)\n"
      end

      def self.json_typed_paths_columns_metadata(
        key_name : String,
        value_name : String,
        paths : Array(JSONTypedPathColumn),
      ) : String
        declaration = paths.sort_by(&.name).map { |path| "#{path.name} #{path.type_name}" }.join(", ")
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` JSON(#{declaration})\n"
      end

      def self.json_object_structure_bytes : Bytes
        Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 0_u8]
      end

      def self.substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n1 substreams for column `#{value_name}`:\n\t#{value_name}\n"
      end

      def self.nullable_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size\n\t#{value_name}\n"
      end

      def self.dynamic_string_substreams_metadata(key_name : String, value_name : String) : String
        value_streams = [
          "#{value_name}.dynamic_structure",
          "#{value_name}.variant_discr",
          "#{value_name}.SharedVariant.size",
          "#{value_name}.SharedVariant",
          "#{value_name}.String.size",
          "#{value_name}.String",
        ]
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.dynamic_string_string_uint64_substreams_metadata(key_name : String, value_name : String) : String
        value_streams = [
          "#{value_name}.dynamic_structure",
          "#{value_name}.variant_discr",
          "#{value_name}.SharedVariant.size",
          "#{value_name}.SharedVariant",
          "#{value_name}.String.size",
          "#{value_name}.String",
          "#{value_name}.UInt64",
        ]
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.variant_string_uint64_substreams_metadata(key_name : String, value_name : String) : String
        value_streams = WideVariantStringUInt64TypePlan.physical_streams(value_name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.variant_bool_string_uint64_substreams_metadata(key_name : String, value_name : String) : String
        value_streams = WideVariantBoolStringUInt64TypePlan.physical_streams(value_name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.tuple_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}%2Ea\n\t#{value_name}%2Eb.size\n\t#{value_name}%2Eb\n"
      end

      def self.array_tuple_substreams_metadata(
        key_name : String,
        value_name : String,
        type_plan : WideTypePlan,
      ) : String
        value_streams = type_plan.physical_substreams(value_name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.json_typed_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "7 substreams for column `#{value_name}`:\n\t#{value_name}.object_structure\n\t#{value_name}.a\n" +
          "\t#{value_name}.b.size\n\t#{value_name}.b\n" +
          "\t#{value_name}.object_shared_data.0.size0\n" +
          "\t#{value_name}.object_shared_data.0%2Epaths\n" +
          "\t#{value_name}.object_shared_data.0%2Evalues\n"
      end

      def self.json_typed_paths_substreams_metadata(
        key_name : String,
        value_name : String,
        sorted_paths : Array(JSONTypedPathColumn),
      ) : String
        streams = ["#{value_name}.object_structure"]
        sorted_paths.each do |path|
          typed_name = "#{value_name}.#{path.name}"
          streams << "#{typed_name}.size" if path.type_name == "String"
          streams << typed_name
        end
        streams.concat([
          "#{value_name}.object_shared_data.0.size0",
          "#{value_name}.object_shared_data.0%2Epaths",
          "#{value_name}.object_shared_data.0%2Evalues",
        ])
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.low_cardinality_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.dict\n\t#{value_name}\n"
      end

      def self.array_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
      end

      def self.array_array_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}\n"
      end

      def self.array_array_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.size\n\t#{value_name}\n"
      end

      def self.array_array_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.null\n\t#{value_name}.size\n\t#{value_name}\n"
      end

      def self.array_array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.array_array_nullable_numeric_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        array_nullable_numeric_substreams_metadata(key_name, value_name)
      end

      def self.array_nullable_numeric_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.array_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size\n\t#{value_name}\n"
      end

      def self.array_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}.size\n\t#{value_name}\n"
      end

      def self.array_fixed_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
      end

      def self.array_nullable_fixed_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.array_bool_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
      end

      def self.array_nullable_bool_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
      end

      def self.map_uint64_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
      end

      def self.map_uint64_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues\n"
      end

      def self.map_numeric_substreams_metadata(key_name : String, value_name : String, string_keys : Bool) : String
        if string_keys
          "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
            "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
            "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues\n"
        else
          map_uint64_uint64_substreams_metadata(key_name, value_name)
        end
      end

      def self.map_nullable_numeric_substreams_metadata(key_name : String, value_name : String, string_keys : Bool) : String
        if string_keys
          "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
            "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
            "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
            "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
        else
          "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
            "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
            "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
        end
      end

      def self.map_uint64_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
      end

      def self.map_uint64_array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size1\n" +
          "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
      end

      def self.map_array_nullable_numeric_substreams_metadata(key_name : String, value_name : String, string_keys : Bool) : String
        if string_keys
          "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
            "6 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
            "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
            "\t#{value_name}%2Evalues.size1\n\t#{value_name}%2Evalues.null\n" +
            "\t#{value_name}%2Evalues\n"
        else
          "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
            "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
            "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size1\n" +
            "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
        end
      end

      def self.map_uint64_array_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size1\n" +
          "\t#{value_name}%2Evalues\n"
      end

      def self.map_uint64_array_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "6 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size1\n" +
          "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues.size\n" +
          "\t#{value_name}%2Evalues\n"
      end

      def self.map_uint64_array_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size1\n" +
          "\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
      end

      def self.map_uint64_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.null\n" +
          "\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
      end

      def self.map_string_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues\n"
      end

      def self.array_map_string_uint64_substreams_metadata(
        key_name : String,
        value_name : String,
        physical_plan : ArrayMapStringUInt64PhysicalPlan,
      ) : String
        streams = physical_plan.streams.map(&.name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.array_map_numeric_substreams_metadata(
        key_name : String,
        value_name : String,
        physical_plan : ArrayMapNumericPhysicalPlan,
      ) : String
        streams = physical_plan.streams.map(&.name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.array_map_string_substreams_metadata(
        key_name : String,
        value_name : String,
        physical_plan : ArrayMapStringPhysicalPlan,
      ) : String
        streams = physical_plan.streams.map(&.name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.array_map_array_numeric_substreams_metadata(
        key_name : String,
        value_name : String,
        physical_plan : ArrayMapArrayNumericPhysicalPlan,
      ) : String
        streams = physical_plan.streams.map(&.name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.array_map_array_substreams_metadata(
        key_name : String,
        value_name : String,
        physical_plan : ArrayMapArrayPhysicalPlan,
      ) : String
        streams = physical_plan.streams.map(&.name)
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{streams.size} substreams for column `#{value_name}`:\n"
        streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.array_map_array_serialization_metadata : String
        "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      def self.map_string_array_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.size1\n\t#{value_name}%2Evalues\n"
      end

      def self.map_string_array_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "6 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.size1\n\t#{value_name}%2Evalues.size\n" +
          "\t#{value_name}%2Evalues\n"
      end

      def self.map_string_array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "6 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.size1\n\t#{value_name}%2Evalues.null\n" +
          "\t#{value_name}%2Evalues\n"
      end

      def self.map_string_array_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "7 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.size1\n\t#{value_name}%2Evalues.null\n" +
          "\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
      end

      def self.map_string_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues\n"
      end

      def self.map_string_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "6 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.null\n\t#{value_name}%2Evalues.size\n" +
          "\t#{value_name}%2Evalues\n"
      end

      def self.map_string_string_substreams_metadata(key_name : String, value_name : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "5 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
          "\t#{value_name}%2Ekeys.size\n\t#{value_name}%2Ekeys\n" +
          "\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
      end

      def self.typed_columns_metadata(key_name : String, value_name : String, type_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{type_name}\n"
      end

      def self.typed_substreams_metadata(key_name : String, value_name : String, type_name : String) : String
        value_streams = if type_name == "String"
                          ["#{value_name}.size", value_name]
                        elsif type_name == "Nullable(String)"
                          ["#{value_name}.null", "#{value_name}.size", value_name]
                        elsif type_name.starts_with?("Nullable(")
                          ["#{value_name}.null", value_name]
                        else
                          [value_name]
                        end
        payload = IO::Memory.new
        payload << "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
        payload << "#{value_streams.size} substreams for column `#{value_name}`:\n"
        value_streams.each { |stream| payload << "\t#{stream}\n" }
        payload.to_s
      end

      def self.typed_serialization_metadata(type_name : String) : String
        versions = if type_name == "String"
                     "\"string\":1"
                   elsif type_name == "Nullable(String)"
                     "\"nullable\":0,\"string\":1"
                   elsif type_name == "UUID" || type_name == "IPv4" || type_name == "IPv6" || type_name == "Int128" || type_name == "UInt128" || type_name == "Int256" || type_name == "UInt256" || type_name.starts_with?("Nullable(") || semantic_fixed_width_type?(type_name) || type_name == "Time" || !WidePart.time64_scale(type_name).nil? || !IntervalColumnType.parse(type_name).nil?
                     # BASIC Nullable payloads, UUID, IPv4, and IPv6 use this global
                     # serializer-version metadata. Semantic identity is
                     # carried by the exact column type.
                     "\"string\":1"
                   else
                     ""
                   end
        "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{#{versions}},\"version\":1}"
      end

      def self.semantic_fixed_width_type?(type_name : String) : Bool
        type_name == "Bool" || type_name == "BFloat16" || !WidePart.enum8_codes(type_name).nil? || !WidePart.enum16_codes(type_name).nil? ||
          !WidePart.decimal32_scale(type_name).nil? || !WidePart.decimal64_scale(type_name).nil? ||
          !WidePart.decimal128_scale(type_name).nil? || !WidePart.decimal256_scale(type_name).nil?
      end

      def self.nullable_fixed_string_serialization_metadata : String
        "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"nullable\":0,\"string\":1},\"version\":1}"
      end

      def self.serialization_metadata : String
        "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      def self.tuple_string_serialization_metadata(
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Array(Tuple(UInt64, String)),
      ) : String
        rows = values.size
        key_defaults = keys.count { |key| key == 0_u64 }
        tuple_defaults = values.count { |value| value[0] == 0_u64 && value[1].empty? }
        a_defaults = values.count { |value| value[0] == 0_u64 }
        b_defaults = values.count { |value| value[1].empty? }
        String.build do |json|
          json << "{\"columns\":["
          json << "{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{key_defaults},\"num_rows\":#{rows}},"
          json << "{\"kind\":\"Default\",\"name\":\"#{value_name}\",\"num_defaults\":#{tuple_defaults},\"num_rows\":#{rows},\"subcolumns\":["
          json << "{\"kind\":\"Default\",\"num_defaults\":#{a_defaults},\"num_rows\":#{rows}},"
          json << "{\"kind\":\"Default\",\"num_defaults\":#{b_defaults},\"num_rows\":#{rows}}]}],"
          json << "\"propagate_types_serialization_versions_to_nested_types\":true,"
          json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        end
      end

      def self.json_typed_serialization_metadata(key_name : String, keys : Slice(UInt64)) : String
        key_defaults = keys.count { |key| key == 0_u64 }
        String.build do |json|
          json << "{\"columns\":[{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{key_defaults},\"num_rows\":#{keys.size}}],"
          json << "\"propagate_types_serialization_versions_to_nested_types\":true,"
          json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        end
      end
    end
  end
end
