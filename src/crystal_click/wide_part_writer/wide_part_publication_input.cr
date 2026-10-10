module CrystalClick
  module WidePartWriter
    # Complete, preflighted key/grid/file envelope consumed by the one
    # publication owner. It contains no codec policy or arbitrary file bytes.
    private class WidePartPublicationInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter mark_count : Int32
      getter expected_files : Array(String)
      getter expected_rows : Array(UInt64)
      getter logical_names : Array(String)
      getter lane_bindings : Array(WidePartLaneBinding)

      def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @mark_count : Int32,
        @expected_files : Array(String),
        @expected_rows : Array(UInt64),
        @logical_names : Array(String),
        @lane_bindings : Array(WidePartLaneBinding),
      )
      end

      def self.prepare(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        columns : Array(WidePartPreparedColumn),
        rows_per_mark : Int32,
        metadata_version : Int64,
      ) : WidePartPublicationInput
        ensure_supported_platform!
        validate_column_name!(key_name)
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS
          raise ArgumentError.new("a Wide part requires a bounded nonempty key stream")
        end
        if columns.empty? || columns.size + 1 > WidePart::MAX_METADATA_COLUMNS
          raise UnsupportedFormatError.new("Wide part column count is outside the metadata limit")
        end

        first = columns.first
        if first.parent_rows.empty? || first.parent_rows.size > WidePartWriter::MAX_MARKS
          raise ArgumentError.new("parent mark count is outside the writer limit")
        end
        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == first.parent_rows.size.to_i64
          raise ArgumentError.new("parent granule count does not match the key mark grid")
        end
        expected_rows = validate_parent_rows!(keys.size, first.parent_rows, rows_per_mark)
        columns.each do |column|
          validate_column_name!(column.column_name)
          raise ArgumentError.new("key and value column names must differ") if column.column_name == key_name
          unless column.parent_rows == first.parent_rows
            raise ArgumentError.new("all value columns must use the same parent mark grid")
          end
        end
        validate_unique_columns!(columns)
        validate_keys!(keys)
        validate_key_physical_sizes!(keys.size, rows_per_mark, first.parent_rows)

        total_streams = 1
        columns.each do |column|
          if column.stream_names.empty?
            raise UnsupportedFormatError.new("Wide value column must plan at least one physical stream")
          end
          total_streams += column.stream_names.size
          if total_streams > WidePart::MAX_METADATA_SUBSTREAMS
            raise UnsupportedFormatError.new("Wide physical roster is outside the metadata substream limit")
          end
        end
        value_streams = total_streams - 1 # checksum envelope also includes key lanes and three metadata records
        if value_streams > (PartChecksums::MAX_ENTRIES - 5) // 2
          raise UnsupportedFormatError.new("Wide part exceeds checksums entry limit")
        end

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        if File.exists?(target) || File.symlink?(target)
          raise ArgumentError.new("destination must not already exist")
        end

        expected_file_count = total_streams * 2 + 8
        expected_files = Array(String).new(expected_file_count)
        logical_names = Array(String).new(total_streams - 1)
        lane_bindings = Array(WidePartLaneBinding).new(total_streams - 1)
        logical_seen = Set(String).new
        logical_seen.add(key_name)
        names = Array(String).new(expected_file_count)
        columns.each do |column|
          column.stream_names.each do |logical_name|
            unless logical_name.bytesize > 0 && logical_name.bytesize <= WidePart::MAX_METADATA_LINE_BYTES
              raise UnsupportedFormatError.new("physical stream name exceeds metadata line limit")
            end
            unless logical_seen.add?(logical_name)
              raise UnsupportedFormatError.new("physical stream names collide across the part")
            end
            data_filename = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".bin")
            marks_filename = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".mrk2")
            validate_filename!(data_filename)
            validate_filename!(marks_filename)
            names << data_filename
            names << marks_filename
            logical_names << logical_name
            lane_bindings << WidePartLaneBinding.new(
              column.column_name, logical_name, data_filename, marks_filename
            )
          end
        end
        logical_names.sort!

        key_base = StreamName.hash(key_name)
        names << PhysicalStreamName.append_literal(key_base, ".bin")
        names << PhysicalStreamName.append_literal(key_base, ".mrk2")
        names.concat([
          "primary.idx", "count.txt", "serialization.json", "columns.txt",
          "columns_substreams.txt", "default_compression_codec.txt",
          "metadata_version.txt", "checksums.txt",
        ])
        names.each { |name| validate_filename!(name) }
        names.sort!
        index = 1
        while index < names.size
          if names[index - 1] == names[index]
            raise UnsupportedFormatError.new("Wide part physical filenames collide")
          end
          index += 1
        end

        new(
          target, parent, key_name, first.parent_rows.size.to_i32,
          names, expected_rows, logical_names, lane_bindings
        )
      end

      private def self.validate_unique_columns!(columns : Array(WidePartPreparedColumn)) : Nil
        seen = Set(String).new
        columns.each do |column|
          unless seen.add?(column.column_name)
            raise ArgumentError.new("value column names must be unique")
          end
        end
        nil
      end

      private def self.validate_parent_rows!(
        row_count : Int,
        parent_rows : Array(Int32),
        rows_per_mark : Int32,
      ) : Array(UInt64)
        expected_rows = Array(UInt64).new(parent_rows.size)
        seen_rows = 0_i64
        parent_rows.each_with_index do |rows, index|
          if rows <= 0 || rows > rows_per_mark
            raise ArgumentError.new("parent granule size is outside the admitted range")
          end
          if index < parent_rows.size - 1 && rows != rows_per_mark
            raise ArgumentError.new("only the final parent granule may be short")
          end
          seen_rows += rows.to_i64
          expected_rows << rows.to_u64
        end
        unless seen_rows == row_count.to_i64
          raise ArgumentError.new("parent row count does not match the key stream")
        end
        expected_rows
      end

      private def self.validate_keys!(keys : Slice(UInt64)) : Nil
        previous = keys[0]
        index = 1
        while index < keys.size
          key = keys[index]
          raise ArgumentError.new("primary keys must be nondecreasing") if key < previous
          previous = key
          index += 1
        end
        nil
      end

      private def self.validate_key_physical_sizes!(
        row_count : Int,
        rows_per_mark : Int32,
        parent_rows : Array(Int32),
      ) : Nil
        mark_count = parent_rows.size
        mark_size = (mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        if mark_size > WidePart::MAX_MARK_FILE_BYTES || mark_size > Int32::MAX
          raise ArgumentError.new("key mark file exceeds reader limit")
        end
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        if index_size > WidePartWriter::MAX_PRIMARY_INDEX_BYTES || index_size > Int32::MAX
          raise ArgumentError.new("primary index exceeds reader limit")
        end
        total_data_size = 0_i64
        parent_rows.each do |rows|
          raw_size = rows.to_i64 * 8_i64
          if raw_size <= 0 || raw_size > WidePartWriter::MAX_FRAME_RAW_BYTES
            raise ArgumentError.new("key granule exceeds frame reader limit")
          end
          payload_size = 1_i64 + (raw_size < 15_i64 ? 0_i64 : ((raw_size - 15_i64) // 255_i64) + 1_i64) + raw_size
          compressed_size = CompressedBlock::HEADER_SIZE + payload_size
          if compressed_size > WidePartWriter::MAX_FRAME_COMPRESSED
            raise ArgumentError.new("key granule exceeds compressed frame limit")
          end
          if compressed_size > WidePart::MAX_DATA_FILE_BYTES - total_data_size
            raise ArgumentError.new("key data file exceeds reader limit")
          end
          total_data_size += compressed_size
        end
        nil
      end

      private def self.validate_column_name!(name : String) : Nil
        unless name.bytesize > 0 && name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("column name must be a bounded ASCII identifier")
        end
        nil
      end

      private def self.validate_filename!(name : String) : Nil
        if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
          raise UnsupportedFormatError.new("Wide physical filename exceeds checksums name limit")
        end
        nil
      end

      private def self.ensure_supported_platform! : Nil
        {% if flag?(:darwin) %}
          nil
        {% else %}
          raise UnsupportedFormatError.new("atomic exclusive Wide-part publication is unsupported on this platform")
        {% end %}
      end
    end
  end
end
