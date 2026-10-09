module CrystalClick
  module WidePartWriter
    # Composes the previously qualified JSON column and UInt64 leaf writers
    # into one complete, unpublished normalized part. Each validation and
    # checksum pass has its own declared logical budget; none claims an RSS
    # bound or a snapshot of concurrently-mutated caller inputs.
    private class ObjectPartWriter
      private struct JSONDataLane
        getter logical_name : String
        getter data_name : String
        getter frames : Array(CompressedFrameDescriptor)
        getter raw_size : Int64

        def initialize(
          @logical_name : String,
          @data_name : String,
          @frames : Array(CompressedFrameDescriptor),
          @raw_size : Int64,
        )
        end
      end

      private struct InputPlan
        getter target : String
        getter parent : String
        getter mark_count : Int32
        getter json_files : Array(String)
        getter expected_files : Array(String)
        getter metadata : ObjectPartMetadata

        def initialize(
          @target : String,
          @parent : String,
          @mark_count : Int32,
          @json_files : Array(String),
          @expected_files : Array(String),
          @metadata : ObjectPartMetadata,
        )
        end
      end

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        schema : ObjectDocumentSchema,
        plan : ObjectDocumentPlan,
        granules : Array(Array(ObjectDocument)),
        rows_per_mark : Int32 = 8192,
        mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
        shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
        shared_target_chunk_rows : Int32 = 1,
      ) : String
        unless shared_target_chunk_rows > 0
          raise ArgumentError.new("Object shared advanced target chunk rows must be positive")
        end
        input = preflight(
          destination, key_name, keys, value_name, schema, plan, granules,
          rows_per_mark, mode, profile, shared_profile, frame_bytes,
          metadata_version, limits
        )

        # W127 owns the one write-direction budget shared by statistics and
        # every JSON physical lane. This returns only after all lanes have
        # passed aggregate output admission and have been encoded.
        column_files = ObjectDocumentColumnWriter.encode(
          value_name,
          plan,
          granules,
          mode,
          profile,
          shared_profile,
          true,
          frame_bytes,
          limits,
          transport_limits,
          shared_json_policy,
          shared_target_chunk_rows,
        )
        unless column_files.file_names == input.json_files
          raise UnsupportedFormatError.new("encoded Object files differ from their preflight roster")
        end

        json_records = checksum_json_files(column_files, input.mark_count, transport_limits)
        metadata = input.metadata
        records = [] of ChecksumRecord
        records.concat(json_records)

        stage = PartDirectoryPublisher.create_stage(input.parent)
        begin
          key_records = LeafStreamWriter.write_uint64_stream(
            stage, key_name, keys, rows_per_mark
          )
          validate_key_record_roster!(key_records, key_name)
          records.concat(key_records)

          # Pairs are detached on access and written one file at a time so no
          # mmap, borrowed decoder workspace, or file-pair slice can escape.
          input.json_files.each do |name|
            File.write(File.join(stage, name), column_files.file_bytes(name))
          end

          records << PrimaryIndexWriter.write(stage, keys, rows_per_mark)
          records << write_checksummed_file(stage, "count.txt", metadata.count)
          records << write_checksummed_file(stage, "serialization.json", metadata.serialization)
          File.write(File.join(stage, "columns.txt"), metadata.columns)
          File.write(File.join(stage, "columns_substreams.txt"), metadata.substreams)
          File.write(File.join(stage, "default_compression_codec.txt"), metadata.codec)
          File.write(File.join(stage, "metadata_version.txt"), metadata.metadata_version)
          PartChecksumsWriter.write(stage, records)

          validate_staged_part!(
            stage, input.expected_files, key_name, keys, value_name,
            schema, granules, rows_per_mark, profile, limits,
            transport_limits, records
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
        schema : ObjectDocumentSchema,
        plan : ObjectDocumentPlan,
        granules : Array(Array(ObjectDocument)),
        rows_per_mark : Int32,
        mode : UInt64,
        profile : BinaryBulkProfile,
        shared_profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
      ) : InputPlan
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and Object column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless limits.max_depth == schema.limits.max_depth &&
               limits.max_nodes == schema.limits.max_nodes &&
               limits.max_elements == schema.limits.max_elements &&
               limits.max_bytes == schema.limits.max_bytes
          raise ArgumentError.new("writer and schema codec limits must match")
        end
        unless shared_profile.single_stream?
          raise UnsupportedFormatError.new("normalized Object shared MAP requires the stock single-stream profile")
        end
        unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
          raise ArgumentError.new("unsupported Dynamic discriminator write mode")
        end
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless frame_bytes > 0 && frame_bytes <= Int32::MAX && frame_bytes >= DynamicDiscriminatorCodec::HEADER_BYTES
          raise ArgumentError.new("frame size must contain the complete discriminator prefix")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS
          raise ArgumentError.new("a normalized part requires a bounded nonempty key stream")
        end
        if granules.empty?
          raise ArgumentError.new("a normalized Object part requires at least one real granule")
        end

        validate_keys!(keys)
        mark_count = checked_mark_count(keys.size, rows_per_mark)
        validate_granules!(keys.size, granules, rows_per_mark, mark_count)
        validate_key_physical_sizes!(keys.size, rows_per_mark, mark_count)
        schema.validate_plan(plan)

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        physical = ObjectDocumentPhysicalPlan.new(
          value_name, plan, profile, shared_profile, limits
        )
        stream_count = physical.stream_count
        checksum_entries = stream_count.to_i64 * 2_i64 + 5_i64
        if checksum_entries > PartChecksums::MAX_ENTRIES
          raise UnsupportedFormatError.new("normalized part exceeds checksums entry limit")
        end

        json_files = preflight_json_names!(physical, key_name)
        metadata = ObjectPartMetadata.new(
          key_name, value_name, schema, physical, keys, metadata_version, profile
        )
        validate_metadata_sizes!(metadata)

        expected_files = Array(String).new(json_files.size + 10)
        expected_files.concat(json_files)
        key_base = StreamName.hash(key_name)
        expected_files << PhysicalStreamName.append_literal(key_base, ".bin")
        expected_files << PhysicalStreamName.append_literal(key_base, ".mrk2")
        expected_files.concat([
          "primary.idx", "count.txt", "serialization.json",
          "columns.txt", "columns_substreams.txt", "default_compression_codec.txt",
          "metadata_version.txt", "checksums.txt",
        ])
        expected_files.sort!
        InputPlan.new(target, parent, mark_count, json_files, expected_files, metadata)
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
        if count <= 0 || count > MAX_MARKS
          raise ArgumentError.new("mark count exceeds writer limit")
        end
        count.to_i32
      end

      private def self.validate_granules!(
        row_count : Int,
        granules : Array(Array(ObjectDocument)),
        rows_per_mark : Int32,
        mark_count : Int32,
      ) : Nil
        unless granules.size == mark_count
          raise ArgumentError.new("Object granule count does not match the key mark grid")
        end
        seen_rows = 0_i64
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("Object granule size is outside the admitted range")
          end
          if index < mark_count - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final Object granule may be short")
          end
          seen_rows += granule.size.to_i64
        end
        unless seen_rows == row_count.to_i64
          raise ArgumentError.new("Object row count does not match the key stream")
        end
      end

      private def self.validate_key_physical_sizes!(
        row_count : Int,
        rows_per_mark : Int32,
        mark_count : Int32,
      ) : Nil
        mark_size = (mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        if mark_size > WidePart::MAX_MARK_FILE_BYTES || mark_size > Int32::MAX
          raise ArgumentError.new("key mark file exceeds reader limit")
        end
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        if index_size > MAX_PRIMARY_INDEX_BYTES || index_size > Int32::MAX
          raise ArgumentError.new("primary index exceeds reader limit")
        end

        encoded_size = 0_i64
        mark_count.times do |mark|
          start = mark.to_i64 * rows_per_mark
          rows = {rows_per_mark.to_i64, row_count.to_i64 - start}.min
          raw_size = rows.to_i64 * 8_i64
          if raw_size <= 0 || raw_size > MAX_FRAME_RAW_BYTES
            raise ArgumentError.new("key granule exceeds frame reader limit")
          end
          payload_size = 1_i64 + (raw_size < 15_i64 ? 0_i64 : ((raw_size - 15_i64) // 255_i64) + 1_i64) + raw_size
          compressed_size = CompressedBlock::HEADER_SIZE + payload_size
          if compressed_size > MAX_FRAME_COMPRESSED
            raise ArgumentError.new("key granule exceeds compressed frame limit")
          end
          frame_size = CompressedBlock::CHECKSUM_SIZE + compressed_size
          if encoded_size > WidePart::MAX_DATA_FILE_BYTES - frame_size
            raise ArgumentError.new("key data file exceeds reader limit")
          end
          encoded_size += frame_size
        end
        nil
      end

      private def self.preflight_json_names!(
        physical : ObjectDocumentPhysicalPlan,
        key_name : String,
      ) : Array(String)
        seen = Hash(String, Bool).new
        key_base = StreamName.hash(key_name)
        key_data = PhysicalStreamName.append_literal(key_base, ".bin")
        key_marks = PhysicalStreamName.append_literal(key_base, ".mrk2")
        register_filename!(key_data, seen)
        register_filename!(key_marks, seen)

        files = Array(String).new(physical.stream_count * 2)
        physical.stream_names.each do |logical_name|
          base = StreamName.hash(logical_name)
          data_name = PhysicalStreamName.append_literal(base, ".bin")
          marks_name = PhysicalStreamName.append_literal(base, ".mrk2")
          register_filename!(data_name, seen)
          register_filename!(marks_name, seen)
          files << data_name
          files << marks_name
        end
        unless files.size == physical.stream_count * 2
          raise UnsupportedFormatError.new("Object file roster differs from its scalar stream count")
        end
        files.sort!
        files
      end

      private def self.register_filename!(name : String, seen : Hash(String, Bool)) : Nil
        if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
          raise UnsupportedFormatError.new("normalized part filename exceeds checksums name limit")
        end
        if seen.has_key?(name)
          raise UnsupportedFormatError.new("normalized part filenames collide after hashing")
        end
        seen[name] = true
      end

      private def self.validate_metadata_sizes!(metadata : ObjectPartMetadata) : Nil
        {
          metadata.columns,
          metadata.substreams,
          metadata.count,
          metadata.serialization,
          metadata.metadata_version,
        }.each do |content|
          if content.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise UnsupportedFormatError.new("normalized part metadata exceeds reader limit")
          end
        end
        if metadata.codec.bytesize > WidePart::MAX_CODEC_FILE_BYTES
          raise UnsupportedFormatError.new("default codec metadata exceeds reader limit")
        end
      end

      private def self.checksum_json_files(
        files : ObjectDocumentColumnFiles,
        mark_count : Int32,
        limits : CompressedStreamLimits,
      ) : Array(ChecksumRecord)
        # This is a distinct read-direction checksum phase, shared across all
        # JSON lanes. W127's shared write budget has already admitted and
        # produced the complete file-pair batch before this phase starts.
        budget = CompressedStreamBudget.new(limits)
        names = files.stream_names
        lanes = Array(JSONDataLane).new(names.size)
        total_raw_size = 0_i64
        expected_mark_size = (mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE

        names.each do |logical_name|
          data_name = PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".bin")
          pair = files.pair_for(logical_name)
          data = pair.data
          marks = pair.marks
          if data.size.to_i64 > WidePart::MAX_DATA_FILE_BYTES || data.size > Int32::MAX
            raise UnsupportedFormatError.new("JSON data file exceeds reader limit")
          end
          unless marks.size.to_i64 == expected_mark_size && marks.size.to_i64 <= WidePart::MAX_MARK_FILE_BYTES
            raise UnsupportedFormatError.new("JSON mark file differs from the complete outer grid")
          end
          budget.reserve_file_bytes(data.size.to_i64 + marks.size.to_i64)

          if data.empty?
            lanes << JSONDataLane.new(logical_name, data_name, [] of CompressedFrameDescriptor, 0_i64)
            next
          end

          index = CompressedFrameIndex.new(data, limits, budget)
          if index.logical_size > WidePart::MAX_DATA_FILE_BYTES
            raise UnsupportedFormatError.new("JSON raw data exceeds reader limit")
          end
          index.frames.each do |frame|
            unless frame.method == CompressedBlock::METHOD_LZ4
              raise UnsupportedFormatError.new("normalized JSON output must use LZ4 frames")
            end
          end
          if total_raw_size > Int64::MAX - index.logical_size
            raise UnsupportedFormatError.new("aggregate JSON raw size overflows")
          end
          total_raw_size += index.logical_size
          lanes << JSONDataLane.new(logical_name, data_name, index.frames, index.logical_size)
        end

        # Reserve the aggregate decoded/checksum result before inspecting a
        # frame checksum or requesting any decoded workspace.
        budget.reserve_decoded_bytes(total_raw_size)
        budget.reserve_result_bytes(total_raw_size)

        workspace = CompressedBlock::DecodeWorkspace.new
        records = Array(ChecksumRecord).new(names.size * 2)
        lanes.each do |lane|
          pair = files.pair_for(lane.logical_name)
          data = pair.data
          marks = pair.marks
          raw_hash = CityHashV1::FileHasher.new

          # Authenticate every touched frame in this file before asking its
          # decoder for output storage, then decode into one reusable workspace.
          lane.frames.each do |frame|
            verify_frame_checksum!(data, frame)
          end
          lane.frames.each do |frame|
            decoded = CompressedBlock.decode_frame_into(
              data,
              frame.compressed_offset,
              workspace,
              limits.max_frame_compressed_bytes,
              limits.max_frame_decompressed_bytes
            )
            unless decoded.end_offset == frame.end_offset && decoded.output.size.to_i64 == frame.decompressed_size
              raise CorruptPartError.new("JSON frame changed after header indexing")
            end
            raw_hash.update(decoded.output)
          end

          raw_hash_value = raw_hash.finish
          records << ChecksumRecord.new(
            lane.data_name,
            data.size.to_u64,
            CityHashV1.file_hash(data),
            true,
            lane.raw_size.to_u64,
            raw_hash_value
          )
          marks_name = PhysicalStreamName.append_literal(StreamName.hash(lane.logical_name), ".mrk2")
          records << ChecksumRecord.new(
            marks_name,
            marks.size.to_u64,
            CityHashV1.file_hash(marks),
            false
          )
        end
        records
      end

      private def self.verify_frame_checksum!(
        data : Bytes,
        frame : CompressedFrameDescriptor,
      ) : Nil
        offset = frame.compressed_offset.to_i
        expected = {
          read_uint64_le(data, offset),
          read_uint64_le(data, offset + 8),
        }
        body_offset = offset + CompressedBlock::CHECKSUM_SIZE
        actual = CityHashV1.hash128(data[body_offset, frame.compressed_size.to_i])
        raise CorruptPartError.new("JSON compressed frame checksum does not match") unless actual == expected
        nil
      end

      private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
        if offset < 0 || offset > bytes.size - 8
          raise CorruptPartError.new("truncated JSON frame checksum")
        end
        value = 0_u64
        8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
        value
      end

      private def self.validate_key_record_roster!(records : Array(ChecksumRecord), key_name : String) : Nil
        base = StreamName.hash(key_name)
        expected_data = PhysicalStreamName.append_literal(base, ".bin")
        expected_marks = PhysicalStreamName.append_literal(base, ".mrk2")
        unless records.size == 2 && records.any? { |record| record.name == expected_data } &&
               records.any? { |record| record.name == expected_marks }
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
        expected_files : Array(String),
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        schema : ObjectDocumentSchema,
        granules : Array(Array(ObjectDocument)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        records : Array(ChecksumRecord),
      ) : Nil
        unless Dir.children(stage).sort == expected_files
          raise CorruptPartError.new("staged normalized part file roster differs from preflight")
        end
        checksums = PartChecksums.open(stage)
        record_names = records.map(&.name).sort
        unless checksums.entries.keys.sort == record_names
          raise CorruptPartError.new("staged checksums roster differs from generated files")
        end
        records.each { |record| checksums.validate_selected_entries(stage, record.name) }

        primary = PrimaryKeyIndex.open(stage, granules.size, checksums, verify_recorded_hash: true)
        unless primary.keys.size == granules.size + 1
          raise CorruptPartError.new("staged primary index has the wrong mark count")
        end
        row = 0
        granules.each_with_index do |granule, mark|
          unless primary.keys[mark] == keys[row]
            raise CorruptPartError.new("staged primary index differs from the key granules")
          end
          row += granule.size
        end
        unless primary.keys.last == keys.last
          raise CorruptPartError.new("staged primary index terminal differs from the final key")
        end

        key_part = WidePart.open(stage, key_name)
        unless key_part.row_count == keys.size.to_u64 && key_part.mark_count == granules.size
          raise CorruptPartError.new("staged UInt64 key stream row grid differs from the input")
        end
        mark_rows = key_part.mark_row_counts
        unless mark_rows.size == granules.size
          raise CorruptPartError.new("staged UInt64 key mark count differs from the input")
        end
        start = 0
        granules.each_with_index do |granule, mark|
          unless mark_rows[mark] == granule.size.to_u64
            raise CorruptPartError.new("staged UInt64 key rows differ from the outer granules")
          end
          actual = key_part.read_uint64_mark_range(key_name, mark, 1)
          unless actual.size == granule.size
            raise CorruptPartError.new("staged UInt64 key granule size differs from the input")
          end
          granule.size.times do |offset|
            unless actual[offset] == keys[start + offset]
              raise CorruptPartError.new("staged UInt64 keys differ from the input")
            end
          end
          start += granule.size
        end

        typed_schema = schema.typed_paths
        actual_documents = ObjectDocumentFileReader.read(
          stage,
          value_name,
          typed_schema,
          profile: profile,
          shared_profile: BinaryBulkProfile.single_stream,
          hashed: true,
          limits: limits,
          transport_limits: transport_limits
        )
        compare_documents!(actual_documents, granules)
        nil
      end

      private def self.compare_documents!(
        actual : Array(Array(ObjectDocument)),
        expected : Array(Array(ObjectDocument)),
      ) : Nil
        unless actual.size == expected.size
          raise CorruptPartError.new("staged Object mark count differs from the input")
        end
        expected.each_with_index do |expected_rows, mark|
          actual_rows = actual[mark]
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged Object row count differs from the input")
          end
          expected_rows.each_with_index do |expected_document, row|
            compare_document!(actual_rows[row], expected_document)
          end
        end
        nil
      end

      private def self.compare_document!(actual : ObjectDocument, expected : ObjectDocument) : Nil
        actual_index = 0
        expected.path_count.times do |expected_index|
          path = expected.path_at(expected_index)
          expected_value = expected.value_for(path)
          # W125 deliberately normalizes the untyped Nothing NULL sentinel to
          # absence in the shared MAP lane.
          next if expected_value.type.tag == BinaryDataType::TAG_NOTHING && expected_value.is_null?

          unless actual_index < actual.path_count
            raise CorruptPartError.new("staged Object document is missing an input path")
          end
          actual_path = actual.path_at(actual_index)
          unless actual_path == path
            raise CorruptPartError.new("staged Object document path roster differs from the input")
          end
          actual_value = actual.value_for(actual_path)
          compare_value!(actual_value, expected_value)
          actual_index += 1
        end
        unless actual_index == actual.path_count
          raise CorruptPartError.new("staged Object document has an unexpected path")
        end
        nil
      end

      private def self.compare_value!(actual : BinaryValue, expected : BinaryValue) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged Object value differs from the input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged Object scalar bytes differ from the input")
          end
        end
        actual.child_count.times do |index|
          compare_value!(actual.child_at(index), expected.child_at(index))
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
