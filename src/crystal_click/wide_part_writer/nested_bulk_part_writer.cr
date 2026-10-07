module CrystalClick
  module WidePartWriter
    # Owns the two-column envelope and staged readback for one nominal Nested
    # BinaryBulk column. Value-role serialization stays in the shared codec.
    private class NestedBulkPartWriter
      private struct InputPlan
        getter target : String
        getter parent : String
        getter mark_count : Int32
        getter expected_files : Array(String)
        getter role_names : Hash(String, String)
        getter physical : BinaryBulkPhysicalPlan
        getter metadata : RecursiveStoragePartMetadata
        getter canonical_declaration : String

        def initialize(
          @target : String,
          @parent : String,
          @mark_count : Int32,
          @expected_files : Array(String),
          @role_names : Hash(String, String),
          @physical : BinaryBulkPhysicalPlan,
          @metadata : RecursiveStoragePartMetadata,
          @canonical_declaration : String,
        )
        end
      end

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits
        )

        files = NestedBulkColumnWriter.encode(
          type, profile, input.physical, granules,
          Array(UInt64).new(granules.size) { |index| granules[index].size.to_u64 },
          frame_bytes, limits, transport_limits
        )
        physical_names = input.role_names.values.sort!
        unless files.keys.sort == physical_names
          raise UnsupportedFormatError.new("encoded Nested files differ from the admitted physical roster")
        end
        records = checksum_column_files(files, input, transport_limits)

        stage = PartDirectoryPublisher.create_stage(input.parent)
        begin
          key_records = LeafStreamWriter.write_uint64_stream(stage, key_name, keys, rows_per_mark)
          validate_key_record_roster!(key_records, key_name)
          records.concat(key_records)

          input.role_names.each do |role, logical_name|
            pair = files[logical_name]
            File.write(File.join(stage, input.physical.data_file_for(role, true)), pair.data)
            File.write(File.join(stage, input.physical.marks_file_for(role, true)), pair.marks)
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
            stage, input, key_name, keys, value_name, type, granules,
            rows_per_mark, records, profile, limits, transport_limits
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
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : InputPlan
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and Nested column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        raise ArgumentError.new("rows_per_mark is outside the admitted range") unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
        raise ArgumentError.new("a Nested part requires a bounded nonempty key stream") unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS
        raise ArgumentError.new("a Nested part requires at least one real mark") if granules.empty?

        unless type.tag == BinaryDataType::TAG_NESTED
          raise UnsupportedFormatError.new("Nested bulk writer requires a nominal Nested descriptor")
        end

        # Bound recursive name traversal before static-type predicates, codec
        # plans, or the metadata adapter can render or inspect the descriptor.
        name_budget = BinaryCodecBudget.new(limits, true)
        name_bounds = BinaryTypeNameBudget.measure(type, name_budget)
        canonical = BinaryTypeNameBudget.materialize(type, name_budget, name_bounds)
        # StorageColumnSchema.bulk retains its own canonical type-name render.
        # Reserve the same measured work before that owner is allowed to run.
        name_budget.ensure_wire_bytes(name_bounds[1])
        name_budget.charge_wire_bytes(name_bounds[1])

        BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
        unless profile.single_stream? || profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported Nested String profile")
        end
        unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
          raise ArgumentError.new("Nested frame size is outside the compressed transport limit")
        end

        unless granules.size <= MAX_MARKS
          raise ArgumentError.new("Nested mark count exceeds writer limit")
        end
        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == granules.size.to_i64
          raise ArgumentError.new("Nested granule count does not match the key mark grid")
        end
        validate_keys!(keys)
        validate_granules!(keys.size, granules, rows_per_mark)
        validate_key_physical_sizes!(keys.size, rows_per_mark, granules.size)

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        physical = BinaryBulkPhysicalPlan.new(
          type, value_name, profile, limits, PhysicalStreamPlanContext.new(limits)
        )
        role_names = physical.stream_names
        physical_names = role_names.values
        expected_files = expected_file_roster(role_names, physical, key_name)
        checksum_count = role_names.size.to_i64 * 2_i64 + 5_i64
        if checksum_count > PartChecksums::MAX_ENTRIES
          raise UnsupportedFormatError.new("Nested part exceeds checksums entry limit")
        end

        schema = StorageColumnSchema.bulk(type, canonical)
        unless schema.declaration == canonical
          raise UnsupportedFormatError.new("Nested metadata schema changed its canonical declaration")
        end
        metadata = RecursiveStoragePartMetadata.new(
          key_name, value_name, schema, physical_names, keys,
          metadata_version, profile, limits
        )
        InputPlan.new(
          target, parent, granules.size.to_i32, expected_files,
          role_names, physical, metadata, canonical
        )
      end

      private def self.validate_granules!(
        row_count : Int,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
      ) : Nil
        seen_rows = 0_i64
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("Nested parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final Nested parent granule may be short")
          end
          seen_rows += granule.size.to_i64
        end
        raise ArgumentError.new("Nested row count does not match the key stream") unless seen_rows == row_count.to_i64
        nil
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

      private def self.expected_file_roster(
        role_names : Hash(String, String),
        physical : BinaryBulkPhysicalPlan,
        key_name : String,
      ) : Array(String)
        names = Array(String).new(role_names.size * 2 + 10)
        role_names.each_key do |role|
          names << physical.data_file_for(role, true)
          names << physical.marks_file_for(role, true)
        end
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
            raise UnsupportedFormatError.new("Nested physical filename exceeds checksums name limit")
          end
        end
        names.sort!
        index = 1
        while index < names.size
          raise UnsupportedFormatError.new("Nested part filenames collide") if names[index - 1] == names[index]
          index += 1
        end
        names
      end

      private def self.checksum_column_files(
        files : Hash(String, CompressedMarkFiles),
        input : InputPlan,
        limits : CompressedStreamLimits,
      ) : Array(ChecksumRecord)
        budget = CompressedStreamBudget.new(limits, true)
        expected_mark_size = (input.mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        lanes = Array(Tuple(String, String, String, Bytes, Bytes, Array(CompressedFrameDescriptor), Int64)).new(input.role_names.size)
        total_raw_size = 0_i64
        input.role_names.each do |role, logical_name|
          pair = files[logical_name]
          data = pair.data
          marks = pair.marks
          if data.size.to_i64 > WidePart::MAX_DATA_FILE_BYTES || data.size > Int32::MAX
            raise UnsupportedFormatError.new("Nested data file exceeds reader limit")
          end
          unless marks.size.to_i64 == expected_mark_size && marks.size.to_i64 <= WidePart::MAX_MARK_FILE_BYTES
            raise UnsupportedFormatError.new("Nested mark file differs from the complete parent grid")
          end
          if data.size.to_i64 > Int64::MAX - marks.size.to_i64
            raise UnsupportedFormatError.new("Nested lane file byte count overflows")
          end
          budget.reserve_file_bytes(data.size.to_i64 + marks.size.to_i64)
          data_name = input.physical.data_file_for(role, true)
          marks_name = input.physical.marks_file_for(role, true)
          if data.empty?
            lanes << {logical_name, data_name, marks_name, data, marks, [] of CompressedFrameDescriptor, 0_i64}
            next
          end
          index = CompressedFrameIndex.new(data, limits, budget)
          if index.logical_size > WidePart::MAX_DATA_FILE_BYTES
            raise UnsupportedFormatError.new("Nested raw data exceeds reader limit")
          end
          index.frames.each do |frame|
            raise UnsupportedFormatError.new("Nested output must use LZ4 frames") unless frame.method == CompressedBlock::METHOD_LZ4
          end
          if index.logical_size > Int64::MAX - total_raw_size
            raise UnsupportedFormatError.new("aggregate Nested raw size overflows")
          end
          total_raw_size += index.logical_size
          lanes << {logical_name, data_name, marks_name, data, marks, index.frames, index.logical_size}
        end
        budget.reserve_decoded_bytes(total_raw_size)
        budget.reserve_result_bytes(total_raw_size)

        workspace = CompressedBlock::DecodeWorkspace.new
        records = Array(ChecksumRecord).new(input.role_names.size * 2)
        lanes.each do |lane|
          _logical_name, data_name, marks_name, data, marks, frames, raw_size = lane
          raw_hash = CityHashV1::FileHasher.new
          frames.each { |frame| verify_frame_checksum!(data, frame) }
          frames.each do |frame|
            decoded = CompressedBlock.decode_frame_into(
              data, frame.compressed_offset, workspace,
              limits.max_frame_compressed_bytes,
              limits.max_frame_decompressed_bytes
            )
            unless decoded.end_offset == frame.end_offset && decoded.output.size.to_i64 == frame.decompressed_size
              raise CorruptPartError.new("Nested frame changed after header indexing")
            end
            raw_hash.update(decoded.output)
          end
          records << ChecksumRecord.new(
            data_name, data.size.to_u64, CityHashV1.file_hash(data), true,
            raw_size.to_u64, raw_hash.finish
          )
          records << ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false)
        end
        records
      end

      private def self.verify_frame_checksum!(data : Bytes, frame : CompressedFrameDescriptor) : Nil
        offset = frame.compressed_offset.to_i
        expected = {read_uint64_le(data, offset), read_uint64_le(data, offset + 8)}
        body_offset = offset + CompressedBlock::CHECKSUM_SIZE
        actual = CityHashV1.hash128(data[body_offset, frame.compressed_size.to_i])
        raise CorruptPartError.new("Nested compressed frame checksum does not match") unless actual == expected
        nil
      end

      private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
        if offset < 0 || offset > bytes.size - 8
          raise CorruptPartError.new("truncated Nested frame checksum")
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
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        records : Array(ChecksumRecord),
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : Nil
        unless Dir.children(stage).sort == input.expected_files
          raise CorruptPartError.new("staged Nested part file roster differs from preflight")
        end
        checksums = PartChecksums.open(stage)
        record_names = records.map(&.name).sort
        unless checksums.entries.keys.sort == record_names
          raise CorruptPartError.new("staged Nested checksums roster differs from generated files")
        end
        records.each { |record| checksums.validate_selected_entries(stage, record.name) }

        primary = PrimaryKeyIndex.open(stage, granules.size, checksums, verify_recorded_hash: true)
        unless primary.keys.size == granules.size + 1
          raise CorruptPartError.new("staged primary index has the wrong mark count")
        end
        key_start = 0
        granules.each_with_index do |granule, mark|
          unless primary.keys[mark] == keys[key_start]
            raise CorruptPartError.new("staged primary index differs from Nested key granules")
          end
          key_start += granule.size
        end
        raise CorruptPartError.new("staged primary index terminal differs from final key") unless primary.keys.last == keys.last

        key_part = WidePart.open(stage, key_name)
        unless key_part.row_count == keys.size.to_u64 && key_part.mark_count == granules.size
          raise CorruptPartError.new("staged UInt64 key row grid differs from Nested input")
        end
        key_start = 0
        granules.each_with_index do |granule, mark|
          unless key_part.mark_row_counts[mark] == granule.size.to_u64
            raise CorruptPartError.new("staged UInt64 key rows differ from Nested parent marks")
          end
          actual = key_part.read_uint64_mark_range(key_name, mark, 1)
          unless actual.size == granule.size
            raise CorruptPartError.new("staged UInt64 key granule size differs from Nested input")
          end
          granule.size.times do |offset|
            unless actual[offset] == keys[key_start + offset]
              raise CorruptPartError.new("staged UInt64 keys differ from Nested input")
            end
          end
          key_start += granule.size
        end

        reader = NestedBulkColumnReader.open(stage, value_name, type, limits, transport_limits)
        unless reader.row_count == keys.size.to_u64 && reader.mark_count == granules.size &&
               reader.schema_declaration == input.canonical_declaration &&
               reader.source_declaration == input.canonical_declaration &&
               reader.ordinary_profile == profile &&
               reader.physical_stream_names == input.role_names.values.sort!
          raise CorruptPartError.new("staged Nested declaration or physical grid differs from input")
        end
        expected_rows = granules.map { |granule| granule.size.to_u64 }
        unless reader.mark_row_counts == expected_rows
          raise CorruptPartError.new("staged Nested parent row grid differs from input")
        end
        actual_granules = reader.read_marks(0, granules.size)
        unless actual_granules.size == granules.size
          raise CorruptPartError.new("staged Nested reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows, mark|
          actual_rows = actual_granules[mark]
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged Nested reader returned the wrong parent row count")
          end
          expected_rows.each_with_index do |expected, row|
            compare_binary_value!(actual_rows[row], expected)
          end
        end
        nil
      end

      private def self.compare_binary_value!(actual : BinaryValue, expected : BinaryValue) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged Nested BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged Nested BinaryValue scalar bytes differ from input")
          end
        end
        actual.child_count.times { |index| compare_binary_value!(actual.child_at(index), expected.child_at(index)) }
        nil
      end

      private def self.validate_column_name!(name : String) : Nil
        unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("column name must be a bounded ASCII identifier")
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
