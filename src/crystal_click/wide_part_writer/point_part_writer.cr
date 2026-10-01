module CrystalClick
  module WidePartWriter
    # Owns the bounded paired Point profile: exact metadata, Float64 leaf
    # routing, primary-key association, and pre-publication typed readback.
    # Framing, checksums, index serialization and publication stay shared.
    private class PointPartWriter
      CHECKSUMED_METADATA_RESERVE = 4096_u64

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        values : Slice(WidePointValue),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
        before_validation_hook : Proc(String, Nil),
      ) : String
        input = preflight(destination, key_name, keys, value_name, values, rows_per_mark, infrastructure)
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size), input.rows_per_mark
          ))

          coordinate_type = input.type_plan.coordinate_type
          x_stream, y_stream = input.type_plan.coordinate_streams(input.value_name)
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, x_stream, coordinate_type,
            input.x_values.as(TupleLeafBuffers), nil, input.schedule, infrastructure
          ))
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, y_stream, coordinate_type,
            input.y_values.as(TupleLeafBuffers), nil, input.schedule, infrastructure
          ))

          records << infrastructure.write_primary_index(
            stage, input.keys.to_unsafe.to_slice(input.keys.size), input.rows_per_mark
          )
          records << infrastructure.write_checksummed_file(stage, "count.txt", input.keys.size.to_s)
          records << infrastructure.write_checksummed_file(stage, "serialization.json", input.serialization_metadata)
          infrastructure.write_plain_metadata(stage, "columns.txt", input.columns_metadata)
          infrastructure.write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
          infrastructure.write_plain_metadata(stage, "metadata_version.txt", "0")
          infrastructure.write_plain_metadata(stage, "columns_substreams.txt", input.substreams_metadata)
          infrastructure.write_checksums(stage, records)

          # The test-only seam can alter a stage but cannot mutate the owned
          # expected snapshots or replace the validator.
          before_validation_hook.call(stage)
          validate_staged_part(stage, input, records)
          infrastructure.publish_exclusively(stage, input.target)
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
        values : Slice(WidePointValue),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : PointPartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("columns must be distinct") if key_name == value_name
        if keys.empty? || keys.size != values.size
          raise ArgumentError.new("keys and Point values must have the same nonzero row count")
        end
        if keys.size.to_u64 > WidePart::MAX_ROWS
          raise ArgumentError.new("row count exceeds writer limit")
        end
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        if rows_per_mark > MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark exceeds writer limit")
        end

        type_plan = PointColumnType.for_type("Point") ||
                    raise ArgumentError.new("Point writer requires the exact Point descriptor")
        previous = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
          previous = key
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        if mark_count > MAX_MARKS
          raise ArgumentError.new("Point mark count exceeds reader limit")
        end
        mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
        if mark_file_size > MAX_MARK_FILE_BYTES
          raise ArgumentError.new("Point mark file exceeds reader limit")
        end
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        if index_size > MAX_PRIMARY_INDEX_BYTES || index_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
          raise ArgumentError.new("primary index exceeds reader limit")
        end

        x_stream, y_stream = type_plan.coordinate_streams(value_name)
        logical_streams = [key_name, x_stream, y_stream]
        if logical_streams.map { |name| StreamName.hash(name) }.uniq.size != logical_streams.size
          raise ArgumentError.new("Point physical stream names must be distinct")
        end
        logical_streams.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("Point physical stream name exceeds reader limit")
          end
        end

        schedule = TupleLeafMarkSchedule.row_aligned(keys.size, rows_per_mark)
        compressed_sizes, raw_sizes = preflight_stream_budgets(keys.size, rows_per_mark, mark_count, infrastructure)

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        columns_metadata = columns_metadata(key_name, value_name)
        substreams_metadata = substreams_metadata(key_name, value_name, x_stream, y_stream)
        serialization_metadata = PointSerializationStatistics.build(key_name, keys, value_name, values)
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )
        validate_materialization_charge(type_plan, keys.size, mark_count, rows_per_mark, schedule)

        # Retain exact raw bits only after all schema, frame, metadata, index,
        # schedule and combined reader/writer ownership limits have passed.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        x_values = Array(Float64).new(values.size) { |index| values[index].x }
        y_values = Array(Float64).new(values.size) { |index| values[index].y }

        PointPartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, type_plan,
          x_values, y_values, logical_streams, compressed_sizes, raw_sizes,
          mark_count, mark_file_size, index_size, rows_per_mark, schedule,
          columns_metadata, substreams_metadata, serialization_metadata
        )
      end

      private def self.preflight_stream_budgets(
        row_count : Int32,
        rows_per_mark : Int32,
        mark_count : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64)}
        raw_size = checked_multiply(row_count.to_u64, 8_u64, "Point coordinate stream bytes")
        if raw_size > MAX_DATA_FILE_BYTES.to_u64
          raise ArgumentError.new("Point coordinate stream exceeds reader limit")
        end

        compressed_sizes = Array(Int64).new(3, 0_i64)
        raw_sizes = Array(UInt64).new(3, raw_size)
        stream_index = 0
        while stream_index < 3
          remaining = row_count
          compressed_total = 0_i64
          observed_marks = 0
          while remaining > 0
            rows = {rows_per_mark, remaining}.min
            frame_raw_size = rows.to_i64 * 8_i64
            if frame_raw_size > WidePart::MAX_FRAME_DECOMPRESSED_BYTES
              raise ArgumentError.new("Point coordinate granule exceeds decompressed frame limit")
            end
            frame_size = infrastructure.checked_string_frame_size(frame_raw_size, "Point Float64 coordinate")
            if frame_size > MAX_DATA_FILE_BYTES - compressed_total
              raise ArgumentError.new("Point coordinate stream exceeds reader limit")
            end
            compressed_total += frame_size
            remaining -= rows
            observed_marks += 1
          end
          raise ArgumentError.new("Point stream mark schedule differs") unless observed_marks == mark_count
          compressed_sizes[stream_index] = compressed_total
          stream_index += 1
        end
        {compressed_sizes, raw_sizes}
      end

      private def self.validate_materialization_charge(
        type_plan : PointColumnType,
        rows : Int32,
        mark_count : Int32,
        rows_per_mark : Int32,
        schedule : TupleLeafMarkSchedule,
      ) : Nil
        schedule_charge = checked_add(
          instance_sizeof(Array(UInt64)).to_u64,
          checked_multiply(mark_count.to_u64, sizeof(UInt64).to_u64, "Point reader schedule bytes"),
          "Point reader schedule bytes"
        )
        reader_charge = type_plan.materialization_charge(rows.to_u64, schedule_charge)
        snapshot_charge = checked_multiply(rows.to_u64, 24_u64, "Point writer snapshots")
        key_readback_charge = checked_multiply(
          {rows, rows_per_mark}.min.to_u64, sizeof(UInt64).to_u64, "Point key readback"
        )
        # Account for parsed index keys, the expected key vector, and the
        # retained encoded index bytes while staged validation is live.
        index_arrays_charge = checked_multiply(mark_count.to_u64 + 1_u64, 24_u64, "Point index readback")
        fixed_charge = checked_add(
          checked_add(schedule.logical_charge, index_arrays_charge, "Point retained metadata"),
          CHECKSUMED_METADATA_RESERVE, "Point retained metadata"
        )
        total = checked_add(
          checked_add(reader_charge, snapshot_charge, "Point combined materialization"),
          checked_add(key_readback_charge, fixed_charge, "Point combined materialization"),
          "Point combined materialization"
        )
        if total > PointColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Point writer materialization charge exceeds 64 MiB")
        end
        nil
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Point metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Point metadata line exceeds reader limit")
            end
          end
        end
        nil
      end

      private def self.validate_checksums_file_budget(
        logical_streams : Array(String),
        compressed_sizes : Array(Int64),
        raw_sizes : Array(UInt64),
        mark_file_size : Int64,
        row_count : Int32,
        index_size : Int64,
        serialization_size : UInt64,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        names = ["count.txt", "primary.idx", "serialization.json"] of String
        sizes = [row_count.to_s.bytesize.to_u64, index_size.to_u64, serialization_size]
        compressed = [false, false, false]
        raw_sizes_for_checksums = [0_u64, 0_u64, 0_u64]
        logical_streams.each_with_index do |logical, index|
          base = StreamName.hash(logical)
          names << "#{base}.bin"
          sizes << compressed_sizes[index].to_u64
          compressed << true
          raw_sizes_for_checksums << raw_sizes[index]
          names << "#{base}.mrk2"
          sizes << mark_file_size.to_u64
          compressed << false
          raw_sizes_for_checksums << 0_u64
        end
        raise ArgumentError.new("Point checksum entry count exceeds reader limit") if names.size > PartChecksums::MAX_ENTRIES

        payload_size = var_uint_size(names.size.to_u64)
        names.each_with_index do |name, index|
          payload_size += var_uint_size(name.bytesize.to_u64) + name.bytesize.to_u64
          payload_size += var_uint_size(sizes[index]) + 17_u64
          if compressed[index]
            payload_size += var_uint_size(raw_sizes_for_checksums[index]) + 16_u64
          end
        end
        if payload_size > Int64::MAX.to_u64
          raise ArgumentError.new("Point checksums payload exceeds writer limit")
        end
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "Point checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
          raise ArgumentError.new("Point checksums file exceeds reader limit")
        end
        nil
      end

      private def self.validate_staged_part(
        stage : String,
        input : PointPartWriteInput,
        expected_records : Array(ChecksumRecord),
      ) : Nil
        checksums = PartChecksums.open(stage)
        expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"] of String
        input.logical_streams.each do |logical|
          base = StreamName.hash(logical)
          expected_checksum_files << "#{base}.bin"
          expected_checksum_files << "#{base}.mrk2"
        end
        unless checksums.entries.keys.sort == expected_checksum_files.sort
          raise CorruptPartError.new("staged Point checksum inventory differs")
        end
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        expected_files = expected_checksum_files + [
          "checksums.txt", "columns.txt", "columns_substreams.txt",
          "default_compression_codec.txt", "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged Point file inventory differs")
        end
        expected_files.each do |name|
          path = File.join(stage, name)
          raise CorruptPartError.new("staged Point file must not be a symbolic link") if File.symlink?(path)
          raise CorruptPartError.new("staged Point file is missing") unless File.file?(path)
        end

        unless File.read(File.join(stage, "columns.txt")) == input.columns_metadata
          raise CorruptPartError.new("staged Point columns metadata differs")
        end
        unless File.read(File.join(stage, "columns_substreams.txt")) == input.substreams_metadata
          raise CorruptPartError.new("staged Point substream metadata differs")
        end
        unless File.read(File.join(stage, "serialization.json")) == input.serialization_metadata
          raise CorruptPartError.new("staged Point serialization metadata differs")
        end
        unless File.read(File.join(stage, "count.txt")) == input.keys.size.to_s
          raise CorruptPartError.new("staged Point row count differs")
        end
        unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
          raise CorruptPartError.new("staged Point compression codec differs")
        end
        unless File.read(File.join(stage, "metadata_version.txt")) == "0"
          raise CorruptPartError.new("staged Point metadata version differs")
        end

        index = PrimaryKeyIndex.open(stage, input.mark_count, checksums)
        expected_index = Array(UInt64).new(input.mark_count + 1)
        row = 0
        while row < input.keys.size
          expected_index << input.keys[row]
          row += input.rows_per_mark
        end
        expected_index << input.keys.last
        unless index.keys == expected_index
          raise CorruptPartError.new("staged Point primary index differs from input")
        end

        expected_mark_rows = Array(UInt64).new(input.mark_count) do |mark_index|
          rows_for_mark(input.keys.size, input.rows_per_mark, mark_index).to_u64
        end
        key_part = WidePart.open_typed(stage, input.key_name)
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Point primary-key mark schedule differs")
        end

        point_part = WidePart.open_typed(stage, input.value_name)
        unless point_part.column_type == input.type_plan.type_name && point_part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged Point schema or row count differs")
        end
        unless point_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Point mark schedule differs")
        end
        values = point_part.read_point_mark_range(input.value_name, 0, input.mark_count)
        unless values.size == input.x_values.size && values.size == input.y_values.size
          raise CorruptPartError.new("staged Point readback row count differs")
        end
        values.each_with_index do |actual, row_index|
          unless actual.x.unsafe_as(UInt64) == input.x_values[row_index].unsafe_as(UInt64) &&
                 actual.y.unsafe_as(UInt64) == input.y_values[row_index].unsafe_as(UInt64)
            raise CorruptPartError.new("staged Point raw coordinate readback differs")
          end
        end

        # Keep key readback bounded to one mark at a time. The selected Point
        # range above is already charged at its full raw-plus-result size.
        start = 0
        mark_index = 0
        while mark_index < input.mark_count
          key_values = key_part.read_uint64_mark_range(input.key_name, mark_index, 1)
          rows = rows_for_mark(input.keys.size, input.rows_per_mark, mark_index)
          unless key_values.size == rows
            raise CorruptPartError.new("staged Point primary-key readback row count differs")
          end
          offset = 0
          while offset < rows
            unless key_values[offset] == input.keys[start + offset]
              raise CorruptPartError.new("staged Point primary-key readback differs from input")
            end
            offset += 1
          end
          start += rows
          mark_index += 1
        end

        # Match the checksums declaration to the exact records emitted before
        # the hook. A refreshed but semantically altered stream is rejected
        # above by raw-bit readback before this integrity comparison.
        expected_records.each do |record|
          entry = checksums.entry(record.name) || raise CorruptPartError.new("staged Point checksum record is missing")
          unless entry.physical_size == record.physical_size && entry.file_hash == record.file_hash &&
                 entry.compressed == record.compressed && entry.uncompressed_size == record.uncompressed_size
            raise CorruptPartError.new("staged Point checksum declaration differs")
          end
        end
        nil
      end

      private def self.columns_metadata(key_name : String, value_name : String) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Point\n"
      end

      private def self.substreams_metadata(key_name : String, value_name : String, x_stream : String, y_stream : String) : String
        "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n" +
          "2 substreams for column `#{value_name}`:\n\t#{x_stream}\n\t#{y_stream}\n"
      end

      private def self.rows_for_mark(row_count : Int32, rows_per_mark : Int32, mark_index : Int32) : Int32
        start = mark_index.to_i64 * rows_per_mark.to_i64
        {rows_per_mark, row_count.to_i64 - start}.min.to_i32
      end

      private def self.checked_add(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflow") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflow") if right != 0 && left > UInt64::MAX // right
        left * right
      end

      private def self.var_uint_size(value : UInt64) : UInt64
        size = 1_u64
        remaining = value
        while remaining >= 0x80_u64
          size += 1_u64
          remaining >>= 7
        end
        size
      end
    end
  end
end
