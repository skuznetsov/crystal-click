module CrystalClick
  module WidePartWriter
    # Owns the compositional Tuple writer's preflight, metadata, stage
    # lifecycle, plan-driven leaf writes and staged readback. Payload codecs,
    # checksums, key index and publication remain the existing writer owners.
    private class TuplePartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : String
        input = preflight(destination, key_name, keys, value_name, type_name, columns, rows_per_mark, infrastructure)
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size), input.rows_per_mark
          ))
          records.concat(TupleLeafStreamWriter.write(
            stage, input.value_name, input.type_plan, input.type_plan.fields,
            input.leaf_buffers, input.leaf_null_maps, input.schedule, infrastructure
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

          validate_staged_part(stage, input, infrastructure)
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
        type_name : String,
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : TuplePartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("column names must be distinct") if key_name == value_name
        raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty?
        raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        type_plan = WideTupleTypePlan.for_type(type_name) ||
                    raise ArgumentError.new("unsupported compositional Tuple type")
        fields = type_plan.fields
        raise ArgumentError.new("Tuple leaf count does not match schema") unless columns.size == fields.size
        columns.each_with_index do |column, index|
          field = fields[index]
          unless column.name == field.name && column.type_name == field.type_name
            raise ArgumentError.new("Tuple leaf buffers do not match schema order")
          end
          raise ArgumentError.new("Tuple leaf buffers must match key row count") unless column.size == keys.size
          if field.leaf_type.nullable?
            unless column.leaf_type == field.leaf_type && !column.null_map.nil?
              raise ArgumentError.new("Nullable Tuple leaf storage does not match schema")
            end
          else
            validate_parameterized_column!(column, field)
          end
        end

        previous = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
          previous = key
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
        raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES
        schedule = TupleLeafMarkSchedule.row_aligned(keys.size, rows_per_mark)

        logical_streams = [key_name] + type_plan.physical_streams(value_name)
        if logical_streams.size - 1 > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("Tuple substream count exceeds reader limit")
        end
        if (logical_streams.size * 2 + 3) > PartChecksums::MAX_ENTRIES
          raise ArgumentError.new("checksum entry count exceeds reader limit")
        end
        logical_streams.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("physical stream name exceeds reader limit")
          end
        end
        stream_bases = logical_streams.map { |name| StreamName.hash(name) }
        raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

        # Bound every fixed stream and every String raw stream before retaining
        # leaf snapshots. String size leaves are fixed-width UInt64 streams.
        compressed_sizes, raw_sizes, payload_bytes_by_mark, total_payload_bytes = preflight_stream_budgets(
          keys.size, rows_per_mark, mark_count, value_name, type_plan, columns, fields, logical_streams, infrastructure
        )
        # The shared plan accounts for the materialized Tuple result; the
        # writer also owns a separate UInt64 key snapshot across the range.
        validate_combined_materialization_charge(
          type_plan,
          keys.size,
          total_payload_bytes,
          keys.size.to_u64 * WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
        )
        payload_bytes_by_mark.each_with_index do |mark_payload_bytes, mark_index|
          rows = rows_for_mark(keys.size, rows_per_mark, mark_index)
          key_charge = rows.to_u64 * WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
          validate_combined_materialization_charge(type_plan, rows, mark_payload_bytes, key_charge)
        end

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        # Take owned snapshots after the field-stream, row, mark and aggregate
        # logical bounds pass. Metadata/checksum-file bounds below still run
        # before staging; this logical charge is not a peak-memory limit.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        leaf_buffers = [] of TupleLeafBuffers
        leaf_null_maps = [] of Array(UInt8)?
        columns.each_with_index do |column, index|
          field = fields[index]
          if field.leaf_type.nullable?
            physical_values = if field.leaf_type.base_type_name == "String"
                                infrastructure.copy_string_values(column)
                              else
                                column.physical_values
                              end
            leaf_buffers << physical_values
            leaf_null_maps << column.null_map.not_nil!.bytes
          elsif exact_type = fields[index].parameterized_type
            leaf_buffers << column.owned_copy_for(exact_type).physical_values
          elsif column.type_name == "UInt64"
            leaf_buffers << column.uint64_values
          elsif column.type_name == "String"
            leaf_buffers << infrastructure.copy_string_values(column)
          else
            values = column.physical_values
            field_type = field.type_name
            if WideTupleTemporalType.width(field_type)
              WideTupleTemporalType.validate_buffer!(field_type, values.as(WideTupleTemporalType::Buffer))
            end
            leaf_buffers << values
          end
          leaf_null_maps << nil unless field.leaf_type.nullable?
        end

        columns_metadata = columns_metadata(key_name, value_name, type_plan)
        substreams_metadata = substreams_metadata(key_name, value_name, type_plan)
        serialization_metadata = TupleSerializationStatistics.build(
          key_name, keys_copy, value_name, type_plan, leaf_buffers, leaf_null_maps, fields
        )
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys_copy.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        TuplePartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, type_plan, leaf_buffers, leaf_null_maps,
          logical_streams, compressed_sizes, raw_sizes, mark_count, rows_per_mark,
          schedule,
          columns_metadata, substreams_metadata, serialization_metadata
        )
      end

      private def self.validate_parameterized_column!(column : WideTupleLeafColumn, field : WideTupleField) : Nil
        unless column.parameterized_type == field.parameterized_type
          raise ArgumentError.new("Tuple leaf parameterized type does not match schema")
        end
        # WideTupleLeafColumn's exact constructor validates every immutable
        # nominal row against its descriptor and owns the backing array. Do not
        # call the defensive `values` getter here: preflight must not allocate a
        # full duplicate before the materialization bound is checked. The exact
        # owner comparison above validates empty leaves as well.
        nil
      end

      private def self.preflight_stream_budgets(
        row_count : Int32,
        rows_per_mark : Int32,
        mark_count : Int32,
        value_name : String,
        type_plan : WideTupleTypePlan,
        columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
        logical_streams : Array(String),
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64), Array(UInt64), UInt64}
        compressed_sizes = Array(Int64).new(logical_streams.size, 0_i64)
        raw_sizes = Array(UInt64).new(logical_streams.size, 0_u64)
        payload_bytes_by_mark = Array(UInt64).new(mark_count, 0_u64)
        total_payload_bytes = 0_u64

        fixed_stream_budget(compressed_sizes, raw_sizes, 0, row_count, rows_per_mark, mark_count, 8, "Tuple UInt64 key", infrastructure)
        stream_index = 1
        fields.each_with_index do |field, field_index|
          column = columns[field_index]
          if field.leaf_type.nullable?
            fixed_stream_budget(
              compressed_sizes, raw_sizes, stream_index, row_count, rows_per_mark, mark_count,
              1, "Tuple Nullable mask #{field.name}", infrastructure
            )
            stream_index += 1
          end
          base_type_name = field.leaf_type.base_type_name
          if base_type_name == "String"
            fixed_stream_budget(
              compressed_sizes, raw_sizes, stream_index, row_count, rows_per_mark, mark_count,
              8, "Tuple String size leaf #{field.name}", infrastructure
            )
            stream_index += 1

            raw_stream_size = 0_u64
            mark_raw_size = 0_u64
            mark_index = 0
            rows_in_mark = 0
            values_seen = 0
            column.each_string_bytesize do |byte_count|
              bytes = byte_count.to_u64
              mark_raw_size = checked_add(mark_raw_size, bytes, "Tuple String mark bytes")
              total_payload_bytes = checked_add(total_payload_bytes, bytes, "Tuple String bytes")
              payload_bytes_by_mark[mark_index] = checked_add(
                payload_bytes_by_mark[mark_index], bytes, "Tuple combined materialized payload mark bytes"
              )
              rows_in_mark += 1
              values_seen += 1

              if rows_in_mark == rows_per_mark || values_seen == row_count
                if mark_raw_size > WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_u64
                  raise ArgumentError.new("Tuple String granule exceeds decompressed frame limit")
                end
                raw_stream_size = checked_add(raw_stream_size, mark_raw_size, "Tuple String stream bytes")
                unless mark_raw_size.zero?
                  frame_size = infrastructure.checked_string_frame_size(mark_raw_size.to_i64, "Tuple String")
                  add_compressed_frame!(compressed_sizes, stream_index, frame_size, "Tuple String stream")
                end
                mark_index += 1
                mark_raw_size = 0_u64
                rows_in_mark = 0
              end
              nil
            end
            raise ArgumentError.new("Tuple String row count differs") unless values_seen == row_count
            raise ArgumentError.new("Tuple String mark schedule differs") unless mark_index == mark_count
            raw_sizes[stream_index] = raw_stream_size
            stream_index += 1
          else
            stream_name = logical_streams[stream_index]
            width = type_plan.stream_width(value_name, stream_name) ||
                    raise ArgumentError.new("Tuple numeric stream width is unavailable")
            fixed_stream_budget(
              compressed_sizes, raw_sizes, stream_index, row_count, rows_per_mark, mark_count,
              width, "Tuple #{field.type_name} leaf #{field.name}", infrastructure
            )
            if fixed_type = field.leaf_type.parameterized_type.as?(WideTupleFixedStringType)
              unless fixed_type.width == width
                raise ArgumentError.new("Tuple FixedString stream width differs from its exact owner")
              end
              total_payload_bytes = checked_add(
                total_payload_bytes, row_count.to_u64 * width.to_u64, "Tuple FixedString payload bytes"
              )
              mark_count.times do |mark_index|
                rows = rows_for_mark(row_count, rows_per_mark, mark_index)
                mark_payload_bytes = rows.to_u64 * width.to_u64
                payload_bytes_by_mark[mark_index] = checked_add(
                  payload_bytes_by_mark[mark_index], mark_payload_bytes,
                  "Tuple combined materialized payload mark bytes"
                )
              end
            end
            stream_index += 1
          end
        end

        raise ArgumentError.new("Tuple physical stream plan is inconsistent") unless stream_index == logical_streams.size
        {compressed_sizes, raw_sizes, payload_bytes_by_mark, total_payload_bytes}
      end

      private def self.fixed_stream_budget(
        compressed_sizes : Array(Int64),
        raw_sizes : Array(UInt64),
        stream_index : Int32,
        row_count : Int32,
        rows_per_mark : Int32,
        mark_count : Int32,
        width : Int32,
        label : String,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        raise ArgumentError.new("#{label} width must be positive") if width <= 0
        raw_size = rows_per_mark.to_i64 * width.to_i64
        remaining = row_count
        compressed_total = 0_i64
        raw_total = 0_u64
        mark_index = 0
        while remaining > 0
          rows = {rows_per_mark, remaining}.min
          bytes = rows.to_i64 * width.to_i64
          frame_size = infrastructure.checked_string_frame_size(bytes, label)
          if frame_size > MAX_DATA_FILE_BYTES - compressed_total
            raise ArgumentError.new("#{label} stream exceeds reader limit")
          end
          compressed_total += frame_size
          raw_total = checked_add(raw_total, bytes.to_u64, "#{label} raw bytes")
          remaining -= rows
          mark_index += 1
        end
        raise ArgumentError.new("Tuple mark schedule differs") unless mark_index == mark_count
        # Keep this explicit calculation tied to the largest admitted chunk;
        # the actual short-final-mark size was checked in the loop above.
        raise ArgumentError.new("#{label} granule exceeds decompressed frame limit") if raw_size > WidePart::MAX_FRAME_DECOMPRESSED_BYTES
        compressed_sizes[stream_index] = compressed_total
        raw_sizes[stream_index] = raw_total
        nil
      end

      private def self.add_compressed_frame!(sizes : Array(Int64), index : Int32, frame_size : Int64, label : String) : Nil
        current = sizes[index]
        if frame_size > MAX_DATA_FILE_BYTES - current
          raise ArgumentError.new("#{label} exceeds reader limit")
        end
        sizes[index] = current + frame_size
        nil
      end

      private def self.validate_combined_materialization_charge(
        plan : WideTupleTypePlan,
        rows : Int32,
        string_bytes : UInt64,
        key_charge : UInt64,
      ) : Nil
        charge = plan.materialization_charge(rows.to_u64, string_bytes) ||
                 raise ArgumentError.new("Tuple materialization charge overflows")
        if key_charge > UInt64::MAX - charge || charge + key_charge > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Tuple materialization charge exceeds limit")
        end
        nil
      end

      private def self.checked_add(current : UInt64, addition : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflow") if addition > UInt64::MAX - current
        current + addition
      end

      private def self.rows_for_mark(row_count : Int32, rows_per_mark : Int32, mark_index : Int32) : Int32
        start = mark_index.to_i64 * rows_per_mark.to_i64
        {rows_per_mark, row_count.to_i64 - start}.min.to_i32
      end

      private def self.columns_metadata(key_name : String, value_name : String, plan : WideTupleTypePlan) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{plan.type_name}\n"
      end

      private def self.substreams_metadata(key_name : String, value_name : String, plan : WideTupleTypePlan) : String
        streams = plan.physical_streams(value_name)
        String.build do |metadata|
          metadata << "columns substreams version: 1\n2 columns:\n"
          metadata << "1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
          metadata << "#{streams.size} substreams for column `#{value_name}`:\n"
          streams.each { |stream| metadata << "\t#{stream}\n" }
        end
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Tuple metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Tuple metadata line exceeds reader limit")
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
        physical_sizes = [row_count.to_s.bytesize.to_u64, index_size.to_u64, serialization_size]
        compressed = [false, false, false]
        raw_uncompressed = [0_u64, 0_u64, 0_u64]
        logical_streams.each_with_index do |logical, index|
          base = StreamName.hash(logical)
          names << "#{base}.bin"
          physical_sizes << compressed_sizes[index].to_u64
          compressed << true
          raw_uncompressed << raw_sizes[index]
          names << "#{base}.mrk2"
          physical_sizes << mark_file_size.to_u64
          compressed << false
          raw_uncompressed << 0_u64
        end
        raise ArgumentError.new("checksum entry count exceeds reader limit") if names.size > PartChecksums::MAX_ENTRIES

        payload_size = var_uint_size(names.size.to_u64)
        names.each_with_index do |name, index|
          payload_size += var_uint_size(name.bytesize.to_u64) + name.bytesize.to_u64
          payload_size += var_uint_size(physical_sizes[index]) + 16_u64 + 1_u64
          if compressed[index]
            payload_size += var_uint_size(raw_uncompressed[index]) + 16_u64
          end
        end
        unless payload_size <= Int64::MAX.to_u64
          raise ArgumentError.new("checksums payload exceeds writer limit")
        end
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
          raise ArgumentError.new("checksums file exceeds writer limit")
        end
        nil
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

      private def self.validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        checksums = PartChecksums.open(stage)
        expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"] of String
        input.logical_streams.each do |logical|
          base = StreamName.hash(logical)
          expected_checksum_files << "#{base}.bin"
          expected_checksum_files << "#{base}.mrk2"
        end
        unless checksums.entries.keys.sort == expected_checksum_files.sort
          raise CorruptPartError.new("staged Tuple checksum inventory differs")
        end
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end

        unless File.read(File.join(stage, "columns.txt")) == input.columns_metadata
          raise CorruptPartError.new("staged Tuple columns metadata differs")
        end
        unless File.read(File.join(stage, "columns_substreams.txt")) == input.substreams_metadata
          raise CorruptPartError.new("staged Tuple substream metadata differs")
        end
        unless File.read(File.join(stage, "serialization.json")) == input.serialization_metadata
          raise CorruptPartError.new("staged Tuple serialization metadata differs")
        end
        raise CorruptPartError.new("staged row count differs") unless File.read(File.join(stage, "count.txt")) == input.keys.size.to_s
        raise CorruptPartError.new("staged compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
        raise CorruptPartError.new("staged metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

        index = PrimaryKeyIndex.open(stage, input.mark_count, checksums)
        expected_index = Array(UInt64).new(input.mark_count + 1)
        row = 0
        while row < input.keys.size
          expected_index << input.keys[row]
          row += input.rows_per_mark
        end
        expected_index << input.keys.last
        raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index

        expected_mark_rows = Array(UInt64).new(input.mark_count) do |mark_index|
          rows_for_mark(input.keys.size, input.rows_per_mark, mark_index).to_u64
        end
        key_part = WidePart.open_typed(stage, input.key_name)
        key_values = key_part.read_uint64_mark_range(input.key_name, 0, input.mark_count)
        raise CorruptPartError.new("staged UInt64 key readback differs") unless key_values == input.keys
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged UInt64 key mark schedule differs")
        end

        part = WidePart.open_typed(stage, input.value_name)
        raise CorruptPartError.new("staged Tuple row count differs") unless part.row_count == input.keys.size.to_u64
        unless part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Tuple mark schedule differs")
        end
        decoded = part.read_tuple_mark_range(input.value_name, 0, input.mark_count)
        raise CorruptPartError.new("staged Tuple readback row count differs") unless decoded.row_count == input.keys.size
        fields = input.type_plan.fields
        raise CorruptPartError.new("staged Tuple readback schema differs") unless decoded.fields == fields
        decoded_columns = decoded.columns
        input.leaf_buffers.each_with_index do |expected, index|
          actual = decoded_columns[index]
          field = fields[index]
          unless actual.leaf_type == field.leaf_type && actual.type_name == field.type_name
            raise CorruptPartError.new("staged Tuple leaf type identity differs")
          end
          if expected_null_map = input.leaf_null_maps[index]
            actual_null_map = actual.null_map
            unless actual.leaf_type == field.leaf_type && actual_null_map && actual_null_map.bytes == expected_null_map
              raise CorruptPartError.new("staged Nullable Tuple mask readback differs")
            end
            unless TupleLeafPhysicalValues.matches?(expected, actual.physical_values)
              raise CorruptPartError.new("staged Nullable Tuple raw leaf readback differs")
            end
            next
          end
          unless TupleLeafPhysicalValues.matches?(expected, actual.physical_values)
            raise CorruptPartError.new(TupleLeafPhysicalValues.staged_mismatch_message(field.leaf_type))
          end
          if expected.is_a?(Array(Bool))
            infrastructure.validate_bool_stream(
              stage, input.type_plan.leaf_stream_name(input.value_name, field), expected,
              input.rows_per_mark, input.schedule
            )
          end
        end
        nil
      end
    end
  end
end
