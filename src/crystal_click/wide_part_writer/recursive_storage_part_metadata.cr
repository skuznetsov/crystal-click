module CrystalClick
  module WidePartWriter
    # Bounded metadata snapshot for one recursive storage value column.
    # The admitted schema supplies the declaration and the complete physical
    # roster; this class owns only the two-column part envelope.
    private class RecursiveStoragePartMetadata
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
        schema : StorageColumnSchema,
        stream_names : Array(String),
        keys : Slice(UInt64),
        metadata_version : Int64,
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
      )
        if metadata_version < 0
          raise ArgumentError.new("metadata version must be nonnegative")
        end

        budget = BinaryCodecBudget.new(limits, true)
        budget.visit_node(1)
        row_count = keys.size.to_u64
        budget.preflight_children(row_count) if row_count > 0_u64
        defaults = 0_u64
        keys.each do |key|
          budget.charge_node
          defaults += 1_u64 if key == 0_u64
        end

        stream_count = stream_names.size.to_u64
        if stream_count == 0_u64 || stream_count > WidePart::MAX_METADATA_SUBSTREAMS.to_u64
          raise UnsupportedFormatError.new("recursive physical roster is outside the metadata substream limit")
        end
        budget.preflight_children(stream_count)
        stream_count.times { budget.charge_node }

        key_size = key_name.bytesize.to_u64
        value_size = value_name.bytesize.to_u64
        declaration_size = schema.declaration_byte_size.to_u64
        stream_bytes = 0_u64
        stream_names.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise UnsupportedFormatError.new("recursive physical stream name exceeds metadata line limit")
          end
          stream_bytes = checked_add(stream_bytes, name.bytesize.to_u64)
        end
        rows_text_size = decimal_digits(row_count)
        defaults_text_size = decimal_digits(defaults)
        stream_count_text_size = decimal_digits(stream_count)
        version_text = metadata_version.to_s
        version_text_size = version_text.bytesize.to_u64
        string_version = profile.with_size_stream? ? 1_u8 : 0_u8

        columns_size = checked_add(
          "columns format version: 1\n2 columns:\n".bytesize.to_u64,
          checked_add(checked_add(key_size, 10_u64), checked_add(checked_add(value_size, 4_u64), declaration_size))
        )
        substreams_size = "columns substreams version: 1\n2 columns:\n".bytesize.to_u64
        substreams_size = checked_add(
          substreams_size,
          checked_add(
            checked_multiply(key_size, 2_u64),
            checked_add("1 substreams for column `".bytesize.to_u64, "`:\n\t\n".bytesize.to_u64)
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
        codec_size = CODEC.bytesize.to_u64
        total_output = checked_add(
          columns_size,
          checked_add(substreams_size, checked_add(count_size, checked_add(serialization_size, checked_add(version_text_size, codec_size))))
        )

        metadata_limit = WidePart::MAX_METADATA_FILE_BYTES.to_u64
        if columns_size > metadata_limit || substreams_size > metadata_limit || count_size > metadata_limit ||
           serialization_size > metadata_limit || version_text_size > metadata_limit
          raise UnsupportedFormatError.new("recursive part metadata exceeds reader limit")
        end
        if codec_size > WidePart::MAX_CODEC_FILE_BYTES.to_u64
          raise UnsupportedFormatError.new("default codec metadata exceeds reader limit")
        end

        # Charge the retained output and the detached declaration/name inputs
        # before any String.build or roster copy. This is a logical codec
        # budget, not a process-RSS bound.
        total_bytes = checked_add(
          checked_multiply(total_output, 2_u64),
          checked_add(stream_bytes, checked_add(declaration_size, checked_add(key_size, value_size)))
        )
        budget.ensure_wire_bytes(total_bytes)
        budget.charge_wire_bytes(total_bytes)

        names = stream_names
        names.sort!
        index = 1
        while index < names.size
          if names[index - 1] == names[index]
            raise UnsupportedFormatError.new("recursive physical stream names are not unique")
          end
          index += 1
        end

        declaration = schema.declaration
        @columns = String.build do |io|
          io << "columns format version: 1\n2 columns:\n`" << key_name << "` UInt64\n`" << value_name << "` " << declaration << '\n'
        end
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
        @metadata_version = version_text
        @codec = String.new(CODEC.to_slice)

        unless @columns.bytesize.to_u64 == columns_size && @substreams.bytesize.to_u64 == substreams_size &&
               @count.bytesize.to_u64 == count_size && @serialization.bytesize.to_u64 == serialization_size &&
               @metadata_version.bytesize.to_u64 == version_text_size && @codec.bytesize.to_u64 == codec_size
          raise UnsupportedFormatError.new("recursive part metadata exceeded its preflight size")
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
        if left > UInt64::MAX - right
          raise UnsupportedFormatError.new("recursive part metadata size overflows UInt64")
        end
        left + right
      end

      private def checked_multiply(left : UInt64, right : UInt64) : UInt64
        if right != 0_u64 && left > UInt64::MAX // right
          raise UnsupportedFormatError.new("recursive part metadata size overflows UInt64")
        end
        left * right
      end
    end
  end
end
