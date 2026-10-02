module CrystalClick
  module WidePartWriter
    # Bounded metadata snapshot for one normalized JSON Wide part. The source
    # physical plan already owns its logical-name bounds and collision check;
    # this owner only formats that admitted roster and the explicit key data.
    private class ObjectPartMetadata
      CODEC = "CODEC(LZ4)"

      @limits : BinaryCodecLimits
      @columns : String
      @substreams : String
      @count : String
      @serialization : String
      @metadata_version : String
      @codec : String

      def initialize(
        key_name : String,
        value_name : String,
        schema : ObjectDocumentSchema,
        physical : ObjectDocumentPhysicalPlan,
        keys : Slice(UInt64),
        metadata_version : Int64 = 0_i64,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      )
        @limits = schema.limits
        budget = BinaryCodecBudget.new(@limits, true)
        budget.visit_node(1)

        row_count = keys.size.to_u64
        budget.preflight_children(row_count) if row_count > 0_u64
        key_defaults = 0_u64
        keys.each do |key|
          budget.charge_node
          key_defaults += 1_u64 if key == 0_u64
        end

        stream_count = physical.stream_count.to_u64
        if stream_count == 0_u64
          raise UnsupportedFormatError.new("normalized Object physical roster cannot be empty")
        end
        budget.preflight_children(stream_count)
        physical.stream_count.times { budget.charge_node }

        # ObjectDocumentPhysicalPlan owns and bounds its full logical name set
        # before this snapshot API copies it. Check the known entry count first.
        streams = physical.stream_names
        unless streams.size.to_u64 == stream_count
          raise UnsupportedFormatError.new("Object physical stream count changed after planning")
        end
        streams.sort!
        index = 1
        while index < streams.size
          if streams[index - 1] == streams[index]
            raise UnsupportedFormatError.new("Object physical stream names are not unique")
          end
          index += 1
        end

        declaration_size = schema.declaration_byte_size.to_u64
        key_size = key_name.bytesize.to_u64
        value_size = value_name.bytesize.to_u64
        stream_bytes = 0_u64
        streams.each { |name| stream_bytes = checked_add(stream_bytes, name.bytesize.to_u64) }
        rows_text_size = decimal_digits(row_count)
        defaults_text_size = decimal_digits(key_defaults)
        stream_count_text_size = decimal_digits(stream_count)
        version_text = metadata_version.to_s
        version_text_size = version_text.bytesize.to_u64
        string_version = profile.with_size_stream? ? 1_u8 : 0_u8

        columns_size = checked_add(
          "columns format version: 1\n2 columns:\n".bytesize.to_u64,
          checked_add(
            checked_add(key_size, 10_u64),
            checked_add(checked_add(value_size, 4_u64), declaration_size)
          )
        )
        substreams_size = "columns substreams version: 1\n2 columns:\n".bytesize.to_u64
        substreams_size = checked_add(
          substreams_size,
          checked_add(checked_multiply(key_size, 2_u64), checked_add("1 substreams for column `".bytesize.to_u64, checked_add("`:\n\t".bytesize.to_u64, 1_u64)))
        )
        substreams_size = checked_add(
          substreams_size,
          checked_add(
            value_size,
            checked_add(stream_count_text_size, checked_add(" substreams for column `".bytesize.to_u64, "`:\n".bytesize.to_u64))
          )
        )
        substreams_size = checked_add(substreams_size, checked_add(stream_bytes, checked_multiply(stream_count, 2_u64)))
        count_size = rows_text_size
        serialization_size = checked_add(
          "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\"\",\"num_defaults\":,\"num_rows\":}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":},\"version\":1}".bytesize.to_u64,
          checked_add(key_name.bytesize.to_u64, checked_add(defaults_text_size, checked_add(rows_text_size, 1_u64)))
        )
        metadata_version_size = version_text_size
        total_output = checked_add(columns_size, checked_add(substreams_size, checked_add(count_size, checked_add(serialization_size, checked_add(metadata_version_size, CODEC.bytesize.to_u64)))))
        # Account both retained metadata output and the physical/schema name
        # snapshots that must be traversed while composing it.
        total_bytes = checked_add(checked_multiply(total_output, 2_u64), checked_add(stream_bytes, declaration_size))
        budget.ensure_wire_bytes(total_bytes)
        budget.charge_wire_bytes(total_bytes)

        declaration = schema.declaration
        @columns = String.build do |io|
          io << "columns format version: 1\n2 columns:\n`" << key_name << "` UInt64\n`" << value_name << "` " << declaration << '\n'
        end

        @substreams = String.build do |io|
          io << "columns substreams version: 1\n2 columns:\n"
          io << "1 substreams for column `" << key_name << "`:\n\t" << key_name << '\n'
          io << streams.size << " substreams for column `" << value_name << "`:\n"
          streams.each { |name| io << '\t' << name << '\n' }
        end

        @count = row_count.to_s
        @metadata_version = version_text
        @codec = String.new(CODEC.to_slice)
        @serialization = String.build do |io|
          io << "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\""
          io << key_name << "\",\"num_defaults\":" << key_defaults << ",\"num_rows\":" << row_count
          io << "}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":" << string_version << "},\"version\":1}"
        end
        unless @columns.bytesize.to_u64 == columns_size &&
               @substreams.bytesize.to_u64 == substreams_size &&
               @serialization.bytesize.to_u64 == serialization_size
          raise UnsupportedFormatError.new("Object part metadata exceeded its preflight size")
        end
      end

      def columns : String
        detached(@columns)
      end

      def substreams : String
        detached(@substreams)
      end

      def count : String
        detached(@count)
      end

      def serialization : String
        detached(@serialization)
      end

      def metadata_version : String
        detached(@metadata_version)
      end

      def codec : String
        detached(@codec)
      end

      private def detached(value : String) : String
        budget = BinaryCodecBudget.new(@limits, true)
        size = value.bytesize.to_u64
        budget.ensure_wire_bytes(size)
        budget.charge_wire_bytes(size)
        String.new(value.to_slice)
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
          raise UnsupportedFormatError.new("Object part metadata size overflows UInt64")
        end
        left + right
      end

      private def checked_multiply(left : UInt64, right : UInt64) : UInt64
        if right != 0_u64 && left > UInt64::MAX // right
          raise UnsupportedFormatError.new("Object part metadata size overflows UInt64")
        end
        left * right
      end
    end
  end
end
