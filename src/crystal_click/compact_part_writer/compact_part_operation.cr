module CrystalClick
  # Owns the bounded whole-part write, staged validation, and exclusive
  # publication for the admitted static Compact mark formats.
  class CompactPartOperation
    private alias ChecksumRecord = PartWriterInfrastructure::ChecksumRecord

    def self.write_uint64_columns(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      rows_per_mark : Int32,
      frame_bytes : Int,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      reader_limits : CompressedStreamLimits,
      mark_format : CompactMarkFormat,
    ) : String
      validate_mark_format!(mark_format)
      validate_dimensions!(keys, columns, rows_per_mark)
      validate_column_name!(key_name)
      validate_column_set!(key_name, columns)
      validate_key_order!(keys)
      target, parent = validate_destination(destination)

      write_codec_budget = BinaryCodecBudget.new(limits, true)
      write_transport_budget = CompressedStreamBudget.new(transport_limits, true)
      read_codec_budget = BinaryCodecBudget.new(limits, false)
      read_transport_budget = CompressedStreamBudget.new(reader_limits, false)

      reserve_mark_grid!(write_transport_budget, mark_count(keys.size, rows_per_mark))
      rows_per_mark_grid = mark_rows(keys.size, rows_per_mark)
      key_snapshot, key_granules = snapshot_key_inputs(keys, rows_per_mark_grid, write_transport_budget)
      reserve_input_descriptors!(write_transport_budget, key_name, columns)
      value_inputs = Array(CompactStaticColumnInput).new(columns.size)
      columns.each { |column| value_inputs << column.static_input }
      key_input = CompactStaticColumnInput.new(
        key_name,
        BinaryDataType.primitive("UInt64"),
        key_granules,
      )
      backend_columns = Array(CompactStaticColumnInput).new(columns.size + 1)
      backend_columns << key_input
      value_inputs.each { |input| backend_columns << input }
      write_plan = CompactStaticWritePlan.new(backend_columns, limits, mark_format)

      metadata = CompactPartMetadata.new(
        key_name,
        value_inputs,
        keys.size.to_u64,
        limits,
        write_codec_budget,
        write_transport_budget,
        write_plan,
      )
      files = CompactStaticWriter.encode(
        backend_columns,
        rows_per_mark_grid,
        limits,
        frame_bytes,
        write_transport_budget,
        write_codec_budget,
        write_plan,
      )
      validate_output_sizes!(files, rows_per_mark_grid.size, write_plan.slot_count, write_plan.mark_format)

      data_size = files.data_size
      marks_size = files.marks_size
      reserve_pair_snapshot!(write_transport_budget, data_size, marks_size)
      data = files.data
      marks = files.marks

      index_record = planned_primary_index_record(key_snapshot, rows_per_mark_grid)
      reserve_primary_index_output!(write_transport_budget, index_record)
      count_bytes = metadata.count_text.to_slice
      serialization_bytes = metadata.serialization_text.to_slice
      records = Array(ChecksumRecord).new(5)
      records << ChecksumRecord.new(
        "data.bin",
        data_size.to_u64,
        files.data_hash,
        true,
        files.raw_size,
        files.raw_hash_fold,
      )
      marks_name = mark_file_name(write_plan.mark_format)
      records << ChecksumRecord.new(marks_name, marks_size.to_u64, files.marks_hash, false)
      records << index_record
      records << ChecksumRecord.new("count.txt", count_bytes.size.to_u64, CityHashV1.file_hash(count_bytes), false)
      records << ChecksumRecord.new(
        "serialization.json",
        serialization_bytes.size.to_u64,
        CityHashV1.file_hash(serialization_bytes),
        false,
      )
      checksums_size = PartWriterInfrastructure::PartChecksumsWriter.encoded_size(records)
      if checksums_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES || checksums_size > Int32::MAX
        raise UnsupportedFormatError.new("Compact checksums envelope exceeds the reader limit")
      end
      reserve_checksums_output!(write_transport_budget, checksums_size)
      checksums_bytes = PartWriterInfrastructure::PartChecksumsWriter.encode(records)
      unless checksums_bytes.size.to_i64 == checksums_size
        raise UnsupportedFormatError.new("Compact checksums envelope differs from its preflight")
      end

      stage = PartWriterInfrastructure::PartDirectoryPublisher.create_stage(parent)
      begin
        File.write(File.join(stage, "data.bin"), data)
        File.write(File.join(stage, marks_name), marks)
        written_index = PartWriterInfrastructure::PrimaryIndexWriter.write(
          stage,
          key_snapshot.to_unsafe.to_slice(key_snapshot.size),
          rows_per_mark,
        )
        unless same_checksum_record?(written_index, index_record)
          raise UnsupportedFormatError.new("Compact primary index changed after preflight")
        end

        File.write(File.join(stage, "columns.txt"), metadata.columns_text)
        if write_plan.mark_format.mrk4?
          File.write(File.join(stage, "columns_substreams.txt"), metadata.columns_substreams_text)
        end
        File.write(File.join(stage, "count.txt"), metadata.count_text)
        File.write(File.join(stage, "serialization.json"), metadata.serialization_text)
        File.write(File.join(stage, "default_compression_codec.txt"), metadata.codec_text)
        File.write(File.join(stage, "metadata_version.txt"), metadata.metadata_version_text)
        File.write(File.join(stage, "checksums.txt"), checksums_bytes)

        validate_staged_part!(
          stage,
          metadata,
          key_snapshot,
          value_inputs,
          rows_per_mark_grid,
          records,
          checksums_bytes,
          write_plan,
          limits,
          reader_limits,
          read_codec_budget,
          read_transport_budget,
        )
        PartWriterInfrastructure::PartDirectoryPublisher.publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    private def self.validate_dimensions!(
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      rows_per_mark : Int32,
    ) : Nil
      if keys.empty? || keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("Compact key rows are empty or exceed the writer limit")
      end
      if columns.empty? || columns.size >= WidePartTable::MAX_COLUMNS
        raise ArgumentError.new("Compact column count is outside the reader limit")
      end
      if rows_per_mark <= 0 || rows_per_mark > WidePartWriter::MAX_ROWS_PER_MARK ||
         rows_per_mark > WidePartTable::MAX_MARK_ROWS
        raise ArgumentError.new("rows_per_mark is outside the Compact reader limit")
      end
      marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      if marks <= 0 || marks > WidePartTable::MAX_MARKS_PER_READER || marks > Int32::MAX
        raise ArgumentError.new("Compact mark count is outside the reader limit")
      end
      nil
    end

    private def self.validate_column_set!(key_name : String, columns : Array(CompactPartColumn)) : Nil
      names = Set(String).new
      names << key_name
      columns.each do |column|
        validate_column_name!(column.name)
        unless names.add?(column.name)
          raise ArgumentError.new("Compact column names must be unique")
        end
      end
      nil
    end

    private def self.validate_column_name!(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= WidePartTable::MAX_COLUMN_NAME_BYTES &&
             /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("Compact column name is invalid or exceeds its reader bound")
      end
      nil
    end

    private def self.validate_mark_format!(mark_format : CompactMarkFormat) : Nil
      unless mark_format.mrk3? || mark_format.mrk4?
        raise UnsupportedFormatError.new("unsupported Compact mark format")
      end
      nil
    end

    private def self.validate_key_order!(keys : Slice(UInt64)) : Nil
      previous = nil.as(UInt64?)
      keys.each do |key|
        if prior = previous
          raise ArgumentError.new("Compact primary keys must be nondecreasing") if key < prior
        end
        previous = key
      end
      nil
    end

    private def self.validate_destination(destination : String) : Tuple(String, String)
      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      if File.exists?(target) || File.symlink?(target)
        raise ArgumentError.new("destination must not already exist")
      end
      {target, parent}
    end

    private def self.mark_rows(row_count : Int, rows_per_mark : Int32) : Array(UInt64)
      mark_count = ((row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64).to_i
      rows = Array(UInt64).new(mark_count)
      remaining = row_count
      while remaining > 0
        mark_rows = {remaining, rows_per_mark}.min
        rows << mark_rows.to_u64
        remaining -= mark_rows
      end
      rows
    end

    private def self.mark_count(row_count : Int, rows_per_mark : Int32) : Int
      ((row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64).to_i
    end

    private def self.reserve_mark_grid!(budget : CompressedStreamBudget, mark_count : Int) : Nil
      bytes = checked_add_u64(
        instance_sizeof(Array(UInt64)).to_u64,
        checked_multiply_u64(mark_count.to_u64, sizeof(UInt64).to_u64),
      )
      budget.reserve_result_bytes(to_i64(bytes))
      nil
    end

    private def self.reserve_input_descriptors!(
      budget : CompressedStreamBudget,
      key_name : String,
      columns : Array(CompactPartColumn),
    ) : Nil
      value_count = columns.size.to_u64
      input_count = value_count + 1_u64
      slot_count = value_count * 2_u64 + 1_u64
      bytes = checked_multiply_u64(instance_sizeof(Array(CompactStaticColumnInput)).to_u64, 2_u64)
      bytes = checked_add_u64(bytes, checked_multiply_u64(slot_count, sizeof(Pointer(CompactStaticColumnInput)).to_u64))
      bytes = checked_add_u64(bytes, checked_multiply_u64(input_count, instance_sizeof(CompactStaticColumnInput).to_u64))
      bytes = checked_add_u64(bytes, checked_multiply_u64(input_count, instance_sizeof(BinaryBulkProfile).to_u64))
      bytes = checked_add_u64(bytes, string_owner_bytes(key_name))
      columns.each do |column|
        bytes = checked_add_u64(bytes, string_owner_bytes(column.name))
        bytes = checked_add_u64(bytes, column.static_input_workspace_bytes)
      end
      budget.reserve_result_bytes(to_i64(bytes))
      nil
    end

    private def self.snapshot_key_inputs(
      keys : Slice(UInt64),
      rows : Array(UInt64),
      budget : CompressedStreamBudget,
    ) : Tuple(Array(UInt64), Array(Array(BinaryValue)))
      row_count = keys.size.to_u64
      per_row = instance_sizeof(BinaryValue).to_u64 + sizeof(Bytes).to_u64 + 8_u64 +
                sizeof(Pointer(BinaryValue)).to_u64 + sizeof(UInt64).to_u64
      array_bytes = instance_sizeof(Array(Array(BinaryValue))).to_u64 +
                    rows.size.to_u64 * sizeof(Pointer(Array(BinaryValue))).to_u64
      array_bytes = checked_add_u64(array_bytes, instance_sizeof(Array(UInt64)).to_u64)
      row_headers = rows.size.to_u64 * instance_sizeof(Array(BinaryValue)).to_u64
      if row_count > UInt64::MAX // per_row
        raise UnsupportedFormatError.new("Compact key snapshot workspace overflows")
      end
      workspace = checked_add_u64(checked_multiply_u64(row_count, per_row), checked_add_u64(array_bytes, row_headers))
      budget.reserve_result_bytes(to_i64(workspace))

      snapshot = Array(UInt64).new(keys.size)
      keys.each { |key| snapshot << key }
      granules = Array(Array(BinaryValue)).new(rows.size)
      key_offset = 0
      rows.each do |mark_rows|
        values = Array(BinaryValue).new(mark_rows.to_i)
        mark_rows.to_i.times do
          values << BinaryValue.uint64(snapshot[key_offset])
          key_offset += 1
        end
        granules << values
      end
      unless key_offset == snapshot.size
        raise ArgumentError.new("Compact key snapshot differs from its mark grid")
      end
      {snapshot, granules}
    end

    private def self.validate_output_sizes!(
      files : CompactStaticPartFiles,
      mark_count : Int,
      slot_count : Int,
      mark_format : CompactMarkFormat,
    ) : Nil
      data_size = files.data_size.to_i64
      marks_size = files.marks_size.to_i64
      if data_size <= 0 || data_size > WidePart::MAX_DATA_FILE_BYTES || data_size > Int32::MAX
        raise UnsupportedFormatError.new("Compact data.bin exceeds the typed reader bound")
      end
      if marks_size <= 0 || marks_size > WidePart::MAX_MARK_FILE_BYTES || marks_size > Int32::MAX
        raise UnsupportedFormatError.new("Compact #{mark_file_name(mark_format)} exceeds the typed reader bound")
      end
      if mark_count <= 0 || mark_count > WidePartTable::MAX_MARKS_PER_READER || slot_count <= 0
        raise UnsupportedFormatError.new("Compact mark count cannot represent the terminal record")
      end
      record_width = checked_add_u64(checked_multiply_u64(slot_count.to_u64, 16_u64), 8_u64)
      expected = checked_multiply_u64(checked_add_u64(mark_count.to_u64, 1_u64), record_width)
      unless marks_size.to_u64 == expected
        raise UnsupportedFormatError.new("Compact #{mark_file_name(mark_format)} output differs from its complete grid")
      end
      nil
    end

    private def self.mark_file_name(mark_format : CompactMarkFormat) : String
      case mark_format
      when CompactMarkFormat::Mrk3
        "data.mrk3"
      when CompactMarkFormat::Mrk4
        "data.mrk4"
      else
        raise UnsupportedFormatError.new("unsupported Compact mark format")
      end
    end

    private def self.reserve_pair_snapshot!(budget : CompressedStreamBudget, data_size : Int32, marks_size : Int32) : Nil
      total = data_size.to_i64 + marks_size.to_i64
      budget.reserve_result_bytes(total)
      nil
    end

    private def self.planned_primary_index_record(keys : Array(UInt64), rows : Array(UInt64)) : ChecksumRecord
      entry_count = rows.size.to_i64 + 1_i64
      physical_size = entry_count * 8_i64
      if physical_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
        raise UnsupportedFormatError.new("Compact primary index exceeds the reader limit")
      end
      scratch = Bytes.new(8)
      hasher = CityHashV1::FileHasher.new
      offset = 0
      rows.each do |mark_rows|
        PartWriterInfrastructure::StreamEncoding.write_uint64_le(scratch, 0, keys[offset])
        hasher.update(scratch)
        offset += mark_rows.to_i
      end
      PartWriterInfrastructure::StreamEncoding.write_uint64_le(scratch, 0, keys.last)
      hasher.update(scratch)
      ChecksumRecord.new("primary.idx", physical_size.to_u64, hasher.finish, false)
    end

    private def self.reserve_primary_index_output!(budget : CompressedStreamBudget, record : ChecksumRecord) : Nil
      file_bytes = to_i64(record.physical_size)
      if file_bytes > (Int64::MAX - 64_i64 - instance_sizeof(IO::Memory).to_i64) // 2_i64
        raise UnsupportedFormatError.new("Compact primary-index workspace overflows")
      end

      # PrimaryIndexWriter first accumulates the exact index in IO::Memory.
      # Reserve for geometric backing capacity plus fixed writer/view overhead,
      # independently of the exact primary.idx file-byte charge.
      workspace_bytes = file_bytes * 2_i64 + 64_i64 + instance_sizeof(IO::Memory).to_i64
      budget.preflight_file_bytes(file_bytes)
      budget.preflight_result_bytes(workspace_bytes)
      budget.reserve_file_bytes(file_bytes)
      budget.reserve_result_bytes(workspace_bytes)
      nil
    end

    private def self.reserve_checksums_output!(budget : CompressedStreamBudget, byte_count : Int64) : Nil
      if byte_count > Int64::MAX // 3_i64
        raise UnsupportedFormatError.new("Compact checksums workspace overflows")
      end
      budget.reserve_file_bytes(byte_count)
      budget.reserve_result_bytes(byte_count * 3_i64)
      nil
    end

    private def self.validate_staged_part!(
      stage : String,
      metadata : CompactPartMetadata,
      keys : Array(UInt64),
      value_inputs : Array(CompactStaticColumnInput),
      rows : Array(UInt64),
      records : Array(ChecksumRecord),
      expected_checksums : Bytes,
      write_plan : CompactStaticWritePlan,
      limits : BinaryCodecLimits,
      reader_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      unless Dir.children(stage).sort == metadata.expected_files.sort
        raise CorruptPartError.new("staged Compact file roster differs from preflight")
      end

      metadata_reader = PartMetadataFileReader.new(stage, transport_budget)
      expected_metadata = [
        {"columns.txt", metadata.columns_text, WidePart::MAX_METADATA_FILE_BYTES.to_i64},
        {"count.txt", metadata.count_text, 32_i64},
        {"serialization.json", metadata.serialization_text, WidePart::MAX_METADATA_FILE_BYTES.to_i64},
        {"default_compression_codec.txt", metadata.codec_text, WidePart::MAX_CODEC_FILE_BYTES.to_i64},
        {"metadata_version.txt", metadata.metadata_version_text, 32_i64},
      ] of Tuple(String, String, Int64)
      if write_plan.mark_format.mrk4?
        expected_metadata << {
          "columns_substreams.txt",
          metadata.columns_substreams_text,
          WidePart::MAX_METADATA_FILE_BYTES.to_i64,
        }
      end
      expected_metadata.each do |name, expected, maximum|
        transport_budget.reserve_result_bytes(expected.bytesize.to_i64)
        actual = metadata_reader.read(name, maximum)
        unless actual == expected
          raise CorruptPartError.new("staged Compact metadata differs from preflight")
        end
      end

      transport_budget.reserve_result_bytes(expected_checksums.size.to_i64)
      checksum_text = metadata_reader.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES)
      unless bytes_equal?(checksum_text.to_slice, expected_checksums)
        raise CorruptPartError.new("staged Compact checksums differ from preflight")
      end
      checksums = PartChecksums.parse(checksum_text.to_slice)
      expected_names = records.map(&.name).sort
      unless checksums.entries.keys.sort == expected_names
        raise CorruptPartError.new("staged Compact checksum roster differs from generated files")
      end
      records.each do |record|
        entry = checksums.entry(record.name) || raise(CorruptPartError.new("staged Compact checksum entry is missing"))
        unless entry.physical_size == record.physical_size && entry.file_hash == record.file_hash &&
               entry.compressed == record.compressed && entry.uncompressed_size == record.uncompressed_size
          raise CorruptPartError.new("staged Compact checksum declaration differs from preflight")
        end
        checksums.validate_selected_entries(stage, record.name)
      end

      data_record = records.find { |record| record.name == "data.bin" } ||
                    raise(CorruptPartError.new("staged Compact data.bin checksum record is missing"))
      planned_data_size = data_record.physical_size
      slot_count = write_plan.slot_count
      CompactReadbackGrid.preflight!(transport_budget, rows.size, slot_count, planned_data_size)

      context = CompactPartPhysicalContext.open(stage, transport_budget)
      context_workspace = checked_add_u64(context.retained_workspace_bytes, context.retained_grid_workspace_bytes)
      transport_budget.reserve_result_bytes(to_i64(context_workspace))
      unless context.mode == write_plan.mark_format && context.row_count == keys.size.to_u64 &&
             context.granule_count == rows.size && context.columns == metadata.schema_columns
        raise CorruptPartError.new("staged Compact physical metadata differs from preflight")
      end
      if write_plan.mark_format.mrk4?
        transport_budget.reserve_result_bytes(to_i64(metadata.physical_roster_snapshot_workspace_bytes))
      end
      unless metadata.physical_roster_matches?(context.physical_roster) &&
             context.mark_row_counts == rows
        raise CorruptPartError.new("staged Compact physical grid differs from preflight")
      end

      index_bytes = (rows.size.to_i64 + 1_i64) * 8_i64
      if index_bytes > Int64::MAX // 2_i64
        raise UnsupportedFormatError.new("Compact primary-index validation workspace overflows")
      end
      transport_budget.reserve_file_bytes(index_bytes)
      transport_budget.reserve_result_bytes(index_bytes * 2_i64)
      primary = PrimaryKeyIndex.open(stage, rows.size, checksums, verify_recorded_hash: true)
      offset = 0
      rows.each_with_index do |mark_rows, mark|
        unless primary.keys[mark] == keys[offset]
          raise CorruptPartError.new("staged Compact primary index differs from the parent grid")
        end
        offset += mark_rows.to_i
      end
      unless offset == keys.size && primary.keys.last == keys.last
        raise CorruptPartError.new("staged Compact primary-index terminal differs from the final key")
      end

      key_type = BinaryDataType.primitive("UInt64")
      key_name = metadata.schema_columns[0][0]
      validate_column_values!(
        stage,
        key_name,
        key_type,
        keys,
        nil,
        rows,
        planned_data_size,
        slot_count,
        limits,
        reader_limits,
        codec_budget,
        transport_budget,
      )
      value_inputs.each do |input|
        validate_column_values!(
          stage,
          input.name,
          input.type,
          keys,
          input.granules,
          rows,
          planned_data_size,
          slot_count,
          limits,
          reader_limits,
          codec_budget,
          transport_budget,
        )
      end
    end

    private def self.validate_column_values!(
      stage : String,
      name : String,
      type : BinaryDataType,
      keys : Array(UInt64),
      input : Array(Array(BinaryValue))?,
      rows : Array(UInt64),
      planned_data_size : UInt64,
      slot_count : Int,
      limits : BinaryCodecLimits,
      reader_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      unless BinaryValueTypedBatchAdapter.admitted?(type)
        raise UnsupportedFormatError.new("Compact selected type has no established typed batch carrier")
      end
      CompactReadbackGrid.preflight!(transport_budget, rows.size, slot_count, planned_data_size)
      reader = CompactBinaryBulkColumnReader.open(
        stage,
        name,
        type,
        limits,
        reader_limits,
        codec_budget,
        transport_budget,
      )
      unless reader.row_count == keys.size.to_u64 && reader.mark_row_counts == rows
        raise CorruptPartError.new("staged Compact typed reader differs from the parent grid")
      end
      reader_base = reader.retained_workspace_bytes
      if reader_base > reader_limits.max_result_bytes.to_u64
        raise UnsupportedFormatError.new("staged Compact reader workspace exceeds its result limit")
      end
      transport_budget.reserve_result_bytes(to_i64(reader_base))
      mark_offset = 0
      rows.each_with_index do |mark_rows, mark_index|
        peak_workspace = 0_u64
        output_workspace = column_result_workspace(input, mark_index, mark_rows)
        transport_budget.reserve_result_bytes(to_i64(output_workspace))
        observer = ->(workspace : UInt64) do
          transport_budget.preflight_result_bytes(to_i64(workspace))
          peak_workspace = workspace if workspace > peak_workspace
          nil
        end
        actual_marks = reader.read_marks(mark_index, 1, observer)
        unless actual_marks.size == 1 && actual_marks[0].size.to_u64 == mark_rows
          raise CorruptPartError.new("staged Compact typed readback returned the wrong parent grid")
        end
        values = actual_marks[0]
        mark_rows.to_i.times do |row|
          value = values[row]
          if input_granules = input
            expected = input_granules[mark_index][row]
            unless binary_values_equal?(value, expected)
              raise CorruptPartError.new("staged Compact values differ from the immutable input")
            end
          else
            unless value.type == type && !value.is_null? && decode_uint64(value) == keys[mark_offset + row]
              raise CorruptPartError.new("staged Compact key values differ from the immutable input")
            end
          end
        end
        # Keep the observer's full transient peak separate from the retained
        # reader-base census above; its reported workspace must not be reduced
        # by a second estimate of that base.
        transport_budget.reserve_result_bytes(to_i64(peak_workspace))
        mark_offset += mark_rows.to_i
      end
      unless mark_offset == keys.size
        raise CorruptPartError.new("staged Compact readback did not consume all input rows")
      end
      nil
    end

    private def self.binary_values_equal?(left : BinaryValue, right : BinaryValue) : Bool
      return false unless left.type == right.type && left.is_null? == right.is_null? &&
                          left.byte_size == right.byte_size && left.child_count == right.child_count
      left.byte_size.times do |index|
        return false unless left.byte_at(index) == right.byte_at(index)
      end
      left.child_count.times do |index|
        return false unless binary_values_equal?(left.child_at(index), right.child_at(index))
      end
      true
    end

    private def self.column_result_workspace(
      input : Array(Array(BinaryValue))?,
      mark_index : Int,
      rows : UInt64,
    ) : UInt64
      row_count = rows.to_u64
      bytes = checked_add_u64(
        instance_sizeof(Array(Array(BinaryValue))).to_u64 + sizeof(Pointer(Array(BinaryValue))).to_u64,
        checked_add_u64(
          instance_sizeof(Array(BinaryValue)).to_u64,
          checked_multiply_u64(row_count, sizeof(Pointer(BinaryValue)).to_u64),
        ),
      )
      if granules = input
        granule = granules[mark_index]
        row_count.times do |row|
          bytes = checked_add_u64(bytes, binary_value_workspace(granule[row.to_i]))
        end
      else
        key_value_bytes = instance_sizeof(BinaryValue).to_u64 + instance_sizeof(Array(BinaryValue)).to_u64 + 8_u64
        bytes = checked_add_u64(bytes, checked_multiply_u64(row_count, key_value_bytes))
      end
      bytes
    end

    private def self.binary_value_workspace(value : BinaryValue) : UInt64
      bytes = instance_sizeof(BinaryValue).to_u64
      bytes = checked_add_u64(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
      bytes = checked_add_u64(bytes, value.byte_size.to_u64)
      bytes = checked_add_u64(
        bytes,
        checked_multiply_u64(value.child_count.to_u64, sizeof(Pointer(BinaryValue)).to_u64),
      )
      value.child_count.times do |child|
        bytes = checked_add_u64(bytes, binary_value_workspace(value.child_at(child)))
      end
      bytes
    end

    private def self.decode_uint64(value : BinaryValue) : UInt64
      unless value.type.tag == BinaryDataType::TAG_UINT64 && value.byte_size == 8
        raise CorruptPartError.new("staged Compact key has a non-UInt64 carrier")
      end
      decoded = 0_u64
      8.times { |index| decoded |= value.byte_at(index).to_u64 << (index * 8) }
      decoded
    end

    private def self.same_checksum_record?(left : ChecksumRecord, right : ChecksumRecord) : Bool
      left.name == right.name && left.physical_size == right.physical_size &&
        left.file_hash == right.file_hash && left.compressed == right.compressed &&
        left.uncompressed_size == right.uncompressed_size && left.uncompressed_hash == right.uncompressed_hash
    end

    private def self.bytes_equal?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.size.times { |index| return false unless left[index] == right[index] }
      true
    end

    private def self.checked_add_u64(left : UInt64, right : UInt64) : UInt64
      raise UnsupportedFormatError.new("Compact workspace size overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def self.checked_multiply_u64(left : UInt64, right : UInt64) : UInt64
      raise UnsupportedFormatError.new("Compact workspace size overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end

    private def self.to_i64(value : UInt64) : Int64
      raise UnsupportedFormatError.new("Compact workspace exceeds Int64") if value > Int64::MAX.to_u64
      value.to_i64
    end

    private def self.string_owner_bytes(value : String) : UInt64
      checked_add_u64(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end
  end
end
