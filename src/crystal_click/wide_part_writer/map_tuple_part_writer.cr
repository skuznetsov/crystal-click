module CrystalClick
  module WidePartWriter
    # Owns Map(K, Tuple(...)) preflight, the outer/entry mark schedule,
    # Map-specific metadata and exact staged readback. Scalar leaf bytes are
    # emitted by TupleLeafStreamWriter; key ordering and duplicate entries are
    # never normalized into a Hash.
    private class MapTuplePartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        row_sizes : Slice(UInt64),
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type_name, row_sizes,
          map_keys, value_columns, rows_per_mark, infrastructure
        )
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size),
            input.rows_per_mark, input.schedule, TupleLeafMarkSchedule::Axis::Outer
          ))
          records.concat(infrastructure.write_uint64_stream(
            stage, input.type_plan.outer_size_stream(input.value_name),
            input.row_sizes.to_unsafe.to_slice(input.row_sizes.size),
            input.rows_per_mark, input.schedule, TupleLeafMarkSchedule::Axis::Outer
          ))
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, input.type_plan.key_stream_name(input.value_name),
            input.type_plan.key_type, input.map_key_buffer, nil,
            input.schedule, infrastructure
          ))
          records.concat(TupleLeafStreamWriter.write(
            stage, input.type_plan.value_column_prefix(input.value_name),
            input.type_plan.tuple_plan, input.type_plan.tuple_plan.fields,
            input.value_leaf_buffers, input.value_leaf_null_maps,
            input.schedule, infrastructure
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
        row_sizes : Slice(UInt64),
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : MapTuplePartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("columns must be distinct") if key_name == value_name
        if keys.empty? || row_sizes.size != keys.size
          raise ArgumentError.new("keys and Map outer sizes must have the same nonzero row count")
        end
        if keys.size.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS
          raise ArgumentError.new("Map outer row count exceeds staged reader materialization limit")
        end
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        type_plan = WideMapTupleTypePlan.for_type(type_name) ||
                    raise ArgumentError.new("unsupported compositional Map(Tuple) type")
        tuple_plan = type_plan.tuple_plan
        fields = tuple_plan.fields
        raise ArgumentError.new("Map Tuple leaf count does not match schema") unless value_columns.size == fields.size

        previous_key = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous_key
          previous_key = key
        end

        entry_count = 0_u64
        row_sizes.each do |row_size|
          if entry_count > WidePart::MAX_ARRAY_MARK_ELEMENTS ||
             row_size > WidePart::MAX_ARRAY_MARK_ELEMENTS - entry_count
            raise ArgumentError.new("Map entries exceed staged reader materialization limit")
          end
          entry_count += row_size
        end

        key_type = type_plan.key_type
        unless map_keys.name == "keys" && map_keys.leaf_type == key_type && !key_type.nullable?
          raise ArgumentError.new("Map key storage does not match its exact nonnullable schema")
        end
        unless map_keys.size.to_u64 == entry_count && map_keys.null_map.nil?
          raise ArgumentError.new("Map key storage cardinality or nullability differs")
        end

        value_columns.each_with_index do |column, index|
          field = fields[index]
          unless column.name == field.name && column.type_name == field.type_name &&
                 column.leaf_type == field.leaf_type
            raise ArgumentError.new("Map Tuple leaf buffers do not match schema order")
          end
          unless column.size.to_u64 == entry_count
            raise ArgumentError.new("Map Tuple leaf buffers must match flattened entry count")
          end
          if field.leaf_type.nullable?
            null_map = column.null_map || raise(ArgumentError.new("Nullable Map Tuple leaf has no null map"))
            unless null_map.size.to_u64 == entry_count
              raise ArgumentError.new("Nullable Map Tuple null-map cardinality differs")
            end
          elsif column.null_map
            raise ArgumentError.new("bare Map Tuple leaf unexpectedly has a null map")
          end
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
        raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

        map_streams = type_plan.physical_streams(value_name)
        logical_streams = [key_name] of String
        logical_streams.concat(map_streams)
        if map_streams.size > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("Map substream count exceeds reader limit")
        end
        if logical_streams.size * 2 + 3 > PartChecksums::MAX_ENTRIES
          raise ArgumentError.new("checksum entry count exceeds reader limit")
        end
        logical_streams.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("physical stream name exceeds reader limit")
          end
        end
        stream_bases = logical_streams.map { |name| StreamName.hash(name) }
        raise ArgumentError.new("physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

        schedule_charge = TupleLeafMarkSchedule.ragged_logical_charge(mark_count) ||
                          raise ArgumentError.new("Map schedule charge overflows")
        key_string_bytes = string_payload_bytes(map_keys, key_type)
        value_string_bytes = 0_u64
        value_columns.each_with_index do |column, index|
          value_string_bytes = checked_add(
            value_string_bytes, string_payload_bytes(column, fields[index].leaf_type),
            "Map Tuple String payload bytes"
          )
        end
        base_charge = type_plan.materialization_charge(
          keys.size.to_u64, entry_count, key_string_bytes, value_string_bytes
        ) || raise(ArgumentError.new("Map materialization charge overflows"))
        primary_key_charge = keys.size.to_u64 * WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
        if primary_key_charge > UInt64::MAX - base_charge ||
           base_charge + primary_key_charge > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Map combined materialization charge exceeds limit")
        end

        remaining_schedule_charge = WideTupleTypePlan::MAX_MATERIALIZED_BYTES - base_charge - primary_key_charge
        if schedule_charge > remaining_schedule_charge
          raise ArgumentError.new("Map mark schedule exceeds materialization limit")
        end

        # The checked combined charge leaves room before the ragged schedule
        # allocation; its row and entry axes are retained independently.
        schedule = TupleLeafMarkSchedule.from_row_sizes(
          row_sizes, rows_per_mark, WidePart::MAX_ARRAY_MARK_ROWS,
          WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i32, MAX_MARKS, remaining_schedule_charge
        )
        schedule.mark_count.times do |index|
          mark = schedule.mark(index)
          if mark.outer_rows.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS ||
             mark.leaf_count.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS
            raise ArgumentError.new("Map mark exceeds staged reader materialization limit")
          end
          mark_charge = mark_materialization_charge(
            type_plan, key_type, mark, map_keys, value_columns, fields
          ) || raise(ArgumentError.new("Map mark materialization charge overflows"))
          mark_key_charge = mark.outer_rows.to_u64 * WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
          if mark_key_charge > UInt64::MAX - mark_charge ||
             mark_charge + mark_key_charge > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
            raise ArgumentError.new("Map mark materialization charge exceeds limit")
          end
        end

        compressed_sizes, raw_sizes = preflight_stream_budgets(
          logical_streams, value_name, type_plan, map_keys, value_columns,
          fields, schedule, infrastructure
        )

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        # Owned physical-buffer and mask snapshots happen only after schema,
        # all axes, full and per-mark budgets, stream frames and target checks.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        row_sizes_copy = Array(UInt64).new(row_sizes.size) { |index| row_sizes[index] }
        map_key_buffer = copy_leaf(map_keys, key_type, infrastructure)
        value_leaf_buffers = [] of TupleLeafBuffers
        value_leaf_null_maps = [] of Array(UInt8)?
        value_columns.each_with_index do |column, index|
          field = fields[index]
          value_leaf_buffers << copy_leaf(column, field.leaf_type, infrastructure)
          value_leaf_null_maps << column.null_map.try(&.bytes)
        end

        columns_metadata = columns_metadata(key_name, value_name, type_plan)
        substreams_metadata = substreams_metadata(key_name, value_name, map_streams)
        serialization_metadata = serialization_metadata(key_name, keys_copy)
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys_copy.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        MapTuplePartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, type_plan, row_sizes_copy,
          map_key_buffer, value_leaf_buffers, value_leaf_null_maps, logical_streams,
          compressed_sizes, raw_sizes, mark_count, rows_per_mark, schedule,
          columns_metadata, substreams_metadata, serialization_metadata
        )
      end

      private def self.copy_leaf(
        column : WideTupleLeafColumn,
        leaf_type : WideTupleLeafType,
        infrastructure : TuplePartInfrastructure,
      ) : TupleLeafBuffers
        if leaf_type.nullable?
          return infrastructure.copy_string_values(column) if leaf_type.base_type_name == "String"
          return column.physical_values
        end
        if exact_type = leaf_type.parameterized_type
          return column.owned_copy_for(exact_type).physical_values
        end
        if exact_type = leaf_type.datetime_type
          return column.owned_copy_for(exact_type).physical_values
        end
        return infrastructure.copy_string_values(column) if leaf_type.base_type_name == "String"

        values = column.physical_values
        if WideTupleTemporalType.width(leaf_type.type_name)
          WideTupleTemporalType.validate_buffer!(leaf_type.type_name, values.as(WideTupleTemporalType::Buffer))
        end
        values
      end

      private def self.string_payload_bytes(column : WideTupleLeafColumn, leaf_type : WideTupleLeafType) : UInt64
        return 0_u64 unless string_or_fixed_string?(leaf_type)
        total = 0_u64
        column.each_string_bytesize do |byte_count|
          total = checked_add(total, byte_count.to_u64, "Map String payload bytes")
        end
        total
      end

      private def self.string_payload_bytes_for_mark(
        column : WideTupleLeafColumn,
        leaf_type : WideTupleLeafType,
        start : Int32,
        count : Int32,
      ) : UInt64
        return 0_u64 unless string_or_fixed_string?(leaf_type)
        total = 0_u64
        finish = start + count
        index = start
        while index < finish
          total = checked_add(total, column.string_bytesize_at(index), "Map String mark bytes")
          index += 1
        end
        total
      end

      private def self.value_string_bytes_for_mark(
        columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
        start : Int32,
        count : Int32,
      ) : UInt64
        total = 0_u64
        columns.each_with_index do |column, index|
          total = checked_add(
            total, string_payload_bytes_for_mark(column, fields[index].leaf_type, start, count),
            "Map Tuple String mark bytes"
          )
        end
        total
      end

      private def self.mark_materialization_charge(
        type_plan : WideMapTupleTypePlan,
        key_type : WideTupleLeafType,
        mark : TupleLeafMarkSchedule::Mark,
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
      ) : UInt64?
        key_string_bytes = string_payload_bytes_for_mark(
          map_keys, key_type, mark.leaf_start, mark.leaf_count
        )
        value_string_bytes = value_string_bytes_for_mark(
          value_columns, fields, mark.leaf_start, mark.leaf_count
        )
        schedule_charge = TupleLeafMarkSchedule.ragged_logical_charge(1) || return nil
        type_plan.materialization_charge(
          mark.outer_rows.to_u64, mark.leaf_count.to_u64,
          key_string_bytes, value_string_bytes, schedule_charge
        )
      end

      private def self.string_or_fixed_string?(leaf_type : WideTupleLeafType) : Bool
        leaf_type.base_type_name == "String" || leaf_type.parameterized_type.is_a?(WideTupleFixedStringType)
      end

      private def self.preflight_stream_budgets(
        logical_streams : Array(String),
        value_name : String,
        type_plan : WideMapTupleTypePlan,
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
        schedule : TupleLeafMarkSchedule,
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64)}
        compressed_sizes = Array(Int64).new(logical_streams.size, 0_i64)
        raw_sizes = Array(UInt64).new(logical_streams.size, 0_u64)
        key_stream = type_plan.key_stream_name(value_name)
        value_prefix = type_plan.value_column_prefix(value_name)
        field_indices = {} of String => Int32
        fields.each_with_index do |field, index|
          field_indices[type_plan.tuple_plan.leaf_stream_name(value_prefix, field)] = index.to_i32
        end

        logical_streams.each_with_index do |stream, stream_index|
          if stream_index == 0
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule,
              TupleLeafMarkSchedule::Axis::Outer, 8, "Map UInt64 primary key", infrastructure)
          elsif stream == type_plan.outer_size_stream(value_name)
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule,
              TupleLeafMarkSchedule::Axis::Outer, 8, "Map size0", infrastructure)
          elsif type_plan.raw_string_stream?(value_name, stream)
            string_column = if stream == key_stream
                              map_keys
                            else
                              field_index = field_indices[stream]? ||
                                            raise ArgumentError.new("Map String stream has no leaf owner")
                              value_columns[field_index]
                            end
            raw_total = 0_u64
            compressed_total = 0_i64
            schedule.mark_count.times do |mark_index|
              mark = schedule.mark(mark_index)
              mark_raw = string_payload_bytes_for_mark(string_column,
                stream == key_stream ? type_plan.key_type : fields[field_indices[stream]].leaf_type,
                mark.leaf_start, mark.leaf_count)
              if mark_raw > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 || mark_raw > MAX_FRAME_RAW_BYTES.to_u64
                raise ArgumentError.new("Map String mark exceeds reader limit")
              end
              raw_total = checked_add(raw_total, mark_raw, "Map String raw stream bytes")
              raise ArgumentError.new("Map String raw stream exceeds reader limit") if raw_total > MAX_DATA_FILE_BYTES.to_u64
              unless mark_raw == 0
                frame_size = infrastructure.checked_string_frame_size(mark_raw.to_i64, "Map String")
                compressed_total = checked_compressed_add(compressed_total, frame_size, "Map String stream")
              end
            end
            compressed_sizes[stream_index] = compressed_total
            raw_sizes[stream_index] = raw_total
          else
            width = type_plan.stream_width(value_name, stream) ||
                    raise ArgumentError.new("Map stream width is unavailable")
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule,
              TupleLeafMarkSchedule::Axis::Leaf, width, "Map stream #{stream}", infrastructure)
          end
        end
        {compressed_sizes, raw_sizes}
      end

      private def self.budget_fixed_stream!(
        compressed_sizes : Array(Int64),
        raw_sizes : Array(UInt64),
        stream_index : Int32,
        schedule : TupleLeafMarkSchedule,
        axis : TupleLeafMarkSchedule::Axis,
        width : Int32,
        label : String,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        raise ArgumentError.new("#{label} width must be positive") if width <= 0
        compressed_total = 0_i64
        raw_total = 0_u64
        schedule.mark_count.times do |mark_index|
          mark = schedule.mark(mark_index, axis)
          count = axis == TupleLeafMarkSchedule::Axis::Outer ? mark.outer_rows : mark.leaf_count
          raw_bytes = count.to_u64 * width.to_u64
          if raw_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 || raw_bytes > MAX_FRAME_RAW_BYTES.to_u64
            raise ArgumentError.new("#{label} granule exceeds reader limit")
          end
          raw_total = checked_add(raw_total, raw_bytes, "#{label} raw bytes")
          raise ArgumentError.new("#{label} raw stream exceeds reader limit") if raw_total > MAX_DATA_FILE_BYTES.to_u64
          unless raw_bytes == 0
            frame_size = infrastructure.checked_string_frame_size(raw_bytes.to_i64, label)
            compressed_total = checked_compressed_add(compressed_total, frame_size, label)
          end
        end
        compressed_sizes[stream_index] = compressed_total
        raw_sizes[stream_index] = raw_total
        nil
      end

      private def self.columns_metadata(key_name : String, value_name : String, type_plan : WideMapTupleTypePlan) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{type_plan.type_name}\n"
      end

      private def self.substreams_metadata(key_name : String, value_name : String, streams : Array(String)) : String
        String.build do |metadata|
          metadata << "columns substreams version: 1\n2 columns:\n"
          metadata << "1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
          metadata << "#{streams.size} substreams for column `#{value_name}`:\n"
          streams.each { |stream| metadata << "\t#{stream}\n" }
        end
      end

      private def self.serialization_metadata(key_name : String, keys : Array(UInt64)) : String
        defaults = keys.count { |key| key == 0_u64 }
        "{\"columns\":[{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{defaults},\"num_rows\":#{keys.size}}]," +
          "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Map metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Map metadata line exceeds reader limit")
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
          payload_size += var_uint_size(raw_uncompressed[index]) + 16_u64 if compressed[index]
        end
        raise ArgumentError.new("checksums payload exceeds writer limit") if payload_size > Int64::MAX.to_u64
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        raise ArgumentError.new("checksums file exceeds writer limit") if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
        nil
      end

      private def self.validate_staged_part(
        stage : String,
        input : MapTuplePartWriteInput,
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
          raise CorruptPartError.new("staged Map checksum inventory differs")
        end
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        unless File.read(File.join(stage, "columns.txt")) == input.columns_metadata
          raise CorruptPartError.new("staged Map columns metadata differs")
        end
        unless File.read(File.join(stage, "columns_substreams.txt")) == input.substreams_metadata
          raise CorruptPartError.new("staged Map substream metadata differs")
        end
        unless File.read(File.join(stage, "serialization.json")) == input.serialization_metadata
          raise CorruptPartError.new("staged Map serialization metadata differs")
        end
        raise CorruptPartError.new("staged row count differs") unless File.read(File.join(stage, "count.txt")) == input.keys.size.to_s
        raise CorruptPartError.new("staged compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
        raise CorruptPartError.new("staged metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

        expected_files = expected_checksum_files + [
          "checksums.txt", "columns.txt", "columns_substreams.txt",
          "default_compression_codec.txt", "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged Map file inventory differs")
        end

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
          input.schedule.mark(mark_index, TupleLeafMarkSchedule::Axis::Outer).outer_rows.to_u64
        end
        key_part = WidePart.open_typed(stage, input.key_name)
        keys = key_part.read_uint64_mark_range(input.key_name, 0, input.mark_count)
        raise CorruptPartError.new("staged UInt64 key readback differs") unless keys == input.keys
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged UInt64 key mark schedule differs")
        end

        part = WidePart.open_typed(stage, input.value_name)
        unless part.column_type == input.type_plan.type_name && part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged Map declaration or outer row count differs")
        end
        unless part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Map outer mark schedule differs")
        end
        decoded = part.read_map_tuple_mark_range(input.value_name, 0, input.mark_count)
        unless decoded.plan.type_name == input.type_plan.type_name &&
               decoded.row_count == input.keys.size && decoded.entry_count == input.map_key_buffer.size &&
               decoded.row_sizes == input.row_sizes
          raise CorruptPartError.new("staged Map row boundaries or cardinality differ")
        end

        key_column = decoded.key_column
        unless key_column.name == "keys" && key_column.leaf_type == input.type_plan.key_type && key_column.null_map.nil?
          raise CorruptPartError.new("staged Map key descriptor differs")
        end
        unless TupleLeafPhysicalValues.matches?(input.map_key_buffer, key_column.physical_values)
          raise CorruptPartError.new(TupleLeafPhysicalValues.staged_mismatch_message(input.type_plan.key_type))
        end

        fields = input.type_plan.tuple_plan.fields
        tuple_data = decoded.tuple_data
        raise CorruptPartError.new("staged Map Tuple schema differs") unless tuple_data.fields == fields
        decoded_columns = tuple_data.columns
        input.value_leaf_buffers.each_with_index do |expected, leaf_index|
          actual = decoded_columns[leaf_index]
          field = fields[leaf_index]
          unless actual.leaf_type == field.leaf_type && actual.type_name == field.type_name
            raise CorruptPartError.new("staged Map Tuple leaf descriptor differs")
          end
          if expected_null_map = input.value_leaf_null_maps[leaf_index]
            actual_null_map = actual.null_map
            unless actual_null_map && actual_null_map.bytes == expected_null_map
              raise CorruptPartError.new("staged Nullable Map Tuple mask differs")
            end
          elsif actual.null_map
            raise CorruptPartError.new("staged bare Map Tuple leaf unexpectedly has a mask")
          end
          unless TupleLeafPhysicalValues.matches?(expected, actual.physical_values)
            raise CorruptPartError.new(TupleLeafPhysicalValues.staged_mismatch_message(field.leaf_type))
          end
          if expected.is_a?(Array(Bool))
            field_stream = input.type_plan.tuple_plan.leaf_stream_name(
              input.type_plan.value_column_prefix(input.value_name), field
            )
            infrastructure.validate_bool_stream(stage, field_stream, expected, input.rows_per_mark, input.schedule)
          end
        end
        nil
      end

      private def self.checked_compressed_add(current : Int64, addition : Int64, label : String) : Int64
        if addition > MAX_DATA_FILE_BYTES - current
          raise ArgumentError.new("#{label} exceeds reader limit")
        end
        current + addition
      end

      private def self.checked_add(current : UInt64, addition : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows") if addition > UInt64::MAX - current
        current + addition
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
