module CrystalClick
  class WidePart
    # Explicit caller binding for ClickHouse's flattened Nested representation.
    # It normalizes sibling Arrays only in memory and never infers Nested from
    # dotted names in an ordinary part reader.
    class FlattenedNestedStoragePlan
      struct Binding
        @key_name : String
        @selected_column : String
        @logical_columns : Array({String, String})

        def initialize(
          @key_name : String,
          @selected_column : String,
          @logical_columns : Array({String, String}),
        )
          @key_name = String.new(key_name.to_slice)
          @selected_column = String.new(selected_column.to_slice)
          @logical_columns = logical_columns.map do |name, type|
            {String.new(name.to_slice), String.new(type.to_slice)}
          end
        end

        def key_name : String
          String.new(@key_name.to_slice)
        end

        def selected_column : String
          String.new(@selected_column.to_slice)
        end

        def logical_columns : Array({String, String})
          @logical_columns.map do |name, type|
            {String.new(name.to_slice), String.new(type.to_slice)}
          end
        end
      end

      @group_name : String
      @nested_plan : WideNestedTypePlan

      private def initialize(group_name : String, @nested_plan : WideNestedTypePlan)
        @group_name = String.new(group_name.to_slice)
      end

      # Nil denotes an unsupported caller declaration. Bound the root before
      # retaining/copying it; field/type parsing is owned by W171's plan.
      def self.for_type(group_name : String, type_name : String) : FlattenedNestedStoragePlan?
        return nil if group_name.empty? || group_name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
        return nil unless simple_identifier?(group_name)
        nested_plan = WideNestedTypePlan.for_type(type_name) || return nil
        fields = nested_plan.tuple_plan.fields
        return nil if fields.empty? || fields.any? { |field| field.path_depth != 1 }

        plan = new(group_name, nested_plan)
        return nil if plan.root_physical_streams.any? { |stream| stream.bytesize > WidePart::MAX_METADATA_LINE_BYTES }
        fields.each do |field|
          column_name = "#{group_name}.#{field.name}"
          return nil if column_name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
          return nil if "Array(#{field.type_name})".bytesize > WidePart::MAX_METADATA_LINE_BYTES
        end
        plan
      end

      def group_name : String
        String.new(@group_name.to_slice)
      end

      def type_name : String
        @nested_plan.type_name
      end

      def storage_plan : WideArrayTupleTypePlan
        @nested_plan.storage_plan
      end

      def tuple_plan : WideTupleTypePlan
        @nested_plan.tuple_plan
      end

      def root_physical_streams : Array(String)
        storage_plan.physical_streams(@group_name)
      end

      # Bind exactly `[UInt64 key, one Array sibling per direct Nested leaf]`.
      # A key sharing the virtual root name is rejected because it cannot name
      # both normalized logical columns unambiguously.
      def bind_columns(
        columns : Array({String, String}),
        selected_column : String?,
      ) : Binding
        raise UnsupportedFormatError.new("flattened Nested part must contain one UInt64 key and every sibling") unless columns.size == tuple_plan.field_count + 1
        key_name, key_type = columns[0]
        unless key_type == "UInt64" && key_name.bytesize <= WidePart::MAX_METADATA_LINE_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(key_name)
          raise UnsupportedFormatError.new("flattened Nested key must be a simple UInt64 column")
        end
        raise UnsupportedFormatError.new("flattened Nested key collides with its logical root") if key_name == @group_name

        expected = [{String.new(key_name.to_slice), "UInt64"}] of {String, String}
        tuple_plan.fields.each do |field|
          expected << {sibling_column_name(field), "Array(#{field.type_name})"}
        end
        raise UnsupportedFormatError.new("flattened Nested sibling roster or order does not match declaration") unless columns == expected

        selected = selected_column || @group_name
        unless selected == @group_name || selected == key_name
          raise UnsupportedFormatError.new("flattened Nested selection must name its logical root or UInt64 key")
        end
        logical_columns = [
          {String.new(key_name.to_slice), "UInt64"},
          {String.new(@group_name.to_slice), type_name},
        ] of {String, String}
        Binding.new(String.new(key_name.to_slice), String.new(selected.to_slice), logical_columns)
      end

      def columns_metadata(key_name : String) : String
        String.build do |metadata|
          metadata << "columns format version: 1\n"
          metadata << (tuple_plan.field_count + 1) << " columns:\n"
          metadata << "`" << key_name << "` UInt64\n"
          tuple_plan.fields.each do |field|
            metadata << "`" << sibling_column_name(field) << "` Array(" << field.type_name << ")\n"
          end
        end
      end

      def substreams_metadata(key_name : String) : String
        String.build do |metadata|
          metadata << "columns substreams version: 1\n"
          metadata << (tuple_plan.field_count + 1) << " columns:\n"
          metadata << "1 substreams for column `" << key_name << "`:\n\t" << key_name << "\n"
          tuple_plan.fields.each do |field|
            streams = sibling_substreams(field)
            metadata << streams.size << " substreams for column `" << sibling_column_name(field) << "`:\n"
            streams.each { |stream| metadata << "\t" << stream << "\n" }
          end
        end
      end

      def expected_substreams(column_name : String, key_name : String) : Array(String)?
        return [String.new(key_name.to_slice)] of String if column_name == key_name
        tuple_plan.fields.each do |field|
          return sibling_substreams(field) if sibling_column_name(field) == column_name
        end
        nil
      end

      # Validate every physical block before returning either the root streams
      # or the key stream. Only repeated references to the exact shared size0
      # stream are admitted; ordinary substream parsing remains unchanged.
      def physical_streams_for(
        text : String,
        physical_columns : Array({String, String}),
        binding : Binding,
      ) : Array(String)
        bytes = text.to_slice
        cursor = 0
        PartMetadataTextParser.require_metadata_line(bytes, cursor, "columns substreams version: 1", "columns_substreams.txt")
        cursor += PartMetadataTextParser.line_length(bytes, cursor)
        count_line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
        cursor += PartMetadataTextParser.line_length(bytes, cursor)
        count = PartMetadataTextParser.parse_count_line(count_line, " columns:", WidePart::MAX_METADATA_COLUMNS, "columns_substreams.txt")
        raise UnsupportedFormatError.new("flattened Nested substream column count does not match") unless count == physical_columns.size

        seen_columns = Set(String).new
        seen_streams = Set(String).new
        total_streams = 0
        count.times do |index|
          line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
          cursor += PartMetadataTextParser.line_length(bytes, cursor)
          stream_count, column = PartMetadataTextParser.parse_substream_header(line)
          expected_column = physical_columns[index][0]
          raise UnsupportedFormatError.new("flattened Nested physical column order does not match") unless column == expected_column
          raise UnsupportedFormatError.new("duplicate flattened Nested column block") if seen_columns.includes?(column)
          seen_columns << column

          expected_streams = expected_substreams(column, binding.key_name) ||
                             raise UnsupportedFormatError.new("unexpected flattened Nested physical column")
          streams = Array(String).new(stream_count)
          stream_count.times do
            stream_line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
            cursor += PartMetadataTextParser.line_length(bytes, cursor)
            raise UnsupportedFormatError.new("invalid physical stream name") unless stream_line.starts_with?("\t")
            stream = String.new(stream_line.to_slice[1, stream_line.bytesize - 1])
            PartMetadataTextParser.validate_opaque_name(stream)
            if seen_streams.includes?(stream) && stream != shared_size_stream
              raise UnsupportedFormatError.new("duplicate flattened Nested physical stream")
            end
            seen_streams << stream
            streams << stream
            total_streams += 1
            if total_streams > WidePart::MAX_METADATA_SUBSTREAMS
              raise UnsupportedFormatError.new("flattened Nested substream count exceeds limit")
            end
          end
          unless streams == expected_streams
            raise UnsupportedFormatError.new("flattened Nested physical substreams do not match exact sibling shape")
          end
        end
        raise UnsupportedFormatError.new("trailing columns_substreams.txt data") unless cursor == bytes.size
        unless seen_columns.size == physical_columns.size && seen_streams.includes?(shared_size_stream)
          raise UnsupportedFormatError.new("flattened Nested physical substream roster is incomplete")
        end

        if binding.selected_column == @group_name
          root_physical_streams
        else
          [String.new(binding.key_name.to_slice)] of String
        end
      end

      def shared_size_stream : String
        "#{@group_name}.size0"
      end

      private def sibling_column_name(field : WideTupleField) : String
        "#{@group_name}.#{field.name}"
      end

      private def sibling_substreams(field : WideTupleField) : Array(String)
        leaf_stream = storage_plan.leaf_stream_name(@group_name, field)
        streams = [shared_size_stream]
        streams << "#{leaf_stream}.null" if field.leaf_type.nullable?
        streams << "#{leaf_stream}.size" if field.leaf_type.base_type_name == "String"
        streams << leaf_stream
        streams
      end

      private def self.simple_identifier?(name : String) : Bool
        bytes = name.to_slice
        return false if bytes.empty?
        first = bytes[0]
        return false unless first == '_'.ord ||
                            (first >= 'A'.ord && first <= 'Z'.ord) ||
                            (first >= 'a'.ord && first <= 'z'.ord)
        bytes[1..].each do |byte|
          unless byte == '_'.ord ||
                 (byte >= 'A'.ord && byte <= 'Z'.ord) ||
                 (byte >= 'a'.ord && byte <= 'z'.ord) ||
                 (byte >= '0'.ord && byte <= '9'.ord)
            return false
          end
        end
        true
      end
    end
  end
end
