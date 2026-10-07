module CrystalClick
  module WidePartWriter
    # Publishes the admitted recursive column profile. Lane owners
    # are composed before publication; this class supplies the bounded part
    # envelope and staged readback only.
    private class RecursiveStoragePartWriter
      private struct InputPlan
        getter target : String
        getter parent : String
        getter mark_count : Int32
        getter expected_files : Array(String)
        getter metadata : RecursiveStoragePartMetadata
        getter column_plan : RecursiveStorageColumnPlan

        def initialize(
          @target : String,
          @parent : String,
          @mark_count : Int32,
          @expected_files : Array(String),
          @metadata : RecursiveStoragePartMetadata,
          @column_plan : RecursiveStorageColumnPlan,
        )
        end
      end

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        schema : StorageColumnSchema,
        object_plans : Hash(String, ObjectDocumentPlan),
        granules : Array(Array(StorageColumnValue)),
        rows_per_mark : Int32 = 8192,
        mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
        dynamic_plans : Hash(String, BinaryDynamicBulkPlan) = Hash(String, BinaryDynamicBulkPlan).new,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, schema, object_plans,
          granules, rows_per_mark, mode, profile, shared_profile,
          frame_bytes, metadata_version, limits, transport_limits, dynamic_plans
        )

        # The plan binds every structural site and the entire physical/file
        # roster before row payload encoding. Site encoders then share one
        # operation budget; a late lane failure cannot create a stage.
        files = RecursiveStorageColumnWriter.encode(input.column_plan, granules)
        unless files.file_names == input.column_plan.file_names &&
               files.physical_stream_names == input.column_plan.physical_stream_names
          raise UnsupportedFormatError.new("encoded recursive files differ from the admitted physical roster")
        end
        records = checksum_column_files(files, input.mark_count, transport_limits)

        stage = PartDirectoryPublisher.create_stage(input.parent)
        begin
          key_records = LeafStreamWriter.write_uint64_stream(stage, key_name, keys, rows_per_mark)
          validate_key_record_roster!(key_records, key_name)
          records.concat(key_records)

          input.column_plan.file_names.each do |name|
            File.write(File.join(stage, name), files.file_bytes(name))
          end

          records << PrimaryIndexWriter.write(stage, keys, rows_per_mark)
          records << write_checksummed_file(stage, "count.txt", input.metadata.count)
          records << write_checksummed_file(stage, "serialization.json", input.metadata.serialization)
          File.write(File.join(stage, "columns.txt"), input.metadata.columns)
          File.write(File.join(stage, "columns_substreams.txt"), input.metadata.substreams)
          File.write(File.join(stage, "default_compression_codec.txt"), input.metadata.codec)
          File.write(File.join(stage, "metadata_version.txt"), input.metadata.metadata_version)
          PartChecksumsWriter.write(stage, records)

          validate_staged_part!(
            stage, input, key_name, keys, value_name, schema, granules,
            rows_per_mark, records
          )
          PartDirectoryPublisher.publish_exclusively(stage, input.target)
          input.target
        ensure
          FileUtils.rm_rf(stage) if Dir.exists?(stage)
        end
      end

      private def self.preflight(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        schema : StorageColumnSchema,
        object_plans : Hash(String, ObjectDocumentPlan),
        granules : Array(Array(StorageColumnValue)),
        rows_per_mark : Int32,
        mode : UInt64,
        profile : BinaryBulkProfile,
        shared_profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      ) : InputPlan
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and recursive column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless shared_profile.single_stream?
          raise UnsupportedFormatError.new("recursive Object shared data requires the stock single-stream profile")
        end
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS
          raise ArgumentError.new("a recursive part requires a bounded nonempty key stream")
        end
        unless (schema.tuple? || schema.array?) && schema.has_json?
          raise UnsupportedFormatError.new("recursive persisted columns require a root Tuple or Array with a JSON leaf")
        end
        unless granules.size > 0
          raise ArgumentError.new("a recursive part requires at least one real mark")
        end

        validate_keys!(keys)
        mark_count = checked_mark_count(keys.size, rows_per_mark)
        validate_granules!(keys.size, granules, rows_per_mark, mark_count)
        validate_key_physical_sizes!(keys.size, rows_per_mark, mark_count)

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        column_plan = RecursiveStorageColumnPlan.for_column(
          value_name, schema, object_plans, profile, shared_profile, true,
          mode, frame_bytes, limits, transport_limits, dynamic_plans: dynamic_plans
        )
        expected_files = expected_file_roster(column_plan.file_names, key_name)
        checksum_count = column_plan.physical_stream_names.size.to_i64 * 2_i64 + 5_i64
        if checksum_count > PartChecksums::MAX_ENTRIES
          raise UnsupportedFormatError.new("recursive part exceeds checksums entry limit")
        end
        metadata = RecursiveStoragePartMetadata.new(
          key_name, value_name, schema, column_plan.physical_stream_names,
          keys, metadata_version, profile, limits
        )
        InputPlan.new(target, parent, mark_count, expected_files, metadata, column_plan)
      end

      private def self.validate_column_name!(name : String) : Nil
        unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("column name must be a bounded ASCII identifier")
        end
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
      end

      private def self.checked_mark_count(row_count : Int, rows_per_mark : Int32) : Int32
        count = (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        raise ArgumentError.new("mark count exceeds writer limit") if count <= 0 || count > MAX_MARKS
        count.to_i32
      end

      private def self.validate_granules!(
        row_count : Int,
        granules : Array(Array(StorageColumnValue)),
        rows_per_mark : Int32,
        mark_count : Int32,
      ) : Nil
        raise ArgumentError.new("recursive granule count does not match key mark grid") unless granules.size == mark_count
        seen_rows = 0_i64
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("recursive granule size is outside the admitted range")
          end
          if index < mark_count - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final recursive granule may be short")
          end
          seen_rows += granule.size.to_i64
        end
        raise ArgumentError.new("recursive row count does not match key stream") unless seen_rows == row_count.to_i64
        nil
      end

      private def self.validate_key_physical_sizes!(row_count : Int, rows_per_mark : Int32, mark_count : Int32) : Nil
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

      private def self.expected_file_roster(column_files : Array(String), key_name : String) : Array(String)
        names = column_files.dup
        key_base = StreamName.hash(key_name)
        names << PhysicalStreamName.append_literal(key_base, ".bin")
        names << PhysicalStreamName.append_literal(key_base, ".mrk2")
        names.concat([
          "primary.idx", "count.txt", "serialization.json", "columns.txt",
          "columns_substreams.txt", "default_compression_codec.txt",
          "metadata_version.txt", "checksums.txt",
        ])
        names.each do |name|
          if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
            raise UnsupportedFormatError.new("recursive physical filename exceeds checksums name limit")
          end
        end
        names.sort!
        index = 1
        while index < names.size
          raise UnsupportedFormatError.new("recursive part filenames collide") if names[index - 1] == names[index]
          index += 1
        end
        names
      end

      private def self.checksum_column_files(
        files : RecursiveStorageColumnFiles,
        mark_count : Int32,
        limits : CompressedStreamLimits,
      ) : Array(ChecksumRecord)
        budget = CompressedStreamBudget.new(limits)
        names = files.stream_names
        expected_mark_size = (mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        lanes = Array({String, String, Bytes, Bytes, Array(CompressedFrameDescriptor), Int64}).new(names.size)
        total_raw_size = 0_i64
        names.each do |logical_name|
          pair = files.pair_for(logical_name)
          data = pair.data
          marks = pair.marks
          if data.size.to_i64 > WidePart::MAX_DATA_FILE_BYTES || data.size > Int32::MAX
            raise UnsupportedFormatError.new("recursive data file exceeds reader limit")
          end
          unless marks.size.to_i64 == expected_mark_size && marks.size.to_i64 <= WidePart::MAX_MARK_FILE_BYTES
            raise UnsupportedFormatError.new("recursive mark file differs from the complete parent grid")
          end
          budget.reserve_file_bytes(data.size.to_i64 + marks.size.to_i64)
          data_name = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".bin")
          if data.empty?
            lanes << {logical_name, data_name, data, marks, [] of CompressedFrameDescriptor, 0_i64}
            next
          end
          index = CompressedFrameIndex.new(data, limits, budget)
          raise UnsupportedFormatError.new("recursive raw data exceeds reader limit") if index.logical_size > WidePart::MAX_DATA_FILE_BYTES
          index.frames.each do |frame|
            raise UnsupportedFormatError.new("recursive output must use LZ4 frames") unless frame.method == CompressedBlock::METHOD_LZ4
          end
          if index.logical_size > Int64::MAX - total_raw_size
            raise UnsupportedFormatError.new("aggregate recursive raw size overflows")
          end
          total_raw_size += index.logical_size
          lanes << {logical_name, data_name, data, marks, index.frames, index.logical_size}
        end
        budget.reserve_decoded_bytes(total_raw_size)
        budget.reserve_result_bytes(total_raw_size)

        workspace = CompressedBlock::DecodeWorkspace.new
        records = Array(ChecksumRecord).new(names.size * 2)
        lanes.each do |lane|
          logical_name, data_name, data, marks, frames, raw_size = lane
          raw_hash = CityHashV1::FileHasher.new
          frames.each { |frame| verify_frame_checksum!(data, frame) }
          frames.each do |frame|
            decoded = CompressedBlock.decode_frame_into(
              data,
              frame.compressed_offset,
              workspace,
              limits.max_frame_compressed_bytes,
              limits.max_frame_decompressed_bytes
            )
            unless decoded.end_offset == frame.end_offset && decoded.output.size.to_i64 == frame.decompressed_size
              raise CorruptPartError.new("recursive frame changed after header indexing")
            end
            raw_hash.update(decoded.output)
          end
          records << ChecksumRecord.new(data_name, data.size.to_u64, CityHashV1.file_hash(data), true, raw_size.to_u64, raw_hash.finish)
          marks_name = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".mrk2")
          records << ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false)
        end
        records
      end

      private def self.verify_frame_checksum!(data : Bytes, frame : CompressedFrameDescriptor) : Nil
        offset = frame.compressed_offset.to_i
        expected = {read_uint64_le(data, offset), read_uint64_le(data, offset + 8)}
        body_offset = offset + CompressedBlock::CHECKSUM_SIZE
        actual = CityHashV1.hash128(data[body_offset, frame.compressed_size.to_i])
        raise CorruptPartError.new("recursive compressed frame checksum does not match") unless actual == expected
        nil
      end

      private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
        if offset < 0 || offset > bytes.size - 8
          raise CorruptPartError.new("truncated recursive frame checksum")
        end
        value = 0_u64
        8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
        value
      end

      private def self.validate_key_record_roster!(records : Array(ChecksumRecord), key_name : String) : Nil
        base = StreamName.hash(key_name)
        expected_data = PhysicalStreamName.append_literal(base, ".bin")
        expected_marks = PhysicalStreamName.append_literal(base, ".mrk2")
        unless records.size == 2 && records.any? { |record| record.name == expected_data } && records.any? { |record| record.name == expected_marks }
          raise UnsupportedFormatError.new("UInt64 key writer returned an unexpected physical roster")
        end
        nil
      end

      private def self.write_checksummed_file(stage : String, name : String, content : String) : ChecksumRecord
        File.write(File.join(stage, name), content)
        bytes = content.to_slice
        ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end

      private def self.validate_staged_part!(
        stage : String,
        input : InputPlan,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        schema : StorageColumnSchema,
        granules : Array(Array(StorageColumnValue)),
        rows_per_mark : Int32,
        records : Array(ChecksumRecord),
      ) : Nil
        unless Dir.children(stage).sort == input.expected_files
          raise CorruptPartError.new("staged recursive part file roster differs from preflight")
        end
        checksums = PartChecksums.open(stage)
        record_names = records.map(&.name).sort
        unless checksums.entries.keys.sort == record_names
          raise CorruptPartError.new("staged recursive checksums roster differs from generated files")
        end
        records.each { |record| checksums.validate_selected_entries(stage, record.name) }

        primary = PrimaryKeyIndex.open(stage, granules.size, checksums, verify_recorded_hash: true)
        unless primary.keys.size == granules.size + 1
          raise CorruptPartError.new("staged primary index has the wrong mark count")
        end
        key_start = 0
        granules.each_with_index do |granule, mark|
          unless primary.keys[mark] == keys[key_start]
            raise CorruptPartError.new("staged primary index differs from key granules")
          end
          key_start += granule.size
        end
        raise CorruptPartError.new("staged primary index terminal differs from final key") unless primary.keys.last == keys.last

        key_part = WidePart.open(stage, key_name)
        unless key_part.row_count == keys.size.to_u64 && key_part.mark_count == granules.size
          raise CorruptPartError.new("staged UInt64 key row grid differs from input")
        end
        key_start = 0
        granules.each_with_index do |granule, mark|
          unless key_part.mark_row_counts[mark] == granule.size.to_u64
            raise CorruptPartError.new("staged UInt64 key rows differ from recursive granules")
          end
          actual = key_part.read_uint64_mark_range(key_name, mark, 1)
          unless actual.size == granule.size
            raise CorruptPartError.new("staged UInt64 key granule size differs from input")
          end
          granule.size.times do |offset|
            unless actual[offset] == keys[key_start + offset]
              raise CorruptPartError.new("staged UInt64 keys differ from input")
            end
          end
          key_start += granule.size
        end

        reader = RecursiveStorageColumnReader.open(stage, value_name, schema)
        unless reader.row_count == keys.size.to_u64 && reader.mark_count == granules.size &&
               reader.schema_declaration == schema.declaration && reader.source_declaration == schema.declaration &&
               reader.physical_stream_names == input.column_plan.physical_stream_names
          raise CorruptPartError.new("staged recursive declaration or physical grid differs from input")
        end
        granules.each_with_index do |expected_rows, mark|
          unless reader.mark_row_counts[mark] == expected_rows.size.to_u64
            raise CorruptPartError.new("staged recursive parent row grid differs from input")
          end
          actual_rows = reader.read_marks(mark, 1)[0]?
          raise CorruptPartError.new("staged recursive mark is missing") unless actual_rows
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged recursive parent row count differs from input")
          end
          expected_rows.each_with_index do |expected_value, row_index|
            compare_storage_value!(actual_rows[row_index], expected_value)
          end
        end
        nil
      end

      private def self.compare_storage_value!(actual : StorageColumnValue, expected : StorageColumnValue) : Nil
        unless actual.kind == expected.kind && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged recursive value shape differs from input")
        end
        if actual.tuple? || actual.array?
          actual.child_count.times { |index| compare_storage_value!(actual.child_at(index), expected.child_at(index)) }
        elsif actual.object?
          compare_document!(actual.object_document, expected.object_document)
        else
          compare_binary_value!(actual.bulk_value, expected.bulk_value)
        end
        nil
      end

      private def self.compare_document!(actual : ObjectDocument, expected : ObjectDocument) : Nil
        actual_index = 0
        expected.path_count.times do |expected_index|
          path = expected.path_at(expected_index)
          expected_value = expected.value_for(path)
          next if expected_value.type.tag == BinaryDataType::TAG_NOTHING && expected_value.is_null?
          raise CorruptPartError.new("staged recursive document is missing an input path") unless actual_index < actual.path_count
          actual_path = actual.path_at(actual_index)
          raise CorruptPartError.new("staged recursive document path roster differs from input") unless actual_path == path
          compare_binary_value!(actual.value_for(actual_path), expected_value)
          actual_index += 1
        end
        raise CorruptPartError.new("staged recursive document has an unexpected path") unless actual_index == actual.path_count
        nil
      end

      private def self.compare_binary_value!(actual : BinaryValue, expected : BinaryValue) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged recursive BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged recursive BinaryValue scalar bytes differ from input")
          end
        end
        if actual.type.tag == BinaryDataType::TAG_JSON
          compare_json_row!(actual.json_row, expected.json_row)
          return nil
        end
        actual.child_count.times { |index| compare_binary_value!(actual.child_at(index), expected.child_at(index)) }
        nil
      end

      private def self.compare_json_row!(actual : BinaryJsonRow, expected : BinaryJsonRow) : Nil
        unless actual.path_count == expected.path_count
          raise CorruptPartError.new("staged recursive JSON path count differs from input")
        end
        expected.path_count.times do |index|
          unless actual.path_at(index) == expected.path_at(index)
            raise CorruptPartError.new("staged recursive JSON path bytes differ from input")
          end
          compare_binary_value!(actual.value_at(index), expected.value_at(index))
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
