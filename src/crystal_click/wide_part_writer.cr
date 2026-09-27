module CrystalClick
  # Bounded writer for two-column UInt64-key Wide-part slices.
  #
  # Each data granule is one literal-only LZ4 block in a ClickHouse compressed
  # frame. The implementation intentionally accepts less than the theoretical
  # format maximum per granule so its output stays within this repository's
  # table-reader materialization bound as well as the frame decoder's bounds.
  module WidePartWriter
    MAX_ROWS_PER_MARK                      = 65_536
    MAX_LOW_CARDINALITY_KEYS               =    256
    MAX_LOW_CARDINALITY_DICTIONARY_BYTES   = 64_i64 * 1024 * 1024
    LOW_CARDINALITY_DICTIONARY_FRAME_BYTES = 32 * 1024 * 1024
    MAX_MARKS                              = WidePartTable::MAX_MARKS_PER_READER
    MAX_COLUMN_NAME_BYTES                  = 128
    MAX_FRAME_RAW_BYTES                    = WidePart::MAX_FRAME_DECOMPRESSED_BYTES
    MAX_FRAME_COMPRESSED                   = WidePart::MAX_FRAME_COMPRESSED_BYTES
    MAX_DATA_FILE_BYTES                    = WidePart::MAX_DATA_FILE_BYTES
    MAX_MARK_FILE_BYTES                    = WidePart::MAX_MARK_FILE_BYTES
    MAX_PRIMARY_INDEX_BYTES                = PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
    RENAME_EXCL                            = 0x0000_0004_u32

    private struct ChecksumRecord
      getter name : String
      getter physical_size : UInt64
      getter file_hash : {UInt64, UInt64}
      getter compressed : Bool
      getter uncompressed_size : UInt64?
      getter uncompressed_hash : {UInt64, UInt64}?

      def initialize(
        @name : String,
        @physical_size : UInt64,
        @file_hash : {UInt64, UInt64},
        @compressed : Bool,
        @uncompressed_size : UInt64? = nil,
        @uncompressed_hash : {UInt64, UInt64}? = nil,
      )
      end
    end

    {% if flag?(:darwin) %}
      @[Link("c")]
      lib LibWidePartWriterAtomicPublish
        fun renamex_np(old_path : UInt8*, new_path : UInt8*, flags : UInt32) : Int32
      end
    {% end %}

    # Write one immutable part at `destination`. The parent directory must
    # already exist. Publication is a same-filesystem atomic exclusive rename;
    # an existing path is never replaced.
    def self.write_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_uint64_stream(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        write_plain_metadata(stage, "columns.txt", columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 primary key and a
    # Nullable(UInt64) payload. BASIC Nullable serialization stores one
    # UInt8 null flag per row plus a nested UInt64 value for every row; NULL
    # rows use a zero placeholder in that nested stream.
    def self.write_uint64_nullable_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64?),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_nullable_uint64_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_nullable_uint64_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", nullable_columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", nullable_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_nullable_uint64_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 primary key and a regular
    # String payload. String lengths are stored in the `.size` substream and
    # each mark's raw payload bytes are concatenated without terminators.
    def self.write_uint64_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_string_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", string_columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write a sorted UInt64 primary key and a named Tuple(a UInt64, b String)
    # payload. Tuple leaves retain independent Wide-part streams and marks;
    # the public Crystal values remain positional {UInt64, String} tuples.
    def self.write_uint64_tuple_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_tuple_header_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      a_values = values.map { |value| value[0] }
      b_values = values.map { |value| value[1] }
      a_slice = a_values.to_unsafe.to_slice(a_values.size)
      b_slice = b_values.to_unsafe.to_slice(b_values.size)
      validate_inputs(destination, key_name, keys, value_name, a_slice, rows_per_mark)
      validate_string_inputs(destination, key_name, keys, value_name, b_slice, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_uint64_stream(stage, "#{value_name}%2Ea", a_slice, rows_per_mark))
        records.concat(write_string_streams(stage, "#{value_name}%2Eb", b_slice, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", tuple_string_serialization_metadata(key_name, value_name, keys, values))
        write_plain_metadata(stage, "columns.txt", tuple_string_columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", tuple_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_tuple_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one sorted UInt64 key and the exact JSON(a UInt64, b String)
    # Object V3 shape. Values are positional declared-path pairs; absent
    # paths must already be normalized to their ClickHouse scalar defaults.
    def self.write_uint64_json_typed_a_uint64_b_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_json_typed_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      a_values = values.map { |value| value[0] }
      b_values = values.map { |value| value[1] }
      a_slice = a_values.to_unsafe.to_slice(a_values.size)
      b_slice = b_values.to_unsafe.to_slice(b_values.size)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_uint64_stream(stage, "#{value_name}.a", a_slice, rows_per_mark))
        records.concat(write_string_streams(stage, "#{value_name}.b", b_slice, rows_per_mark))
        records.concat(write_json_object_structure_stream(stage, value_name, keys.size, rows_per_mark))
        records.concat(write_json_shared_size0_stream(stage, "#{value_name}.object_shared_data.0.size0", keys.size, rows_per_mark))
        records.concat(write_json_empty_stream(stage, "#{value_name}.object_shared_data.0%2Epaths", keys.size, rows_per_mark))
        records.concat(write_json_empty_stream(stage, "#{value_name}.object_shared_data.0%2Evalues", keys.size, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", json_typed_serialization_metadata(key_name, keys))
        write_plain_metadata(stage, "columns.txt", json_typed_columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", json_typed_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_json_typed_part(stage, key_name, keys, value_name, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 primary key and a shared-
    # dictionary LowCardinality(String) payload. Dictionary keys are assigned
    # in first-seen order and each data mark stores UInt8 dictionary IDs.
    def self.write_uint64_low_cardinality_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      rows_per_mark : Int32 = 8192,
    ) : String
      dictionary, value_ids = validate_low_cardinality_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_low_cardinality_dictionary_stream(stage, value_name, dictionary, keys.size, rows_per_mark))
        records.concat(write_low_cardinality_index_stream(stage, value_name, values, value_ids, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "LowCardinality(String)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", low_cardinality_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_low_cardinality_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write a sorted UInt64 primary key and a FixedString(N) payload. Values
    # are byte strings: short values are zero-padded to N and values longer
    # than N are rejected. FixedString has one raw payload stream and no
    # per-row size substream.
    def self.write_uint64_fixed_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      width : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_fixed_string_inputs(destination, key_name, keys, value_name, values, width, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_fixed_string_stream(stage, value_name, values, width, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "FixedString(#{width})"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", typed_substreams_metadata(key_name, value_name, "FixedString(#{width})"))
        write_checksums(stage, records)
        validate_staged_fixed_string_part(stage, key_name, value_name, keys, values, width, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write BASIC Nullable(FixedString(N)) with an explicit byte width. NULL
    # rows have a one-byte null flag and a zero-filled N-byte nested slot;
    # non-NULL rows are zero-padded to N bytes without a size substream.
    def self.write_uint64_nullable_fixed_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String?),
      width : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_nullable_fixed_string_inputs(destination, key_name, keys, value_name, values, width, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_nullable_fixed_string_streams(stage, value_name, values, width, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", nullable_fixed_string_serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Nullable(FixedString(#{width}))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", nullable_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_nullable_fixed_string_part(stage, key_name, value_name, keys, values, width, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an Array(UInt64)
    # payload. The size0 stream stores one outer-array length per input row;
    # the payload stream stores all nested elements flattened in row order.
    def self.write_uint64_array_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(UInt64)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_uint64_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_uint64_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(UInt64)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_uint64_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_uint64_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write a sorted UInt64 key and one-level Array(T) with an exact
    # fixed-width numeric leaf. The physical payload width and readback type
    # are selected from the closed numeric type family.
    def self.write_uint64_array_numeric_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(T)),
      rows_per_mark : Int32 = 8192,
    ) : String forall T
      type_name = WidePart.numeric_type_name(T)
      raise ArgumentError.new("Array numeric writer requires an exact supported numeric type") unless WidePart.supports_numeric_type?(type_name)
      validate_array_numeric_inputs(destination, key_name, keys, value_name, values, rows_per_mark, type_name)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_numeric_streams(stage, value_name, values, rows_per_mark, type_name))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(#{type_name})"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_uint64_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_numeric_part(stage, key_name, value_name, keys, values, rows_per_mark, type_name)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write a sorted UInt64 key and an exact Array(Array(UInt64)) payload.
    # The two offsets streams and the flattened leaf stream share outer-row
    # mark granules, while their byte positions advance by their own depths.
    def self.write_uint64_array_array_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Array(UInt64))),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_array_uint64_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_array_uint64_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Array(UInt64))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_array_uint64_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_array_uint64_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write an exact Array(Array(Nullable(UInt64))) payload. The two offsets
    # streams, null map, and flattened value stream retain independent marks
    # over the same outer-row granules.
    def self.write_uint64_array_array_nullable_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Array(UInt64?))),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_array_nullable_uint64_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_array_nullable_uint64_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Array(Nullable(UInt64)))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_array_nullable_uint64_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_array_nullable_uint64_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an
    # Array(Nullable(UInt64)) payload. Outer sizes, a flattened null map, and
    # flattened UInt64 values are separate streams; NULL slots retain a zero
    # placeholder in the value stream.
    def self.write_uint64_array_nullable_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(UInt64?)),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_array_nullable_numeric_pair(destination, key_name, keys, value_name, values, rows_per_mark)
    end

    # Write one immutable part with a sorted UInt64 key and one exact
    # Array(Nullable(T)) primitive numeric payload. NULL leaves consume a null
    # byte and a zero-valued fixed-width placeholder, matching ClickHouse's
    # physical serialization for all supported numeric leaf widths.
    def self.write_uint64_array_nullable_numeric_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(T?)),
      rows_per_mark : Int32 = 8192,
    ) : String forall T
      type_name = WidePart.numeric_type_name(T)
      unless WidePart.supports_numeric_type?(type_name) && WidePart.nullable_numeric_array_element_type("Array(Nullable(#{type_name}))") == type_name
        raise ArgumentError.new("Array nullable numeric writer requires an exact supported numeric type")
      end
      validate_array_nullable_numeric_inputs(destination, key_name, keys, value_name, values, rows_per_mark, type_name)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_nullable_numeric_streams(stage, value_name, values, rows_per_mark, type_name))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Nullable(#{type_name}))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_nullable_numeric_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_nullable_numeric_part(stage, key_name, value_name, keys, values, rows_per_mark, type_name)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an Array(String)
    # payload. Outer lengths, nested byte lengths, and raw string bytes are
    # separate streams; all nested values are flattened in row order.
    def self.write_uint64_array_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_string_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(String)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an
    # Array(Nullable(String)) payload. NULL elements have a null-map entry and
    # a zero String-size slot, but contribute no raw String bytes.
    def self.write_uint64_array_nullable_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String?)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_nullable_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_nullable_string_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Nullable(String))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_nullable_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_nullable_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write a sorted UInt64 key and Array(FixedString(N)) payload. The outer
    # size0 stream stores row lengths; flattened child values occupy exactly N
    # bytes each, with short strings zero-padded and long strings rejected.
    def self.write_uint64_array_fixed_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String)),
      width : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_fixed_string_inputs(destination, key_name, keys, value_name, values, width, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_fixed_string_streams(stage, value_name, values, width, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(FixedString(#{width}))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_fixed_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_fixed_string_part(stage, key_name, value_name, keys, values, width, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write Array(Nullable(FixedString(N))) with flattened null and fixed-width
    # child streams. NULL elements retain a zero-filled N-byte nested slot.
    def self.write_uint64_array_nullable_fixed_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String?)),
      width : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_nullable_fixed_string_inputs(destination, key_name, keys, value_name, values, width, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_nullable_fixed_string_streams(stage, value_name, values, width, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Nullable(FixedString(#{width})))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_nullable_fixed_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_nullable_fixed_string_part(stage, key_name, value_name, keys, values, width, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an exact
    # Array(Bool) payload. Bool remains a semantic type: each child is emitted
    # as one canonical 0/1 byte rather than through the numeric-array writer.
    def self.write_uint64_array_bool_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Bool)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_bool_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_bool_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Bool)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_bool_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_bool_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write exact Array(Nullable(Bool)) leaves with separate one-byte null
    # and value streams. NULL child slots remain present and are zero-filled.
    def self.write_uint64_array_nullable_bool_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Bool?)),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_array_nullable_bool_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_array_nullable_bool_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Array(Nullable(Bool))"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", array_nullable_bool_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_array_nullable_bool_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable part with a sorted UInt64 key and an exact top-level
    # Map(UInt64, String) payload. Map entries are ordered tuples, so duplicate
    # keys and their insertion order are preserved rather than collapsed.
    def self.write_uint64_map_uint64_string_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Tuple(UInt64, String))),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_map_uint64_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_map_uint64_string_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Map(UInt64, String)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", map_uint64_string_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_map_uint64_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write an immutable sorted-key part with exact Map(UInt64, UInt64) values.
    # The three map streams are fixed-width UInt64 sequences; ordered tuple
    # arrays preserve duplicate keys and insertion order.
    def self.write_uint64_map_uint64_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Tuple(UInt64, UInt64))),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_map_uint64_uint64_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_map_uint64_uint64_streams(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        records << write_checksummed_file(stage, "serialization.json", serialization_metadata)
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, "Map(UInt64, UInt64)"))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", map_uint64_uint64_substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_map_uint64_uint64_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    # Write one immutable two-column part with a sorted UInt64 primary key.
    # The payload's Crystal type selects an admitted numeric, String, or
    # BASIC Nullable type; numeric values are encoded by their exact bits.
    def self.write_uint64_typed_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(T),
      rows_per_mark : Int32 = 8192,
    ) : String forall T
      {% if T == String %}
        write_uint64_string_pair(destination, key_name, keys, value_name, values, rows_per_mark)
      {% elsif T == UInt64? %}
        write_uint64_nullable_uint64_pair(destination, key_name, keys, value_name, values, rows_per_mark)
      {% else %}
        type_name = typed_type_name(values)
        write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% end %}
    end

    # Write UUID values as the pinned ClickHouse 16-byte representation:
    # little-endian high UInt64 followed by little-endian low UInt64. UUID has
    # a named entry point so it is never inferred from a numeric or string slice.
    def self.write_uint64_uuid_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UUIDValue),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "UUID", rows_per_mark)
    end

    # Write BASIC Nullable(UUID). NULL rows retain a separate null flag and a
    # zero-filled 16-byte nested slot; the all-zero UUID remains a value.
    def self.write_uint64_nullable_uuid_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UUIDValue?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(UUID)", rows_per_mark)
    end

    # Write IPv4 values stored as network-order UInt32 values and serialized
    # little-endian, matching the pinned ClickHouse RowBinary representation.
    # The distinct value type prevents generic UInt32 inference from selecting
    # IPv4 metadata.
    def self.write_uint64_ipv4_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(IPv4Value),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "IPv4", rows_per_mark)
    end

    # Write BASIC Nullable(IPv4). NULL rows retain a separate null flag and a
    # zero-filled four-byte nested slot; 0.0.0.0 remains a non-NULL value.
    def self.write_uint64_nullable_ipv4_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(IPv4Value?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(IPv4)", rows_per_mark)
    end

    # Write IPv6 values as their exact 16-byte network-order representation:
    # big-endian high UInt64 followed by big-endian low UInt64. The named
    # entry point keeps IPv6 distinct from UUID, UInt128, and FixedString(16).
    def self.write_uint64_ipv6_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(IPv6Value),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "IPv6", rows_per_mark)
    end

    # Write BASIC Nullable(IPv6). NULL rows have a separate null flag and a
    # zero-filled 16-byte nested slot; :: remains a non-NULL value.
    def self.write_uint64_nullable_ipv6_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(IPv6Value?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(IPv6)", rows_per_mark)
    end

    # Write Bool as its exact semantic type rather than a UInt8 alias.
    def self.write_uint64_bool_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Bool),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Bool", rows_per_mark)
    end

    # BASIC Nullable(Bool) keeps NULL separate from false.
    def self.write_uint64_nullable_bool_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Bool?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Bool)", rows_per_mark)
    end

    # Decimal32/64 retain signed scaled integers. ClickHouse normalizes their
    # part declarations to Decimal(9, S) / Decimal(18, S).
    def self.write_uint64_decimal32_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int32), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal32 scale must be between 0 and 9") unless (0..9).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Decimal(9, #{scale})", rows_per_mark)
    end

    def self.write_uint64_decimal64_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int64), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal64 scale must be between 0 and 18") unless (0..18).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Decimal(18, #{scale})", rows_per_mark)
    end

    def self.write_uint64_nullable_decimal32_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int32?), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal32 scale must be between 0 and 9") unless (0..9).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Decimal(9, #{scale}))", rows_per_mark)
    end

    def self.write_uint64_nullable_decimal64_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int64?), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal64 scale must be between 0 and 18") unless (0..18).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Decimal(18, #{scale}))", rows_per_mark)
    end

    # Decimal128 stores the signed Int128 coefficient unchanged. Its part
    # declaration is normalized to Decimal(38, S) by ClickHouse.
    def self.write_uint64_decimal128_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int128), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal128 scale must be between 0 and 38") unless (0..38).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Decimal(38, #{scale})", rows_per_mark)
    end

    def self.write_uint64_nullable_decimal128_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int128?), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal128 scale must be between 0 and 38") unless (0..38).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Decimal(38, #{scale}))", rows_per_mark)
    end

    # Decimal256 stores its signed two's-complement coefficient unchanged.
    def self.write_uint64_decimal256_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Decimal256Value), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal256 scale must be between 0 and 76") unless (0..76).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Decimal(76, #{scale})", rows_per_mark)
    end

    def self.write_uint64_nullable_decimal256_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Decimal256Value?), scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("Decimal256 scale must be between 0 and 76") unless (0..76).includes?(scale)
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Decimal(76, #{scale}))", rows_per_mark)
    end

    # Enum payloads retain a validated exact label/code declaration. Only
    # declared signed codes may be written; generic Int8/Int16 writes remain
    # ordinary numeric columns.
    def self.write_uint64_enum8_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int8), enum_type : String,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise UnsupportedFormatError.new("exact Enum8 declaration required") unless enum_type.starts_with?("Enum8(")
      codes = WidePart.enum8_codes(enum_type) || raise(UnsupportedFormatError.new("unsupported Enum8 declaration"))
      values.each { |value| raise ArgumentError.new("Enum8 code is not declared") unless codes.includes?(value) }
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, enum_type, rows_per_mark)
    end

    def self.write_uint64_enum16_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int16), enum_type : String,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise UnsupportedFormatError.new("exact Enum16 declaration required") unless enum_type.starts_with?("Enum16(")
      codes = WidePart.enum16_codes(enum_type) || raise(UnsupportedFormatError.new("unsupported Enum16 declaration"))
      values.each { |value| raise ArgumentError.new("Enum16 code is not declared") unless codes.includes?(value) }
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, enum_type, rows_per_mark)
    end

    def self.write_uint64_nullable_enum8_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int8?), enum_type : String,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise UnsupportedFormatError.new("exact Enum8 declaration required") unless enum_type.starts_with?("Enum8(")
      codes = WidePart.enum8_codes(enum_type) || raise(UnsupportedFormatError.new("unsupported Enum8 declaration"))
      values.each { |value| raise ArgumentError.new("Enum8 code is not declared") if !value.nil? && !codes.includes?(value.not_nil!) }
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(#{enum_type})", rows_per_mark)
    end

    def self.write_uint64_nullable_enum16_pair(
      destination : String, key_name : String, keys : Slice(UInt64),
      value_name : String, values : Slice(Int16?), enum_type : String,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise UnsupportedFormatError.new("exact Enum16 declaration required") unless enum_type.starts_with?("Enum16(")
      codes = WidePart.enum16_codes(enum_type) || raise(UnsupportedFormatError.new("unsupported Enum16 declaration"))
      values.each { |value| raise ArgumentError.new("Enum16 code is not declared") if !value.nil? && !codes.includes?(value.not_nil!) }
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(#{enum_type})", rows_per_mark)
    end

    # Write a Date payload as raw UInt16 day codes since 1970-01-01. Codes are
    # preserved as supplied; no civil-date conversion or range clamping occurs.
    def self.write_uint64_date_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt16),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Date", rows_per_mark)
    end

    # Write a Date32 payload as raw signed Int32 day codes since 1970-01-01.
    # The full Int32 domain is retained without civil-date conversion.
    def self.write_uint64_date32_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Int32),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Date32", rows_per_mark)
    end

    # Write a DateTime payload as raw UInt32 epoch seconds. Values are
    # preserved exactly; no timezone or civil-time conversion is performed.
    def self.write_uint64_datetime_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      seconds : Slice(UInt32),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, seconds, "DateTime", rows_per_mark)
    end

    # Write a DateTime64 payload as raw signed ticks at the explicit decimal
    # precision. Values are preserved exactly without rounding or clamping.
    def self.write_uint64_datetime64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      ticks : Slice(Int64),
      scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("DateTime64 precision must be between 0 and 9") if scale < 0 || scale > 9
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, ticks, "DateTime64(#{scale})", rows_per_mark)
    end

    # Write Nullable(Date) as raw UInt16 day codes. NULL has its own null-map
    # entry and a zero placeholder in the nested value stream; non-NULL codes,
    # including zero, are preserved exactly.
    def self.write_uint64_nullable_date_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt16?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Date)", rows_per_mark)
    end

    # Write Nullable(Date32) as raw signed Int32 day codes.
    def self.write_uint64_nullable_date32_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Int32?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(Date32)", rows_per_mark)
    end

    # Write Nullable(DateTime) as raw UInt32 epoch seconds.
    def self.write_uint64_nullable_datetime_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt32?),
      rows_per_mark : Int32 = 8192,
    ) : String
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(DateTime)", rows_per_mark)
    end

    # Write Nullable(DateTime64(p)) as raw signed Int64 ticks. The explicit
    # precision is part of the stored semantic type and uses W13's canonical
    # one-digit 0..9 spelling.
    def self.write_uint64_nullable_datetime64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Int64?),
      scale : Int32,
      rows_per_mark : Int32 = 8192,
    ) : String
      raise ArgumentError.new("DateTime64 precision must be between 0 and 9") if scale < 0 || scale > 9
      write_uint64_typed_pair_with_type(destination, key_name, keys, value_name, values, "Nullable(DateTime64(#{scale}))", rows_per_mark)
    end

    private def self.write_uint64_typed_pair_with_type(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : String forall T
      validate_typed_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_typed_payload_streams(stage, value_name, values, rows_per_mark, type_name))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        if type_name == "UUID" || type_name == "IPv4" || type_name == "IPv6" || type_name.starts_with?("Nullable(") || semantic_fixed_width_type?(type_name)
          records << write_checksummed_file(stage, "serialization.json", typed_serialization_metadata(type_name))
        end
        write_plain_metadata(stage, "columns.txt", typed_columns_metadata(key_name, value_name, type_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", typed_substreams_metadata(key_name, value_name, type_name))
        write_checksums(stage, records)
        validate_staged_typed_part(stage, key_name, value_name, keys, values, type_name, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    private def self.validate_nullable_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64?),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, "#{value_name}.null", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      key_data_bytes = 0_i64
      null_data_bytes = 0_i64
      nested_data_bytes = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        key_raw_size = rows.to_i64 * 8_i64
        null_raw_size = rows.to_i64
        nested_raw_size = key_raw_size
        {
          {key_raw_size, "UInt64 key"},
          {null_raw_size, "Nullable null-map"},
          {nested_raw_size, "Nullable nested UInt64"},
        }.each do |raw_size, label|
          if raw_size > MAX_FRAME_RAW_BYTES.to_i64
            raise ArgumentError.new("#{label} granule exceeds decompressed frame limit")
          end
          frame_size = literal_frame_size(raw_size)
          if frame_size > MAX_FRAME_COMPRESSED.to_i64
            raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit")
          end
        end

        key_frame_bytes = literal_frame_size(key_raw_size)
        null_frame_bytes = literal_frame_size(null_raw_size)
        nested_frame_bytes = literal_frame_size(nested_raw_size)
        if key_frame_bytes > MAX_DATA_FILE_BYTES - key_data_bytes
          raise ArgumentError.new("UInt64 data stream exceeds reader limit")
        end
        if null_frame_bytes > MAX_DATA_FILE_BYTES - null_data_bytes
          raise ArgumentError.new("Nullable null-map stream exceeds reader limit")
        end
        if nested_frame_bytes > MAX_DATA_FILE_BYTES - nested_data_bytes
          raise ArgumentError.new("Nullable nested stream exceeds reader limit")
        end
        key_data_bytes += key_frame_bytes
        null_data_bytes += null_frame_bytes
        nested_data_bytes += nested_frame_bytes
        start_row += rows
      end
      nil
    end

    private def self.validate_array_common_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      rows_per_mark : Int32,
      value_streams : Array(String),
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty?
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = ([key_name] + value_streams).map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end
      nil
    end

    private def self.checked_array_frame_size(raw_size : Int64, label : String) : Int64
      raise ArgumentError.new("#{label} granule exceeds decompressed frame limit") if raw_size <= 0 || raw_size > MAX_FRAME_RAW_BYTES.to_i64
      frame_size = literal_frame_size(raw_size)
      raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit") if frame_size > MAX_FRAME_COMPRESSED.to_i64
      frame_size
    end

    private def self.add_array_frame_size(current : Int64, frame_size : Int64, label : String) : Int64
      raise ArgumentError.new("#{label} stream exceeds reader limit") if frame_size > MAX_DATA_FILE_BYTES - current
      current + frame_size
    end

    private def self.checked_array_element_bytes(elements : UInt64, label : String) : Int64
      raise ArgumentError.new("#{label} byte count overflows") if elements > Int64::MAX.to_u64 // 8_u64
      (elements * 8_u64).to_i64
    end

    private def self.checked_array_element_checksum_size(elements : UInt64, label : String) : UInt64
      checked_array_element_bytes(elements, label).to_u64
    end

    private def self.validate_array_array_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Array(UInt64))),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.size1", value_name]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      size1_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_inner_arrays = 0_u64
      total_leaf_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_inner_arrays = 0_u64
        mark_leaf_elements = 0_u64
        rows.times do |offset|
          inner_arrays = values[start_row + offset]
          inner_count = inner_arrays.size.to_u64
          if inner_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_inner_arrays
            raise ArgumentError.new("Array(Array(UInt64)) inner-array count exceeds per-mark limit")
          end
          mark_inner_arrays += inner_count
          inner_arrays.each do |inner|
            leaf_count = inner.size.to_u64
            if leaf_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_leaf_elements
              raise ArgumentError.new("Array(Array(UInt64)) leaf element count exceeds per-mark limit")
            end
            mark_leaf_elements += leaf_count
          end
        end

        size1_raw_size = checked_array_element_bytes(mark_inner_arrays, "Array(Array(UInt64)) size1")
        if size1_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Array(UInt64)) size1 bytes exceed per-mark limit")
        end
        unless size1_raw_size == 0
          size1_data_bytes = add_array_frame_size(
            size1_data_bytes,
            checked_array_frame_size(size1_raw_size, "Array(Array(UInt64)) size1"),
            "Array(Array(UInt64)) size1"
          )
        end

        value_raw_size = checked_array_element_bytes(mark_leaf_elements, "Array(Array(UInt64)) nested")
        if value_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Array(UInt64)) nested bytes exceed per-mark limit")
        end
        unless value_raw_size == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(value_raw_size, "Array(Array(UInt64)) nested"),
            "Array(Array(UInt64)) nested"
          )
        end
        if mark_inner_arrays > UInt64::MAX - total_inner_arrays
          raise ArgumentError.new("Array(Array(UInt64)) inner-array count overflows")
        end
        if mark_leaf_elements > UInt64::MAX - total_leaf_elements
          raise ArgumentError.new("Array(Array(UInt64)) leaf element count overflows")
        end
        total_inner_arrays += mark_inner_arrays
        total_leaf_elements += mark_leaf_elements
        start_row += rows
      end
      nil
    end

    private def self.validate_array_array_nullable_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Array(UInt64?))),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.size1", "#{value_name}.null", value_name]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      size1_data_bytes = 0_i64
      null_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_inner_arrays = 0_u64
      total_leaf_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_inner_arrays = 0_u64
        mark_leaf_elements = 0_u64
        rows.times do |offset|
          row = values[start_row + offset]
          inner_count = row.size.to_u64
          if inner_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_inner_arrays
            raise ArgumentError.new("Array(Array(Nullable(UInt64))) inner-array count exceeds per-mark limit")
          end
          mark_inner_arrays += inner_count
          row.each do |inner|
            leaf_count = inner.size.to_u64
            if leaf_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_leaf_elements
              raise ArgumentError.new("Array(Array(Nullable(UInt64))) leaf element count exceeds per-mark limit")
            end
            mark_leaf_elements += leaf_count
          end
        end

        size1_raw_size = checked_array_element_bytes(mark_inner_arrays, "Array(Array(Nullable(UInt64))) size1")
        if size1_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Array(Nullable(UInt64))) size1 bytes exceed per-mark limit")
        end
        unless size1_raw_size == 0
          size1_data_bytes = add_array_frame_size(
            size1_data_bytes,
            checked_array_frame_size(size1_raw_size, "Array(Array(Nullable(UInt64))) size1"),
            "Array(Array(Nullable(UInt64))) size1"
          )
        end

        null_raw_size = mark_leaf_elements.to_i64
        if null_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Array(Nullable(UInt64))) null map exceeds decompressed frame limit")
        end
        unless null_raw_size == 0
          null_data_bytes = add_array_frame_size(
            null_data_bytes,
            checked_array_frame_size(null_raw_size, "Array(Array(Nullable(UInt64))) null map"),
            "Array(Array(Nullable(UInt64))) null map"
          )
        end

        value_raw_size = checked_array_element_bytes(mark_leaf_elements, "Array(Array(Nullable(UInt64))) nested")
        if value_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Array(Nullable(UInt64))) nested bytes exceed per-mark limit")
        end
        unless value_raw_size == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(value_raw_size, "Array(Array(Nullable(UInt64))) nested"),
            "Array(Array(Nullable(UInt64))) nested"
          )
        end

        if mark_inner_arrays > UInt64::MAX - total_inner_arrays
          raise ArgumentError.new("Array(Array(Nullable(UInt64))) inner-array count overflows")
        end
        if mark_leaf_elements > UInt64::MAX - total_leaf_elements
          raise ArgumentError.new("Array(Array(Nullable(UInt64))) leaf element count overflows")
        end
        total_inner_arrays += mark_inner_arrays
        total_leaf_elements += mark_leaf_elements
        start_row += rows
      end
      nil
    end

    private def self.validate_array_numeric_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(T)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Nil forall T
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      raise ArgumentError.new("Array numeric writer requires an exact supported numeric type") unless WidePart.numeric_array_element_type("Array(#{type_name})") == type_name
      validate_array_common_inputs(destination, key_name, keys, value_name, rows_per_mark, ["#{value_name}.size0", value_name])

      width = numeric_width(type_name)
      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
        end

        nested_raw_size = checked_array_numeric_bytes(mark_elements, width, "Array nested")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array nested bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array nested granule exceeds decompressed frame limit")
        end
        if nested_raw_size.to_u64 > UInt64::MAX - total_nested_bytes
          raise ArgumentError.new("Array nested byte count overflows")
        end
        total_nested_bytes += nested_raw_size.to_u64
        unless nested_raw_size == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(nested_raw_size, "Array nested"),
            "Array nested"
          )
        end
        start_row += rows
      end
      nil
    end

    private def self.write_array_numeric_streams(
      stage : String,
      column : String,
      values : Slice(Array(T)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Array(ChecksumRecord) forall T
      width = numeric_width(type_name)
      size0_base = StreamName.hash("#{column}.size0")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      value_data_size = 0_u64
      total_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            size0_raw = Bytes.new(rows * 8)
            mark_elements = 0_u64
            rows.times do |row|
              row_values = values[start_row + row]
              write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
              if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                raise ArgumentError.new("Array nested element count exceeds per-mark limit")
              end
              mark_elements += row_values.size.to_u64
            end

            nested_raw_size = checked_array_numeric_bytes(mark_elements, width, "Array nested")
            nested_raw = Bytes.new(nested_raw_size)
            nested_offset = 0
            rows.times do |row|
              values[start_row + row].each do |value|
                write_typed_numeric_le(nested_raw, nested_offset, value)
                nested_offset += width
              end
            end

            write_uint64_le(size0_mark_bytes, size0_data_size)
            write_uint64_le(size0_mark_bytes, 0_u64)
            write_uint64_le(size0_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            size0_frame = encode_lz4_frame(size0_raw)
            if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
              raise ArgumentError.new("Array size0 stream exceeds reader limit")
            end
            size0_data_file.write(size0_frame)
            size0_data_hash.update(size0_frame)
            size0_raw_hash.update(size0_raw)
            size0_data_size += size0_frame.size.to_u64

            unless nested_raw.empty?
              value_frame = encode_lz4_frame(nested_raw)
              if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                raise ArgumentError.new("Array nested stream exceeds reader limit")
              end
              value_data_file.write(value_frame)
              value_data_hash.update(value_frame)
              value_data_size += value_frame.size.to_u64
            end
            value_raw_hash.update(nested_raw)
            if mark_elements > UInt64::MAX - total_elements
              raise ArgumentError.new("Array nested element count overflows")
            end
            total_elements += mark_elements
            start_row += rows
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size0_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_numeric_checksum_size(total_elements, width, "Array nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.checked_array_numeric_bytes(elements : UInt64, width : Int32, label : String) : Int64
      byte_width = width.to_u64
      raise ArgumentError.new("#{label} byte count overflows") if byte_width == 0 || elements > Int64::MAX.to_u64 // byte_width
      (elements * byte_width).to_i64
    end

    private def self.checked_array_numeric_checksum_size(elements : UInt64, width : Int32, label : String) : UInt64
      checked_array_numeric_bytes(elements, width, label).to_u64
    end

    private def self.validate_array_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(UInt64)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(destination, key_name, keys, value_name, rows_per_mark, ["#{value_name}.size0", value_name])

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array nested element count exceeds per-mark limit")
          end
          if row_elements > UInt64::MAX - mark_elements
            raise ArgumentError.new("Array nested element count overflows")
          end
          mark_elements += row_elements
        end
        if mark_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS
          raise ArgumentError.new("Array nested element count exceeds per-mark limit")
        end

        nested_raw_size = checked_array_element_bytes(mark_elements, "Array nested")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array nested bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array nested granule exceeds decompressed frame limit")
        end
        mark_nested_bytes = nested_raw_size.to_u64
        if mark_nested_bytes > UInt64::MAX - total_nested_bytes
          raise ArgumentError.new("Array nested byte count overflows")
        end
        total_nested_bytes += mark_nested_bytes
        unless nested_raw_size == 0
          nested_frame_size = checked_array_frame_size(nested_raw_size, "Array nested")
          value_data_bytes = add_array_frame_size(value_data_bytes, nested_frame_size, "Array nested")
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_array_nullable_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(UInt64?)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.null", value_name]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      null_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_null_bytes = 0_u64
      total_value_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(Nullable(UInt64)) nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
        end

        null_raw_size = mark_elements.to_i64
        value_raw_size = checked_array_element_bytes(mark_elements, "Array(Nullable(UInt64)) nested")
        if value_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Nullable(UInt64)) nested bytes exceed per-mark limit")
        end
        if null_raw_size > 0
          null_frame_size = checked_array_frame_size(null_raw_size, "Array(Nullable(UInt64)) null map")
          null_data_bytes = add_array_frame_size(null_data_bytes, null_frame_size, "Array(Nullable(UInt64)) null map")
          value_frame_size = checked_array_frame_size(value_raw_size, "Array(Nullable(UInt64)) nested")
          value_data_bytes = add_array_frame_size(value_data_bytes, value_frame_size, "Array(Nullable(UInt64)) nested")
        end
        if mark_elements > UInt64::MAX - total_null_bytes
          raise ArgumentError.new("Array(Nullable(UInt64)) null-map byte count overflows")
        end
        if mark_elements > UInt64::MAX // 8_u64 || mark_elements * 8_u64 > UInt64::MAX - total_value_bytes
          raise ArgumentError.new("Array(Nullable(UInt64)) nested byte count overflows")
        end
        total_null_bytes += mark_elements
        total_value_bytes += mark_elements * 8_u64
        start_row += rows
      end
      nil
    end

    private def self.validate_array_nullable_numeric_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(T?)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Nil forall T
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      unless WidePart.supports_numeric_type?(type_name) && WidePart.nullable_numeric_array_element_type("Array(Nullable(#{type_name}))") == type_name
        raise ArgumentError.new("Array nullable numeric writer requires an exact supported numeric type")
      end
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.null", value_name]
      )

      width = WidePart.numeric_payload_width(type_name)
      label = "Array(Nullable(#{type_name}))"
      element_limit_label = type_name == "UInt64" ? "Array(Nullable(UInt64))" : label
      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      null_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("#{element_limit_label} nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
        end

        null_raw_size = checked_array_numeric_bytes(mark_elements, 1, "#{label} null map")
        value_raw_size = checked_array_numeric_bytes(mark_elements, width, "#{label} nested")
        combined_raw_size = checked_array_numeric_bytes(mark_elements, width + 1, "#{label} child streams")
        if combined_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("#{label} child stream bytes exceed per-mark limit")
        end
        unless null_raw_size == 0
          null_data_bytes = add_array_frame_size(
            null_data_bytes,
            checked_array_frame_size(null_raw_size, "#{label} null map"),
            "#{label} null map"
          )
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(value_raw_size, "#{label} nested"),
            "#{label} nested"
          )
        end
        if mark_elements > UInt64::MAX - total_elements
          raise ArgumentError.new("#{label} nested element count overflows")
        end
        total_elements += mark_elements
        start_row += rows
      end
      nil
    end

    private def self.validate_array_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(destination, key_name, keys, value_name, rows_per_mark, ["#{value_name}.size0", "#{value_name}.size", value_name])

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      nested_size_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      total_nested_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        mark_raw_bytes = 0_u64
        rows.times do |offset|
          row = values[start_row + offset]
          row_elements = row.size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array nested element count exceeds per-mark limit")
          end
          if row_elements > UInt64::MAX - mark_elements
            raise ArgumentError.new("Array nested element count overflows")
          end
          mark_elements += row_elements
          row.each do |value|
            value_bytes = value.bytesize.to_u64
            if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_bytes
              raise ArgumentError.new("Array nested bytes exceed per-mark limit")
            end
            if value_bytes > UInt64::MAX - mark_raw_bytes
              raise ArgumentError.new("Array nested byte count overflows")
            end
            mark_raw_bytes += value_bytes
          end
        end

        nested_size_raw_size = checked_array_element_bytes(mark_elements, "Array nested size")
        if nested_size_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array nested size granule exceeds decompressed frame limit")
        end
        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array nested element count overflows")
        end
        total_nested_elements += mark_elements
        nested_size_bytes = nested_size_raw_size.to_u64
        if nested_size_bytes > UInt64::MAX - total_nested_bytes
          raise ArgumentError.new("Array nested byte count overflows")
        end
        total_nested_bytes += nested_size_bytes

        unless nested_size_raw_size == 0
          nested_size_frame_size = checked_array_frame_size(nested_size_raw_size, "Array nested size")
          nested_size_data_bytes = add_array_frame_size(nested_size_data_bytes, nested_size_frame_size, "Array nested size")
        end
        if mark_raw_bytes > MAX_FRAME_RAW_BYTES.to_u64
          raise ArgumentError.new("Array nested granule exceeds decompressed frame limit")
        end
        if mark_raw_bytes > UInt64::MAX - total_nested_bytes
          raise ArgumentError.new("Array nested byte count overflows")
        end
        total_nested_bytes += mark_raw_bytes
        unless mark_raw_bytes == 0
          nested_frame_size = checked_array_frame_size(mark_raw_bytes.to_i64, "Array nested")
          value_data_bytes = add_array_frame_size(value_data_bytes, nested_frame_size, "Array nested")
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_array_nullable_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String?)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.null", "#{value_name}.size", value_name]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      null_data_bytes = 0_i64
      nested_size_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      total_raw_string_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        mark_raw_string_bytes = 0_u64
        rows.times do |offset|
          row = values[start_row + offset]
          row_elements = row.size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(Nullable(String)) nested element count exceeds per-mark limit")
          end
          if row_elements > UInt64::MAX - mark_elements
            raise ArgumentError.new("Array(Nullable(String)) nested element count overflows")
          end
          mark_elements += row_elements
          row.each do |value|
            next if value.nil?
            value_bytes = value.not_nil!.bytesize.to_u64
            if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_string_bytes
              raise ArgumentError.new("Array(Nullable(String)) nested bytes exceed per-mark limit")
            end
            if value_bytes > UInt64::MAX - mark_raw_string_bytes
              raise ArgumentError.new("Array(Nullable(String)) nested byte count overflows")
            end
            mark_raw_string_bytes += value_bytes
          end
        end

        null_raw_size = mark_elements.to_i64
        nested_size_raw_size = checked_array_element_bytes(mark_elements, "Array(Nullable(String)) nested size")
        if null_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(String)) null map granule exceeds decompressed frame limit")
        end
        if nested_size_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(String)) nested size granule exceeds decompressed frame limit")
        end
        if mark_raw_string_bytes > MAX_FRAME_RAW_BYTES.to_u64
          raise ArgumentError.new("Array(Nullable(String)) nested granule exceeds decompressed frame limit")
        end

        unless null_raw_size == 0
          null_data_bytes = add_array_frame_size(
            null_data_bytes,
            checked_array_frame_size(null_raw_size, "Array(Nullable(String)) null map"),
            "Array(Nullable(String)) null map"
          )
        end
        unless nested_size_raw_size == 0
          nested_size_data_bytes = add_array_frame_size(
            nested_size_data_bytes,
            checked_array_frame_size(nested_size_raw_size, "Array(Nullable(String)) nested size"),
            "Array(Nullable(String)) nested size"
          )
        end
        unless mark_raw_string_bytes == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(mark_raw_string_bytes.to_i64, "Array(Nullable(String)) nested"),
            "Array(Nullable(String)) nested"
          )
        end

        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array(Nullable(String)) nested element count overflows")
        end
        total_nested_elements += mark_elements
        if mark_raw_string_bytes > UInt64::MAX - total_raw_string_bytes
          raise ArgumentError.new("Array(Nullable(String)) nested byte count overflows")
        end
        total_raw_string_bytes += mark_raw_string_bytes
        start_row += rows
      end
      checked_array_element_checksum_size(total_nested_elements, "Array(Nullable(String)) nested size")
      nil
    end

    private def self.validate_array_fixed_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      raise ArgumentError.new("FixedString width must be positive") if width <= 0
      raise ArgumentError.new("FixedString width exceeds reader limit") if width > WidePart::MAX_FIXED_STRING_WIDTH
      validate_array_common_inputs(destination, key_name, keys, value_name, rows_per_mark, ["#{value_name}.size0", value_name])
      raise ArgumentError.new("Array(FixedString) rows_per_mark exceeds reader materialization limit") if rows_per_mark.to_u64 > WidePart::MAX_FIXED_STRING_RANGE_ROWS

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(FixedString) nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
          values[start_row + offset].each do |value|
            if value.bytesize > width
              raise ArgumentError.new("FixedString value exceeds declared byte width")
            end
          end
        end

        nested_raw_size = checked_array_numeric_bytes(mark_elements, width, "Array(FixedString) nested")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(FixedString) nested bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(FixedString) nested granule exceeds decompressed frame limit")
        end
        unless nested_raw_size == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(nested_raw_size, "Array(FixedString) nested"),
            "Array(FixedString) nested"
          )
        end

        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array(FixedString) nested element count overflows")
        end
        total_nested_elements += mark_elements
        start_row += rows
      end
      checked_array_numeric_checksum_size(total_nested_elements, width, "Array(FixedString) nested")
      nil
    end

    private def self.validate_array_nullable_fixed_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(String?)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      raise ArgumentError.new("FixedString width must be positive") if width <= 0
      raise ArgumentError.new("FixedString width exceeds reader limit") if width > WidePart::MAX_FIXED_STRING_WIDTH
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.null", value_name]
      )
      raise ArgumentError.new("Array(Nullable(FixedString)) rows_per_mark exceeds reader materialization limit") if rows_per_mark.to_u64 > WidePart::MAX_FIXED_STRING_RANGE_ROWS

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      null_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_values = values[start_row + offset]
          row_elements = row_values.size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(Nullable(FixedString)) nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
          row_values.each do |value|
            if value && value.bytesize > width
              raise ArgumentError.new("FixedString value exceeds declared byte width")
            end
          end
        end

        null_raw_size = mark_elements.to_i64
        nested_raw_size = checked_array_numeric_bytes(mark_elements, width, "Array(Nullable(FixedString)) nested")
        combined_raw_size = null_raw_size + nested_raw_size
        if combined_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Nullable(FixedString)) child stream bytes exceed per-mark limit")
        end
        if null_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(FixedString)) null-map granule exceeds decompressed frame limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(FixedString)) nested granule exceeds decompressed frame limit")
        end
        unless null_raw_size == 0
          null_data_bytes = add_array_frame_size(
            null_data_bytes,
            checked_array_frame_size(null_raw_size, "Array(Nullable(FixedString)) null map"),
            "Array(Nullable(FixedString)) null map"
          )
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(nested_raw_size, "Array(Nullable(FixedString)) nested"),
            "Array(Nullable(FixedString)) nested"
          )
        end

        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array(Nullable(FixedString)) nested element count overflows")
        end
        total_nested_elements += mark_elements
        start_row += rows
      end
      checked_array_numeric_checksum_size(total_nested_elements, width, "Array(Nullable(FixedString)) nested")
      nil
    end

    private def self.validate_array_bool_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Bool)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(destination, key_name, keys, value_name, rows_per_mark, ["#{value_name}.size0", value_name])
      raise ArgumentError.new("Array(Bool) rows_per_mark exceeds reader materialization limit") if rows_per_mark.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(Bool) nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
        end

        nested_raw_size = checked_array_numeric_bytes(mark_elements, 1, "Array(Bool) nested")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Bool) nested bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Bool) nested granule exceeds decompressed frame limit")
        end
        unless nested_raw_size == 0
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(nested_raw_size, "Array(Bool) nested"),
            "Array(Bool) nested"
          )
        end

        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array(Bool) nested element count overflows")
        end
        total_nested_elements += mark_elements
        start_row += rows
      end
      checked_array_numeric_checksum_size(total_nested_elements, 1, "Array(Bool) nested")
      nil
    end

    private def self.validate_array_nullable_bool_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Bool?)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}.null", value_name]
      )
      raise ArgumentError.new("Array(Nullable(Bool)) rows_per_mark exceeds reader materialization limit") if rows_per_mark.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      null_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_nested_elements = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Array size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Array size0")

        mark_elements = 0_u64
        rows.times do |offset|
          row_elements = values[start_row + offset].size.to_u64
          if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
            raise ArgumentError.new("Array(Nullable(Bool)) nested element count exceeds per-mark limit")
          end
          mark_elements += row_elements
        end

        null_raw_size = checked_array_numeric_bytes(mark_elements, 1, "Array(Nullable(Bool)) null map")
        value_raw_size = checked_array_numeric_bytes(mark_elements, 1, "Array(Nullable(Bool)) nested")
        combined_raw_size = null_raw_size + value_raw_size
        if combined_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Array(Nullable(Bool)) child stream bytes exceed per-mark limit")
        end
        if null_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(Bool)) null-map granule exceeds decompressed frame limit")
        end
        if value_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Array(Nullable(Bool)) nested granule exceeds decompressed frame limit")
        end
        unless mark_elements == 0
          null_data_bytes = add_array_frame_size(
            null_data_bytes,
            checked_array_frame_size(null_raw_size, "Array(Nullable(Bool)) null map"),
            "Array(Nullable(Bool)) null map"
          )
          value_data_bytes = add_array_frame_size(
            value_data_bytes,
            checked_array_frame_size(value_raw_size, "Array(Nullable(Bool)) nested"),
            "Array(Nullable(Bool)) nested"
          )
        end

        if mark_elements > UInt64::MAX - total_nested_elements
          raise ArgumentError.new("Array(Nullable(Bool)) nested element count overflows")
        end
        total_nested_elements += mark_elements
        start_row += rows
      end
      checked_array_element_checksum_size(total_nested_elements, "Array(Nullable(Bool)) null map")
      checked_array_numeric_checksum_size(total_nested_elements, 1, "Array(Nullable(Bool)) nested")
      nil
    end

    private def self.validate_map_uint64_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Tuple(UInt64, String))),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}%2Ekeys", "#{value_name}%2Evalues.size", "#{value_name}%2Evalues"]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      map_key_data_bytes = 0_i64
      value_size_data_bytes = 0_i64
      value_data_bytes = 0_i64
      total_entries = 0_u64
      total_value_bytes = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Map size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Map size0")

        mark_entries = 0_u64
        mark_value_bytes = 0_u64
        rows.times do |offset|
          row_entries = values[start_row + offset]
          if row_entries.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_entries
            raise ArgumentError.new("Map entry count exceeds per-mark limit")
          end
          mark_entries += row_entries.size.to_u64
          row_entries.each do |entry|
            value_bytes = entry[1].bytesize.to_u64
            if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - mark_value_bytes
              raise ArgumentError.new("Map String bytes exceed per-mark limit")
            end
            if value_bytes > UInt64::MAX - mark_value_bytes
              raise ArgumentError.new("Map String byte count overflows")
            end
            mark_value_bytes += value_bytes
          end
        end

        nested_raw_size = checked_array_element_bytes(mark_entries, "Map entries")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Map key/size bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Map key/size granule exceeds decompressed frame limit")
        end
        unless nested_raw_size == 0
          nested_frame_size = checked_array_frame_size(nested_raw_size, "Map key/size")
          map_key_data_bytes = add_array_frame_size(map_key_data_bytes, nested_frame_size, "Map keys")
          value_size_data_bytes = add_array_frame_size(value_size_data_bytes, nested_frame_size, "Map String sizes")
        end
        if mark_entries > UInt64::MAX - total_entries
          raise ArgumentError.new("Map entry count overflows")
        end
        total_entries += mark_entries

        if mark_value_bytes > MAX_FRAME_RAW_BYTES.to_u64
          raise ArgumentError.new("Map String granule exceeds decompressed frame limit")
        end
        if mark_value_bytes > UInt64::MAX - total_value_bytes
          raise ArgumentError.new("Map String byte count overflows")
        end
        total_value_bytes += mark_value_bytes
        unless mark_value_bytes == 0
          string_frame_size = checked_array_frame_size(mark_value_bytes.to_i64, "Map String")
          value_data_bytes = add_array_frame_size(value_data_bytes, string_frame_size, "Map String values")
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_map_uint64_uint64_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(Array(Tuple(UInt64, UInt64))),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.size != values.size
      validate_array_common_inputs(
        destination,
        key_name,
        keys,
        value_name,
        rows_per_mark,
        ["#{value_name}.size0", "#{value_name}%2Ekeys", "#{value_name}%2Evalues"]
      )

      key_data_bytes = 0_i64
      size0_data_bytes = 0_i64
      map_key_data_bytes = 0_i64
      map_value_data_bytes = 0_i64
      total_entries = 0_u64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_array_frame_size(fixed_raw_size, "Map size0")
        key_data_bytes = add_array_frame_size(key_data_bytes, fixed_frame_size, "UInt64 key")
        size0_data_bytes = add_array_frame_size(size0_data_bytes, fixed_frame_size, "Map size0")

        mark_entries = 0_u64
        rows.times do |offset|
          row_entries = values[start_row + offset]
          if row_entries.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_entries
            raise ArgumentError.new("Map entry count exceeds per-mark limit")
          end
          mark_entries += row_entries.size.to_u64
        end

        nested_raw_size = checked_array_element_bytes(mark_entries, "Map entries")
        if nested_raw_size > WidePart::MAX_ARRAY_MARK_BYTES
          raise ArgumentError.new("Map key/value bytes exceed per-mark limit")
        end
        if nested_raw_size > MAX_FRAME_RAW_BYTES.to_i64
          raise ArgumentError.new("Map key/value granule exceeds decompressed frame limit")
        end
        unless nested_raw_size == 0
          nested_frame_size = checked_array_frame_size(nested_raw_size, "Map key/value")
          map_key_data_bytes = add_array_frame_size(map_key_data_bytes, nested_frame_size, "Map keys")
          map_value_data_bytes = add_array_frame_size(map_value_data_bytes, nested_frame_size, "Map values")
        end
        if mark_entries > UInt64::MAX - total_entries
          raise ArgumentError.new("Map entry count overflows")
        end
        total_entries += mark_entries
        start_row += rows
      end
      checked_array_element_checksum_size(total_entries, "Map entries")
      nil
    end

    private def self.validate_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, "#{value_name}.size", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      key_data_bytes = 0_i64
      size_data_bytes = 0_i64
      string_data_bytes = 0_i64
      total_string_bytes = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_string_frame_size(fixed_raw_size, "UInt64 key and String size")
        if fixed_frame_size > MAX_DATA_FILE_BYTES - key_data_bytes
          raise ArgumentError.new("UInt64 key stream exceeds reader limit")
        end
        if fixed_frame_size > MAX_DATA_FILE_BYTES - size_data_bytes
          raise ArgumentError.new("String size stream exceeds reader limit")
        end
        key_data_bytes += fixed_frame_size
        size_data_bytes += fixed_frame_size

        raw_string_size = 0_i64
        rows.times do |offset|
          value_size = values[start_row + offset].bytesize.to_i64
          if value_size > MAX_FRAME_RAW_BYTES.to_i64 - raw_string_size
            raise ArgumentError.new("String payload granule exceeds decompressed frame limit")
          end
          if value_size > MAX_DATA_FILE_BYTES - total_string_bytes
            raise ArgumentError.new("String payload exceeds reader limit")
          end
          raw_string_size += value_size
          total_string_bytes += value_size
        end

        unless raw_string_size == 0
          string_frame_size = checked_string_frame_size(raw_string_size, "String payload")
          if string_frame_size > MAX_DATA_FILE_BYTES - string_data_bytes
            raise ArgumentError.new("String data stream exceeds reader limit")
          end
          string_data_bytes += string_frame_size
        end
        start_row += rows
      end

      nil
    end

    private def self.validate_tuple_header_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES
      validate_tuple_stream_names(key_name, value_name)

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end
      nil
    end

    private def self.validate_json_typed_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32,
    ) : Nil
      # Reuse the established two-column key, row, mark, and primary-index
      # checks. The JSON paths below have their own physical stream names.
      validate_tuple_header_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      logical_names = [
        key_name,
        "#{value_name}.object_structure",
        "#{value_name}.a",
        "#{value_name}.b.size",
        "#{value_name}.b",
        "#{value_name}.object_shared_data.0.size0",
        "#{value_name}.object_shared_data.0%2Epaths",
        "#{value_name}.object_shared_data.0%2Evalues",
      ]
      logical_names.each do |name|
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
          raise ArgumentError.new("physical stream name exceeds reader limit")
        end
      end
      stream_bases = logical_names.map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES

      structure_frame_size = literal_frame_size(json_object_structure_bytes.size.to_i64)
      raise ArgumentError.new("Object structure frame exceeds reader limit") if structure_frame_size > MAX_FRAME_COMPRESSED.to_i64

      fixed_stream_bytes = 0_i64
      string_stream_bytes = 0_i64
      total_string_bytes = 0_i64
      start_row = 0
      while start_row < keys.size
        rows = {rows_per_mark, keys.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        raise ArgumentError.new("JSON typed UInt64 granule exceeds reader limit") if fixed_raw_size > MAX_FRAME_RAW_BYTES.to_i64
        fixed_frame_size = checked_string_frame_size(fixed_raw_size, "JSON typed UInt64")
        if fixed_frame_size > MAX_DATA_FILE_BYTES - fixed_stream_bytes
          raise ArgumentError.new("JSON typed UInt64 stream exceeds reader limit")
        end
        fixed_stream_bytes += fixed_frame_size

        raw_string_size = 0_i64
        rows.times do |offset|
          value_size = values[start_row + offset][1].bytesize.to_i64
          if value_size > MAX_FRAME_RAW_BYTES.to_i64 - raw_string_size
            raise ArgumentError.new("JSON typed String granule exceeds decompressed frame limit")
          end
          if value_size > MAX_DATA_FILE_BYTES.to_i64 - total_string_bytes
            raise ArgumentError.new("JSON typed String stream exceeds reader limit")
          end
          raw_string_size += value_size
          total_string_bytes += value_size
        end

        unless raw_string_size == 0
          string_frame_size = checked_string_frame_size(raw_string_size, "JSON typed String")
          if string_frame_size > MAX_DATA_FILE_BYTES - string_stream_bytes
            raise ArgumentError.new("JSON typed String stream exceeds reader limit")
          end
          string_stream_bytes += string_frame_size
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_tuple_stream_names(key_name : String, value_name : String) : Nil
      stream_bases = [
        key_name,
        "#{value_name}%2Ea",
        "#{value_name}%2Eb.size",
        "#{value_name}%2Eb",
      ].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size
      nil
    end

    private def self.validate_low_cardinality_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      rows_per_mark : Int32,
    ) : {Array(String), Hash(String, UInt8)}
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, "#{value_name}.dict", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      raise ArgumentError.new("LowCardinality mark count exceeds reader limit") if mark_count > WidePart::MAX_LOW_CARDINALITY_MARKS
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      # ColumnUnique reserves the default non-nullable value at index zero.
      # For String this is the empty byte string, including when inputs never
      # reference it; stock LowCardinality parts serialize this special key.
      dictionary = [""]
      value_ids = Hash(String, UInt8).new
      value_ids[""] = 0_u8
      dictionary_raw_size = 17_i64 # version, dictionary count, empty-string length
      key_data_size = 0_i64
      index_data_size = 0_i64
      index_raw_data_size = 0_i64
      dictionary_data_size = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        key_frame_size = checked_string_frame_size(rows.to_i64 * 8_i64, "UInt64 key")
        raise ArgumentError.new("UInt64 key stream exceeds reader limit") if key_frame_size > MAX_DATA_FILE_BYTES - key_data_size
        key_data_size += key_frame_size

        index_raw_size = rows.to_i64 + 16_i64
        if index_raw_size > WidePart::MAX_LOW_CARDINALITY_INDEX_BYTES.to_i64 - index_raw_data_size
          raise ArgumentError.new("LowCardinality index exceeds reader decoded-size limit")
        end
        index_raw_data_size += index_raw_size
        index_frame_size = checked_string_frame_size(index_raw_size, "LowCardinality index")
        raise ArgumentError.new("LowCardinality index stream exceeds reader limit") if index_frame_size > MAX_DATA_FILE_BYTES - index_data_size
        index_data_size += index_frame_size

        mark_value_bytes = 0_i64
        rows.times do |offset|
          value = values[start_row + offset]
          value_size = value.bytesize.to_i64
          if value_size > WidePart::MAX_STRING_RANGE_BYTES.to_i64 - mark_value_bytes
            raise ArgumentError.new("LowCardinality String mark exceeds materialization limit")
          end
          mark_value_bytes += value_size

          unless value_ids.has_key?(value)
            raise ArgumentError.new("LowCardinality dictionary exceeds 256 entries including its default key") if dictionary.size >= MAX_LOW_CARDINALITY_KEYS
            entry_size = value_size + low_cardinality_var_uint_size(value_size.to_u64)
            if entry_size > MAX_LOW_CARDINALITY_DICTIONARY_BYTES - dictionary_raw_size
              raise ArgumentError.new("LowCardinality dictionary exceeds decoded-size limit")
            end
            value_id = dictionary.size.to_u8
            dictionary << value
            value_ids[value] = value_id
            dictionary_raw_size += entry_size
          end
        end
        start_row += rows
      end

      # Literal frames are emitted in bounded chunks, so the maximum dictionary
      # always fits the reader's aggregate data-file limit.
      cursor = 0_i64
      while cursor < dictionary_raw_size
        chunk_size = {LOW_CARDINALITY_DICTIONARY_FRAME_BYTES.to_i64, dictionary_raw_size - cursor}.min
        frame_size = checked_string_frame_size(chunk_size, "LowCardinality dictionary")
        raise ArgumentError.new("LowCardinality dictionary stream exceeds reader limit") if frame_size > MAX_DATA_FILE_BYTES - dictionary_data_size
        dictionary_data_size += frame_size
        cursor += chunk_size
      end

      {dictionary, value_ids}
    end

    private def self.low_cardinality_var_uint_size(value : UInt64) : Int64
      size = 1_i64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1
      end
      size
    end

    private def self.validate_fixed_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("FixedString width must be positive") if width <= 0
      raise ArgumentError.new("FixedString width exceeds reader limit") if width > WidePart::MAX_FIXED_STRING_WIDTH
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK
      raise ArgumentError.new("FixedString rows_per_mark exceeds reader materialization limit") if rows_per_mark > WidePart::MAX_FIXED_STRING_RANGE_ROWS

      stream_bases = [key_name, value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      key_data_bytes = 0_i64
      value_data_bytes = 0_i64
      fixed_width = width.to_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        {
          {rows.to_i64 * 8_i64, "UInt64 key", key_data_bytes},
          {rows.to_i64 * fixed_width, "FixedString payload", value_data_bytes},
        }.each do |raw_size, label, prior_bytes|
          if raw_size > MAX_FRAME_RAW_BYTES.to_i64
            raise ArgumentError.new("#{label} granule exceeds decompressed frame limit")
          end
          frame_size = literal_frame_size(raw_size)
          if frame_size > MAX_FRAME_COMPRESSED.to_i64
            raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit")
          end
          if frame_size > MAX_DATA_FILE_BYTES - prior_bytes
            raise ArgumentError.new("#{label} stream exceeds reader limit")
          end
          if label == "UInt64 key"
            key_data_bytes += frame_size
          else
            value_data_bytes += frame_size
          end
        end

        rows.times do |offset|
          if values[start_row + offset].bytesize > width
            raise ArgumentError.new("FixedString value exceeds declared byte width")
          end
        end
        start_row += rows
      end

      nil
    end

    private def self.validate_nullable_fixed_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String?),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("FixedString width must be positive") if width <= 0
      raise ArgumentError.new("FixedString width exceeds reader limit") if width > WidePart::MAX_FIXED_STRING_WIDTH
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK
      raise ArgumentError.new("Nullable(FixedString) rows_per_mark exceeds reader materialization limit") if rows_per_mark > WidePart::MAX_FIXED_STRING_RANGE_ROWS

      stream_bases = [key_name, "#{value_name}.null", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      key_data_bytes = 0_i64
      null_data_bytes = 0_i64
      nested_data_bytes = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        {
          {rows.to_i64 * 8_i64, "UInt64 key", key_data_bytes},
          {rows.to_i64, "Nullable null-map", null_data_bytes},
          {rows.to_i64 * width.to_i64, "Nullable FixedString nested", nested_data_bytes},
        }.each do |raw_size, label, prior_bytes|
          if raw_size > MAX_FRAME_RAW_BYTES.to_i64
            raise ArgumentError.new("#{label} granule exceeds decompressed frame limit")
          end
          frame_size = literal_frame_size(raw_size)
          if frame_size > MAX_FRAME_COMPRESSED.to_i64
            raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit")
          end
          if frame_size > MAX_DATA_FILE_BYTES - prior_bytes
            raise ArgumentError.new("#{label} stream exceeds reader limit")
          end
          if label == "UInt64 key"
            key_data_bytes += frame_size
          elsif label == "Nullable null-map"
            null_data_bytes += frame_size
          else
            nested_data_bytes += frame_size
          end
        end

        rows.times do |offset|
          value = values[start_row + offset]
          if value && value.bytesize > width
            raise ArgumentError.new("FixedString value exceeds declared byte width")
          end
        end
        start_row += rows
      end

      nil
    end

    private def self.checked_string_frame_size(raw_size : Int64, label : String) : Int64
      raise ArgumentError.new("#{label} granule exceeds decompressed frame limit") if raw_size <= 0 || raw_size > MAX_FRAME_RAW_BYTES.to_i64
      frame_size = literal_frame_size(raw_size)
      raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit") if frame_size > MAX_FRAME_COMPRESSED.to_i64
      frame_size
    end

    private def self.validate_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      mark_count = checked_mark_count(keys.size, rows_per_mark)

      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES
      raw_file_bytes = keys.size.to_i64 * 8_i64
      raise ArgumentError.new("UInt64 data exceeds reader limit") if raw_file_bytes > MAX_DATA_FILE_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      # Ensure every possible full granule, including literal-LZ4 expansion,
      # fits both the frame decoder and this table reader's row bound.
      full_granule_rows = rows_per_mark
      raw_size = full_granule_rows.to_i64 * 8_i64
      raise ArgumentError.new("granule exceeds decompressed frame limit") if raw_size > MAX_FRAME_RAW_BYTES
      raise ArgumentError.new("granule literal frame exceeds compressed frame limit") if literal_frame_size(raw_size) > MAX_FRAME_COMPRESSED.to_i64
      nil
    end

    private def self.typed_type_name(values : Slice(T)) : String forall T
      {% if T == Bool %}
        "Bool"
      {% elsif T == UInt8 %}
        "UInt8"
      {% elsif T == UInt16 %}
        "UInt16"
      {% elsif T == UInt32 %}
        "UInt32"
      {% elsif T == UInt64 %}
        "UInt64"
      {% elsif T == Int8 %}
        "Int8"
      {% elsif T == Int16 %}
        "Int16"
      {% elsif T == Int32 %}
        "Int32"
      {% elsif T == Int64 %}
        "Int64"
      {% elsif T == Float32 %}
        "Float32"
      {% elsif T == Float64 %}
        "Float64"
      {% elsif T == Bool? %}
        "Nullable(Bool)"
      {% elsif T == UInt8? %}
        "Nullable(UInt8)"
      {% elsif T == UInt16? %}
        "Nullable(UInt16)"
      {% elsif T == UInt32? %}
        "Nullable(UInt32)"
      {% elsif T == UInt64? %}
        "Nullable(UInt64)"
      {% elsif T == Int8? %}
        "Nullable(Int8)"
      {% elsif T == Int16? %}
        "Nullable(Int16)"
      {% elsif T == Int32? %}
        "Nullable(Int32)"
      {% elsif T == Int64? %}
        "Nullable(Int64)"
      {% elsif T == Float32? %}
        "Nullable(Float32)"
      {% elsif T == Float64? %}
        "Nullable(Float64)"
      {% elsif T == String %}
        "String"
      {% elsif T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
        "Nullable(String)"
      {% else %}
        raise UnsupportedFormatError.new("typed writer requires one of the supported numeric, String, or Nullable payload types")
      {% end %}
    end

    private def self.validate_typed_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      {% if T == UUIDValue %}
        raise UnsupportedFormatError.new("UUID writer requires exact UUID metadata") unless type_name == "UUID"
        validate_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == IPv4Value %}
        raise UnsupportedFormatError.new("IPv4 writer requires exact IPv4 metadata") unless type_name == "IPv4"
        validate_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == IPv6Value %}
        raise UnsupportedFormatError.new("IPv6 writer requires exact IPv6 metadata") unless type_name == "IPv6"
        validate_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == UUIDValue? %}
        raise UnsupportedFormatError.new("Nullable UUID writer requires exact Nullable(UUID) metadata") unless type_name == "Nullable(UUID)"
        validate_nullable_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == IPv4Value? %}
        raise UnsupportedFormatError.new("Nullable IPv4 writer requires exact Nullable(IPv4) metadata") unless type_name == "Nullable(IPv4)"
        validate_nullable_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == IPv6Value? %}
        raise UnsupportedFormatError.new("Nullable IPv6 writer requires exact Nullable(IPv6) metadata") unless type_name == "Nullable(IPv6)"
        validate_nullable_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == Decimal256Value %}
        raise UnsupportedFormatError.new("Decimal256 writer requires exact Decimal(76, S) metadata") unless WidePart.decimal256_scale(type_name)
        validate_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == Decimal256Value? %}
        raise UnsupportedFormatError.new("Nullable Decimal256 writer requires exact Nullable(Decimal(76, S)) metadata") unless WidePart.nullable_decimal256_scale(type_name)
        validate_nullable_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == Bool || T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 || T == Int128 || T == Float32 || T == Float64 %}
        validate_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T == Bool? || T == UInt8? || T == UInt16? || T == UInt32? || T == Int8? || T == Int16? || T == Int32? || T == Int64? || T == Int128? || T == Float32? || T == Float64? %}
        validate_nullable_typed_numeric_inputs(destination, key_name, keys, value_name, values, type_name, rows_per_mark)
      {% elsif T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
        validate_nullable_string_inputs(destination, key_name, keys, value_name, values, rows_per_mark)
      {% else %}
        raise UnsupportedFormatError.new("unsupported typed writer payload")
      {% end %}
    end

    private def self.write_typed_payload_streams(
      stage : String,
      column : String,
      values : Slice(T),
      rows_per_mark : Int32,
      type_name : String,
    ) : Array(ChecksumRecord) forall T
      {% if T == UUIDValue %}
        raise UnsupportedFormatError.new("UUID writer requires exact UUID metadata") unless type_name == "UUID"
        write_typed_numeric_stream(stage, column, values, rows_per_mark, type_name)
      {% elsif T == IPv4Value %}
        raise UnsupportedFormatError.new("IPv4 writer requires exact IPv4 metadata") unless type_name == "IPv4"
        write_typed_numeric_stream(stage, column, values, rows_per_mark, type_name)
      {% elsif T == IPv6Value %}
        raise UnsupportedFormatError.new("IPv6 writer requires exact IPv6 metadata") unless type_name == "IPv6"
        write_typed_numeric_stream(stage, column, values, rows_per_mark, type_name)
      {% elsif T == UUIDValue? %}
        raise UnsupportedFormatError.new("Nullable UUID writer requires exact Nullable(UUID) metadata") unless type_name == "Nullable(UUID)"
        write_nullable_typed_numeric_streams(stage, column, values, rows_per_mark, type_name)
      {% elsif T == IPv4Value? %}
        raise UnsupportedFormatError.new("Nullable IPv4 writer requires exact Nullable(IPv4) metadata") unless type_name == "Nullable(IPv4)"
        write_nullable_typed_numeric_streams(stage, column, values, rows_per_mark, type_name)
      {% elsif T == IPv6Value? %}
        raise UnsupportedFormatError.new("Nullable IPv6 writer requires exact Nullable(IPv6) metadata") unless type_name == "Nullable(IPv6)"
        write_nullable_typed_numeric_streams(stage, column, values, rows_per_mark, type_name)
      {% elsif T == Decimal256Value %}
        raise UnsupportedFormatError.new("Decimal256 writer requires exact Decimal(76, S) metadata") unless WidePart.decimal256_scale(type_name)
        write_typed_numeric_stream(stage, column, values, rows_per_mark, type_name)
      {% elsif T == Decimal256Value? %}
        raise UnsupportedFormatError.new("Nullable Decimal256 writer requires exact Nullable(Decimal(76, S)) metadata") unless WidePart.nullable_decimal256_scale(type_name)
        write_nullable_typed_numeric_streams(stage, column, values, rows_per_mark, type_name)
      {% elsif T == Bool || T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 || T == Int128 || T == Float32 || T == Float64 %}
        write_typed_numeric_stream(stage, column, values, rows_per_mark, type_name)
      {% elsif T == Bool? || T == UInt8? || T == UInt16? || T == UInt32? || T == Int8? || T == Int16? || T == Int32? || T == Int64? || T == Int128? || T == Float32? || T == Float64? %}
        write_nullable_typed_numeric_streams(stage, column, values, rows_per_mark, type_name)
      {% elsif T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
        write_nullable_string_streams(stage, column, values, rows_per_mark)
      {% else %}
        raise UnsupportedFormatError.new("unsupported typed writer payload")
      {% end %}
    end

    private def self.numeric_width(type_name : String) : Int32
      case type_name
      when "UInt8", "Int8", "Bool"
        1
      when "UInt16", "Int16", "Date"
        2
      when "UInt32", "Int32", "Float32", "Date32", "IPv4"
        4
      when "UInt64", "Int64", "Float64", "DateTime64(0)", "DateTime64(1)", "DateTime64(2)", "DateTime64(3)", "DateTime64(4)", "DateTime64(5)", "DateTime64(6)", "DateTime64(7)", "DateTime64(8)", "DateTime64(9)"
        8
      when "UUID", "IPv6"
        16
      when "DateTime"
        4
      else
        return 1 if WidePart.enum8_codes(type_name)
        return 2 if WidePart.enum16_codes(type_name)
        return 4 if WidePart.decimal32_scale(type_name)
        return 8 if WidePart.decimal64_scale(type_name)
        return 16 if WidePart.decimal128_scale(type_name)
        return 32 if WidePart.decimal256_scale(type_name)
        raise UnsupportedFormatError.new("typed writer requires an exact fixed-width primitive numeric payload")
      end
    end

    private def self.validate_nullable_typed_numeric_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, "#{value_name}.null", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      width = numeric_width(type_name["Nullable(".size...-1])
      key_data_bytes = 0_i64
      null_data_bytes = 0_i64
      nested_data_bytes = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        {
          {rows.to_i64 * 8_i64, "UInt64 key", key_data_bytes},
          {rows.to_i64, "Nullable null-map", null_data_bytes},
          {rows.to_i64 * width.to_i64, "Nullable nested", nested_data_bytes},
        }.each do |raw_size, label, prior_bytes|
          raise ArgumentError.new("#{label} granule exceeds decompressed frame limit") if raw_size > MAX_FRAME_RAW_BYTES.to_i64
          frame_size = literal_frame_size(raw_size)
          raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit") if frame_size > MAX_FRAME_COMPRESSED.to_i64
          raise ArgumentError.new("#{label} stream exceeds reader limit") if frame_size > MAX_DATA_FILE_BYTES - prior_bytes
          if label == "UInt64 key"
            key_data_bytes += frame_size
          elsif label == "Nullable null-map"
            null_data_bytes += frame_size
          else
            nested_data_bytes += frame_size
          end
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_nullable_string_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(String?),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, "#{value_name}.null", "#{value_name}.size", value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      key_data_bytes = 0_i64
      null_data_bytes = 0_i64
      size_data_bytes = 0_i64
      string_data_bytes = 0_i64
      total_raw_size = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        fixed_raw_size = rows.to_i64 * 8_i64
        fixed_frame_size = checked_string_frame_size(fixed_raw_size, "UInt64 key and Nullable(String) size")
        {
          {"UInt64 key", key_data_bytes},
          {"Nullable(String) size", size_data_bytes},
        }.each do |label, prior_bytes|
          raise ArgumentError.new("#{label} stream exceeds reader limit") if fixed_frame_size > MAX_DATA_FILE_BYTES - prior_bytes
          if label == "UInt64 key"
            key_data_bytes += fixed_frame_size
          else
            size_data_bytes += fixed_frame_size
          end
        end

        null_frame_size = checked_string_frame_size(rows.to_i64, "Nullable(String) null-map")
        raise ArgumentError.new("Nullable(String) null-map exceeds reader limit") if null_frame_size > MAX_DATA_FILE_BYTES - null_data_bytes
        null_data_bytes += null_frame_size

        raw_string_size = 0_i64
        rows.times do |offset|
          value = values[start_row + offset]
          unless value.nil?
            value_size = value.not_nil!.bytesize.to_i64
            if value_size > MAX_FRAME_RAW_BYTES.to_i64 - raw_string_size
              raise ArgumentError.new("Nullable(String) payload granule exceeds decompressed frame limit")
            end
            raw_string_size += value_size
            total_raw_size += value_size
            raise ArgumentError.new("Nullable(String) payload exceeds reader limit") if total_raw_size > MAX_DATA_FILE_BYTES
          end
        end
        unless raw_string_size == 0
          frame_size = checked_string_frame_size(raw_string_size, "Nullable(String) payload")
          raise ArgumentError.new("Nullable(String) data stream exceeds reader limit") if frame_size > MAX_DATA_FILE_BYTES - string_data_bytes
          string_data_bytes += frame_size
        end
        start_row += rows
      end
      nil
    end

    private def self.validate_typed_numeric_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      stream_bases = [key_name, value_name].map { |name| StreamName.hash(name) }
      raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      width = numeric_width(type_name).to_i64
      key_data_bytes = 0_i64
      value_data_bytes = 0_i64
      start_row = 0
      while start_row < values.size
        rows = {rows_per_mark, values.size - start_row}.min
        {
          {rows.to_i64 * 8_i64, "UInt64 key", key_data_bytes},
          {rows.to_i64 * width, "typed numeric", value_data_bytes},
        }.each do |raw_size, label, prior_bytes|
          raise ArgumentError.new("#{label} granule exceeds decompressed frame limit") if raw_size > MAX_FRAME_RAW_BYTES.to_i64
          frame_size = literal_frame_size(raw_size)
          raise ArgumentError.new("#{label} granule literal frame exceeds compressed frame limit") if frame_size > MAX_FRAME_COMPRESSED.to_i64
          raise ArgumentError.new("#{label} data stream exceeds reader limit") if frame_size > MAX_DATA_FILE_BYTES - prior_bytes
          if label == "UInt64 key"
            key_data_bytes += frame_size
          else
            value_data_bytes += frame_size
          end
        end
        start_row += rows
      end
      nil
    end

    private def self.write_typed_numeric_stream(
      stage : String,
      column : String,
      values : Slice(T),
      rows_per_mark : Int32,
      type_name : String,
    ) : Array(ChecksumRecord) forall T
      width = numeric_width(type_name)
      base_name = StreamName.hash(column)
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      data_path = File.join(stage, data_name)
      mark_path = File.join(stage, marks_name)
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      mark_bytes = IO::Memory.new
      data_size = 0_u64
      start_row = 0

      File.open(data_path, "wb") do |data_file|
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          raw = Bytes.new(rows * width)
          rows.times do |row|
            write_typed_numeric_le(raw, row * width, values[start_row + row])
          end

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          raise ArgumentError.new("typed numeric data stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(mark_path, marks)
      mark_hash = CityHashV1.file_hash(marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64 * width.to_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, mark_hash, false),
      ]
    end

    private def self.write_nullable_typed_numeric_streams(
      stage : String,
      column : String,
      values : Slice(T),
      rows_per_mark : Int32,
      type_name : String,
    ) : Array(ChecksumRecord) forall T
      width = numeric_width(type_name["Nullable(".size...-1])
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      null_data_path = File.join(stage, null_data_name)
      null_mark_path = File.join(stage, null_marks_name)
      value_data_path = File.join(stage, value_data_name)
      value_mark_path = File.join(stage, value_marks_name)
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      null_data_size = 0_u64
      value_data_size = 0_u64
      start_row = 0

      File.open(null_data_path, "wb") do |null_data_file|
        File.open(value_data_path, "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            null_raw = Bytes.new(rows)
            value_raw = Bytes.new(rows * width)
            rows.times do |row|
              value = values[start_row + row]
              offset = row * width
              if value.nil?
                null_raw[row] = 1_u8
                width.times { |byte| value_raw[offset + byte] = 0_u8 }
              else
                null_raw[row] = 0_u8
                write_typed_numeric_le(value_raw, offset, value.not_nil!)
              end
            end

            write_uint64_le(null_mark_bytes, null_data_size)
            write_uint64_le(null_mark_bytes, 0_u64)
            write_uint64_le(null_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            null_frame = encode_lz4_frame(null_raw)
            value_frame = encode_lz4_frame(value_raw)
            raise ArgumentError.new("Nullable null-map stream exceeds reader limit") if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
            raise ArgumentError.new("Nullable nested stream exceeds reader limit") if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
            null_data_file.write(null_frame)
            null_data_hash.update(null_frame)
            null_raw_hash.update(null_raw)
            null_data_size += null_frame.size.to_u64
            value_data_file.write(value_frame)
            value_data_hash.update(value_frame)
            value_raw_hash.update(value_raw)
            value_data_size += value_frame.size.to_u64
            start_row += rows
          end
        end
      end

      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if null_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(null_mark_path, null_marks)
      File.write(value_mark_path, value_marks)

      [
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, values.size.to_u64, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, values.size.to_u64 * width.to_u64, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_typed_numeric_le(bytes : Bytes, offset : Int, value : T) : Nil forall T
      {% if T == Bool %}
        bytes[offset] = value ? 1_u8 : 0_u8
      {% elsif T == UInt8 %}
        bytes[offset] = value
      {% elsif T == UInt16 %}
        2.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u16).to_u8 }
      {% elsif T == UInt32 %}
        write_uint32_le(bytes, offset, value)
      {% elsif T == UInt64 %}
        write_uint64_le(bytes, offset, value)
      {% elsif T == Int8 %}
        bytes[offset] = value.unsafe_as(UInt8)
      {% elsif T == Int16 %}
        bits = value.unsafe_as(UInt16)
        2.times { |index| bytes[offset + index] = ((bits >> (index * 8)) & 0xff_u16).to_u8 }
      {% elsif T == Int32 %}
        write_uint32_le(bytes, offset, value.unsafe_as(UInt32))
      {% elsif T == Int64 %}
        write_uint64_le(bytes, offset, value.unsafe_as(UInt64))
      {% elsif T == Int128 %}
        bits = value.unsafe_as(UInt128)
        16.times { |index| bytes[offset + index] = ((bits >> (index * 8)) & 0xff_u128).to_u8 }
      {% elsif T == Decimal256Value %}
        16.times { |index| bytes[offset + index] = ((value.low >> (index * 8)) & 0xff_u128).to_u8 }
        16.times { |index| bytes[offset + 16 + index] = ((value.high >> (index * 8)) & 0xff_u128).to_u8 }
      {% elsif T == UUIDValue %}
        write_uint64_le(bytes, offset, value.high)
        write_uint64_le(bytes, offset + 8, value.low)
      {% elsif T == IPv4Value %}
        write_uint32_le(bytes, offset, value.network_order)
      {% elsif T == IPv6Value %}
        write_uint64_be(bytes, offset, value.high)
        write_uint64_be(bytes, offset + 8, value.low)
      {% elsif T == Float32 %}
        write_uint32_le(bytes, offset, value.unsafe_as(UInt32))
      {% elsif T == Float64 %}
        write_uint64_le(bytes, offset, value.unsafe_as(UInt64))
      {% else %}
        raise UnsupportedFormatError.new("typed writer requires an exact fixed-width primitive numeric payload")
      {% end %}
      nil
    end

    private def self.checked_mark_count(row_count : Int, rows_per_mark : Int32) : Int32
      count = (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      raise ArgumentError.new("mark count exceeds writer limit") if count > MAX_MARKS
      count.to_i32
    end

    private def self.validate_column_name(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES && /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("column name must be a bounded ASCII identifier")
      end
    end

    private def self.create_stage(parent : String) : String
      8.times do
        candidate = File.tempname(".crystal-click-wide-writer-", nil, dir: parent)
        next if File.exists?(candidate) || File.symlink?(candidate)
        begin
          Dir.mkdir(candidate)
          {% if flag?(:crystal_click_test_failpoints) %}
            TestFailpoint.hit("writer_stage_created")
          {% end %}
          return candidate
        rescue ex : File::Error
          raise ex unless Errno.value == Errno::EEXIST
        end
      end
      raise IO::Error.new("cannot allocate a unique Wide-part staging directory")
    end

    private def self.write_uint64_stream(
      stage : String,
      column : String,
      values : Slice(UInt64),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base_name = StreamName.hash(column)
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      data_path = File.join(stage, data_name)
      mark_path = File.join(stage, marks_name)
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      mark_bytes = IO::Memory.new
      data_size = 0_u64
      start_row = 0

      File.open(data_path, "wb") do |data_file|
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          raw = Bytes.new(rows * 8)
          rows.times do |row|
            write_uint64_le(raw, row * 8, values[start_row + row])
          end

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          raise ArgumentError.new("data stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(mark_path, marks)
      mark_hash = CityHashV1.file_hash(marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64 * 8_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, mark_hash, false),
      ]
    end

    private def self.write_json_object_structure_stream(
      stage : String,
      column : String,
      row_count : Int,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base_name = StreamName.hash("#{column}.object_structure")
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      raw = json_object_structure_bytes
      frame = encode_lz4_frame(raw)
      raise ArgumentError.new("Object structure stream exceeds reader limit") if frame.size.to_i64 > MAX_DATA_FILE_BYTES

      data_hash = CityHashV1::FileHasher.new
      data_hash.update(frame)
      raw_hash = CityHashV1::FileHasher.new
      raw_hash.update(raw)
      File.write(File.join(stage, data_name), frame)

      mark_count = checked_mark_count(row_count, rows_per_mark)
      mark_bytes = IO::Memory.new
      start_row = 0
      while start_row < row_count
        rows = {rows_per_mark, row_count - start_row}.min
        write_uint64_le(mark_bytes, 0_u64)
        write_uint64_le(mark_bytes, 11_u64)
        write_uint64_le(mark_bytes, rows.to_u64)
        start_row += rows
      end
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, raw.size.to_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("Object structure marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, marks_name), marks)

      [
        ChecksumRecord.new(data_name, frame.size.to_u64, data_hash.finish, true, raw.size.to_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ]
    end

    private def self.write_json_shared_size0_stream(
      stage : String,
      logical_name : String,
      row_count : Int,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base_name = StreamName.hash(logical_name)
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      mark_bytes = IO::Memory.new
      data_size = 0_u64
      start_row = 0

      File.open(File.join(stage, data_name), "wb") do |data_file|
        while start_row < row_count
          rows = {rows_per_mark, row_count - start_row}.min
          raw = Bytes.new(rows * 8, 0_u8)
          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          raise ArgumentError.new("JSON shared size0 stream exceeds reader limit") if frame.size.to_i64 > MAX_DATA_FILE_BYTES - data_size.to_i64
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("JSON shared size0 marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, marks_name), marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, row_count.to_u64 * 8_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ]
    end

    private def self.write_json_empty_stream(
      stage : String,
      logical_name : String,
      row_count : Int,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base_name = StreamName.hash(logical_name)
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      File.open(File.join(stage, data_name), "wb") { }

      mark_bytes = IO::Memory.new
      start_row = 0
      while start_row < row_count
        rows = {rows_per_mark, row_count - start_row}.min
        write_uint64_le(mark_bytes, 0_u64)
        write_uint64_le(mark_bytes, 0_u64)
        write_uint64_le(mark_bytes, rows.to_u64)
        start_row += rows
      end
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("JSON shared empty marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, marks_name), marks)

      [
        ChecksumRecord.new(data_name, 0_u64, data_hash.finish, true, 0_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ]
    end

    private def self.write_nullable_uint64_streams(
      stage : String,
      column : String,
      values : Slice(UInt64?),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      null_name = StreamName.hash("#{column}.null")
      value_name = StreamName.hash(column)
      null_data_name = "#{null_name}.bin"
      null_marks_name = "#{null_name}.mrk2"
      value_data_name = "#{value_name}.bin"
      value_marks_name = "#{value_name}.mrk2"
      null_data_path = File.join(stage, null_data_name)
      null_mark_path = File.join(stage, null_marks_name)
      value_data_path = File.join(stage, value_data_name)
      value_mark_path = File.join(stage, value_marks_name)
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      null_data_size = 0_u64
      value_data_size = 0_u64
      start_row = 0

      File.open(null_data_path, "wb") do |null_data_file|
        File.open(value_data_path, "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            null_raw = Bytes.new(rows)
            value_raw = Bytes.new(rows * 8)
            rows.times do |row|
              value = values[start_row + row]
              if value.nil?
                null_raw[row] = 1_u8
                write_uint64_le(value_raw, row * 8, 0_u64)
              else
                null_raw[row] = 0_u8
                write_uint64_le(value_raw, row * 8, value)
              end
            end

            write_uint64_le(null_mark_bytes, null_data_size)
            write_uint64_le(null_mark_bytes, 0_u64)
            write_uint64_le(null_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            null_frame = encode_lz4_frame(null_raw)
            value_frame = encode_lz4_frame(value_raw)
            raise ArgumentError.new("Nullable null-map stream exceeds reader limit") if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
            raise ArgumentError.new("Nullable nested stream exceeds reader limit") if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
            null_data_file.write(null_frame)
            null_data_hash.update(null_frame)
            null_raw_hash.update(null_raw)
            null_data_size += null_frame.size.to_u64
            value_data_file.write(value_frame)
            value_data_hash.update(value_frame)
            value_raw_hash.update(value_raw)
            value_data_size += value_frame.size.to_u64
            start_row += rows
          end
        end
      end

      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if null_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(null_mark_path, null_marks)
      File.write(value_mark_path, value_marks)

      [
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, values.size.to_u64, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, values.size.to_u64 * 8_u64, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_string_streams(
      stage : String,
      column : String,
      values : Slice(T),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord) forall T
      size_base = StreamName.hash("#{column}.size")
      value_base = StreamName.hash(column)
      size_data_name = "#{size_base}.bin"
      size_marks_name = "#{size_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size_data_path = File.join(stage, size_data_name)
      size_mark_path = File.join(stage, size_marks_name)
      value_data_path = File.join(stage, value_data_name)
      value_mark_path = File.join(stage, value_marks_name)
      size_data_hash = CityHashV1::FileHasher.new
      size_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size_data_size = 0_u64
      value_data_size = 0_u64
      total_raw_size = 0_u64
      start_row = 0

      File.open(size_data_path, "wb") do |size_data_file|
        File.open(value_data_path, "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            sizes_raw = Bytes.new(rows * 8)
            string_raw_size = 0_i64
            rows.times do |row|
              value_size = typed_string_value(values[start_row + row]).bytesize.to_i64
              if value_size > MAX_FRAME_RAW_BYTES.to_i64 - string_raw_size
                raise ArgumentError.new("String payload granule exceeds decompressed frame limit")
              end
              string_raw_size += value_size
              write_uint64_le(sizes_raw, row * 8, value_size.to_u64)
            end
            raise ArgumentError.new("String payload exceeds reader limit") if string_raw_size.to_u64 > MAX_DATA_FILE_BYTES.to_u64 - total_raw_size

            string_raw = Bytes.new(string_raw_size.to_i)
            string_offset = 0
            rows.times do |row|
              value = typed_string_value(values[start_row + row])
              value_bytes = value.to_slice
              if value_bytes.size > 0
                value_bytes.copy_to(string_raw[string_offset, value_bytes.size])
                string_offset += value_bytes.size
              end
            end

            write_uint64_le(size_mark_bytes, size_data_size)
            write_uint64_le(size_mark_bytes, 0_u64)
            write_uint64_le(size_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            size_frame = encode_lz4_frame(sizes_raw)
            raise ArgumentError.new("String size stream exceeds reader limit") if size_data_size > MAX_DATA_FILE_BYTES.to_u64 - size_frame.size.to_u64
            size_data_file.write(size_frame)
            size_data_hash.update(size_frame)
            size_raw_hash.update(sizes_raw)
            size_data_size += size_frame.size.to_u64

            unless string_raw.empty?
              string_frame = encode_lz4_frame(string_raw)
              raise ArgumentError.new("String data stream exceeds reader limit") if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - string_frame.size.to_u64
              value_data_file.write(string_frame)
              value_data_hash.update(string_frame)
              value_data_size += string_frame.size.to_u64
            end
            value_raw_hash.update(string_raw)
            total_raw_size += string_raw.size.to_u64
            start_row += rows
          end
        end
      end

      write_uint64_le(size_mark_bytes, size_data_size)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size_marks = size_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(size_mark_path, size_marks)
      File.write(value_mark_path, value_marks)

      [
        ChecksumRecord.new(size_data_name, size_data_size, size_data_hash.finish, true, values.size.to_u64 * 8_u64, size_raw_hash.finish),
        ChecksumRecord.new(size_marks_name, size_marks.size.to_u64, CityHashV1.file_hash(size_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, total_raw_size, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_low_cardinality_dictionary_stream(
      stage : String,
      column : String,
      dictionary : Array(String),
      row_count : Int32,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base = StreamName.hash("#{column}.dict")
      data_name = "#{base}.bin"
      marks_name = "#{base}.mrk2"
      data_path = File.join(stage, data_name)
      marks_path = File.join(stage, marks_name)
      raw = IO::Memory.new
      write_uint64_le(raw, 1_u64)
      write_uint64_le(raw, dictionary.size.to_u64)
      dictionary.each do |value|
        value_bytes = value.to_slice
        write_var_uint(raw, value_bytes.size.to_u64)
        raw.write(value_bytes)
      end
      raw_bytes = raw.to_slice
      raise ArgumentError.new("LowCardinality dictionary exceeds decoded-size limit") if raw_bytes.size.to_i64 > MAX_LOW_CARDINALITY_DICTIONARY_BYTES

      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      data_size = 0_u64
      File.open(data_path, "wb") do |file|
        cursor = 0
        while cursor < raw_bytes.size
          chunk_size = {LOW_CARDINALITY_DICTIONARY_FRAME_BYTES, raw_bytes.size - cursor}.min
          chunk = raw_bytes[cursor, chunk_size]
          frame = encode_lz4_frame(chunk)
          raise ArgumentError.new("LowCardinality dictionary stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          file.write(frame)
          data_hash.update(frame)
          raw_hash.update(chunk)
          data_size += frame.size.to_u64
          cursor += chunk_size
        end
      end

      mark_bytes = IO::Memory.new
      start_row = 0
      while start_row < row_count
        rows = {rows_per_mark, row_count - start_row}.min
        # The shared dictionary starts after its eight-byte version prefix.
        write_uint64_le(mark_bytes, 0_u64)
        write_uint64_le(mark_bytes, 8_u64)
        write_uint64_le(mark_bytes, rows.to_u64)
        start_row += rows
      end
      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("LowCardinality dictionary marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(marks_path, marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, raw_bytes.size.to_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ]
    end

    private def self.write_low_cardinality_index_stream(
      stage : String,
      column : String,
      values : Slice(String),
      value_ids : Hash(String, UInt8),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base = StreamName.hash(column)
      data_name = "#{base}.bin"
      marks_name = "#{base}.mrk2"
      data_path = File.join(stage, data_name)
      marks_path = File.join(stage, marks_name)
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      data_size = 0_u64
      raw_size = 0_u64
      mark_bytes = IO::Memory.new
      start_row = 0
      mark_index = 0

      File.open(data_path, "wb") do |file|
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          raw = IO::Memory.new
          write_uint64_le(raw, mark_index == 0 ? 0x500_u64 : 0x100_u64)
          write_uint64_le(raw, rows.to_u64)
          rows.times do |offset|
            value = values[start_row + offset]
            value_id = value_ids[value]?
            raise CorruptPartError.new("LowCardinality dictionary is missing an input value") unless value_id
            raw.write_byte(value_id)
          end
          raw_bytes = raw.to_slice

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)
          frame = encode_lz4_frame(raw_bytes)
          raise ArgumentError.new("LowCardinality index stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw_bytes)
          data_size += frame.size.to_u64
          raw_size += raw_bytes.size.to_u64
          start_row += rows
          mark_index += 1
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("LowCardinality index marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(marks_path, marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, raw_size, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ]
    end

    private def self.write_array_uint64_streams(
      stage : String,
      column : String,
      values : Slice(Array(UInt64)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      value_data_size = 0_u64
      total_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            size0_raw = Bytes.new(rows * 8)
            mark_elements = 0_u64
            rows.times do |row|
              row_values = values[start_row + row]
              write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
              if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                raise ArgumentError.new("Array nested element count exceeds per-mark limit")
              end
              mark_elements += row_values.size.to_u64
            end

            if mark_elements > UInt64::MAX // 8_u64
              raise ArgumentError.new("Array nested byte count overflows")
            end
            nested_raw = Bytes.new((mark_elements * 8_u64).to_i)
            nested_offset = 0
            rows.times do |row|
              values[start_row + row].each do |value|
                write_uint64_le(nested_raw, nested_offset, value)
                nested_offset += 8
              end
            end

            write_uint64_le(size0_mark_bytes, size0_data_size)
            write_uint64_le(size0_mark_bytes, 0_u64)
            write_uint64_le(size0_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            size0_frame = encode_lz4_frame(size0_raw)
            if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
              raise ArgumentError.new("Array size0 stream exceeds reader limit")
            end
            size0_data_file.write(size0_frame)
            size0_data_hash.update(size0_frame)
            size0_raw_hash.update(size0_raw)
            size0_data_size += size0_frame.size.to_u64

            unless nested_raw.empty?
              value_frame = encode_lz4_frame(nested_raw)
              if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                raise ArgumentError.new("Array nested stream exceeds reader limit")
              end
              value_data_file.write(value_frame)
              value_data_hash.update(value_frame)
              value_data_size += value_frame.size.to_u64
            end
            value_raw_hash.update(nested_raw)
            nested_elements = mark_elements
            if nested_elements > UInt64::MAX - total_elements
              raise ArgumentError.new("Array nested element count overflows")
            end
            total_elements += nested_elements
            start_row += rows
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size0_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_element_checksum_size(total_elements, "Array nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_array_uint64_streams(
      stage : String,
      column : String,
      values : Slice(Array(Array(UInt64))),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      size1_base = StreamName.hash("#{column}.size1")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      size1_data_name = "#{size1_base}.bin"
      size1_marks_name = "#{size1_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      size1_data_hash = CityHashV1::FileHasher.new
      size1_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      size1_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      size1_data_size = 0_u64
      value_data_size = 0_u64
      total_inner_arrays = 0_u64
      total_leaf_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, size1_data_name), "wb") do |size1_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8)
              mark_inner_arrays = 0_u64
              mark_leaf_elements = 0_u64
              rows.times do |row_offset|
                row = values[start_row + row_offset]
                inner_count = row.size.to_u64
                if inner_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_inner_arrays
                  raise ArgumentError.new("Array(Array(UInt64)) inner-array count exceeds per-mark limit")
                end
                mark_inner_arrays += inner_count
                write_uint64_le(size0_raw, row_offset * 8, inner_count)
                row.each do |inner|
                  leaf_count = inner.size.to_u64
                  if leaf_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_leaf_elements
                    raise ArgumentError.new("Array(Array(UInt64)) leaf element count exceeds per-mark limit")
                  end
                  mark_leaf_elements += leaf_count
                end
              end

              size1_raw_size = checked_array_element_bytes(mark_inner_arrays, "Array(Array(UInt64)) size1")
              value_raw_size = checked_array_element_bytes(mark_leaf_elements, "Array(Array(UInt64)) nested")
              size1_raw = Bytes.new(size1_raw_size)
              value_raw = Bytes.new(value_raw_size)
              size1_offset = 0
              value_offset = 0
              rows.times do |row_offset|
                values[start_row + row_offset].each do |inner|
                  write_uint64_le(size1_raw, size1_offset, inner.size.to_u64)
                  size1_offset += 8
                  inner.each do |value|
                    write_uint64_le(value_raw, value_offset, value)
                    value_offset += 8
                  end
                end
              end
              raise CorruptPartError.new("Array(Array(UInt64)) size1 writer count changed") unless size1_offset == size1_raw.size
              raise CorruptPartError.new("Array(Array(UInt64)) leaf writer count changed") unless value_offset == value_raw.size

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(size1_mark_bytes, size1_data_size)
              write_uint64_le(size1_mark_bytes, 0_u64)
              write_uint64_le(size1_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless size1_raw.empty?
                size1_frame = encode_lz4_frame(size1_raw)
                if size1_data_size > MAX_DATA_FILE_BYTES.to_u64 - size1_frame.size.to_u64
                  raise ArgumentError.new("Array(Array(UInt64)) size1 stream exceeds reader limit")
                end
                size1_data_file.write(size1_frame)
                size1_data_hash.update(size1_frame)
                size1_data_size += size1_frame.size.to_u64
              end
              size1_raw_hash.update(size1_raw)

              unless value_raw.empty?
                value_frame = encode_lz4_frame(value_raw)
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("Array(Array(UInt64)) nested stream exceeds reader limit")
                end
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              value_raw_hash.update(value_raw)
              if mark_inner_arrays > UInt64::MAX - total_inner_arrays || mark_leaf_elements > UInt64::MAX - total_leaf_elements
                raise ArgumentError.new("Array(Array(UInt64)) element count overflows")
              end
              total_inner_arrays += mark_inner_arrays
              total_leaf_elements += mark_leaf_elements
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size1_mark_bytes, size1_data_size)
      write_uint64_le(size1_mark_bytes, 0_u64)
      write_uint64_le(size1_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      size1_marks = size1_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size0_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if size1_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, size1_marks_name), size1_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(size1_data_name, size1_data_size, size1_data_hash.finish, true, checked_array_element_checksum_size(total_inner_arrays, "Array(Array(UInt64)) size1"), size1_raw_hash.finish),
        ChecksumRecord.new(size1_marks_name, size1_marks.size.to_u64, CityHashV1.file_hash(size1_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_element_checksum_size(total_leaf_elements, "Array(Array(UInt64)) nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_array_nullable_uint64_streams(
      stage : String,
      column : String,
      values : Slice(Array(Array(UInt64?))),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      size1_base = StreamName.hash("#{column}.size1")
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      size1_data_name = "#{size1_base}.bin"
      size1_marks_name = "#{size1_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      size1_data_hash = CityHashV1::FileHasher.new
      size1_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      size1_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      size1_data_size = 0_u64
      null_data_size = 0_u64
      value_data_size = 0_u64
      total_inner_arrays = 0_u64
      total_leaf_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, size1_data_name), "wb") do |size1_data_file|
          File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
            File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
              while start_row < values.size
                rows = {rows_per_mark, values.size - start_row}.min
                size0_raw = Bytes.new(rows * 8)
                mark_inner_arrays = 0_u64
                mark_leaf_elements = 0_u64
                rows.times do |row_offset|
                  row = values[start_row + row_offset]
                  inner_count = row.size.to_u64
                  if inner_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_inner_arrays
                    raise ArgumentError.new("Array(Array(Nullable(UInt64))) inner-array count exceeds per-mark limit")
                  end
                  mark_inner_arrays += inner_count
                  write_uint64_le(size0_raw, row_offset * 8, inner_count)
                  row.each do |inner|
                    leaf_count = inner.size.to_u64
                    if leaf_count > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_leaf_elements
                      raise ArgumentError.new("Array(Array(Nullable(UInt64))) leaf element count exceeds per-mark limit")
                    end
                    mark_leaf_elements += leaf_count
                  end
                end

                size1_raw = Bytes.new(checked_array_element_bytes(mark_inner_arrays, "Array(Array(Nullable(UInt64))) size1"))
                null_raw = Bytes.new(mark_leaf_elements.to_i)
                value_raw = Bytes.new(checked_array_element_bytes(mark_leaf_elements, "Array(Array(Nullable(UInt64))) nested"))
                size1_offset = 0
                leaf_offset = 0
                rows.times do |row_offset|
                  values[start_row + row_offset].each do |inner|
                    write_uint64_le(size1_raw, size1_offset, inner.size.to_u64)
                    size1_offset += 8
                    inner.each do |value|
                      if value.nil?
                        null_raw[leaf_offset] = 1_u8
                        write_uint64_le(value_raw, leaf_offset * 8, 0_u64)
                      else
                        null_raw[leaf_offset] = 0_u8
                        write_uint64_le(value_raw, leaf_offset * 8, value.not_nil!)
                      end
                      leaf_offset += 1
                    end
                  end
                end
                raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 writer count changed") unless size1_offset == size1_raw.size
                raise CorruptPartError.new("Array(Array(Nullable(UInt64))) leaf writer count changed") unless leaf_offset == mark_leaf_elements

                write_uint64_le(size0_mark_bytes, size0_data_size)
                write_uint64_le(size0_mark_bytes, 0_u64)
                write_uint64_le(size0_mark_bytes, rows.to_u64)
                write_uint64_le(size1_mark_bytes, size1_data_size)
                write_uint64_le(size1_mark_bytes, 0_u64)
                write_uint64_le(size1_mark_bytes, rows.to_u64)
                write_uint64_le(null_mark_bytes, null_data_size)
                write_uint64_le(null_mark_bytes, 0_u64)
                write_uint64_le(null_mark_bytes, rows.to_u64)
                write_uint64_le(value_mark_bytes, value_data_size)
                write_uint64_le(value_mark_bytes, 0_u64)
                write_uint64_le(value_mark_bytes, rows.to_u64)

                size0_frame = encode_lz4_frame(size0_raw)
                if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                  raise ArgumentError.new("Array size0 stream exceeds reader limit")
                end
                size0_data_file.write(size0_frame)
                size0_data_hash.update(size0_frame)
                size0_raw_hash.update(size0_raw)
                size0_data_size += size0_frame.size.to_u64

                unless size1_raw.empty?
                  size1_frame = encode_lz4_frame(size1_raw)
                  if size1_data_size > MAX_DATA_FILE_BYTES.to_u64 - size1_frame.size.to_u64
                    raise ArgumentError.new("Array(Array(Nullable(UInt64))) size1 stream exceeds reader limit")
                  end
                  size1_data_file.write(size1_frame)
                  size1_data_hash.update(size1_frame)
                  size1_data_size += size1_frame.size.to_u64
                end
                size1_raw_hash.update(size1_raw)

                unless null_raw.empty?
                  null_frame = encode_lz4_frame(null_raw)
                  if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                    raise ArgumentError.new("Array(Array(Nullable(UInt64))) null-map stream exceeds reader limit")
                  end
                  null_data_file.write(null_frame)
                  null_data_hash.update(null_frame)
                  null_data_size += null_frame.size.to_u64
                end
                null_raw_hash.update(null_raw)

                unless value_raw.empty?
                  value_frame = encode_lz4_frame(value_raw)
                  if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                    raise ArgumentError.new("Array(Array(Nullable(UInt64))) nested stream exceeds reader limit")
                  end
                  value_data_file.write(value_frame)
                  value_data_hash.update(value_frame)
                  value_data_size += value_frame.size.to_u64
                end
                value_raw_hash.update(value_raw)

                if mark_inner_arrays > UInt64::MAX - total_inner_arrays || mark_leaf_elements > UInt64::MAX - total_leaf_elements
                  raise ArgumentError.new("Array(Array(Nullable(UInt64))) element count overflows")
                end
                total_inner_arrays += mark_inner_arrays
                total_leaf_elements += mark_leaf_elements
                start_row += rows
              end
            end
          end
        end
      end

      {
        {size0_mark_bytes, size0_data_size},
        {size1_mark_bytes, size1_data_size},
        {null_mark_bytes, null_data_size},
        {value_mark_bytes, value_data_size},
      }.each do |mark_bytes, data_size|
        write_uint64_le(mark_bytes, data_size)
        write_uint64_le(mark_bytes, 0_u64)
        write_uint64_le(mark_bytes, 0_u64)
        raise ArgumentError.new("mark stream exceeds reader limit") if mark_bytes.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      size0_marks = size0_mark_bytes.to_slice
      size1_marks = size1_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, size1_marks_name), size1_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(size1_data_name, size1_data_size, size1_data_hash.finish, true, checked_array_element_checksum_size(total_inner_arrays, "Array(Array(Nullable(UInt64))) size1"), size1_raw_hash.finish),
        ChecksumRecord.new(size1_marks_name, size1_marks.size.to_u64, CityHashV1.file_hash(size1_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, total_leaf_elements, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_element_checksum_size(total_leaf_elements, "Array(Array(Nullable(UInt64))) nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_nullable_numeric_streams(
      stage : String,
      column : String,
      values : Slice(Array(T?)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Array(ChecksumRecord) forall T
      width = WidePart.numeric_payload_width(type_name)
      size0_base = StreamName.hash("#{column}.size0")
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      null_data_size = 0_u64
      value_data_size = 0_u64
      total_elements = 0_u64
      start_row = 0
      label = "Array(Nullable(#{type_name}))"

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8)
              mark_elements = 0_u64
              rows.times do |row|
                row_elements = values[start_row + row].size.to_u64
                if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                  element_limit_label = type_name == "UInt64" ? "Array(Nullable(UInt64))" : label
                  raise ArgumentError.new("#{element_limit_label} nested element count exceeds per-mark limit")
                end
                mark_elements += row_elements
                write_uint64_le(size0_raw, row * 8, row_elements)
              end

              null_raw = Bytes.new(mark_elements.to_i)
              value_raw = Bytes.new(checked_array_numeric_bytes(mark_elements, width, "#{label} nested"))
              element_offset = 0
              value_offset = 0
              rows.times do |row|
                values[start_row + row].each do |value|
                  if value.nil?
                    null_raw[element_offset] = 1_u8
                  else
                    null_raw[element_offset] = 0_u8
                    write_typed_numeric_le(value_raw, value_offset, value.not_nil!)
                  end
                  element_offset += 1
                  value_offset += width
                end
              end

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(null_mark_bytes, null_data_size)
              write_uint64_le(null_mark_bytes, 0_u64)
              write_uint64_le(null_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless null_raw.empty?
                null_frame = encode_lz4_frame(null_raw)
                value_frame = encode_lz4_frame(value_raw)
                if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                  raise ArgumentError.new("#{label} null-map stream exceeds reader limit")
                end
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("#{label} nested stream exceeds reader limit")
                end
                null_data_file.write(null_frame)
                null_data_hash.update(null_frame)
                null_data_size += null_frame.size.to_u64
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              null_raw_hash.update(null_raw)
              value_raw_hash.update(value_raw)
              if mark_elements > UInt64::MAX - total_elements
                raise ArgumentError.new("#{label} nested element count overflows")
              end
              total_elements += mark_elements
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)

      size0_marks = size0_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, null_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, total_elements, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_numeric_checksum_size(total_elements, width, "#{label} nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_nullable_uint64_streams(
      stage : String,
      column : String,
      values : Slice(Array(UInt64?)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      null_data_size = 0_u64
      value_data_size = 0_u64
      total_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8)
              mark_elements = 0_u64
              rows.times do |row|
                row_elements = values[start_row + row].size.to_u64
                if row_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                  raise ArgumentError.new("Array(Nullable(UInt64)) nested element count exceeds per-mark limit")
                end
                mark_elements += row_elements
                write_uint64_le(size0_raw, row * 8, row_elements)
              end

              null_raw = Bytes.new(mark_elements.to_i)
              value_raw = Bytes.new((mark_elements * 8_u64).to_i)
              element_offset = 0
              rows.times do |row|
                values[start_row + row].each do |value|
                  if value.nil?
                    null_raw[element_offset] = 1_u8
                    write_uint64_le(value_raw, element_offset * 8, 0_u64)
                  else
                    null_raw[element_offset] = 0_u8
                    write_uint64_le(value_raw, element_offset * 8, value.not_nil!)
                  end
                  element_offset += 1
                end
              end

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(null_mark_bytes, null_data_size)
              write_uint64_le(null_mark_bytes, 0_u64)
              write_uint64_le(null_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless null_raw.empty?
                null_frame = encode_lz4_frame(null_raw)
                value_frame = encode_lz4_frame(value_raw)
                if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(UInt64)) null-map stream exceeds reader limit")
                end
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(UInt64)) nested stream exceeds reader limit")
                end
                null_data_file.write(null_frame)
                null_data_hash.update(null_frame)
                null_data_size += null_frame.size.to_u64
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              null_raw_hash.update(null_raw)
              value_raw_hash.update(value_raw)
              if mark_elements > UInt64::MAX - total_elements
                raise ArgumentError.new("Array(Nullable(UInt64)) nested element count overflows")
              end
              total_elements += mark_elements
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)

      size0_marks = size0_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, null_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      null_raw_size = total_elements
      if total_elements > UInt64::MAX // 8_u64
        raise ArgumentError.new("Array(Nullable(UInt64)) nested byte count overflows")
      end
      value_raw_size = total_elements * 8_u64
      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, null_raw_size, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, value_raw_size, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_string_streams(
      stage : String,
      column : String,
      values : Slice(Array(String)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      size_base = StreamName.hash("#{column}.size")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      size_data_name = "#{size_base}.bin"
      size_marks_name = "#{size_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      size_data_hash = CityHashV1::FileHasher.new
      size_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      size_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      size_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      total_raw_size = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, size_data_name), "wb") do |size_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8)
              mark_elements = 0_u64
              mark_raw_size = 0_u64
              rows.times do |row|
                row_values = values[start_row + row]
                write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
                if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                  raise ArgumentError.new("Array nested element count exceeds per-mark limit")
                end
                mark_elements += row_values.size.to_u64
                row_values.each do |value|
                  value_size = value.bytesize.to_u64
                  if value_size > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_size
                    raise ArgumentError.new("Array nested bytes exceed per-mark limit")
                  end
                  if value_size > UInt64::MAX - mark_raw_size
                    raise ArgumentError.new("Array nested byte count overflows")
                  end
                  mark_raw_size += value_size
                end
              end

              nested_size_raw = Bytes.new((mark_elements * 8_u64).to_i)
              nested_raw = Bytes.new(mark_raw_size.to_i)
              nested_index = 0
              raw_offset = 0
              rows.times do |row|
                values[start_row + row].each do |value|
                  value_bytes = value.to_slice
                  write_uint64_le(nested_size_raw, nested_index * 8, value_bytes.size.to_u64)
                  nested_index += 1
                  unless value_bytes.empty?
                    value_bytes.copy_to(nested_raw[raw_offset, value_bytes.size])
                    raw_offset += value_bytes.size
                  end
                end
              end

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(size_mark_bytes, size_data_size)
              write_uint64_le(size_mark_bytes, 0_u64)
              write_uint64_le(size_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless nested_size_raw.empty?
                size_frame = encode_lz4_frame(nested_size_raw)
                if size_data_size > MAX_DATA_FILE_BYTES.to_u64 - size_frame.size.to_u64
                  raise ArgumentError.new("Array nested size stream exceeds reader limit")
                end
                size_data_file.write(size_frame)
                size_data_hash.update(size_frame)
                size_raw_hash.update(nested_size_raw)
                size_data_size += size_frame.size.to_u64
              end
              unless nested_raw.empty?
                value_frame = encode_lz4_frame(nested_raw)
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("Array nested stream exceeds reader limit")
                end
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              value_raw_hash.update(nested_raw)

              if mark_elements > UInt64::MAX - total_nested_elements
                raise ArgumentError.new("Array nested element count overflows")
              end
              total_nested_elements += mark_elements
              if mark_raw_size > UInt64::MAX - total_raw_size
                raise ArgumentError.new("Array nested byte count overflows")
              end
              total_raw_size += mark_raw_size
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size_mark_bytes, size_data_size)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      size_marks = size_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size0_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if size_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, size_marks_name), size_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(size_data_name, size_data_size, size_data_hash.finish, true, checked_array_element_checksum_size(total_nested_elements, "Array nested size"), size_raw_hash.finish),
        ChecksumRecord.new(size_marks_name, size_marks.size.to_u64, CityHashV1.file_hash(size_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, total_raw_size, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_nullable_string_streams(
      stage : String,
      column : String,
      values : Slice(Array(String?)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      null_base = StreamName.hash("#{column}.null")
      size_base = StreamName.hash("#{column}.size")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      size_data_name = "#{size_base}.bin"
      size_marks_name = "#{size_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      size_data_hash = CityHashV1::FileHasher.new
      size_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      size_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      null_data_size = 0_u64
      size_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      total_raw_string_bytes = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
          File.open(File.join(stage, size_data_name), "wb") do |size_data_file|
            File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
              while start_row < values.size
                rows = {rows_per_mark, values.size - start_row}.min
                size0_raw = Bytes.new(rows * 8)
                mark_elements = 0_u64
                mark_raw_string_bytes = 0_u64
                rows.times do |row|
                  row_values = values[start_row + row]
                  write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
                  if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                    raise ArgumentError.new("Array(Nullable(String)) nested element count exceeds per-mark limit")
                  end
                  mark_elements += row_values.size.to_u64
                  row_values.each do |value|
                    next if value.nil?
                    value_bytes = value.not_nil!.bytesize.to_u64
                    if value_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_string_bytes
                      raise ArgumentError.new("Array(Nullable(String)) nested bytes exceed per-mark limit")
                    end
                    mark_raw_string_bytes += value_bytes
                  end
                end

                null_raw = Bytes.new(mark_elements.to_i)
                nested_size_raw = Bytes.new(checked_array_element_bytes(mark_elements, "Array(Nullable(String)) nested size"))
                nested_raw = Bytes.new(mark_raw_string_bytes.to_i)
                element_offset = 0
                raw_offset = 0
                rows.times do |row|
                  values[start_row + row].each do |value|
                    if value.nil?
                      null_raw[element_offset] = 1_u8
                      write_uint64_le(nested_size_raw, element_offset * 8, 0_u64)
                    else
                      string_value = value.not_nil!
                      string_bytes = string_value.to_slice
                      null_raw[element_offset] = 0_u8
                      write_uint64_le(nested_size_raw, element_offset * 8, string_bytes.size.to_u64)
                      unless string_bytes.empty?
                        string_bytes.copy_to(nested_raw[raw_offset, string_bytes.size])
                        raw_offset += string_bytes.size
                      end
                    end
                    element_offset += 1
                  end
                end

                write_uint64_le(size0_mark_bytes, size0_data_size)
                write_uint64_le(size0_mark_bytes, 0_u64)
                write_uint64_le(size0_mark_bytes, rows.to_u64)
                write_uint64_le(null_mark_bytes, null_data_size)
                write_uint64_le(null_mark_bytes, 0_u64)
                write_uint64_le(null_mark_bytes, rows.to_u64)
                write_uint64_le(size_mark_bytes, size_data_size)
                write_uint64_le(size_mark_bytes, 0_u64)
                write_uint64_le(size_mark_bytes, rows.to_u64)
                write_uint64_le(value_mark_bytes, value_data_size)
                write_uint64_le(value_mark_bytes, 0_u64)
                write_uint64_le(value_mark_bytes, rows.to_u64)

                size0_frame = encode_lz4_frame(size0_raw)
                if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                  raise ArgumentError.new("Array size0 stream exceeds reader limit")
                end
                size0_data_file.write(size0_frame)
                size0_data_hash.update(size0_frame)
                size0_raw_hash.update(size0_raw)
                size0_data_size += size0_frame.size.to_u64

                unless null_raw.empty?
                  null_frame = encode_lz4_frame(null_raw)
                  if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                    raise ArgumentError.new("Array(Nullable(String)) null-map stream exceeds reader limit")
                  end
                  null_data_file.write(null_frame)
                  null_data_hash.update(null_frame)
                  null_data_size += null_frame.size.to_u64
                end
                null_raw_hash.update(null_raw)

                unless nested_size_raw.empty?
                  size_frame = encode_lz4_frame(nested_size_raw)
                  if size_data_size > MAX_DATA_FILE_BYTES.to_u64 - size_frame.size.to_u64
                    raise ArgumentError.new("Array(Nullable(String)) nested size stream exceeds reader limit")
                  end
                  size_data_file.write(size_frame)
                  size_data_hash.update(size_frame)
                  size_raw_hash.update(nested_size_raw)
                  size_data_size += size_frame.size.to_u64
                end

                unless nested_raw.empty?
                  value_frame = encode_lz4_frame(nested_raw)
                  if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                    raise ArgumentError.new("Array(Nullable(String)) nested stream exceeds reader limit")
                  end
                  value_data_file.write(value_frame)
                  value_data_hash.update(value_frame)
                  value_data_size += value_frame.size.to_u64
                end
                value_raw_hash.update(nested_raw)

                if mark_elements > UInt64::MAX - total_nested_elements
                  raise ArgumentError.new("Array(Nullable(String)) nested element count overflows")
                end
                total_nested_elements += mark_elements
                if mark_raw_string_bytes > UInt64::MAX - total_raw_string_bytes
                  raise ArgumentError.new("Array(Nullable(String)) nested byte count overflows")
                end
                total_raw_string_bytes += mark_raw_string_bytes
                start_row += rows
              end
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(size_mark_bytes, size_data_size)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(size_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)

      size0_marks = size0_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      size_marks = size_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, null_marks, size_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, size_marks_name), size_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      size_raw_size = checked_array_element_checksum_size(total_nested_elements, "Array(Nullable(String)) nested size")
      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, total_nested_elements, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(size_data_name, size_data_size, size_data_hash.finish, true, size_raw_size, size_raw_hash.finish),
        ChecksumRecord.new(size_marks_name, size_marks.size.to_u64, CityHashV1.file_hash(size_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, total_raw_string_bytes, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_fixed_string_streams(
      stage : String,
      column : String,
      values : Slice(Array(String)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            size0_raw = Bytes.new(rows * 8, 0_u8)
            mark_elements = 0_u64
            rows.times do |row|
              row_values = values[start_row + row]
              write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
              if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                raise ArgumentError.new("Array(FixedString) nested element count exceeds per-mark limit")
              end
              mark_elements += row_values.size.to_u64
            end

            nested_raw = Bytes.new(checked_array_numeric_bytes(mark_elements, width, "Array(FixedString) nested"), 0_u8)
            nested_offset = 0
            rows.times do |row|
              values[start_row + row].each do |value|
                value_bytes = value.to_slice
                value_bytes.copy_to(nested_raw[nested_offset, value_bytes.size]) unless value_bytes.empty?
                nested_offset += width
              end
            end

            write_uint64_le(size0_mark_bytes, size0_data_size)
            write_uint64_le(size0_mark_bytes, 0_u64)
            write_uint64_le(size0_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            size0_frame = encode_lz4_frame(size0_raw)
            if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
              raise ArgumentError.new("Array size0 stream exceeds reader limit")
            end
            size0_data_file.write(size0_frame)
            size0_data_hash.update(size0_frame)
            size0_raw_hash.update(size0_raw)
            size0_data_size += size0_frame.size.to_u64

            unless nested_raw.empty?
              value_frame = encode_lz4_frame(nested_raw)
              if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                raise ArgumentError.new("Array(FixedString) nested stream exceeds reader limit")
              end
              value_data_file.write(value_frame)
              value_data_hash.update(value_frame)
              value_data_size += value_frame.size.to_u64
            end
            value_raw_hash.update(nested_raw)

            if mark_elements > UInt64::MAX - total_nested_elements
              raise ArgumentError.new("Array(FixedString) nested element count overflows")
            end
            total_nested_elements += mark_elements
            start_row += rows
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if size0_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_numeric_checksum_size(total_nested_elements, width, "Array(FixedString) nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_nullable_fixed_string_streams(
      stage : String,
      column : String,
      values : Slice(Array(String?)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      null_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8, 0_u8)
              mark_elements = 0_u64
              rows.times do |row|
                row_values = values[start_row + row]
                write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
                if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                  raise ArgumentError.new("Array(Nullable(FixedString)) nested element count exceeds per-mark limit")
                end
                mark_elements += row_values.size.to_u64
              end

              null_raw = Bytes.new(mark_elements.to_i, 0_u8)
              nested_raw = Bytes.new(checked_array_numeric_bytes(mark_elements, width, "Array(Nullable(FixedString)) nested"), 0_u8)
              element_offset = 0
              nested_offset = 0
              rows.times do |row|
                values[start_row + row].each do |value|
                  if value.nil?
                    null_raw[element_offset] = 1_u8
                  else
                    value_bytes = value.not_nil!.to_slice
                    value_bytes.copy_to(nested_raw[nested_offset, value_bytes.size]) unless value_bytes.empty?
                  end
                  element_offset += 1
                  nested_offset += width
                end
              end

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(null_mark_bytes, null_data_size)
              write_uint64_le(null_mark_bytes, 0_u64)
              write_uint64_le(null_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless null_raw.empty?
                null_frame = encode_lz4_frame(null_raw)
                if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(FixedString)) null-map stream exceeds reader limit")
                end
                null_data_file.write(null_frame)
                null_data_hash.update(null_frame)
                null_data_size += null_frame.size.to_u64
              end
              null_raw_hash.update(null_raw)

              unless nested_raw.empty?
                value_frame = encode_lz4_frame(nested_raw)
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(FixedString)) nested stream exceeds reader limit")
                end
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              value_raw_hash.update(nested_raw)

              if mark_elements > UInt64::MAX - total_nested_elements
                raise ArgumentError.new("Array(Nullable(FixedString)) nested element count overflows")
              end
              total_nested_elements += mark_elements
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, null_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, total_nested_elements, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_numeric_checksum_size(total_nested_elements, width, "Array(Nullable(FixedString)) nested"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_bool_streams(
      stage : String,
      column : String,
      values : Slice(Array(Bool)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            size0_raw = Bytes.new(rows * 8, 0_u8)
            mark_elements = 0_u64
            rows.times do |row|
              row_values = values[start_row + row]
              write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
              if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                raise ArgumentError.new("Array(Bool) nested element count exceeds per-mark limit")
              end
              mark_elements += row_values.size.to_u64
            end

            value_raw = Bytes.new(mark_elements.to_i, 0_u8)
            element_offset = 0
            rows.times do |row|
              values[start_row + row].each do |value|
                value_raw[element_offset] = value ? 1_u8 : 0_u8
                element_offset += 1
              end
            end

            write_uint64_le(size0_mark_bytes, size0_data_size)
            write_uint64_le(size0_mark_bytes, 0_u64)
            write_uint64_le(size0_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            size0_frame = encode_lz4_frame(size0_raw)
            if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
              raise ArgumentError.new("Array size0 stream exceeds reader limit")
            end
            size0_data_file.write(size0_frame)
            size0_data_hash.update(size0_frame)
            size0_raw_hash.update(size0_raw)
            size0_data_size += size0_frame.size.to_u64

            unless value_raw.empty?
              value_frame = encode_lz4_frame(value_raw)
              if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                raise ArgumentError.new("Array(Bool) child stream exceeds reader limit")
              end
              value_data_file.write(value_frame)
              value_data_hash.update(value_frame)
              value_data_size += value_frame.size.to_u64
            end
            value_raw_hash.update(value_raw)

            if mark_elements > UInt64::MAX - total_nested_elements
              raise ArgumentError.new("Array(Bool) nested element count overflows")
            end
            total_nested_elements += mark_elements
            start_row += rows
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, checked_array_numeric_checksum_size(total_nested_elements, 1, "Array(Bool) child"), value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_array_nullable_bool_streams(
      stage : String,
      column : String,
      values : Slice(Array(Bool?)),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      size0_data_name = "#{size0_base}.bin"
      size0_marks_name = "#{size0_base}.mrk2"
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      size0_data_hash = CityHashV1::FileHasher.new
      size0_raw_hash = CityHashV1::FileHasher.new
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      size0_mark_bytes = IO::Memory.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      size0_data_size = 0_u64
      null_data_size = 0_u64
      value_data_size = 0_u64
      total_nested_elements = 0_u64
      start_row = 0

      File.open(File.join(stage, size0_data_name), "wb") do |size0_data_file|
        File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
          File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              size0_raw = Bytes.new(rows * 8, 0_u8)
              mark_elements = 0_u64
              rows.times do |row|
                row_values = values[start_row + row]
                write_uint64_le(size0_raw, row * 8, row_values.size.to_u64)
                if row_values.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_elements
                  raise ArgumentError.new("Array(Nullable(Bool)) nested element count exceeds per-mark limit")
                end
                mark_elements += row_values.size.to_u64
              end

              null_raw = Bytes.new(mark_elements.to_i, 0_u8)
              value_raw = Bytes.new(mark_elements.to_i, 0_u8)
              element_offset = 0
              rows.times do |row|
                values[start_row + row].each do |value|
                  if value.nil?
                    null_raw[element_offset] = 1_u8
                  else
                    value_raw[element_offset] = value ? 1_u8 : 0_u8
                  end
                  element_offset += 1
                end
              end

              write_uint64_le(size0_mark_bytes, size0_data_size)
              write_uint64_le(size0_mark_bytes, 0_u64)
              write_uint64_le(size0_mark_bytes, rows.to_u64)
              write_uint64_le(null_mark_bytes, null_data_size)
              write_uint64_le(null_mark_bytes, 0_u64)
              write_uint64_le(null_mark_bytes, rows.to_u64)
              write_uint64_le(value_mark_bytes, value_data_size)
              write_uint64_le(value_mark_bytes, 0_u64)
              write_uint64_le(value_mark_bytes, rows.to_u64)

              size0_frame = encode_lz4_frame(size0_raw)
              if size0_data_size > MAX_DATA_FILE_BYTES.to_u64 - size0_frame.size.to_u64
                raise ArgumentError.new("Array size0 stream exceeds reader limit")
              end
              size0_data_file.write(size0_frame)
              size0_data_hash.update(size0_frame)
              size0_raw_hash.update(size0_raw)
              size0_data_size += size0_frame.size.to_u64

              unless null_raw.empty?
                null_frame = encode_lz4_frame(null_raw)
                if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(Bool)) null-map stream exceeds reader limit")
                end
                null_data_file.write(null_frame)
                null_data_hash.update(null_frame)
                null_data_size += null_frame.size.to_u64
              end
              null_raw_hash.update(null_raw)

              unless value_raw.empty?
                value_frame = encode_lz4_frame(value_raw)
                if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
                  raise ArgumentError.new("Array(Nullable(Bool)) child stream exceeds reader limit")
                end
                value_data_file.write(value_frame)
                value_data_hash.update(value_frame)
                value_data_size += value_frame.size.to_u64
              end
              value_raw_hash.update(value_raw)

              if mark_elements > UInt64::MAX - total_nested_elements
                raise ArgumentError.new("Array(Nullable(Bool)) nested element count overflows")
              end
              total_nested_elements += mark_elements
              start_row += rows
            end
          end
        end
      end

      write_uint64_le(size0_mark_bytes, size0_data_size)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(size0_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      size0_marks = size0_mark_bytes.to_slice
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      {size0_marks, null_marks, value_marks}.each do |marks|
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      File.write(File.join(stage, size0_marks_name), size0_marks)
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(size0_data_name, size0_data_size, size0_data_hash.finish, true, checked_array_element_checksum_size(values.size.to_u64, "Array size0"), size0_raw_hash.finish),
        ChecksumRecord.new(size0_marks_name, size0_marks.size.to_u64, CityHashV1.file_hash(size0_marks), false),
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, total_nested_elements, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, total_nested_elements, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.write_map_uint64_string_streams(
      stage : String,
      column : String,
      values : Slice(Array(Tuple(UInt64, String))),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      keys_base = StreamName.hash("#{column}%2Ekeys")
      value_sizes_base = StreamName.hash("#{column}%2Evalues.size")
      value_base = StreamName.hash("#{column}%2Evalues")
      data_names = ["#{size0_base}.bin", "#{keys_base}.bin", "#{value_sizes_base}.bin", "#{value_base}.bin"]
      mark_names = ["#{size0_base}.mrk2", "#{keys_base}.mrk2", "#{value_sizes_base}.mrk2", "#{value_base}.mrk2"]
      data_hashes = Array(CityHashV1::FileHasher).new(4) { CityHashV1::FileHasher.new }
      raw_hashes = Array(CityHashV1::FileHasher).new(4) { CityHashV1::FileHasher.new }
      mark_bytes = Array(IO::Memory).new(4) { IO::Memory.new }
      data_sizes = Array(UInt64).new(4, 0_u64)
      total_entries = 0_u64
      total_value_bytes = 0_u64
      start_row = 0

      files = data_names.map { |name| File.open(File.join(stage, name), "wb") }
      begin
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          size0_raw = Bytes.new(rows * 8)
          mark_entries = 0_u64
          mark_value_bytes = 0_u64
          rows.times do |row|
            entries = values[start_row + row]
            write_uint64_le(size0_raw, row * 8, entries.size.to_u64)
            mark_entries += entries.size.to_u64
            entries.each do |entry|
              mark_value_bytes += entry[1].bytesize.to_u64
            end
          end

          nested_raw_size = (mark_entries * 8_u64).to_i
          keys_raw = Bytes.new(nested_raw_size)
          value_sizes_raw = Bytes.new(nested_raw_size)
          value_raw = Bytes.new(mark_value_bytes.to_i)
          entry_index = 0
          value_offset = 0
          rows.times do |row|
            values[start_row + row].each do |entry|
              write_uint64_le(keys_raw, entry_index * 8, entry[0])
              write_uint64_le(value_sizes_raw, entry_index * 8, entry[1].bytesize.to_u64)
              entry_bytes = entry[1].to_slice
              unless entry_bytes.empty?
                entry_bytes.copy_to(value_raw[value_offset, entry_bytes.size])
                value_offset += entry_bytes.size
              end
              entry_index += 1
            end
          end

          raw_streams = [size0_raw, keys_raw, value_sizes_raw, value_raw]
          raw_streams.each_with_index do |raw, stream_index|
            write_uint64_le(mark_bytes[stream_index], data_sizes[stream_index])
            write_uint64_le(mark_bytes[stream_index], 0_u64)
            write_uint64_le(mark_bytes[stream_index], rows.to_u64)

            unless stream_index > 0 && raw.empty?
              frame = encode_lz4_frame(raw)
              if data_sizes[stream_index] > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
                raise ArgumentError.new("Map data stream exceeds reader limit")
              end
              files[stream_index].write(frame)
              data_hashes[stream_index].update(frame)
              data_sizes[stream_index] += frame.size.to_u64
            end
            raw_hashes[stream_index].update(raw)
          end

          if mark_entries > UInt64::MAX - total_entries
            raise ArgumentError.new("Map entry count overflows")
          end
          total_entries += mark_entries
          if mark_value_bytes > UInt64::MAX - total_value_bytes
            raise ArgumentError.new("Map String byte count overflows")
          end
          total_value_bytes += mark_value_bytes
          start_row += rows
        end
      ensure
        files.each { |file| file.close unless file.closed? }
      end

      mark_bytes.each_with_index do |bytes, stream_index|
        write_uint64_le(bytes, data_sizes[stream_index])
        write_uint64_le(bytes, 0_u64)
        write_uint64_le(bytes, 0_u64)
      end

      marks = mark_bytes.map(&.to_slice)
      marks.each do |bytes|
        raise ArgumentError.new("mark stream exceeds reader limit") if bytes.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      marks.each_with_index do |bytes, stream_index|
        File.write(File.join(stage, mark_names[stream_index]), bytes)
      end

      entry_bytes = checked_array_element_checksum_size(total_entries, "Map entries")
      [
        ChecksumRecord.new(data_names[0], data_sizes[0], data_hashes[0].finish, true, values.size.to_u64 * 8_u64, raw_hashes[0].finish),
        ChecksumRecord.new(mark_names[0], marks[0].size.to_u64, CityHashV1.file_hash(marks[0]), false),
        ChecksumRecord.new(data_names[1], data_sizes[1], data_hashes[1].finish, true, entry_bytes, raw_hashes[1].finish),
        ChecksumRecord.new(mark_names[1], marks[1].size.to_u64, CityHashV1.file_hash(marks[1]), false),
        ChecksumRecord.new(data_names[2], data_sizes[2], data_hashes[2].finish, true, entry_bytes, raw_hashes[2].finish),
        ChecksumRecord.new(mark_names[2], marks[2].size.to_u64, CityHashV1.file_hash(marks[2]), false),
        ChecksumRecord.new(data_names[3], data_sizes[3], data_hashes[3].finish, true, total_value_bytes, raw_hashes[3].finish),
        ChecksumRecord.new(mark_names[3], marks[3].size.to_u64, CityHashV1.file_hash(marks[3]), false),
      ]
    end

    private def self.write_map_uint64_uint64_streams(
      stage : String,
      column : String,
      values : Slice(Array(Tuple(UInt64, UInt64))),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      size0_base = StreamName.hash("#{column}.size0")
      keys_base = StreamName.hash("#{column}%2Ekeys")
      values_base = StreamName.hash("#{column}%2Evalues")
      data_names = ["#{size0_base}.bin", "#{keys_base}.bin", "#{values_base}.bin"]
      mark_names = ["#{size0_base}.mrk2", "#{keys_base}.mrk2", "#{values_base}.mrk2"]
      data_hashes = Array(CityHashV1::FileHasher).new(3) { CityHashV1::FileHasher.new }
      raw_hashes = Array(CityHashV1::FileHasher).new(3) { CityHashV1::FileHasher.new }
      mark_bytes = Array(IO::Memory).new(3) { IO::Memory.new }
      data_sizes = Array(UInt64).new(3, 0_u64)
      total_entries = 0_u64
      start_row = 0

      files = data_names.map { |name| File.open(File.join(stage, name), "wb") }
      begin
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          size0_raw = Bytes.new(rows * 8)
          mark_entries = 0_u64
          rows.times do |row|
            entries = values[start_row + row]
            if entries.size.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS - mark_entries
              raise ArgumentError.new("Map entry count exceeds per-mark limit")
            end
            mark_entries += entries.size.to_u64
            write_uint64_le(size0_raw, row * 8, entries.size.to_u64)
          end

          nested_raw_size = checked_array_element_bytes(mark_entries, "Map entries")
          keys_raw = Bytes.new(nested_raw_size.to_i)
          values_raw = Bytes.new(nested_raw_size.to_i)
          entry_index = 0
          rows.times do |row|
            values[start_row + row].each do |entry|
              write_uint64_le(keys_raw, entry_index * 8, entry[0])
              write_uint64_le(values_raw, entry_index * 8, entry[1])
              entry_index += 1
            end
          end

          raw_streams = [size0_raw, keys_raw, values_raw]
          raw_streams.each_with_index do |raw, stream_index|
            write_uint64_le(mark_bytes[stream_index], data_sizes[stream_index])
            write_uint64_le(mark_bytes[stream_index], 0_u64)
            write_uint64_le(mark_bytes[stream_index], rows.to_u64)

            unless stream_index > 0 && raw.empty?
              frame = encode_lz4_frame(raw)
              if data_sizes[stream_index] > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
                raise ArgumentError.new("Map data stream exceeds reader limit")
              end
              files[stream_index].write(frame)
              data_hashes[stream_index].update(frame)
              data_sizes[stream_index] += frame.size.to_u64
            end
            raw_hashes[stream_index].update(raw)
          end

          if mark_entries > UInt64::MAX - total_entries
            raise ArgumentError.new("Map entry count overflows")
          end
          total_entries += mark_entries
          start_row += rows
        end
      ensure
        files.each { |file| file.close unless file.closed? }
      end

      mark_bytes.each_with_index do |bytes, stream_index|
        write_uint64_le(bytes, data_sizes[stream_index])
        write_uint64_le(bytes, 0_u64)
        write_uint64_le(bytes, 0_u64)
      end

      marks = mark_bytes.map(&.to_slice)
      marks.each do |bytes|
        raise ArgumentError.new("mark stream exceeds reader limit") if bytes.size.to_i64 > MAX_MARK_FILE_BYTES
      end
      marks.each_with_index do |bytes, stream_index|
        File.write(File.join(stage, mark_names[stream_index]), bytes)
      end

      entry_bytes = checked_array_element_checksum_size(total_entries, "Map entries")
      [
        ChecksumRecord.new(data_names[0], data_sizes[0], data_hashes[0].finish, true, values.size.to_u64 * 8_u64, raw_hashes[0].finish),
        ChecksumRecord.new(mark_names[0], marks[0].size.to_u64, CityHashV1.file_hash(marks[0]), false),
        ChecksumRecord.new(data_names[1], data_sizes[1], data_hashes[1].finish, true, entry_bytes, raw_hashes[1].finish),
        ChecksumRecord.new(mark_names[1], marks[1].size.to_u64, CityHashV1.file_hash(marks[1]), false),
        ChecksumRecord.new(data_names[2], data_sizes[2], data_hashes[2].finish, true, entry_bytes, raw_hashes[2].finish),
        ChecksumRecord.new(mark_names[2], marks[2].size.to_u64, CityHashV1.file_hash(marks[2]), false),
      ]
    end

    private def self.write_fixed_string_stream(
      stage : String,
      column : String,
      values : Slice(String),
      width : Int32,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      base_name = StreamName.hash(column)
      data_name = "#{base_name}.bin"
      marks_name = "#{base_name}.mrk2"
      data_path = File.join(stage, data_name)
      mark_path = File.join(stage, marks_name)
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      mark_bytes = IO::Memory.new
      data_size = 0_u64
      start_row = 0

      File.open(data_path, "wb") do |data_file|
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          raw = Bytes.new(rows * width)
          rows.times do |row|
            value_bytes = values[start_row + row].to_slice
            value_offset = row * width
            value_bytes.copy_to(raw[value_offset, value_bytes.size]) unless value_bytes.empty?
          end

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
            raise ArgumentError.new("FixedString data stream exceeds reader limit")
          end
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(mark_path, marks)
      mark_hash = CityHashV1.file_hash(marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64 * width.to_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, mark_hash, false),
      ]
    end

    private def self.write_nullable_fixed_string_streams(
      stage : String,
      column : String,
      values : Slice(String?),
      width : Int32,
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      null_base = StreamName.hash("#{column}.null")
      value_base = StreamName.hash(column)
      null_data_name = "#{null_base}.bin"
      null_marks_name = "#{null_base}.mrk2"
      value_data_name = "#{value_base}.bin"
      value_marks_name = "#{value_base}.mrk2"
      null_data_hash = CityHashV1::FileHasher.new
      null_raw_hash = CityHashV1::FileHasher.new
      value_data_hash = CityHashV1::FileHasher.new
      value_raw_hash = CityHashV1::FileHasher.new
      null_mark_bytes = IO::Memory.new
      value_mark_bytes = IO::Memory.new
      null_data_size = 0_u64
      value_data_size = 0_u64
      start_row = 0

      File.open(File.join(stage, null_data_name), "wb") do |null_data_file|
        File.open(File.join(stage, value_data_name), "wb") do |value_data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            null_raw = Bytes.new(rows)
            value_raw = Bytes.new(rows * width)
            rows.times do |row|
              value = values[start_row + row]
              if value.nil?
                null_raw[row] = 1_u8
              else
                null_raw[row] = 0_u8
                value_bytes = value.to_slice
                value_bytes.copy_to(value_raw[row * width, value_bytes.size]) unless value_bytes.empty?
              end
            end

            write_uint64_le(null_mark_bytes, null_data_size)
            write_uint64_le(null_mark_bytes, 0_u64)
            write_uint64_le(null_mark_bytes, rows.to_u64)
            write_uint64_le(value_mark_bytes, value_data_size)
            write_uint64_le(value_mark_bytes, 0_u64)
            write_uint64_le(value_mark_bytes, rows.to_u64)

            null_frame = encode_lz4_frame(null_raw)
            value_frame = encode_lz4_frame(value_raw)
            raise ArgumentError.new("Nullable null-map stream exceeds reader limit") if null_data_size > MAX_DATA_FILE_BYTES.to_u64 - null_frame.size.to_u64
            raise ArgumentError.new("Nullable FixedString nested stream exceeds reader limit") if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - value_frame.size.to_u64
            null_data_file.write(null_frame)
            null_data_hash.update(null_frame)
            null_raw_hash.update(null_raw)
            null_data_size += null_frame.size.to_u64
            value_data_file.write(value_frame)
            value_data_hash.update(value_frame)
            value_raw_hash.update(value_raw)
            value_data_size += value_frame.size.to_u64
            start_row += rows
          end
        end
      end

      write_uint64_le(null_mark_bytes, null_data_size)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(null_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, value_data_size)
      write_uint64_le(value_mark_bytes, 0_u64)
      write_uint64_le(value_mark_bytes, 0_u64)
      null_marks = null_mark_bytes.to_slice
      value_marks = value_mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if null_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(File.join(stage, null_marks_name), null_marks)
      File.write(File.join(stage, value_marks_name), value_marks)

      [
        ChecksumRecord.new(null_data_name, null_data_size, null_data_hash.finish, true, values.size.to_u64, null_raw_hash.finish),
        ChecksumRecord.new(null_marks_name, null_marks.size.to_u64, CityHashV1.file_hash(null_marks), false),
        ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, values.size.to_u64 * width.to_u64, value_raw_hash.finish),
        ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
      ]
    end

    private def self.typed_string_value(value : T) : String forall T
      {% if T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
        value || ""
      {% elsif T == String %}
        value
      {% else %}
        raise UnsupportedFormatError.new("String stream requires String or Nullable(String) values")
      {% end %}
    end

    private def self.write_nullable_string_streams(
      stage : String,
      column : String,
      values : Slice(String?),
      rows_per_mark : Int32,
    ) : Array(ChecksumRecord)
      null_base = StreamName.hash("#{column}.null")
      data_name = "#{null_base}.bin"
      marks_name = "#{null_base}.mrk2"
      data_path = File.join(stage, data_name)
      mark_path = File.join(stage, marks_name)
      data_hash = CityHashV1::FileHasher.new
      raw_hash = CityHashV1::FileHasher.new
      mark_bytes = IO::Memory.new
      data_size = 0_u64
      start_row = 0

      File.open(data_path, "wb") do |data_file|
        while start_row < values.size
          rows = {rows_per_mark, values.size - start_row}.min
          raw = Bytes.new(rows)
          rows.times do |row|
            raw[row] = values[start_row + row].nil? ? 1_u8 : 0_u8
          end

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          raise ArgumentError.new("Nullable(String) null-map exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("Nullable(String) null-map marks exceed reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(mark_path, marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
      ] + write_string_streams(stage, column, values, rows_per_mark)
    end

    private def self.write_primary_index(stage : String, keys : Slice(UInt64), rows_per_mark : Int32) : ChecksumRecord
      bytes = IO::Memory.new
      row = 0
      while row < keys.size
        write_uint64_le(bytes, keys[row])
        row += rows_per_mark
      end
      write_uint64_le(bytes, keys.last)
      raw = bytes.to_slice
      raise ArgumentError.new("primary index exceeds reader limit") if raw.size.to_i64 > MAX_PRIMARY_INDEX_BYTES
      File.write(File.join(stage, "primary.idx"), raw)
      ChecksumRecord.new("primary.idx", raw.size.to_u64, CityHashV1.file_hash(raw), false)
    end

    private def self.write_checksummed_file(stage : String, name : String, content : String) : ChecksumRecord
      File.write(File.join(stage, name), content)
      bytes = content.to_slice
      ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
    end

    private def self.write_plain_metadata(stage : String, name : String, content : String) : Nil
      File.write(File.join(stage, name), content)
      nil
    end

    private def self.write_checksums(stage : String, records : Array(ChecksumRecord)) : Nil
      sorted_records = records.sort_by(&.name)
      payload = IO::Memory.new
      write_var_uint(payload, sorted_records.size.to_u64)
      sorted_records.each do |record|
        name = record.name.to_slice
        write_var_uint(payload, name.size.to_u64)
        payload.write(name)
        write_var_uint(payload, record.physical_size)
        write_hash128_le(payload, record.file_hash)
        if record.compressed
          payload.write_byte(1_u8)
          write_var_uint(payload, record.uncompressed_size || raise "compressed checksum has no raw size")
          write_hash128_le(payload, record.uncompressed_hash || raise "compressed checksum has no raw hash")
        else
          payload.write_byte(0_u8)
        end
      end

      frame = encode_lz4_frame(payload.to_slice)
      File.open(File.join(stage, "checksums.txt"), "wb") do |file|
        file << PartChecksums::CHECKSUMS_HEADER
        file.write(frame)
      end
    end

    private def self.validate_staged_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(UInt64),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged value row count does not match") unless value_part.row_count == values.size.to_u64
      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, expected_mark_rows.size - 1, 1)
        expected_values = value_part.read_uint64_mark_range(value_name, expected_mark_rows.size - 1, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged UInt64 stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged value marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.validate_staged_nullable_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(UInt64?),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Nullable(UInt64) row count does not match") unless value_part.row_count == values.size.to_u64
      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, expected_mark_rows.size - 1, 1)
        expected_values = value_part.read_nullable_numeric_mark_range(value_name, expected_mark_rows.size - 1, 1, UInt64)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Nullable(UInt64) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Nullable(UInt64) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.validate_staged_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(String),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged String row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged String column type does not match") unless value_part.column_type == "String"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        expected_mark_rows << rows.to_u64
        mark_index = expected_mark_rows.size - 1
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged String stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged String marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.validate_staged_tuple_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      unless File.read(File.join(stage, "columns.txt")) == tuple_string_columns_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Tuple columns metadata differs")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == tuple_string_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Tuple substream metadata differs")
      end
      unless File.read(File.join(stage, "serialization.json")) == tuple_string_serialization_metadata(key_name, value_name, keys, values)
        raise CorruptPartError.new("staged Tuple serialization metadata differs")
      end
      raise CorruptPartError.new("staged row count differs") unless File.read(File.join(stage, "count.txt")) == keys.size.to_s
      raise CorruptPartError.new("staged compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index

      streams = [] of Tuple(String, File, File, UInt64)
      begin
        {key_name, "#{value_name}%2Ea", "#{value_name}%2Eb.size", "#{value_name}%2Eb"}.each do |logical_name|
          base = StreamName.hash(logical_name)
          data = File.open(File.join(stage, "#{base}.bin"), "r")
          marks = File.open(File.join(stage, "#{base}.mrk2"), "r")
          streams << {logical_name, data, marks, 0_u64}
        end

        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          key_raw = Bytes.new(rows * 8)
          a_raw = Bytes.new(rows * 8)
          size_raw = Bytes.new(rows * 8)
          b_raw = IO::Memory.new
          rows.times do |offset|
            value = values[start + offset]
            write_uint64_le(key_raw, offset * 8, keys[start + offset])
            write_uint64_le(a_raw, offset * 8, value[0])
            write_uint64_le(size_raw, offset * 8, value[1].bytesize.to_u64)
            b_raw.write(value[1].to_slice)
          end
          raw_marks = [key_raw, a_raw, size_raw, b_raw.to_slice]
          streams.each_with_index do |stream, stream_index|
            new_offset = validate_staged_tuple_mark(
              stream[1], stream[2], stream[0], stream[3], rows.to_u64,
              raw_marks[stream_index], omit_empty_frame: stream_index == 3
            )
            streams[stream_index] = {stream[0], stream[1], stream[2], new_offset}
          end
          start += rows
        end

        streams.each do |stream|
          validate_staged_tuple_sentinel(stream[1], stream[2], stream[0], stream[3])
        end
      ensure
        streams.each do |stream|
          stream[1].close unless stream[1].closed?
          stream[2].close unless stream[2].closed?
        end
      end
      nil
    end

    private def self.validate_staged_tuple_mark(
      data_file : File,
      marks_file : File,
      logical_name : String,
      expected_offset : UInt64,
      expected_rows : UInt64,
      expected_raw : Bytes,
      omit_empty_frame : Bool = false,
    ) : UInt64
      mark = Bytes.new(WidePart::MARK_SIZE)
      marks_file.read_fully(mark)
      raise CorruptPartError.new("staged Tuple mark offset differs for #{logical_name}") unless read_uint64_le(mark, 0) == expected_offset
      raise CorruptPartError.new("staged Tuple decompressed mark offset differs for #{logical_name}") unless read_uint64_le(mark, 8) == 0_u64
      raise CorruptPartError.new("staged Tuple mark row count differs for #{logical_name}") unless read_uint64_le(mark, 16) == expected_rows

      return expected_offset if omit_empty_frame && expected_raw.empty?

      data_file.seek(expected_offset.to_i64)
      header = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE)
      data_file.read_fully(header)
      compressed_size = read_uint32_le(header, CompressedBlock::CHECKSUM_SIZE + 1).to_i64
      frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      unless frame_size >= CompressedBlock::FRAME_HEADER_SIZE && frame_size <= MAX_FRAME_COMPRESSED.to_i64
        raise CorruptPartError.new("staged Tuple frame size is invalid for #{logical_name}")
      end
      frame_bytes = Bytes.new(frame_size.to_i)
      header.copy_to(frame_bytes)
      remaining = frame_bytes.size - header.size
      data_file.read_fully(frame_bytes[header.size, remaining])
      frame = CompressedBlock.decode_frame(frame_bytes, 0_i64, MAX_FRAME_COMPRESSED.to_i64, MAX_FRAME_RAW_BYTES.to_i64)
      unless frame.end_offset == frame_size && frame.output == expected_raw
        raise CorruptPartError.new("staged Tuple stream readback differs for #{logical_name}")
      end
      expected_offset + frame.end_offset.to_u64
    end

    private def self.validate_staged_tuple_sentinel(
      data_file : File,
      marks_file : File,
      logical_name : String,
      expected_offset : UInt64,
    ) : Nil
      sentinel = Bytes.new(WidePart::MARK_SIZE)
      marks_file.read_fully(sentinel)
      raise CorruptPartError.new("staged Tuple sentinel offset differs for #{logical_name}") unless read_uint64_le(sentinel, 0) == expected_offset
      unless read_uint64_le(sentinel, 8) == 0_u64 && read_uint64_le(sentinel, 16) == 0_u64
        raise CorruptPartError.new("staged Tuple sentinel differs for #{logical_name}")
      end
      raise CorruptPartError.new("staged Tuple mark stream has trailing bytes for #{logical_name}") unless marks_file.gets_to_end.empty?
      raise CorruptPartError.new("staged Tuple data stream has trailing bytes for #{logical_name}") unless data_file.size == expected_offset
      nil
    end

    private def self.validate_staged_json_typed_part(
      stage : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Array(Tuple(UInt64, String)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [
        key_name,
        "#{value_name}.object_structure",
        "#{value_name}.a",
        "#{value_name}.b.size",
        "#{value_name}.b",
        "#{value_name}.object_shared_data.0.size0",
        "#{value_name}.object_shared_data.0%2Epaths",
        "#{value_name}.object_shared_data.0%2Evalues",
      ]
      expected_checksums = [] of String
      logical_streams.each do |logical_name|
        base_name = StreamName.hash(logical_name)
        expected_checksums << "#{base_name}.bin"
        expected_checksums << "#{base_name}.mrk2"
      end
      expected_checksums.concat(["primary.idx", "count.txt", "serialization.json"])
      unless expected_checksums.uniq.size == expected_checksums.size &&
             checksums.entries.keys.sort == expected_checksums.sort
        raise CorruptPartError.new("staged JSON checksum entries do not match the expected stream inventory")
      end

      expected_files = expected_checksums + [
        "checksums.txt",
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
      ]
      unless Dir.children(stage).sort == expected_files.sort
        raise CorruptPartError.new("staged JSON file inventory differs from the expected part layout")
      end

      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      raise CorruptPartError.new("staged JSON columns metadata differs") unless File.read(File.join(stage, "columns.txt")) == json_typed_columns_metadata(key_name, value_name)
      raise CorruptPartError.new("staged JSON substream metadata differs") unless File.read(File.join(stage, "columns_substreams.txt")) == json_typed_substreams_metadata(key_name, value_name)
      raise CorruptPartError.new("staged JSON serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == json_typed_serialization_metadata(key_name, keys)
      raise CorruptPartError.new("staged JSON row count differs") unless File.read(File.join(stage, "count.txt")) == keys.size.to_s
      raise CorruptPartError.new("staged JSON compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged JSON metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      raise CorruptPartError.new("staged JSON primary index differs from input") unless index.keys == expected_index

      validate_staged_json_data_stream(stage, key_name, keys, values, :key, rows_per_mark)
      validate_staged_json_data_stream(stage, "#{value_name}.a", keys, values, :a, rows_per_mark)
      validate_staged_json_data_stream(stage, "#{value_name}.b.size", keys, values, :b_size, rows_per_mark)
      validate_staged_json_data_stream(stage, "#{value_name}.b", keys, values, :b, rows_per_mark)
      validate_staged_json_data_stream(
        stage,
        "#{value_name}.object_shared_data.0.size0",
        keys,
        values,
        :shared_size0,
        rows_per_mark
      )
      validate_staged_json_object_structure(stage, value_name, keys.size, rows_per_mark)
      validate_staged_json_empty_stream(stage, "#{value_name}.object_shared_data.0%2Epaths", keys.size, rows_per_mark)
      validate_staged_json_empty_stream(stage, "#{value_name}.object_shared_data.0%2Evalues", keys.size, rows_per_mark)
      nil
    end

    private def self.validate_staged_json_data_stream(
      stage : String,
      logical_name : String,
      keys : Slice(UInt64),
      values : Array(Tuple(UInt64, String)),
      kind : Symbol,
      rows_per_mark : Int32,
    ) : Nil
      base_name = StreamName.hash(logical_name)
      data_file = File.open(File.join(stage, "#{base_name}.bin"), "r")
      marks_file = File.open(File.join(stage, "#{base_name}.mrk2"), "r")
      expected_mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_mark_file_size = (expected_mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      unless marks_file.size == expected_mark_file_size
        data_file.close
        marks_file.close
        raise CorruptPartError.new("staged JSON mark file size differs for #{logical_name}")
      end

      compressed_offset = 0_u64
      start_row = 0
      begin
        while start_row < keys.size
          rows = {rows_per_mark, keys.size - start_row}.min
          expected_raw = json_typed_raw_mark(keys, values, start_row, rows, kind)
          mark = Bytes.new(WidePart::MARK_SIZE)
          marks_file.read_fully(mark)
          unless read_uint64_le(mark, 0) == compressed_offset
            raise CorruptPartError.new("staged JSON mark offset differs for #{logical_name}")
          end
          unless read_uint64_le(mark, 8) == 0_u64
            raise CorruptPartError.new("staged JSON decompressed mark offset differs for #{logical_name}")
          end
          unless read_uint64_le(mark, 16) == rows.to_u64
            raise CorruptPartError.new("staged JSON mark row count differs for #{logical_name}")
          end

          unless expected_raw.empty?
            compressed_offset = validate_staged_json_frame(data_file, logical_name, compressed_offset, expected_raw)
          end
          start_row += rows
        end

        sentinel = Bytes.new(WidePart::MARK_SIZE)
        marks_file.read_fully(sentinel)
        unless read_uint64_le(sentinel, 0) == compressed_offset &&
               read_uint64_le(sentinel, 8) == 0_u64 &&
               read_uint64_le(sentinel, 16) == 0_u64
          raise CorruptPartError.new("staged JSON sentinel differs for #{logical_name}")
        end
        raise CorruptPartError.new("staged JSON mark stream has trailing bytes for #{logical_name}") unless marks_file.gets_to_end.empty?
        raise CorruptPartError.new("staged JSON data stream has trailing bytes for #{logical_name}") unless data_file.size == compressed_offset
      ensure
        data_file.close unless data_file.closed?
        marks_file.close unless marks_file.closed?
      end
      nil
    end

    private def self.json_typed_raw_mark(
      keys : Slice(UInt64),
      values : Array(Tuple(UInt64, String)),
      start_row : Int,
      rows : Int,
      kind : Symbol,
    ) : Bytes
      return Bytes.new(rows * 8, 0_u8) if kind == :shared_size0

      if kind == :b
        byte_size = 0
        rows.times { |offset| byte_size += values[start_row + offset][1].bytesize }
        raw = Bytes.new(byte_size)
        cursor = 0
        rows.times do |offset|
          string = values[start_row + offset][1]
          size = string.bytesize
          string.to_slice.copy_to(raw[cursor, size]) if size > 0
          cursor += size
        end
        return raw
      end

      raw = Bytes.new(rows * 8)
      rows.times do |offset|
        row = start_row + offset
        value = case kind
                when :key    then keys[row]
                when :a      then values[row][0]
                when :b_size then values[row][1].bytesize.to_u64
                else              raise CorruptPartError.new("unknown staged JSON stream kind")
                end
        write_uint64_le(raw, offset * 8, value)
      end
      raw
    end

    private def self.validate_staged_json_object_structure(
      stage : String,
      column : String,
      row_count : Int,
      rows_per_mark : Int32,
    ) : Nil
      base_name = StreamName.hash("#{column}.object_structure")
      data_file = File.open(File.join(stage, "#{base_name}.bin"), "r")
      marks_file = File.open(File.join(stage, "#{base_name}.mrk2"), "r")
      raw = json_object_structure_bytes
      expected_mark_count = checked_mark_count(row_count, rows_per_mark)
      expected_mark_file_size = (expected_mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      unless marks_file.size == expected_mark_file_size
        data_file.close
        marks_file.close
        raise CorruptPartError.new("staged JSON structure mark file size differs")
      end

      begin
        expected_frame_end = validate_staged_json_frame(data_file, "object_structure", 0_u64, raw).to_i64
        raise CorruptPartError.new("staged JSON structure stream has trailing bytes") unless data_file.size == expected_frame_end

        start_row = 0
        while start_row < row_count
          rows = {rows_per_mark, row_count - start_row}.min
          mark = Bytes.new(WidePart::MARK_SIZE)
          marks_file.read_fully(mark)
          unless read_uint64_le(mark, 0) == 0_u64 &&
                 read_uint64_le(mark, 8) == 11_u64 &&
                 read_uint64_le(mark, 16) == rows.to_u64
            raise CorruptPartError.new("staged JSON structure mark differs")
          end
          start_row += rows
        end

        sentinel = Bytes.new(WidePart::MARK_SIZE)
        marks_file.read_fully(sentinel)
        unless read_uint64_le(sentinel, 0) == 0_u64 &&
               read_uint64_le(sentinel, 8) == raw.size.to_u64 &&
               read_uint64_le(sentinel, 16) == 0_u64
          raise CorruptPartError.new("staged JSON structure sentinel differs")
        end
        raise CorruptPartError.new("staged JSON structure marks have trailing bytes") unless marks_file.gets_to_end.empty?
      ensure
        data_file.close unless data_file.closed?
        marks_file.close unless marks_file.closed?
      end
      nil
    end

    private def self.validate_staged_json_empty_stream(
      stage : String,
      logical_name : String,
      row_count : Int,
      rows_per_mark : Int32,
    ) : Nil
      base_name = StreamName.hash(logical_name)
      data_file = File.open(File.join(stage, "#{base_name}.bin"), "r")
      marks_file = File.open(File.join(stage, "#{base_name}.mrk2"), "r")
      expected_mark_count = checked_mark_count(row_count, rows_per_mark)
      expected_mark_file_size = (expected_mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      begin
        raise CorruptPartError.new("staged JSON shared stream is not empty for #{logical_name}") unless data_file.size == 0
        raise CorruptPartError.new("staged JSON shared mark file size differs for #{logical_name}") unless marks_file.size == expected_mark_file_size

        start_row = 0
        while start_row < row_count
          rows = {rows_per_mark, row_count - start_row}.min
          mark = Bytes.new(WidePart::MARK_SIZE)
          marks_file.read_fully(mark)
          unless read_uint64_le(mark, 0) == 0_u64 &&
                 read_uint64_le(mark, 8) == 0_u64 &&
                 read_uint64_le(mark, 16) == rows.to_u64
            raise CorruptPartError.new("staged JSON shared mark differs for #{logical_name}")
          end
          start_row += rows
        end

        sentinel = Bytes.new(WidePart::MARK_SIZE)
        marks_file.read_fully(sentinel)
        unless read_uint64_le(sentinel, 0) == 0_u64 &&
               read_uint64_le(sentinel, 8) == 0_u64 &&
               read_uint64_le(sentinel, 16) == 0_u64
          raise CorruptPartError.new("staged JSON shared sentinel differs for #{logical_name}")
        end
        raise CorruptPartError.new("staged JSON shared marks have trailing bytes for #{logical_name}") unless marks_file.gets_to_end.empty?
      ensure
        data_file.close unless data_file.closed?
        marks_file.close unless marks_file.closed?
      end
      nil
    end

    private def self.validate_staged_json_frame(
      data_file : File,
      logical_name : String,
      expected_offset : UInt64,
      expected_raw : Bytes,
    ) : UInt64
      data_file.seek(expected_offset.to_i64)
      header = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE)
      begin
        data_file.read_fully(header)
      rescue ex : IO::EOFError
        raise CorruptPartError.new("staged JSON frame header is truncated for #{logical_name}")
      end
      compressed_size = read_uint32_le(header, CompressedBlock::CHECKSUM_SIZE + 1).to_i64
      frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      if frame_size < CompressedBlock::FRAME_HEADER_SIZE || frame_size > MAX_FRAME_COMPRESSED.to_i64 ||
         expected_offset.to_i64 > data_file.size - frame_size
        raise CorruptPartError.new("staged JSON frame size is invalid for #{logical_name}")
      end
      frame_bytes = Bytes.new(frame_size.to_i)
      header.copy_to(frame_bytes)
      remaining = frame_bytes.size - header.size
      begin
        data_file.read_fully(frame_bytes[header.size, remaining]) if remaining > 0
      rescue ex : IO::EOFError
        raise CorruptPartError.new("staged JSON frame is truncated for #{logical_name}")
      end
      frame = CompressedBlock.decode_frame(
        frame_bytes,
        0_i64,
        MAX_FRAME_COMPRESSED.to_i64,
        MAX_FRAME_RAW_BYTES.to_i64
      )
      unless frame.end_offset == frame_size && frame.output == expected_raw
        raise CorruptPartError.new("staged JSON stream bytes differ for #{logical_name}")
      end
      expected_offset + frame.end_offset.to_u64
    end

    private def self.validate_staged_low_cardinality_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(String),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged LowCardinality(String) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged LowCardinality(String) type does not match") unless value_part.column_type == "LowCardinality(String)"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_low_cardinality_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged LowCardinality(String) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged LowCardinality(String) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_numeric_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(T)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Nil forall T
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array numeric row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array numeric type does not match") unless value_part.column_type == "Array(#{type_name})"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_numeric_mark_range(value_name, mark_index, 1, T)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && numeric_array_rows_identical?(expected_values[offset], values[start + offset])
            raise CorruptPartError.new("staged Array numeric stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array numeric marks do not match") unless value_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array numeric substream metadata differs") unless File.read(File.join(stage, "columns_substreams.txt")) == array_uint64_substreams_metadata(key_name, value_name)
      raise CorruptPartError.new("staged Array numeric serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.numeric_array_rows_identical?(left : Array(T), right : Array(T)) : Bool forall T
      return false unless left.size == right.size
      left.each_with_index do |value, index|
        other = right[index]
        {% if T == Float32 %}
          return false unless value.unsafe_as(UInt32) == other.unsafe_as(UInt32)
        {% elsif T == Float64 %}
          return false unless value.unsafe_as(UInt64) == other.unsafe_as(UInt64)
        {% else %}
          return false unless value == other
        {% end %}
      end
      true
    end

    private def self.validate_staged_array_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(UInt64)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(UInt64) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(UInt64) column type does not match") unless value_part.column_type == "Array(UInt64)"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_uint64_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(UInt64) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(UInt64) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_array_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Array(UInt64))),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Array(UInt64)) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Array(UInt64)) column type does not match") unless value_part.column_type == "Array(Array(UInt64))"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_array_uint64_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Array(UInt64)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Array(UInt64)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_array_nullable_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Array(UInt64?))),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_array_nullable_uint64_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Array(Nullable(UInt64))) substream metadata differs")
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Array(Nullable(UInt64))) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Array(Nullable(UInt64))) column type does not match") unless value_part.column_type == "Array(Array(Nullable(UInt64)))"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_array_nullable_uint64_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Array(Nullable(UInt64))) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Array(Nullable(UInt64))) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_nullable_numeric_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(T?)),
      rows_per_mark : Int32,
      type_name : String,
    ) : Nil forall T
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      expected_type = "Array(Nullable(#{type_name}))"
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(T)) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(T)) column type does not match") unless value_part.column_type == expected_type
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_nullable_numeric_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Nullable(T)) substream metadata does not match")
      end

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_nullable_numeric_mark_range(value_name, mark_index, 1, T)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && nullable_numeric_array_rows_identical?(expected_values[offset], values[start + offset])
            raise CorruptPartError.new("staged Array(Nullable(T)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(T)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(T)) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.nullable_numeric_array_rows_identical?(left : Array(T?), right : Array(T?)) : Bool forall T
      return false unless left.size == right.size
      left.each_with_index do |value, index|
        return false unless typed_nullable_numeric_value_equal?(value, right[index])
      end
      true
    end

    private def self.validate_staged_array_nullable_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(UInt64?)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(UInt64)) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(UInt64)) column type does not match") unless value_part.column_type == "Array(Nullable(UInt64))"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_nullable_uint64_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Nullable(UInt64)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(UInt64)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(String)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(String) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(String) column type does not match") unless value_part.column_type == "Array(String)"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(String) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(String) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_nullable_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(String?)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [
        key_name,
        "#{value_name}.size0",
        "#{value_name}.null",
        "#{value_name}.size",
        value_name,
      ]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Array(Nullable(String)) checksum inventory differs")
      end
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(String)) row count does not match") unless value_part.row_count == values.size.to_u64
      unless value_part.column_type == "Array(Nullable(String))"
        raise CorruptPartError.new("staged Array(Nullable(String)) column type does not match")
      end
      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Array(Nullable(String))")
        raise CorruptPartError.new("staged Array(Nullable(String)) column metadata does not match")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_nullable_string_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Nullable(String)) substream metadata does not match")
      end
      raise CorruptPartError.new("staged Array(Nullable(String)) codec metadata does not match") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Array(Nullable(String)) metadata version does not match") unless File.read(File.join(stage, "metadata_version.txt")) == "0"
      raise CorruptPartError.new("staged Array(Nullable(String)) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_array_nullable_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Nullable(String)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(String)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_fixed_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(String)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [key_name, "#{value_name}.size0", value_name]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Array(FixedString) checksum inventory differs")
      end
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(FixedString) row count does not match") unless value_part.row_count == values.size.to_u64
      unless value_part.column_type == "Array(FixedString(#{width}))"
        raise CorruptPartError.new("staged Array(FixedString) column type does not match")
      end
      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Array(FixedString(#{width}))")
        raise CorruptPartError.new("staged Array(FixedString) column metadata does not match")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_fixed_string_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(FixedString) substream metadata does not match")
      end
      raise CorruptPartError.new("staged Array(FixedString) codec metadata does not match") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Array(FixedString) metadata version does not match") unless File.read(File.join(stage, "metadata_version.txt")) == "0"
      raise CorruptPartError.new("staged Array(FixedString) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        observed_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        observed_values = value_part.read_array_fixed_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless observed_keys[offset] == keys[start + offset] &&
                 fixed_string_array_row_identical?(observed_values[offset], values[start + offset], width)
            raise CorruptPartError.new("staged Array(FixedString) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(FixedString) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_nullable_fixed_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(String?)),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [key_name, "#{value_name}.size0", "#{value_name}.null", value_name]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Array(Nullable(FixedString)) checksum inventory differs")
      end
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(FixedString)) row count does not match") unless value_part.row_count == values.size.to_u64
      unless value_part.column_type == "Array(Nullable(FixedString(#{width})))"
        raise CorruptPartError.new("staged Array(Nullable(FixedString)) column type does not match")
      end
      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Array(Nullable(FixedString(#{width})))")
        raise CorruptPartError.new("staged Array(Nullable(FixedString)) column metadata does not match")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_nullable_fixed_string_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Nullable(FixedString)) substream metadata does not match")
      end
      raise CorruptPartError.new("staged Array(Nullable(FixedString)) codec metadata does not match") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Array(Nullable(FixedString)) metadata version does not match") unless File.read(File.join(stage, "metadata_version.txt")) == "0"
      raise CorruptPartError.new("staged Array(Nullable(FixedString)) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        observed_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        observed_values = value_part.read_array_nullable_fixed_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless observed_keys[offset] == keys[start + offset] &&
                 nullable_fixed_string_array_row_identical?(observed_values[offset], values[start + offset], width)
            raise CorruptPartError.new("staged Array(Nullable(FixedString)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(FixedString)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_bool_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Bool)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [key_name, "#{value_name}.size0", value_name]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Array(Bool) checksum inventory differs")
      end
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Bool) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Bool) column type does not match") unless value_part.column_type == "Array(Bool)"
      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Array(Bool)")
        raise CorruptPartError.new("staged Array(Bool) column metadata does not match")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_bool_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Bool) substream metadata does not match")
      end
      raise CorruptPartError.new("staged Array(Bool) codec metadata does not match") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Array(Bool) metadata version does not match") unless File.read(File.join(stage, "metadata_version.txt")) == "0"
      raise CorruptPartError.new("staged Array(Bool) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        observed_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        observed_values = value_part.read_array_bool_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless observed_keys[offset] == keys[start + offset] && observed_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Bool) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Bool) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_array_nullable_bool_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Bool?)),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [key_name, "#{value_name}.size0", "#{value_name}.null", value_name]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Array(Nullable(Bool)) checksum inventory differs")
      end
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(Bool)) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Array(Nullable(Bool)) column type does not match") unless value_part.column_type == "Array(Nullable(Bool))"
      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Array(Nullable(Bool))")
        raise CorruptPartError.new("staged Array(Nullable(Bool)) column metadata does not match")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == array_nullable_bool_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array(Nullable(Bool)) substream metadata does not match")
      end
      raise CorruptPartError.new("staged Array(Nullable(Bool)) codec metadata does not match") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Array(Nullable(Bool)) metadata version does not match") unless File.read(File.join(stage, "metadata_version.txt")) == "0"
      raise CorruptPartError.new("staged Array(Nullable(Bool)) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == serialization_metadata

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        observed_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        observed_values = value_part.read_array_nullable_bool_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless observed_keys[offset] == keys[start + offset] && observed_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Array(Nullable(Bool)) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Array(Nullable(Bool)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.fixed_string_array_row_identical?(
      observed : Array(String),
      input : Array(String),
      width : Int32,
    ) : Bool
      return false unless observed.size == input.size
      observed.each_with_index do |value, index|
        return false unless fixed_string_value_identical?(value, input[index], width)
      end
      true
    end

    private def self.nullable_fixed_string_array_row_identical?(
      observed : Array(String?),
      input : Array(String?),
      width : Int32,
    ) : Bool
      return false unless observed.size == input.size
      observed.each_with_index do |value, index|
        expected = input[index]
        if expected.nil?
          return false unless value.nil?
        else
          return false if value.nil?
          return false unless fixed_string_value_identical?(value.not_nil!, expected.not_nil!, width)
        end
      end
      true
    end

    private def self.fixed_string_value_identical?(observed : String, input : String, width : Int32) : Bool
      return false unless observed.bytesize == width && input.bytesize <= width
      observed_bytes = observed.to_slice
      input_bytes = input.to_slice
      width.times do |byte_index|
        expected_byte = byte_index < input_bytes.size ? input_bytes[byte_index] : 0_u8
        return false unless observed_bytes[byte_index] == expected_byte
      end
      true
    end

    private def self.validate_staged_map_uint64_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Tuple(UInt64, String))),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [
        key_name,
        "#{value_name}.size0",
        "#{value_name}%2Ekeys",
        "#{value_name}%2Evalues.size",
        "#{value_name}%2Evalues",
      ]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Map checksum inventory differs")
      end
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Map(UInt64, String)")
        raise CorruptPartError.new("staged Map columns metadata differs")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == map_uint64_string_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Map substream metadata differs")
      end
      unless File.read(File.join(stage, "serialization.json")) == serialization_metadata
        raise CorruptPartError.new("staged Map serialization metadata differs")
      end
      raise CorruptPartError.new("staged Map row count differs") unless File.read(File.join(stage, "count.txt")) == keys.size.to_s
      raise CorruptPartError.new("staged Map compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Map metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

      expected_files = expected_checksum_files + [
        "checksums.txt",
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
      ]
      unless Dir.children(stage).sort == expected_files.sort
        raise CorruptPartError.new("staged Map file inventory differs")
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      raise CorruptPartError.new("staged Map primary index differs from input") unless index.keys == expected_index

      streams = [] of Tuple(String, File, File, UInt64)
      begin
        logical_streams.each do |logical_name|
          base = StreamName.hash(logical_name)
          data = File.open(File.join(stage, "#{base}.bin"), "r")
          marks = File.open(File.join(stage, "#{base}.mrk2"), "r")
          streams << {logical_name, data, marks, 0_u64}
        end

        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          key_raw = Bytes.new(rows * 8)
          size0_raw = Bytes.new(rows * 8)
          entry_count = 0
          string_raw = IO::Memory.new
          rows.times do |offset|
            row_entries = values[start + offset]
            write_uint64_le(key_raw, offset * 8, keys[start + offset])
            write_uint64_le(size0_raw, offset * 8, row_entries.size.to_u64)
            entry_count += row_entries.size
            row_entries.each do |entry|
              string_raw.write(entry[1].to_slice)
            end
          end
          map_keys_raw = Bytes.new(entry_count * 8)
          value_sizes_raw = Bytes.new(entry_count * 8)
          entry_offset = 0
          rows.times do |offset|
            values[start + offset].each do |entry|
              write_uint64_le(map_keys_raw, entry_offset * 8, entry[0])
              write_uint64_le(value_sizes_raw, entry_offset * 8, entry[1].bytesize.to_u64)
              entry_offset += 1
            end
          end

          expected_raw_streams = [key_raw, size0_raw, map_keys_raw, value_sizes_raw, string_raw.to_slice]
          streams.each_with_index do |stream, stream_index|
            next_offset = validate_staged_map_mark(
              stream[1], stream[2], stream[0], stream[3], rows.to_u64,
              expected_raw_streams[stream_index], omit_empty_frame: stream_index >= 2 && expected_raw_streams[stream_index].empty?
            )
            streams[stream_index] = {stream[0], stream[1], stream[2], next_offset}
          end
          start += rows
        end

        streams.each do |stream|
          validate_staged_map_sentinel(stream[1], stream[2], stream[0], stream[3])
        end
      ensure
        streams.each do |stream|
          stream[1].close unless stream[1].closed?
          stream[2].close unless stream[2].closed?
        end
      end
      nil
    end

    private def self.validate_staged_map_uint64_uint64_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(Array(Tuple(UInt64, UInt64))),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      logical_streams = [key_name, "#{value_name}.size0", "#{value_name}%2Ekeys", "#{value_name}%2Evalues"]
      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      logical_streams.each do |logical_name|
        base = StreamName.hash(logical_name)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      unless checksums.entries.keys.sort == expected_checksum_files.sort
        raise CorruptPartError.new("staged Map checksum inventory differs")
      end
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      unless File.read(File.join(stage, "columns.txt")) == typed_columns_metadata(key_name, value_name, "Map(UInt64, UInt64)")
        raise CorruptPartError.new("staged Map columns metadata differs")
      end
      unless File.read(File.join(stage, "columns_substreams.txt")) == map_uint64_uint64_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Map substream metadata differs")
      end
      unless File.read(File.join(stage, "serialization.json")) == serialization_metadata
        raise CorruptPartError.new("staged Map serialization metadata differs")
      end
      raise CorruptPartError.new("staged Map row count differs") unless File.read(File.join(stage, "count.txt")) == keys.size.to_s
      raise CorruptPartError.new("staged Map compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
      raise CorruptPartError.new("staged Map metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

      expected_files = expected_checksum_files + [
        "checksums.txt",
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
      ]
      unless Dir.children(stage).sort == expected_files.sort
        raise CorruptPartError.new("staged Map file inventory differs")
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      raise CorruptPartError.new("staged Map primary index differs from input") unless index.keys == expected_index

      streams = [] of Tuple(String, File, File, UInt64)
      begin
        logical_streams.each do |logical_name|
          base = StreamName.hash(logical_name)
          data = File.open(File.join(stage, "#{base}.bin"), "r")
          marks = File.open(File.join(stage, "#{base}.mrk2"), "r")
          streams << {logical_name, data, marks, 0_u64}
        end

        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          key_raw = Bytes.new(rows * 8)
          size0_raw = Bytes.new(rows * 8)
          entry_count = 0
          rows.times do |offset|
            row_entries = values[start + offset]
            write_uint64_le(key_raw, offset * 8, keys[start + offset])
            write_uint64_le(size0_raw, offset * 8, row_entries.size.to_u64)
            entry_count += row_entries.size
          end
          map_keys_raw = Bytes.new(entry_count * 8)
          map_values_raw = Bytes.new(entry_count * 8)
          entry_offset = 0
          rows.times do |offset|
            values[start + offset].each do |entry|
              write_uint64_le(map_keys_raw, entry_offset * 8, entry[0])
              write_uint64_le(map_values_raw, entry_offset * 8, entry[1])
              entry_offset += 1
            end
          end

          expected_raw_streams = [key_raw, size0_raw, map_keys_raw, map_values_raw]
          streams.each_with_index do |stream, stream_index|
            next_offset = validate_staged_map_mark(
              stream[1], stream[2], stream[0], stream[3], rows.to_u64,
              expected_raw_streams[stream_index], omit_empty_frame: stream_index >= 2 && expected_raw_streams[stream_index].empty?
            )
            streams[stream_index] = {stream[0], stream[1], stream[2], next_offset}
          end
          start += rows
        end

        streams.each do |stream|
          validate_staged_map_sentinel(stream[1], stream[2], stream[0], stream[3])
        end
      ensure
        streams.each do |stream|
          stream[1].close unless stream[1].closed?
          stream[2].close unless stream[2].closed?
        end
      end
      nil
    end

    private def self.validate_staged_map_mark(
      data_file : File,
      marks_file : File,
      logical_name : String,
      expected_offset : UInt64,
      expected_rows : UInt64,
      expected_raw : Bytes,
      omit_empty_frame : Bool = false,
    ) : UInt64
      mark = Bytes.new(WidePart::MARK_SIZE)
      marks_file.read_fully(mark)
      raise CorruptPartError.new("staged Map mark offset differs for #{logical_name}") unless read_uint64_le(mark, 0) == expected_offset
      raise CorruptPartError.new("staged Map decompressed mark offset differs for #{logical_name}") unless read_uint64_le(mark, 8) == 0_u64
      raise CorruptPartError.new("staged Map mark row count differs for #{logical_name}") unless read_uint64_le(mark, 16) == expected_rows

      return expected_offset if omit_empty_frame && expected_raw.empty?

      data_file.seek(expected_offset.to_i64)
      header = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE)
      data_file.read_fully(header)
      compressed_size = read_uint32_le(header, CompressedBlock::CHECKSUM_SIZE + 1).to_i64
      frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      unless frame_size >= CompressedBlock::FRAME_HEADER_SIZE && frame_size <= MAX_FRAME_COMPRESSED.to_i64
        raise CorruptPartError.new("staged Map frame size is invalid for #{logical_name}")
      end
      frame_bytes = Bytes.new(frame_size.to_i)
      header.copy_to(frame_bytes)
      data_file.read_fully(frame_bytes[header.size, frame_bytes.size - header.size])
      frame = CompressedBlock.decode_frame(frame_bytes, 0_i64, MAX_FRAME_COMPRESSED.to_i64, MAX_FRAME_RAW_BYTES.to_i64)
      unless frame.end_offset == frame_size && frame.output == expected_raw
        raise CorruptPartError.new("staged Map stream readback differs for #{logical_name}")
      end
      expected_offset + frame.end_offset.to_u64
    end

    private def self.validate_staged_map_sentinel(
      data_file : File,
      marks_file : File,
      logical_name : String,
      expected_offset : UInt64,
    ) : Nil
      sentinel = Bytes.new(WidePart::MARK_SIZE)
      marks_file.read_fully(sentinel)
      raise CorruptPartError.new("staged Map sentinel offset differs for #{logical_name}") unless read_uint64_le(sentinel, 0) == expected_offset
      unless read_uint64_le(sentinel, 8) == 0_u64 && read_uint64_le(sentinel, 16) == 0_u64
        raise CorruptPartError.new("staged Map sentinel differs for #{logical_name}")
      end
      raise CorruptPartError.new("staged Map mark stream has trailing bytes for #{logical_name}") unless marks_file.gets_to_end.empty?
      raise CorruptPartError.new("staged Map data stream has trailing bytes for #{logical_name}") unless data_file.size == expected_offset
      nil
    end

    private def self.validate_staged_fixed_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(String),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged FixedString row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged FixedString column type does not match") unless value_part.column_type == "FixedString(#{width})"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        expected_mark_rows << rows.to_u64
        mark_index = expected_mark_rows.size - 1
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_fixed_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset]
            raise CorruptPartError.new("staged FixedString key readback differs from input")
          end

          input_bytes = values[start + offset].to_slice
          actual_bytes = expected_values[offset].to_slice
          unless actual_bytes.size == width
            raise CorruptPartError.new("staged FixedString value has an unexpected byte width")
          end
          width.times do |byte_index|
            expected_byte = byte_index < input_bytes.size ? input_bytes[byte_index] : 0_u8
            unless actual_bytes[byte_index] == expected_byte
              raise CorruptPartError.new("staged FixedString stream readback differs from input")
            end
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged FixedString marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.validate_staged_nullable_fixed_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(String?),
      width : Int32,
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Nullable(FixedString) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Nullable(FixedString) type does not match") unless value_part.column_type == "Nullable(FixedString(#{width}))"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        observed_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        observed_values = value_part.read_nullable_fixed_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          raise CorruptPartError.new("staged Nullable(FixedString) key readback differs from input") unless observed_keys[offset] == keys[start + offset]

          input = values[start + offset]
          actual = observed_values[offset]
          if input.nil?
            raise CorruptPartError.new("staged Nullable(FixedString) null map differs from input") unless actual.nil?
          else
            raise CorruptPartError.new("staged Nullable(FixedString) null map differs from input") if actual.nil?
            input_bytes = input.to_slice
            actual_bytes = actual.not_nil!.to_slice
            raise CorruptPartError.new("staged Nullable(FixedString) value has an unexpected byte width") unless actual_bytes.size == width
            width.times do |byte_index|
              expected_byte = byte_index < input_bytes.size ? input_bytes[byte_index] : 0_u8
              raise CorruptPartError.new("staged Nullable(FixedString) nested stream differs from input") unless actual_bytes[byte_index] == expected_byte
            end
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Nullable(FixedString) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_typed_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      {% if T == UUIDValue? || T == IPv4Value? || T == IPv6Value? || T == Decimal256Value? || T == Bool? || T == UInt8? || T == UInt16? || T == UInt32? || T == Int8? || T == Int16? || T == Int32? || T == Int64? || T == Int128? || T == Float32? || T == Float64? %}
        validate_staged_nullable_numeric_part(stage, key_name, value_name, keys, values, type_name, rows_per_mark)
      {% elsif T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
        validate_staged_nullable_string_part(stage, key_name, value_name, keys, values, rows_per_mark)
      {% else %}
        validate_staged_typed_numeric_part(stage, key_name, value_name, keys, values, type_name, rows_per_mark)
      {% end %}
    end

    private def self.validate_staged_typed_numeric_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged typed payload row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged typed payload column type does not match") unless value_part.column_type == type_name

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = read_typed_numeric_mark(value_part, value_name, mark_index, values, type_name)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && typed_numeric_value_equal?(expected_values[offset], values[start + offset])
            raise CorruptPartError.new("staged typed numeric stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged typed payload marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.read_typed_numeric_mark(
      part : WidePart,
      column : String,
      mark_index : Int,
      values : Slice(T),
      type_name : String,
    ) : Array(T) forall T
      {% if T == UUIDValue %}
        if type_name == "UUID"
          part.read_uuids_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed UUID writer requires exact UUID metadata")
        end
      {% elsif T == IPv4Value %}
        if type_name == "IPv4"
          part.read_ipv4s_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed IPv4 writer requires exact IPv4 metadata")
        end
      {% elsif T == IPv6Value %}
        if type_name == "IPv6"
          part.read_ipv6s_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed IPv6 writer requires exact IPv6 metadata")
        end
      {% elsif T == Decimal256Value %}
        if WidePart.decimal256_scale(type_name)
          part.read_decimal256_raw_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed Decimal256 writer requires exact Decimal(76, S) metadata")
        end
      {% elsif T == Bool %}
        part.read_bool_mark_range(column, mark_index, 1)
      {% elsif T == UInt8 %}
        part.read_numeric_mark_range(column, mark_index, 1, UInt8)
      {% elsif T == UInt16 %}
        if type_name == "Date"
          part.read_date_codes_mark_range(column, mark_index, 1)
        elsif type_name == "UInt16"
          part.read_numeric_mark_range(column, mark_index, 1, UInt16)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact UInt16 or Date payload")
        end
      {% elsif T == UInt32 %}
        if type_name == "DateTime"
          part.read_datetime_seconds_mark_range(column, mark_index, 1)
        elsif type_name == "UInt32"
          part.read_numeric_mark_range(column, mark_index, 1, UInt32)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact UInt32 or DateTime payload")
        end
      {% elsif T == UInt64 %}
        part.read_numeric_mark_range(column, mark_index, 1, UInt64)
      {% elsif T == Int8 %}
        if WidePart.enum8_codes(type_name)
          part.read_enum8_codes_mark_range(column, mark_index, 1)
        elsif type_name == "Int8"
          part.read_numeric_mark_range(column, mark_index, 1, Int8)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact Int8 or Enum8 payload")
        end
      {% elsif T == Int16 %}
        if WidePart.enum16_codes(type_name)
          part.read_enum16_codes_mark_range(column, mark_index, 1)
        elsif type_name == "Int16"
          part.read_numeric_mark_range(column, mark_index, 1, Int16)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact Int16 or Enum16 payload")
        end
      {% elsif T == Int32 %}
        if type_name == "Date32"
          part.read_date32_codes_mark_range(column, mark_index, 1)
        elsif WidePart.decimal32_scale(type_name)
          part.read_decimal32_raw_mark_range(column, mark_index, 1)
        elsif type_name == "Int32"
          part.read_numeric_mark_range(column, mark_index, 1, Int32)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact Int32 or Date32 payload")
        end
      {% elsif T == Int64 %}
        if type_name.starts_with?("DateTime64(")
          part.read_datetime64_ticks_mark_range(column, mark_index, 1)
        elsif WidePart.decimal64_scale(type_name)
          part.read_decimal64_raw_mark_range(column, mark_index, 1)
        elsif type_name == "Int64"
          part.read_numeric_mark_range(column, mark_index, 1, Int64)
        else
          raise UnsupportedFormatError.new("typed writer requires an exact Int64 or DateTime64 payload")
        end
      {% elsif T == Int128 %}
        part.read_decimal128_raw_mark_range(column, mark_index, 1)
      {% elsif T == Float32 %}
        part.read_numeric_mark_range(column, mark_index, 1, Float32)
      {% elsif T == Float64 %}
        part.read_numeric_mark_range(column, mark_index, 1, Float64)
      {% else %}
        raise UnsupportedFormatError.new("typed writer requires an exact fixed-width primitive numeric payload")
      {% end %}
    end

    private def self.typed_numeric_value_equal?(expected : T, actual : T) : Bool forall T
      {% if T == UUIDValue %}
        expected.high == actual.high && expected.low == actual.low
      {% elsif T == IPv4Value %}
        expected.network_order == actual.network_order
      {% elsif T == IPv6Value %}
        expected.high == actual.high && expected.low == actual.low
      {% elsif T == Decimal256Value %}
        expected.low == actual.low && expected.high == actual.high
      {% elsif T == Float32 %}
        expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
      {% elsif T == Float64 %}
        expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
      {% elsif T == Bool || T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 || T == Int128 %}
        expected == actual
      {% else %}
        false
      {% end %}
    end

    private def self.validate_staged_nullable_numeric_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(T),
      type_name : String,
      rows_per_mark : Int32,
    ) : Nil forall T
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Nullable payload row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Nullable payload type does not match") unless value_part.column_type == type_name

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = read_typed_nullable_numeric_mark(value_part, value_name, mark_index, values, type_name)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && typed_nullable_numeric_value_equal?(expected_values[offset], values[start + offset])
            raise CorruptPartError.new("staged Nullable numeric stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Nullable payload marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_nullable_string_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(String?),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open_typed(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged Nullable(String) row count does not match") unless value_part.row_count == values.size.to_u64
      raise CorruptPartError.new("staged Nullable(String) type does not match") unless value_part.column_type == "Nullable(String)"

      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        mark_index = expected_mark_rows.size
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
        expected_values = value_part.read_nullable_string_mark_range(value_name, mark_index, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged Nullable(String) stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged Nullable(String) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      validate_staged_primary_index(stage, checksums, keys, rows_per_mark, mark_count)
      nil
    end

    private def self.validate_staged_primary_index(
      stage : String,
      checksums : PartChecksums,
      keys : Slice(UInt64),
      rows_per_mark : Int32,
      mark_count : Int32,
    ) : Nil
      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.read_typed_nullable_numeric_mark(
      part : WidePart,
      column : String,
      mark_index : Int,
      values : Slice(T),
      type_name : String,
    ) : Array(T) forall T
      {% if T == UUIDValue? %}
        if type_name == "Nullable(UUID)"
          part.read_nullable_uuids_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed Nullable UUID writer requires exact Nullable(UUID) metadata")
        end
      {% elsif T == IPv4Value? %}
        if type_name == "Nullable(IPv4)"
          part.read_nullable_ipv4s_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed Nullable IPv4 writer requires exact Nullable(IPv4) metadata")
        end
      {% elsif T == IPv6Value? %}
        if type_name == "Nullable(IPv6)"
          part.read_nullable_ipv6s_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed Nullable IPv6 writer requires exact Nullable(IPv6) metadata")
        end
      {% elsif T == Decimal256Value? %}
        if WidePart.nullable_decimal256_scale(type_name)
          part.read_nullable_decimal256_raw_mark_range(column, mark_index, 1)
        else
          raise UnsupportedFormatError.new("typed Nullable Decimal256 writer requires exact Nullable(Decimal(76, S)) metadata")
        end
      {% elsif T == Bool? %}
        part.read_nullable_bool_mark_range(column, mark_index, 1)
      {% elsif T == UInt8? %}
        part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt8)
      {% elsif T == UInt16? %}
        if type_name == "Nullable(Date)"
          part.read_nullable_date_codes_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(UInt16)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt16)
        else
          raise UnsupportedFormatError.new("typed Nullable UInt16 writer requires exact Date or numeric metadata")
        end
      {% elsif T == UInt32? %}
        if type_name == "Nullable(DateTime)"
          part.read_nullable_datetime_seconds_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(UInt32)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt32)
        else
          raise UnsupportedFormatError.new("typed Nullable UInt32 writer requires exact DateTime or numeric metadata")
        end
      {% elsif T == UInt64? %}
        part.read_nullable_numeric_mark_range(column, mark_index, 1, UInt64)
      {% elsif T == Int8? %}
        if WidePart.enum8_codes(type_name)
          part.read_nullable_enum8_codes_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(Int8)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, Int8)
        else
          raise UnsupportedFormatError.new("typed Nullable Int8 writer requires exact Enum8 or numeric metadata")
        end
      {% elsif T == Int16? %}
        if WidePart.enum16_codes(type_name)
          part.read_nullable_enum16_codes_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(Int16)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, Int16)
        else
          raise UnsupportedFormatError.new("typed Nullable Int16 writer requires exact Enum16 or numeric metadata")
        end
      {% elsif T == Int32? %}
        if type_name == "Nullable(Date32)"
          part.read_nullable_date32_codes_mark_range(column, mark_index, 1)
        elsif WidePart.nullable_decimal32_scale(type_name)
          part.read_nullable_decimal32_raw_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(Int32)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, Int32)
        else
          raise UnsupportedFormatError.new("typed Nullable Int32 writer requires exact Date32 or numeric metadata")
        end
      {% elsif T == Int64? %}
        if WidePart.nullable_datetime64_scale(type_name)
          part.read_nullable_datetime64_ticks_mark_range(column, mark_index, 1)
        elsif WidePart.nullable_decimal64_scale(type_name)
          part.read_nullable_decimal64_raw_mark_range(column, mark_index, 1)
        elsif type_name == "Nullable(Int64)"
          part.read_nullable_numeric_mark_range(column, mark_index, 1, Int64)
        else
          raise UnsupportedFormatError.new("typed Nullable Int64 writer requires exact DateTime64 or numeric metadata")
        end
      {% elsif T == Int128? %}
        part.read_nullable_decimal128_raw_mark_range(column, mark_index, 1)
      {% elsif T == Float32? %}
        part.read_nullable_numeric_mark_range(column, mark_index, 1, Float32)
      {% elsif T == Float64? %}
        part.read_nullable_numeric_mark_range(column, mark_index, 1, Float64)
      {% else %}
        raise UnsupportedFormatError.new("unsupported typed Nullable numeric payload")
      {% end %}
    end

    private def self.typed_nullable_numeric_value_equal?(expected : T, actual : T) : Bool forall T
      if expected.nil?
        actual.nil?
      elsif actual.nil?
        false
      else
        typed_numeric_value_equal?(expected.not_nil!, actual.not_nil!)
      end
    end

    private def self.publish_exclusively(stage : String, target : String) : Nil
      {% if flag?(:darwin) %}
        result = LibWidePartWriterAtomicPublish.renamex_np(stage.to_unsafe, target.to_unsafe, RENAME_EXCL)
        if result != 0
          raise ArgumentError.new("destination already exists") if Errno.value == Errno::EEXIST
          raise IO::Error.from_errno("atomic Wide-part publish failed")
        end
      {% else %}
        raise UnsupportedFormatError.new("atomic exclusive Wide-part publication is unsupported on this platform")
      {% end %}
      {% if flag?(:crystal_click_test_failpoints) %}
        TestFailpoint.hit("part_published")
      {% end %}
      nil
    end

    private def self.columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` UInt64\n"
    end

    private def self.nullable_columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Nullable(UInt64)\n"
    end

    private def self.string_columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` String\n"
    end

    private def self.tuple_string_columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Tuple(a UInt64, b String)\n"
    end

    private def self.json_typed_columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` JSON(a UInt64, b String)\n"
    end

    private def self.json_object_structure_bytes : Bytes
      Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 0_u8]
    end

    private def self.substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n1 substreams for column `#{value_name}`:\n\t#{value_name}\n"
    end

    private def self.nullable_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.null\n\t#{value_name}\n"
    end

    private def self.string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size\n\t#{value_name}\n"
    end

    private def self.tuple_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}%2Ea\n\t#{value_name}%2Eb.size\n\t#{value_name}%2Eb\n"
    end

    private def self.json_typed_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
        "7 substreams for column `#{value_name}`:\n\t#{value_name}.object_structure\n\t#{value_name}.a\n" +
        "\t#{value_name}.b.size\n\t#{value_name}.b\n" +
        "\t#{value_name}.object_shared_data.0.size0\n" +
        "\t#{value_name}.object_shared_data.0%2Epaths\n" +
        "\t#{value_name}.object_shared_data.0%2Evalues\n"
    end

    private def self.low_cardinality_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.dict\n\t#{value_name}\n"
    end

    private def self.array_uint64_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
    end

    private def self.array_array_uint64_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}\n"
    end

    private def self.array_array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.null\n\t#{value_name}\n"
    end

    private def self.array_nullable_uint64_substreams_metadata(key_name : String, value_name : String) : String
      array_nullable_numeric_substreams_metadata(key_name, value_name)
    end

    private def self.array_nullable_numeric_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
    end

    private def self.array_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size\n\t#{value_name}\n"
    end

    private def self.array_nullable_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}.size\n\t#{value_name}\n"
    end

    private def self.array_fixed_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
    end

    private def self.array_nullable_fixed_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
    end

    private def self.array_bool_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}\n"
    end

    private def self.array_nullable_bool_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.null\n\t#{value_name}\n"
    end

    private def self.map_uint64_string_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
        "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
        "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues.size\n\t#{value_name}%2Evalues\n"
    end

    private def self.map_uint64_uint64_substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
        "3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n" +
        "\t#{value_name}%2Ekeys\n\t#{value_name}%2Evalues\n"
    end

    private def self.typed_columns_metadata(key_name : String, value_name : String, type_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{type_name}\n"
    end

    private def self.typed_substreams_metadata(key_name : String, value_name : String, type_name : String) : String
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

    private def self.typed_serialization_metadata(type_name : String) : String
      versions = if type_name == "String"
                   "\"string\":1"
                 elsif type_name == "Nullable(String)"
                   "\"nullable\":0,\"string\":1"
                 elsif type_name == "UUID" || type_name == "IPv4" || type_name == "IPv6" || type_name.starts_with?("Nullable(") || semantic_fixed_width_type?(type_name)
                   # BASIC Nullable payloads, UUID, IPv4, and IPv6 use this global
                   # serializer-version metadata. Semantic identity is
                   # carried by the exact column type.
                   "\"string\":1"
                 else
                   ""
                 end
      "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{#{versions}},\"version\":1}"
    end

    private def self.semantic_fixed_width_type?(type_name : String) : Bool
      type_name == "Bool" || !WidePart.enum8_codes(type_name).nil? || !WidePart.enum16_codes(type_name).nil? ||
        !WidePart.decimal32_scale(type_name).nil? || !WidePart.decimal64_scale(type_name).nil? ||
        !WidePart.decimal128_scale(type_name).nil? || !WidePart.decimal256_scale(type_name).nil?
    end

    private def self.nullable_fixed_string_serialization_metadata : String
      "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"nullable\":0,\"string\":1},\"version\":1}"
    end

    private def self.serialization_metadata : String
      "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
    end

    private def self.tuple_string_serialization_metadata(
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

    private def self.json_typed_serialization_metadata(key_name : String, keys : Slice(UInt64)) : String
      key_defaults = keys.count { |key| key == 0_u64 }
      String.build do |json|
        json << "{\"columns\":[{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{key_defaults},\"num_rows\":#{keys.size}}],"
        json << "\"propagate_types_serialization_versions_to_nested_types\":true,"
        json << "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end
    end

    private def self.literal_frame_size(raw_size : Int64) : Int64
      extension_size = raw_size < 15 ? 0_i64 : ((raw_size - 15) // 255) + 1
      CompressedBlock::HEADER_SIZE.to_i64 + 16_i64 + 1_i64 + extension_size + raw_size
    end

    private def self.encode_lz4_frame(raw : Bytes) : Bytes
      raise ArgumentError.new("empty LZ4 blocks are unsupported") if raw.empty?
      extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
      payload_size = 1 + extension_size + raw.size
      compressed_size = CompressedBlock::HEADER_SIZE + payload_size
      raise ArgumentError.new("compressed frame exceeds reader limit") if compressed_size > MAX_FRAME_COMPRESSED

      frame = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
      header = CompressedBlock::CHECKSUM_SIZE
      frame[header] = CompressedBlock::METHOD_LZ4
      write_uint32_le(frame, header + 1, compressed_size.to_u32)
      write_uint32_le(frame, header + 5, raw.size.to_u32)

      cursor = CompressedBlock::FRAME_HEADER_SIZE
      if raw.size < 15
        frame[cursor] = (raw.size << 4).to_u8
        cursor += 1
      else
        frame[cursor] = 0xf0_u8
        cursor += 1
        remaining = raw.size - 15
        while remaining >= 255
          frame[cursor] = 255_u8
          cursor += 1
          remaining -= 255
        end
        frame[cursor] = remaining.to_u8
        cursor += 1
      end
      raw.copy_to(frame[cursor, raw.size])
      checksum = CityHashV1.hash128(frame[CompressedBlock::CHECKSUM_SIZE, compressed_size])
      write_hash128_le(frame, checksum)
      frame
    end

    private def self.write_var_uint(io : IO, value : UInt64) : Nil
      remaining = value
      while remaining >= 0x80_u64
        io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
        remaining >>= 7
      end
      io.write_byte(remaining.to_u8)
    end

    private def self.write_hash128_le(io : IO, hash : {UInt64, UInt64}) : Nil
      write_uint64_le(io, hash[0])
      write_uint64_le(io, hash[1])
    end

    private def self.write_hash128_le(bytes : Bytes, hash : {UInt64, UInt64}) : Nil
      write_uint64_le(bytes, 0, hash[0])
      write_uint64_le(bytes, 8, hash[1])
    end

    private def self.write_uint64_le(io : IO, value : UInt64) : Nil
      8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    end

    private def self.write_uint64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
    end

    private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.write_uint64_be(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times { |index| bytes[offset + index] = ((value >> ((7 - index) * 8)) & 0xff_u64).to_u8 }
    end

    private def self.write_uint32_le(bytes : Bytes, offset : Int, value : UInt32) : Nil
      4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
    end

    private def self.read_uint32_le(bytes : Bytes, offset : Int) : UInt32
      value = 0_u32
      4.times { |index| value |= bytes[offset + index].to_u32 << (index * 8) }
      value
    end
  end
end
