module CrystalClick
  module WidePartWriter
    # Owns the key/value envelope's checksums, staged validation, and atomic
    # publication. The nominal adapter supplies only encoded lane ownership
    # and its value-specific staged-reader check.
    private class WidePartPublisher
      def self.write(
        input : WidePartPublicationInput,
        keys : Slice(UInt64),
        metadata : WidePartMetadataEnvelope,
        encoded_files : Hash(String, CompressedMarkFiles),
        rows_per_mark : Int32,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        validation_transport_budget : CompressedStreamBudget? = nil,
        projections : Array(ProjectionPreparedPart) = [] of ProjectionPreparedPart,
        additional_index_keys : Array(Slice(UInt64)) = [] of Slice(UInt64),
        frame_bytes : Int = 4096,
        write_transport_budget : CompressedStreamBudget? = nil,
        &validate_value : String -> Nil
      ) : String
        unless keys.size.to_u64 == input.expected_rows.sum(0_u64)
          raise ArgumentError.new("shared writer keys differ from its preflighted parent grid")
        end
        unless additional_index_keys.size == input.additional_key_names.size
          raise ArgumentError.new("compound projection index key count differs from its prepared key roster")
        end
        input.additional_key_names.each_with_index do |name, index|
          expected_stream = PhysicalStreamName.escape(name)
          unless additional_index_keys[index].size == keys.size && input.lane_bindings.any? { |binding|
                   binding.column_name == name && binding.logical_name == expected_stream
                 }
            raise ArgumentError.new("compound projection index differs from its prepared UInt64 key lanes")
          end
        end
        compound_key_columns = if additional_index_keys.empty?
                                 nil
                               else
                                 columns = Array(Slice(UInt64)).new(additional_index_keys.size + 1)
                                 columns << keys
                                 additional_index_keys.each { |key_column| columns << key_column }
                                 columns
                               end
        if rows_per_mark <= 0 || rows_per_mark > MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless encoded_files.size == input.logical_names.size && encoded_files.keys.sort == input.logical_names
          raise UnsupportedFormatError.new("encoded lanes differ from the admitted physical roster")
        end
        unless projections.map(&.entry_name) == input.projection_entries
          raise UnsupportedFormatError.new("prepared projections differ from the admitted parent roster")
        end
        if input.compress_marks
          budget = write_transport_budget || raise ArgumentError.new("compressed Wide marks require a shared write budget")
          budget.ensure_direction(true)
        end

        records = Array(ChecksumRecord).new(input.checksum_entry_count)
        lanes = checksum_column_files(
          encoded_files, input, transport_limits, records, validation_transport_budget,
          frame_bytes, write_transport_budget
        )
        stage = PartDirectoryPublisher.create_stage(input.parent)
        begin
          key_records = LeafStreamWriter.write_uint64_stream(
            stage, input.key_name, keys, rows_per_mark, nil,
            TupleLeafMarkSchedule::Axis::Leaf,
            input.compress_marks, frame_bytes, write_transport_budget
          )
          validate_key_record_roster!(key_records, input.key_name, input.compress_marks)
          records.concat(key_records)

          lanes.each do |lane|
            File.write(File.join(stage, lane.binding.data_filename), lane.data)
            File.write(File.join(stage, lane.binding.marks_filename), lane.marks)
          end

          if index_keys = compound_key_columns
            records << PrimaryIndexWriter.write_compound(stage, index_keys, rows_per_mark)
          else
            records << PrimaryIndexWriter.write(stage, keys, rows_per_mark)
          end
          records << write_checksummed_file(stage, "count.txt", metadata.count)
          records << write_checksummed_file(stage, "serialization.json", metadata.serialization)
          File.write(File.join(stage, "columns.txt"), metadata.columns)
          File.write(File.join(stage, "columns_substreams.txt"), metadata.substreams)
          File.write(File.join(stage, "default_compression_codec.txt"), metadata.codec)
          File.write(File.join(stage, "metadata_version.txt"), metadata.metadata_version)
          projections.each { |projection| records << projection.publish(stage) }
          PartChecksumsWriter.write(stage, records)

          validate_staged_part!(
            stage, input, keys, metadata, records, transport_limits,
            validation_transport_budget, projections, compound_key_columns
          )
          validate_value.call(stage)
          PartDirectoryPublisher.publish_exclusively(stage, input.target)
          input.target
        ensure
          FileUtils.rm_rf(stage) if Dir.exists?(stage)
        end
      end

      private def self.checksum_column_files(
        files : Hash(String, CompressedMarkFiles),
        input : WidePartPublicationInput,
        limits : CompressedStreamLimits,
        records : Array(ChecksumRecord),
        validation_transport_budget : CompressedStreamBudget?,
        frame_bytes : Int,
        write_transport_budget : CompressedStreamBudget?,
      ) : Array(WidePartLane)
        budget = validation_transport_budget || CompressedStreamBudget.new(limits, true)
        if validation_transport_budget
          budget.ensure_direction(false)
        end
        expected_mark_size = (input.mark_count.to_i64 + 1_i64) * CompressedMarkWriter::MARK_RECORD_SIZE
        lanes = Array(WidePartLane).new(input.lane_bindings.size)
        total_raw_size = 0_i64

        input.lane_bindings.each do |binding|
          pair = files[binding.logical_name]
          data = pair.data
          canonical_marks = pair.marks
          if data.size.to_i64 > MAX_DATA_FILE_BYTES || data.size > Int32::MAX
            raise UnsupportedFormatError.new("value data file exceeds reader limit")
          end
          unless canonical_marks.size.to_i64 == expected_mark_size && canonical_marks.size.to_i64 <= WidePart::MAX_MARK_FILE_BYTES
            raise UnsupportedFormatError.new("value mark file differs from the complete parent grid")
          end
          canonical_mark_hash = CityHashV1.file_hash(canonical_marks)
          marks = if input.compress_marks
                    write_budget = write_transport_budget || raise ArgumentError.new("compressed Wide marks require a shared write budget")
                    encoded = CompressedMarkWriter.encode_all(canonical_marks, frame_bytes, write_budget)
                    if encoded.size.to_i64 > WidePart::MAX_MARK_FILE_BYTES.to_i64 ||
                       encoded.size.to_i64 > write_budget.limits.max_mark_bytes
                      raise UnsupportedFormatError.new("compressed Wide marks exceed their configured mark-size limit")
                    end
                    encoded
                  else
                    canonical_marks
                  end
          if data.size.to_i64 > Int64::MAX - marks.size.to_i64
            raise UnsupportedFormatError.new("value lane file byte count overflows")
          end
          budget.reserve_file_bytes(data.size.to_i64 + marks.size.to_i64)

          frames = [] of CompressedFrameDescriptor
          logical_size = 0_i64
          unless data.empty?
            index = CompressedFrameIndex.new(data, limits, budget)
            if index.logical_size > MAX_DATA_FILE_BYTES
              raise UnsupportedFormatError.new("value raw data exceeds reader limit")
            end
            index.frames.each do |frame|
              unless frame.method == CompressedBlock::METHOD_LZ4
                raise UnsupportedFormatError.new("Wide part output must use LZ4 frames")
              end
            end
            if index.logical_size > Int64::MAX - total_raw_size
              raise UnsupportedFormatError.new("aggregate value raw size overflows")
            end
            logical_size = index.logical_size
            total_raw_size += logical_size
            frames = index.frames
          end

          lanes << WidePartLane.new(
            binding, data, marks, frames, logical_size,
            canonical_marks.size.to_u64, canonical_mark_hash
          )
        end

        budget.reserve_decoded_bytes(total_raw_size)
        budget.reserve_result_bytes(total_raw_size)

        workspace = CompressedBlock::DecodeWorkspace.new
        lanes.each do |lane|
          raw_hash = CityHashV1::FileHasher.new
          lane.frames.each do |frame|
            verify_frame_checksum!(lane.data, frame)
            decoded = CompressedBlock.decode_frame_into(
              lane.data, frame.compressed_offset, workspace,
              limits.max_frame_compressed_bytes,
              limits.max_frame_decompressed_bytes
            )
            unless decoded.end_offset == frame.end_offset && decoded.output.size.to_i64 == frame.decompressed_size
              raise CorruptPartError.new("value frame changed after header indexing")
            end
            raw_hash.update(decoded.output)
          end
          records << ChecksumRecord.new(
            lane.binding.data_filename,
            lane.data.size.to_u64,
            CityHashV1.file_hash(lane.data),
            true,
            lane.logical_size.to_u64,
            raw_hash.finish
          )
          marks_hash = if input.compress_marks
                         CityHashV1.file_hash(lane.marks)
                       else
                         lane.canonical_marks_hash
                       end
          marks_record = if input.compress_marks
                           ChecksumRecord.new(
                             lane.binding.marks_filename,
                             lane.marks.size.to_u64,
                             marks_hash,
                             true,
                             lane.canonical_marks_size,
                             lane.canonical_marks_hash,
                           )
                         else
                           ChecksumRecord.new(
                             lane.binding.marks_filename,
                             lane.marks.size.to_u64,
                             marks_hash,
                             false,
                           )
                         end
          records << marks_record
        end
        lanes
      end

      private def self.verify_frame_checksum!(data : Bytes, frame : CompressedFrameDescriptor) : Nil
        offset = frame.compressed_offset.to_i
        expected = {read_uint64_le(data, offset), read_uint64_le(data, offset + 8)}
        body_offset = offset + CompressedBlock::CHECKSUM_SIZE
        actual = CityHashV1.hash128(data[body_offset, frame.compressed_size.to_i])
        raise CorruptPartError.new("compressed value frame checksum does not match") unless actual == expected
        nil
      end

      private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
        if offset < 0 || offset > bytes.size - 8
          raise CorruptPartError.new("truncated compressed frame checksum")
        end
        value = 0_u64
        8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
        value
      end

      private def self.validate_key_record_roster!(
        records : Array(ChecksumRecord),
        key_name : String,
        compress_marks : Bool,
      ) : Nil
        base = StreamName.hash(key_name)
        expected_data = PhysicalStreamName.append_literal(base, ".bin")
        expected_marks = PhysicalStreamName.append_literal(base, compress_marks ? ".cmrk2" : ".mrk2")
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
        input : WidePartPublicationInput,
        keys : Slice(UInt64),
        metadata : WidePartMetadataEnvelope,
        records : Array(ChecksumRecord),
        transport_limits : CompressedStreamLimits,
        validation_transport_budget : CompressedStreamBudget?,
        projections : Array(ProjectionPreparedPart),
        compound_key_columns : Array(Slice(UInt64))?,
      ) : Nil
        unless Dir.children(stage).sort == input.expected_files
          raise CorruptPartError.new("staged part file roster differs from preflight")
        end
        checksums = PartChecksums.open(stage)
        record_names = records.map(&.name).sort
        unless checksums.entries.keys.sort == record_names
          raise CorruptPartError.new("staged checksums roster differs from generated files")
        end
        records.each do |record|
          if record.name.ends_with?(".proj")
            entry = checksums.entry(record.name) ||
                    raise CorruptPartError.new("projection summary entry is absent from checksums.txt")
            projection = projections.find { |child| child.entry_name == record.name } ||
                         raise CorruptPartError.new("projection summary has no prepared child")
            ProjectionPartSummary.validate_entry!(
              stage, record.name, entry, projection.summary_sidecars
            )
          else
            checksums.validate_selected_entries(stage, record.name)
          end
        end
        validate_metadata_files!(stage, metadata)

        primary = nil.as(PrimaryKeyIndex?)
        if index_keys = compound_key_columns
          unless input.additional_key_names.size + 1 == index_keys.size
            raise CorruptPartError.new("compound primary index key count differs from its bound roster")
          end
          PrimaryIndexWriter.validate_compound!(stage, input.expected_rows, index_keys, checksums)
        else
          unless input.additional_key_names.empty?
            raise CorruptPartError.new("bound compound keys have no compound primary index")
          end
          opened = PrimaryKeyIndex.open(stage, input.mark_count, checksums, verify_recorded_hash: true)
          unless opened.keys.size == input.mark_count + 1
            raise CorruptPartError.new("staged primary index has the wrong mark count")
          end
          primary = opened
        end

        key_part = WidePart.open(stage, input.key_name)
        unless key_part.row_count == keys.size.to_u64 && key_part.mark_count == input.mark_count &&
               key_part.mark_row_counts == input.expected_rows
          raise CorruptPartError.new("staged UInt64 key row grid differs from the preflighted parent grid")
        end
        key_start = 0
        input.expected_rows.each_with_index do |rows, mark|
          if scalar_primary = primary
            unless scalar_primary.keys[mark] == keys[key_start]
              raise CorruptPartError.new("staged primary index differs from key parent marks")
            end
          end
          actual = key_part.read_uint64_mark_range(input.key_name, mark, 1)
          unless actual.size.to_u64 == rows
            raise CorruptPartError.new("staged UInt64 key granule differs from the parent grid")
          end
          rows.to_i.times do |offset|
            unless actual[offset] == keys[key_start + offset]
              raise CorruptPartError.new("staged UInt64 keys differ from input")
            end
          end
          key_start += rows.to_i
        end
        unless key_start == keys.size
          raise CorruptPartError.new("staged key marks do not consume the complete key stream")
        end
        if scalar_primary = primary
          unless scalar_primary.keys.last == keys.last
            raise CorruptPartError.new("staged primary index terminal differs from the final key")
          end
        end

        validate_value_grids!(stage, input, checksums, transport_limits, validation_transport_budget)
        nil
      end

      private def self.validate_metadata_files!(stage : String, metadata : WidePartMetadataEnvelope) : Nil
        unless File.read(File.join(stage, "count.txt")) == metadata.count &&
               File.read(File.join(stage, "serialization.json")) == metadata.serialization &&
               File.read(File.join(stage, "columns.txt")) == metadata.columns &&
               File.read(File.join(stage, "columns_substreams.txt")) == metadata.substreams &&
               File.read(File.join(stage, "default_compression_codec.txt")) == metadata.codec &&
               File.read(File.join(stage, "metadata_version.txt")) == metadata.metadata_version
          raise CorruptPartError.new("staged metadata differs from its preflighted envelope")
        end
        nil
      rescue ex : IO::Error
        raise CorruptPartError.new(ex.message || "cannot read staged metadata")
      end

      private def self.validate_value_grids!(
        stage : String,
        input : WidePartPublicationInput,
        checksums : PartChecksums,
        transport_limits : CompressedStreamLimits,
        validation_transport_budget : CompressedStreamBudget?,
      ) : Nil
        budget = validation_transport_budget || CompressedStreamBudget.new(transport_limits)
        if input.compress_marks
          source = PartStreamSource.new(stage, checksums)
          key_data_name = PhysicalStreamName.append_literal(StreamName.hash(input.key_name), ".bin")
          key_marks_name = PhysicalStreamName.append_literal(StreamName.hash(input.key_name), ".cmrk2")
          validate_compressed_mark_grid!(
            source, key_data_name, key_marks_name, input.expected_rows, budget
          )
        end
        input.lane_bindings.each do |binding|
          data_entry = checksums.entry(binding.data_filename) ||
                       raise CorruptPartError.new("value data stream is absent from checksums.txt")
          unless data_entry.compressed && !data_entry.uncompressed_size.nil?
            raise CorruptPartError.new("value data stream lacks compressed checksum metadata")
          end
          grid = if input.compress_marks
                   validate_compressed_mark_grid!(
                     source.not_nil!, binding.data_filename, binding.marks_filename,
                     input.expected_rows, budget
                   )
                 else
                   marks_entry = checksums.entry(binding.marks_filename) ||
                                 raise CorruptPartError.new("value marks stream is absent from checksums.txt")
                   CompressedMarkReader.inspect(
                     File.join(stage, binding.data_filename),
                     File.join(stage, binding.marks_filename),
                     data_entry.physical_size.to_i64,
                     marks_entry.physical_size.to_i64,
                     budget: budget
                   )
                 end
          unless grid.rows_per_mark == input.expected_rows &&
                 grid.logical_size.to_u64 == data_entry.uncompressed_size.not_nil!
            raise CorruptPartError.new("staged value lane differs from the complete parent mark grid")
          end
        end
        nil
      end

      private def self.validate_compressed_mark_grid!(
        source : PartStreamSource,
        data_name : String,
        marks_name : String,
        expected_rows : Array(UInt64),
        budget : CompressedStreamBudget,
      ) : CompressedMarkGrid
        data_entry = source.checksum_entry(data_name) ||
                     raise CorruptPartError.new("compressed mark data stream is absent from checksums.txt")
        marks_entry = source.checksum_entry(marks_name) ||
                      raise CorruptPartError.new("compressed marks stream is absent from checksums.txt")
        unless data_entry.compressed && !data_entry.uncompressed_size.nil?
          raise CorruptPartError.new("compressed mark data stream lacks compressed checksum metadata")
        end
        physical_input = source.physical_input(data_name, marks_name)
        adapter = WideMarkFileAdapter.new(marks_name, marks_entry)
        canonical = adapter.read_canonical_marks(physical_input, budget) ||
                    raise CorruptPartError.new("compressed Wide marks did not produce canonical bytes")
        grid = CompressedMarkReader.inspect_canonical(
          physical_input.data_path,
          physical_input.data_size,
          canonical,
          0,
          budget,
        )
        unless grid.rows_per_mark == expected_rows &&
               grid.logical_size.to_u64 == data_entry.uncompressed_size.not_nil!
          raise CorruptPartError.new("staged compressed marks differ from the complete parent grid")
        end
        grid
      end
    end
  end
end
