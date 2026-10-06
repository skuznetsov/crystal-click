module CrystalClick
  module WidePartWriter
    # Bounded metadata for the admitted one-level Array(Object) part shape.
    # The declaration is wrapped once, while the physical roster is supplied
    # by the recursive column writer (including the wrapper's size0 lane).
    private class ArrayObjectPartMetadata
      CODEC = "CODEC(LZ4)"

      getter columns : String
      getter substreams : String
      getter count : String
      getter serialization : String
      getter metadata_version : String
      getter codec : String

      def initialize(
        key_name : String,
        value_name : String,
        schema : ObjectDocumentSchema,
        stream_names : Array(String),
        keys : Slice(UInt64),
        metadata_version : Int64,
        profile : BinaryBulkProfile,
      )
        budget = BinaryCodecBudget.new(schema.limits, true)
        budget.visit_node(1)

        row_count = keys.size.to_u64
        budget.preflight_children(row_count) if row_count > 0_u64
        defaults = 0_u64
        keys.each do |key|
          budget.charge_node
          defaults += 1_u64 if key == 0_u64
        end

        stream_count = stream_names.size.to_u64
        raise UnsupportedFormatError.new("Array(Object) physical roster cannot be empty") if stream_count == 0_u64
        raise UnsupportedFormatError.new("Array(Object) physical roster exceeds metadata limit") if stream_count > WidePart::MAX_METADATA_SUBSTREAMS.to_u64
        budget.preflight_children(stream_count)
        stream_count.times { budget.charge_node }

        key_size = key_name.bytesize.to_u64
        value_size = value_name.bytesize.to_u64
        declaration_size = schema.declaration_byte_size.to_u64
        stream_bytes = 0_u64
        stream_names.each do |name|
          if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
            raise UnsupportedFormatError.new("Array(Object) physical stream name exceeds metadata limit")
          end
          stream_bytes = checked_add(stream_bytes, name.bytesize.to_u64)
        end
        rows_text_size = decimal_digits(row_count)
        defaults_text_size = decimal_digits(defaults)
        stream_count_text_size = decimal_digits(stream_count)
        version_text_size = decimal_digits(metadata_version.to_u64)
        string_version = profile.with_size_stream? ? 1_u8 : 0_u8

        wrapped_declaration_size = checked_add(declaration_size, "Array()".bytesize.to_u64)
        columns_size = checked_add(
          "columns format version: 1\n2 columns:\n".bytesize.to_u64,
          checked_add(checked_add(key_size, 10_u64), checked_add(checked_add(value_size, 4_u64), wrapped_declaration_size))
        )
        substreams_size = checked_add(
          "columns substreams version: 1\n2 columns:\n".bytesize.to_u64,
          checked_add(
            checked_add(checked_multiply(key_size, 2_u64), "1 substreams for column `".bytesize.to_u64),
            "`:\n\t\n".bytesize.to_u64
          )
        )
        substreams_size = checked_add(
          substreams_size,
          checked_add(
            checked_add(value_size, checked_add(stream_count_text_size, " substreams for column `".bytesize.to_u64)),
            checked_add("`:\n".bytesize.to_u64, checked_add(stream_bytes, checked_multiply(stream_count, 2_u64)))
          )
        )
        count_size = rows_text_size
        serialization_size = checked_add(
          "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\"\",\"num_defaults\":,\"num_rows\":}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":},\"version\":1}".bytesize.to_u64,
          checked_add(key_size, checked_add(defaults_text_size, checked_add(rows_text_size, 1_u64)))
        )
        total_output = checked_add(
          columns_size,
          checked_add(substreams_size, checked_add(count_size, checked_add(serialization_size, checked_add(version_text_size, CODEC.bytesize.to_u64))))
        )
        metadata_limit = WidePart::MAX_METADATA_FILE_BYTES.to_u64
        if columns_size > metadata_limit || substreams_size > metadata_limit || count_size > metadata_limit ||
           serialization_size > metadata_limit || version_text_size > metadata_limit
          raise UnsupportedFormatError.new("Array(Object) part metadata exceeds reader limit")
        end
        if CODEC.bytesize > WidePart::MAX_CODEC_FILE_BYTES
          raise UnsupportedFormatError.new("default codec metadata exceeds reader limit")
        end
        total_bytes = checked_add(
          checked_multiply(total_output, 2_u64),
          checked_add(stream_bytes, checked_add(declaration_size, checked_add(key_size, value_size)))
        )
        budget.ensure_wire_bytes(total_bytes)
        budget.charge_wire_bytes(total_bytes)

        names = stream_names.map { |name| String.new(name.to_slice) }
        names.sort!
        index = 1
        while index < names.size
          raise UnsupportedFormatError.new("Array(Object) physical stream names are not unique") if names[index - 1] == names[index]
          index += 1
        end

        declaration = "Array(#{schema.declaration})"
        @columns = "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{declaration}\n"
        @substreams = String.build do |io|
          io << "columns substreams version: 1\n2 columns:\n"
          io << "1 substreams for column `" << key_name << "`:\n\t" << key_name << "\n"
          io << names.size << " substreams for column `" << value_name << "`:\n"
          names.each { |name| io << '\t' << name << '\n' }
        end
        @count = row_count.to_s
        @serialization = String.build do |io|
          io << "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\""
          io << key_name << "\",\"num_defaults\":" << defaults << ",\"num_rows\":" << row_count
          io << "}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":"
          io << string_version
          io << "},\"version\":1}"
        end
        @metadata_version = metadata_version.to_s
        @codec = String.new(CODEC.to_slice)

        unless @columns.bytesize.to_u64 == columns_size && @substreams.bytesize.to_u64 == substreams_size &&
               @serialization.bytesize.to_u64 == serialization_size
          raise UnsupportedFormatError.new("Array(Object) metadata exceeded its preflight size")
        end
        if @columns.bytesize.to_u64 > metadata_limit ||
           @substreams.bytesize.to_u64 > metadata_limit ||
           @count.bytesize.to_u64 > metadata_limit ||
           @serialization.bytesize.to_u64 > metadata_limit ||
           @metadata_version.bytesize.to_u64 > metadata_limit
          raise UnsupportedFormatError.new("Array(Object) part metadata exceeds reader limit")
        end
        if @codec.bytesize > WidePart::MAX_CODEC_FILE_BYTES
          raise UnsupportedFormatError.new("default codec metadata exceeds reader limit")
        end
      end

      private def decimal_digits(value : UInt64) : UInt64
        count = 1_u64
        remaining = value
        while remaining >= 10_u64
          remaining //= 10_u64
          count += 1_u64
        end
        count
      end

      private def checked_add(left : UInt64, right : UInt64) : UInt64
        raise UnsupportedFormatError.new("Array(Object) metadata size overflows UInt64") if left > UInt64::MAX - right
        left + right
      end

      private def checked_multiply(left : UInt64, right : UInt64) : UInt64
        if right != 0_u64 && left > UInt64::MAX // right
          raise UnsupportedFormatError.new("Array(Object) metadata size overflows UInt64")
        end
        left * right
      end
    end
  end
end
