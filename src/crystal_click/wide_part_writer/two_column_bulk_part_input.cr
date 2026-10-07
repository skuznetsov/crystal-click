module CrystalClick
  module WidePartWriter
    # Common bounded preflight for a complete two-column Wide part. Type
    # admission and role discovery remain with each nominal value adapter.
    private class TwoColumnBulkPartInput
      getter target : String
      getter parent : String
      getter key_name : String
      getter value_name : String
      getter mark_count : Int32
      getter expected_files : Array(String)
      getter expected_rows : Array(UInt64)
      getter logical_names : Array(String)
      getter role_bindings : Hash(String, TwoColumnBulkPartRoleBinding)

      private def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @value_name : String,
        @mark_count : Int32,
        @expected_files : Array(String),
        @expected_rows : Array(UInt64),
        @logical_names : Array(String),
        @role_bindings : Hash(String, TwoColumnBulkPartRoleBinding),
      )
      end

      def self.prepare(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        parent_rows : Array(Int32),
        rows_per_mark : Int32,
        metadata_version : Int64,
        role_bindings : Hash(String, TwoColumnBulkPartRoleBinding),
      ) : TwoColumnBulkPartInput
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and value column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS.to_u64
          raise ArgumentError.new("a two-column part requires a bounded nonempty key stream")
        end
        if parent_rows.empty? || parent_rows.size > MAX_MARKS
          raise ArgumentError.new("parent mark count is outside the writer limit")
        end
        unless role_bindings.size > 0 && role_bindings.size <= WidePart::MAX_METADATA_SUBSTREAMS
          raise UnsupportedFormatError.new("physical role count is outside the metadata substream limit")
        end

        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == parent_rows.size.to_i64
          raise ArgumentError.new("parent granule count does not match the key mark grid")
        end
        expected_rows = validate_parent_rows!(keys.size, parent_rows, rows_per_mark)
        validate_keys!(keys)
        validate_key_physical_sizes!(keys.size, rows_per_mark, parent_rows.size)

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        if File.exists?(target) || File.symlink?(target)
          raise ArgumentError.new("destination must not already exist")
        end

        # The checksummed roster has two records per value lane and five
        # envelope/key records. Reject before allocating roster arrays.
        role_count = role_bindings.size
        if role_count > (PartChecksums::MAX_ENTRIES - 5) // 2
          raise UnsupportedFormatError.new("two-column part exceeds checksums entry limit")
        end

        expected_file_count = role_count * 2 + 10
        names = Array(String).new(expected_file_count)
        logical_names = Array(String).new(role_count)
        role_bindings.each do |role, binding|
          if role.empty?
            raise UnsupportedFormatError.new("physical role name must not be empty")
          end
          logical_name = binding.logical_name
          unless logical_name.bytesize > 0 && logical_name.bytesize <= WidePart::MAX_METADATA_LINE_BYTES
            raise UnsupportedFormatError.new("physical stream name exceeds metadata line limit")
          end
          expected_data = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".bin")
          expected_marks = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".mrk2")
          unless binding.data_filename == expected_data && binding.marks_filename == expected_marks
            raise UnsupportedFormatError.new("physical role filenames differ from the logical stream name")
          end
          validate_filename!(binding.data_filename)
          validate_filename!(binding.marks_filename)
          logical_names << logical_name
          names << binding.data_filename
          names << binding.marks_filename
        end

        logical_names.sort!
        index = 1
        while index < logical_names.size
          if logical_names[index - 1] == logical_names[index]
            raise UnsupportedFormatError.new("physical roles share a logical stream name")
          end
          index += 1
        end

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
            raise UnsupportedFormatError.new("two-column part filenames collide")
          end
          index += 1
        end

        new(
          target, parent, key_name, value_name, parent_rows.size.to_i32,
          names, expected_rows, logical_names, role_bindings
        )
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
        raise ArgumentError.new("parent row count does not match the key stream") unless seen_rows == row_count.to_i64
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

      private def self.validate_key_physical_sizes!(row_count : Int, rows_per_mark : Int32, mark_count : Int) : Nil
        mark_size = (mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        if mark_size > WidePart::MAX_MARK_FILE_BYTES || mark_size > Int32::MAX
          raise ArgumentError.new("key mark file exceeds reader limit")
        end
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        if index_size > MAX_PRIMARY_INDEX_BYTES || index_size > Int32::MAX
          raise ArgumentError.new("primary index exceeds reader limit")
        end
        total_data_size = 0_i64
        mark_count.times do |mark|
          start = mark.to_i64 * rows_per_mark
          rows = {rows_per_mark.to_i64, row_count.to_i64 - start}.min
          raw_size = rows * 8_i64
          raise ArgumentError.new("key granule exceeds frame reader limit") if raw_size <= 0 || raw_size > MAX_FRAME_RAW_BYTES
          payload_size = 1_i64 + (raw_size < 15_i64 ? 0_i64 : ((raw_size - 15_i64) // 255_i64) + 1_i64) + raw_size
          compressed_size = CompressedBlock::HEADER_SIZE + payload_size
          raise ArgumentError.new("key granule exceeds compressed frame limit") if compressed_size > MAX_FRAME_COMPRESSED
          if compressed_size > MAX_DATA_FILE_BYTES - total_data_size
            raise ArgumentError.new("key data file exceeds reader limit")
          end
          total_data_size += compressed_size
        end
        nil
      end

      private def self.validate_column_name!(name : String) : Nil
        unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("column name must be a bounded ASCII identifier")
        end
        nil
      end

      private def self.validate_filename!(name : String) : Nil
        if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
          raise UnsupportedFormatError.new("two-column physical filename exceeds checksums name limit")
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
