module CrystalClick
  module WidePartWriter
    # Owns Array(Tuple)'s outer-row/inner-element preflight and publication.
    # Scalar leaf codecs and raw/mask comparators remain shared with W106.
    private class ArrayTuplePartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : String
        type_plan = WideArrayTupleTypePlan.for_type(type_name) ||
                    raise ArgumentError.new("unsupported compositional Array(Tuple) type")
        write_with_plan(
          destination, key_name, keys, value_name, type_plan, row_sizes, columns,
          rows_per_mark, infrastructure
        )
      end

      def self.write_nested(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : String
        nested_plan = WideNestedTypePlan.for_type(type_name) ||
                      raise ArgumentError.new("unsupported nominal Nested type")
        write_with_plan(
          destination, key_name, keys, value_name, nested_plan.storage_plan, row_sizes,
          columns, rows_per_mark, infrastructure
        )
      end

      def self.write_flattened_nested(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        group_name : String,
        type_name : String,
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : String
        context = WidePart::FlattenedNestedStoragePlan.for_type(group_name, type_name) ||
                  raise ArgumentError.new("unsupported flattened Nested declaration or group name")
        write_with_plan(
          destination, key_name, keys, context.group_name, context.storage_plan,
          row_sizes, columns, rows_per_mark, infrastructure, context
        )
      end

      private def self.write_with_plan(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_plan : WideArrayTupleTypePlan,
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
        flattened_nested_context : WidePart::FlattenedNestedStoragePlan? = nil,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type_plan, row_sizes,
          columns, rows_per_mark, infrastructure, flattened_nested_context
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
          records.concat(TupleLeafStreamWriter.write(
            stage, input.value_name, input.type_plan.tuple_plan,
            input.type_plan.tuple_plan.fields, input.leaf_buffers,
            input.leaf_null_maps, input.schedule, infrastructure
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
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : ArrayTuplePartWriteInput
        type_plan = WideArrayTupleTypePlan.for_type(type_name) ||
                    raise ArgumentError.new("unsupported compositional Array(Tuple) type")
        preflight(
          destination, key_name, keys, value_name, type_plan, row_sizes,
          columns, rows_per_mark, infrastructure
        )
      end

      private def self.preflight(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_plan : WideArrayTupleTypePlan,
        row_sizes : Slice(UInt64),
        columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
        flattened_nested_context : WidePart::FlattenedNestedStoragePlan? = nil,
      ) : ArrayTuplePartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("columns must be distinct") if key_name == value_name
        if flattened_context = flattened_nested_context
          unless type_plan.nested? && flattened_context.group_name == value_name &&
                 flattened_context.type_name == type_plan.type_name
            raise ArgumentError.new("flattened Nested context differs from the storage plan")
          end
        end
        raise ArgumentError.new("keys and outer sizes must have the same nonzero row count") if keys.empty? || row_sizes.size != keys.size
        raise ArgumentError.new("outer row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("outer row count exceeds staged reader materialization limit") if keys.size.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        tuple_plan = type_plan.tuple_plan
        fields = tuple_plan.fields
        raise ArgumentError.new("Array(Tuple) leaf count does not match schema") unless columns.size == fields.size

        previous_key = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous_key
          previous_key = key
        end

        element_count = 0_u64
        row_sizes.each do |row_size|
          if element_count > WidePart::MAX_ARRAY_MARK_ELEMENTS ||
             row_size > WidePart::MAX_ARRAY_MARK_ELEMENTS - element_count
            raise ArgumentError.new("flattened Array(Tuple) elements exceed staged reader materialization limit")
          end
          element_count += row_size
        end
        columns.each_with_index do |column, index|
          field = fields[index]
          unless column.name == field.name && column.type_name == field.type_name &&
                 column.leaf_type == field.leaf_type
            raise ArgumentError.new("Array(Tuple) leaf buffers do not match schema order")
          end
          raise ArgumentError.new("Array(Tuple) leaf buffers must match flattened element count") unless column.size.to_u64 == element_count
          if field.leaf_type.nullable?
            null_map = column.null_map || raise(ArgumentError.new("Nullable Array(Tuple) leaf has no null map"))
            raise ArgumentError.new("Nullable Array(Tuple) null map cardinality differs") unless null_map.size.to_u64 == element_count
          else
            raise ArgumentError.new("bare Array(Tuple) leaf unexpectedly has a null map") unless column.null_map.nil?
          end
          if exact_type = field.parameterized_type
            raise ArgumentError.new("Array(Tuple) leaf parameterized type differs") unless column.parameterized_type == exact_type
          end
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
        raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

        value_streams = type_plan.physical_streams(value_name)
        logical_streams = [key_name] of String
        logical_streams.concat(value_streams)
        if value_streams.size > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("Array(Tuple) substream count exceeds reader limit")
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
                          raise ArgumentError.new("Array(Tuple) schedule charge overflows")
        string_payload_bytes = variable_payload_bytes(columns, fields)
        base_charge = type_plan.materialization_charge(
          keys.size.to_u64, element_count, string_payload_bytes
        ) || raise ArgumentError.new("Array(Tuple) materialization charge overflows")
        key_charge = keys.size.to_u64 * WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
        if key_charge > UInt64::MAX - base_charge || base_charge + key_charge > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Array(Tuple) materialization charge exceeds limit")
        end
        remaining_schedule_charge = WideTupleTypePlan::MAX_MATERIALIZED_BYTES - base_charge - key_charge
        if schedule_charge > remaining_schedule_charge
          raise ArgumentError.new("Array(Tuple) mark schedule exceeds materialization limit")
        end

        # Allocate the bounded per-mark schedule only after the combined
        # result/key budget has left room for its retained records.
        schedule = TupleLeafMarkSchedule.from_row_sizes(
          row_sizes, rows_per_mark, WidePart::MAX_ROWS, Int32::MAX,
          MAX_MARKS, remaining_schedule_charge
        )
        schedule.mark_count.times do |index|
          mark = schedule.mark(index)
          if mark.leaf_count.to_u64 > WidePart::MAX_ARRAY_MARK_ELEMENTS
            raise ArgumentError.new("Array(Tuple) mark exceeds per-mark element limit")
          end
        end

        compressed_sizes, raw_sizes = preflight_stream_budgets(
          logical_streams, value_name, type_plan, fields, columns, schedule, infrastructure
        )

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        # Copy only after schema, cardinality, schedule, frame, file and total
        # logical bounds pass. Nullable String copies include hidden slots.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        row_sizes_copy = Array(UInt64).new(row_sizes.size) { |index| row_sizes[index] }
        leaf_buffers = [] of TupleLeafBuffers
        leaf_null_maps = [] of Array(UInt8)?
        columns.each_with_index do |column, index|
          field = fields[index]
          if field.leaf_type.nullable?
            values = if field.leaf_type.base_type_name == "String"
                       infrastructure.copy_string_values(column)
                     else
                       column.physical_values
                     end
            leaf_buffers << values
            leaf_null_maps << column.null_map.not_nil!.bytes
          elsif exact_type = field.parameterized_type
            leaf_buffers << column.owned_copy_for(exact_type).physical_values
            leaf_null_maps << nil
          elsif field.leaf_type.base_type_name == "String"
            leaf_buffers << infrastructure.copy_string_values(column)
            leaf_null_maps << nil
          else
            values = column.physical_values
            if WideTupleTemporalType.width(field.type_name)
              WideTupleTemporalType.validate_buffer!(field.type_name, values.as(WideTupleTemporalType::Buffer))
            end
            leaf_buffers << values
            leaf_null_maps << nil
          end
        end

        columns_metadata = if flattened_context = flattened_nested_context
                             flattened_context.columns_metadata(key_name)
                           else
                             columns_metadata(key_name, value_name, type_plan)
                           end
        substreams_metadata = if flattened_context = flattened_nested_context
                                flattened_context.substreams_metadata(key_name)
                              else
                                substreams_metadata(key_name, value_name, value_streams)
                              end
        serialization_metadata = serialization_metadata(key_name, keys_copy, type_plan)
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys_copy.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        ArrayTuplePartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, type_plan, flattened_nested_context, row_sizes_copy,
          leaf_buffers, leaf_null_maps, logical_streams, compressed_sizes, raw_sizes,
          mark_count, rows_per_mark, schedule, columns_metadata, substreams_metadata,
          serialization_metadata
        )
      end

      private def self.variable_payload_bytes(
        columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
      ) : UInt64
        total = 0_u64
        columns.each_with_index do |column, index|
          field = fields[index]
          next unless field.leaf_type.base_type_name == "String" ||
                      field.parameterized_type.is_a?(WideTupleFixedStringType)
          column.each_string_bytesize do |bytes|
            total = checked_add(total, bytes.to_u64, "Array(Tuple) materialized payload bytes")
          end
        end
        total
      end

      private def self.preflight_stream_budgets(
        logical_streams : Array(String),
        value_name : String,
        type_plan : WideArrayTupleTypePlan,
        fields : Array(WideTupleField),
        columns : Array(WideTupleLeafColumn),
        schedule : TupleLeafMarkSchedule,
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64)}
        compressed_sizes = Array(Int64).new(logical_streams.size, 0_i64)
        raw_sizes = Array(UInt64).new(logical_streams.size, 0_u64)
        fields_by_stream = {} of String => Int32
        fields.each_with_index do |field, index|
          fields_by_stream[type_plan.leaf_stream_name(value_name, field)] = index.to_i32
        end

        logical_streams.each_with_index do |stream, stream_index|
          if stream_index == 0
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule, TupleLeafMarkSchedule::Axis::Outer, 8, "Array(Tuple) UInt64 key", infrastructure)
          elsif stream == type_plan.outer_size_stream(value_name)
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule, TupleLeafMarkSchedule::Axis::Outer, 8, "Array(Tuple) size0", infrastructure)
          elsif type_plan.raw_string_stream?(value_name, stream)
            field_index = fields_by_stream[stream]? ||
                          raise ArgumentError.new("Array(Tuple) String stream has no leaf owner")
            column = columns[field_index]
            raw_total = 0_u64
            compressed_total = 0_i64
            schedule.mark_count.times do |mark_index|
              mark = schedule.mark(mark_index)
              mark_raw = 0_u64
              index = mark.leaf_start
              finish = index + mark.leaf_count
              while index < finish
                mark_raw = checked_add(
                  mark_raw, column.string_bytesize_at(index), "Array(Tuple) String mark bytes"
                )
                index += 1
              end
              if mark_raw > WidePart::MAX_ARRAY_MARK_BYTES || mark_raw > MAX_FRAME_RAW_BYTES.to_u64
                raise ArgumentError.new("Array(Tuple) String mark exceeds reader limit")
              end
              raw_total = checked_add(raw_total, mark_raw, "Array(Tuple) String raw stream bytes")
              raise ArgumentError.new("Array(Tuple) String raw stream exceeds reader limit") if raw_total > MAX_DATA_FILE_BYTES.to_u64
              unless mark_raw == 0
                frame_size = infrastructure.checked_string_frame_size(mark_raw.to_i64, "Array(Tuple) String")
                compressed_total = checked_compressed_add(compressed_total, frame_size, "Array(Tuple) String stream")
              end
            end
            compressed_sizes[stream_index] = compressed_total
            raw_sizes[stream_index] = raw_total
          else
            width = type_plan.stream_width(value_name, stream) ||
                    raise ArgumentError.new("Array(Tuple) stream width is unavailable")
            budget_fixed_stream!(compressed_sizes, raw_sizes, stream_index, schedule, TupleLeafMarkSchedule::Axis::Leaf, width, "Array(Tuple) stream #{stream}", infrastructure)
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
          if raw_bytes > MAX_FRAME_RAW_BYTES.to_u64
            raise ArgumentError.new("#{label} granule exceeds decompressed frame limit")
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

      private def self.columns_metadata(key_name : String, value_name : String, plan : WideArrayTupleTypePlan) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{plan.type_name}\n"
      end

      private def self.substreams_metadata(key_name : String, value_name : String, streams : Array(String)) : String
        String.build do |metadata|
          metadata << "columns substreams version: 1\n2 columns:\n"
          metadata << "1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
          metadata << "#{streams.size} substreams for column `#{value_name}`:\n"
          streams.each { |stream| metadata << "\t#{stream}\n" }
        end
      end

      private def self.serialization_metadata(
        key_name : String,
        keys : Array(UInt64),
        type_plan : WideArrayTupleTypePlan,
      ) : String
        defaults = keys.count { |key| key == 0_u64 }
        exact_defaults = type_plan.nested? ? ",\"exact_num_defaults\":true" : ""
        "{\"columns\":[{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{defaults},\"num_rows\":#{keys.size}#{exact_defaults}}]," +
          "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Array(Tuple) metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Array(Tuple) metadata line exceeds reader limit")
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
        raise ArgumentError.new("checksums payload exceeds writer limit") if payload_size > Int64::MAX.to_u64
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        raise ArgumentError.new("checksums file exceeds writer limit") if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
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
        input : ArrayTuplePartWriteInput,
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
          raise CorruptPartError.new("staged Array(Tuple) checksum inventory differs")
        end
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        unless File.read(File.join(stage, "columns.txt")) == input.columns_metadata
          raise CorruptPartError.new("staged Array(Tuple) columns metadata differs")
        end
        unless File.read(File.join(stage, "columns_substreams.txt")) == input.substreams_metadata
          raise CorruptPartError.new("staged Array(Tuple) substream metadata differs")
        end
        unless File.read(File.join(stage, "serialization.json")) == input.serialization_metadata
          raise CorruptPartError.new("staged Array(Tuple) serialization metadata differs")
        end
        raise CorruptPartError.new("staged row count differs") unless File.read(File.join(stage, "count.txt")) == input.keys.size.to_s
        raise CorruptPartError.new("staged compression codec differs") unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
        raise CorruptPartError.new("staged metadata version differs") unless File.read(File.join(stage, "metadata_version.txt")) == "0"

        expected_files = expected_checksum_files + [
          "checksums.txt", "columns.txt", "columns_substreams.txt",
          "default_compression_codec.txt", "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged Array(Tuple) file inventory differs")
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
        key_part = if flattened_context = input.flattened_nested_context
                     WidePart.open_flattened_nested(
                       stage, flattened_context.group_name, flattened_context.type_name, input.key_name
                     )
                   else
                     WidePart.open_typed(stage, input.key_name)
                   end
        keys = key_part.read_uint64_mark_range(input.key_name, 0, input.mark_count)
        raise CorruptPartError.new("staged UInt64 key readback differs") unless keys == input.keys
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged UInt64 key mark schedule differs")
        end

        part = if flattened_context = input.flattened_nested_context
                 WidePart.open_flattened_nested(
                   stage, flattened_context.group_name, flattened_context.type_name
                 )
               else
                 WidePart.open_typed(stage, input.value_name)
               end
        unless part.column_type == input.type_plan.type_name && part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged Array(Tuple) declaration or row count differs")
        end
        unless part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Array(Tuple) mark schedule differs")
        end
        decoded = if input.type_plan.nested?
                    part.read_nested_mark_range(input.value_name, 0, input.mark_count)
                  else
                    part.read_array_tuple_mark_range(input.value_name, 0, input.mark_count)
                  end
        unless decoded.type_name == input.type_plan.type_name && decoded.row_count == input.keys.size &&
               decoded.element_count == input.schedule.leaf_count && decoded.row_sizes == input.row_sizes
          raise CorruptPartError.new("staged Array(Tuple) outer sizes or cardinality differ")
        end

        fields = input.type_plan.tuple_plan.fields
        tuple_data = decoded.tuple_data
        raise CorruptPartError.new("staged Array(Tuple) leaf schema differs") unless tuple_data.fields == fields
        decoded_columns = tuple_data.columns
        input.leaf_buffers.each_with_index do |expected, leaf_index|
          actual = decoded_columns[leaf_index]
          field = fields[leaf_index]
          unless actual.leaf_type == field.leaf_type && actual.type_name == field.type_name
            raise CorruptPartError.new("staged Array(Tuple) leaf type identity differs")
          end
          if expected_null_map = input.leaf_null_maps[leaf_index]
            actual_null_map = actual.null_map
            unless actual_null_map && actual_null_map.bytes == expected_null_map
              raise CorruptPartError.new("staged Nullable Array(Tuple) mask differs")
            end
          elsif actual.null_map
            raise CorruptPartError.new("staged bare Array(Tuple) leaf unexpectedly has a mask")
          end
          unless TupleLeafPhysicalValues.matches?(expected, actual.physical_values)
            raise CorruptPartError.new("staged Array(Tuple) raw leaf values differ")
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
