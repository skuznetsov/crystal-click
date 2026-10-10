module CrystalClick
  module WidePartWriter
    # Detached N-column part metadata snapshot. W245 writes under
    # always-Default serialization: the statistics roster is intentionally
    # empty, while the one global String serialization version describes all
    # value columns.
    private class WidePartMetadata
      CODEC = "CODEC(LZ4)"

      getter columns : String
      getter substreams : String
      getter count : String
      getter serialization : String
      getter metadata_version : String
      getter codec : String

      def initialize(
        key_name : String,
        columns : Array(Tuple(String, String, Array(String))),
        keys : Slice(UInt64),
        metadata_version : Int64,
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        budget : BinaryCodecBudget,
      )
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless budget.writing? && same_limits?(budget.limits, limits)
          raise ArgumentError.new("Wide metadata codec budget differs from its write limits")
        end

        row_count = keys.size.to_u64
        declarations_size = line_size(key_name.bytesize.to_u64, "UInt64".bytesize.to_u64)
        substream_size = checked_add(
          substream_header_size(key_name, 1_u64),
          checked_add(key_name.bytesize.to_u64, 2_u64),
        )
        # The key column contributes one physical substream to the same
        # metadata-wide limit as every value lane.
        stream_count = 1_u64
        columns.each do |column|
          name, declaration, streams = column
          declarations_size = checked_add(
            declarations_size,
            line_size(name.bytesize.to_u64, declaration.bytesize.to_u64),
          )
          substream_size = checked_add(substream_size, substream_header_size(name, streams.size.to_u64))
          streams.each do |stream|
            if stream.empty? || stream.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise UnsupportedFormatError.new("Wide physical stream name exceeds metadata line limit")
            end
            substream_size = checked_add(substream_size, checked_add(stream.bytesize.to_u64, 2_u64))
            stream_count = checked_add(stream_count, 1_u64)
          end
        end
        if columns.empty? || columns.size + 1 > WidePart::MAX_METADATA_COLUMNS
          raise UnsupportedFormatError.new("Wide part column count is outside the metadata limit")
        end
        if stream_count == 0_u64 || stream_count > WidePart::MAX_METADATA_SUBSTREAMS.to_u64
          raise UnsupportedFormatError.new("Wide physical roster is outside the metadata substream limit")
        end

        count_text_size = decimal_digits(row_count)
        version_text = metadata_version.to_s
        string_version = profile.with_size_stream? ? 1_u8 : 0_u8
        columns_header = "columns format version: 1\n#{columns.size + 1} columns:\n"
        substreams_header = "columns substreams version: 1\n#{columns.size + 1} columns:\n"
        columns_size = checked_add(columns_header.bytesize.to_u64, declarations_size)
        substreams_size = checked_add(substreams_header.bytesize.to_u64, substream_size)
        serialization_size = checked_add(
          "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":},\"version\":1}".bytesize.to_u64,
          1_u64,
        )
        codec_size = CODEC.bytesize.to_u64
        total_output = checked_add(
          columns_size,
          checked_add(substreams_size, checked_add(count_text_size, checked_add(serialization_size, checked_add(version_text.bytesize.to_u64, codec_size)))),
        )
        metadata_limit = WidePart::MAX_METADATA_FILE_BYTES.to_u64
        if columns_size > metadata_limit || substreams_size > metadata_limit ||
           count_text_size > metadata_limit || serialization_size > metadata_limit ||
           version_text.bytesize.to_u64 > metadata_limit
          raise UnsupportedFormatError.new("Wide part metadata exceeds reader limit")
        end
        if codec_size > WidePart::MAX_CODEC_FILE_BYTES.to_u64
          raise UnsupportedFormatError.new("default codec metadata exceeds reader limit")
        end

        # Reserve before materializing the retained files. The descriptor/name
        # copies are included in the same operation-local logical budget.
        retained = checked_add(checked_multiply(total_output, 2_u64), checked_add(declarations_size, substream_size))
        budget.ensure_wire_bytes(retained)
        budget.charge_wire_bytes(retained)

        @columns = String.build do |io|
          io << columns_header
          io << '`' << key_name << "` UInt64\n"
          columns.each do |column|
            io << '`' << column[0] << "` " << column[1] << '\n'
          end
        end
        @substreams = String.build do |io|
          io << substreams_header
          io << "1 substreams for column `" << key_name << "`:\n\t" << key_name << '\n'
          columns.each do |column|
            streams = column[2]
            io << streams.size << " substreams for column `" << column[0] << "`:\n"
            streams.each { |stream| io << '\t' << stream << '\n' }
          end
        end
        @count = row_count.to_s
        @serialization = String.build do |io|
          io << "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":"
          io << string_version
          io << "},\"version\":1}"
        end
        @metadata_version = version_text
        @codec = String.new(CODEC.to_slice)
        unless @columns.bytesize.to_u64 == columns_size && @substreams.bytesize.to_u64 == substreams_size &&
               @count.bytesize.to_u64 == count_text_size && @serialization.bytesize.to_u64 == serialization_size
          raise UnsupportedFormatError.new("Wide metadata sizing differed from its preflight")
        end
      end

      private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
        left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
          left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
      end

      private def checked_add(left : UInt64, right : UInt64) : UInt64
        raise UnsupportedFormatError.new("Wide metadata size overflows") if left > UInt64::MAX - right
        left + right
      end

      private def checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise UnsupportedFormatError.new("Wide metadata size overflows") if right != 0_u64 && left > UInt64::MAX // right
        left * right
      end

      private def decimal_digits(value : UInt64) : UInt64
        digits = 1_u64
        while value >= 10_u64
          value //= 10_u64
          digits += 1_u64
        end
        digits
      end

      private def line_size(name_bytes : UInt64, type_bytes : UInt64) : UInt64
        checked_add(checked_add(name_bytes, type_bytes), 4_u64)
      end

      private def substream_header_size(name : String, count : UInt64) : UInt64
        checked_add(
          decimal_digits(count),
          checked_add(
            " substreams for column `".bytesize.to_u64,
            checked_add(name.bytesize.to_u64, "`:\n".bytesize.to_u64),
          ),
        )
      end
    end
  end
end
