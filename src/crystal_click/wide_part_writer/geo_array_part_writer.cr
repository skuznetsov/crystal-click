module CrystalClick
  module WidePartWriter
    # Owns the paired UInt64 key + exact nominal Geo Array part profile.
    # Nested cardinality is encoded by one size stream per array edge; all
    # streams retain the outer table mark grid and share bounded leaf codecs.
    private class GeoArrayPartWriter
      CHECKSUMED_METADATA_RESERVE = 8192_u64

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        level_sizes : Array(Array(UInt64)),
        points : Slice(WidePointValue),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
        before_validation_hook : Proc(String, Nil),
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type_name, level_sizes,
          points, rows_per_mark, infrastructure
        )
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size),
            input.rows_per_mark, input.size_schedules[0], TupleLeafMarkSchedule::Axis::Outer
          ))

          input.type_plan.size_streams(input.value_name).each_with_index do |stream, level|
            axis = level == 0 ? TupleLeafMarkSchedule::Axis::Outer : TupleLeafMarkSchedule::Axis::Leaf
            records.concat(infrastructure.write_uint64_stream(
              stage, stream, input.level_sizes[level].to_unsafe.to_slice(input.level_sizes[level].size),
              input.rows_per_mark, input.size_schedules[level], axis
            ))
          end

          x_stream, y_stream = input.type_plan.coordinate_streams(input.value_name)
          coordinate_type = input.type_plan.coordinate_type
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, x_stream, coordinate_type,
            input.x_values.as(TupleLeafBuffers), nil, input.point_schedule, infrastructure
          ))
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, y_stream, coordinate_type,
            input.y_values.as(TupleLeafBuffers), nil, input.point_schedule, infrastructure
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

          # The test-only hook runs after immutable expected snapshots exist;
          # a self-consistent but changed topology must still fail readback.
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
        type_name : String,
        level_sizes : Array(Array(UInt64)),
        points : Slice(WidePointValue),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : GeoArrayPartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("columns must be distinct") if key_name == value_name
        raise ArgumentError.new("keys and Geo Array values must have the same nonzero row count") if keys.empty?
        if keys.size.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS
          raise ArgumentError.new("Geo Array outer row count exceeds writer limit")
        end
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        type_plan = GeoArrayColumnType.for_type(type_name) ||
                    raise ArgumentError.new("Geo Array writer requires an exact stock declaration")
        unless level_sizes.size == type_plan.depth && level_sizes[0].size == keys.size
          raise ArgumentError.new("keys and Geo Array outer sizes must have the same row count")
        end
        WideGeoArrayTopology.validate!(type_plan, level_sizes, points.size)
        previous_key = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous_key
          previous_key = key
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        raise ArgumentError.new("Geo Array mark count exceeds reader limit") if mark_count > MAX_MARKS
        mark_file_size = checked_file_size(mark_count, WidePart::MARK_SIZE, "Geo Array mark file")
        index_size = checked_file_size(mark_count, 8_i64, "Geo Array primary index")
        if mark_file_size > MAX_MARK_FILE_BYTES
          raise ArgumentError.new("Geo Array mark file exceeds reader limit")
        end
        if index_size > MAX_PRIMARY_INDEX_BYTES || index_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
          raise ArgumentError.new("Geo Array primary index exceeds reader limit")
        end

        physical_streams = type_plan.physical_streams(value_name).map(&.[0])
        logical_streams = [key_name] of String
        logical_streams.concat(physical_streams)
        if physical_streams.size > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("Geo Array substream count exceeds reader limit")
        end
        logical_streams.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("Geo Array physical stream name exceeds reader limit")
          end
        end
        stream_bases = logical_streams.map { |name| StreamName.hash(name) }
        raise ArgumentError.new("Geo Array physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size
        checksum_count = logical_streams.size * 2 + 3
        if checksum_count > PartChecksums::MAX_ENTRIES
          raise ArgumentError.new("Geo Array checksum entry count exceeds reader limit")
        end

        # Reserve all retained schedules and interval-vector scratch before
        # allocating the per-mark schedule arrays. The schedule records carry
        # outer rows independently from each stream's logical element count.
        schedule_charge, interval_scratch = schedule_reservation(mark_count, type_plan.depth, level_sizes)
        level_counts = level_sizes.map { |sizes| sizes.size.to_u64 }
        point_count = points.size.to_u64
        reader_charge = type_plan.reader_materialization_charge(level_counts, point_count, mark_count) ||
                        raise ArgumentError.new("Geo Array reader materialization charge exceeds limit")
        input_charge = input_snapshot_charge(
          keys.size, level_sizes, points.size, mark_count, type_plan.depth,
          schedule_charge, interval_scratch
        )
        frame_raw_bound = {WidePart::MAX_ARRAY_MARK_ELEMENTS, WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_u64 // 8_u64}.min * 8_u64
        frame_compressed_bound = infrastructure.checked_string_frame_size(frame_raw_bound.to_i64, "Geo Array maximum frame").to_u64
        frame_scratch = checked_add(frame_raw_bound, frame_compressed_bound, "Geo Array frame scratch")
        retained_metadata_reserve = CHECKSUMED_METADATA_RESERVE
        combined = checked_add(reader_charge, input_charge, "Geo Array combined materialization")
        combined = checked_add(combined, frame_scratch, "Geo Array combined materialization")
        combined = checked_add(combined, retained_metadata_reserve, "Geo Array combined materialization")
        if combined > GeoArrayColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Geo Array writer materialization charge exceeds 64 MiB")
        end

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        size_schedules, point_schedule = build_schedules(level_sizes, rows_per_mark, mark_count, type_plan.depth)
        compressed_sizes, raw_sizes = preflight_stream_budgets(
          keys.size, type_plan, value_name, logical_streams,
          size_schedules, point_schedule, rows_per_mark, mark_count, infrastructure
        )
        columns_metadata = columns_metadata(key_name, value_name, type_plan)
        substreams_metadata = substreams_metadata(key_name, value_name, physical_streams)
        serialization_metadata = serialization_metadata(key_name, keys)
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        # These are the first owned data snapshots. Everything that can reject
        # the declaration, axes, schedule, frames, metadata, index or combined
        # materialization charge has already been checked.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        level_sizes_copy = level_sizes.map { |sizes| Array(UInt64).new(sizes.size) { |index| sizes[index] } }
        x_values = Array(Float64).new(points.size) { |index| points[index].x }
        y_values = Array(Float64).new(points.size) { |index| points[index].y }

        GeoArrayPartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, type_plan, level_sizes_copy,
          x_values, y_values, logical_streams, compressed_sizes, raw_sizes,
          mark_count, mark_file_size, index_size, rows_per_mark,
          size_schedules, point_schedule, columns_metadata, substreams_metadata,
          serialization_metadata
        )
      end

      private def self.schedule_reservation(
        mark_count : Int32,
        depth : Int32,
        level_sizes : Array(Array(UInt64)),
      ) : {UInt64, UInt64}
        schedule_bytes = TupleLeafMarkSchedule.ragged_logical_charge(mark_count) ||
                         raise ArgumentError.new("Geo Array schedule charge overflows")
        schedule_count = depth.to_u64 + 1_u64
        schedule_charge = checked_multiply(schedule_bytes, schedule_count, "Geo Array schedules")
        schedule_charge = checked_add(
          schedule_charge,
          instance_sizeof(Array(TupleLeafMarkSchedule)).to_u64 + schedule_count * sizeof(Pointer(TupleLeafMarkSchedule)).to_u64,
          "Geo Array schedule collection"
        )

        interval_arrays = schedule_count * 2_u64
        interval_scratch = checked_multiply(
          interval_arrays,
          instance_sizeof(Array(UInt64)).to_u64,
          "Geo Array schedule interval headers"
        )
        interval_scratch = checked_add(
          interval_scratch,
          checked_multiply(checked_multiply(interval_arrays, mark_count.to_u64, "Geo Array intervals"), sizeof(UInt64).to_u64, "Geo Array intervals"),
          "Geo Array schedule interval storage"
        )
        # build_schedules retains two outer Array(Array(UInt64)) owners and
        # their child-reference slots in addition to the leaf vectors above.
        interval_scratch = checked_add(
          interval_scratch,
          checked_multiply(2_u64, instance_sizeof(Array(Array(UInt64))).to_u64, "Geo Array schedule outer headers"),
          "Geo Array schedule outer headers"
        )
        interval_scratch = checked_add(
          interval_scratch,
          checked_multiply(2_u64 * depth.to_u64, sizeof(Pointer(Array(UInt64))).to_u64, "Geo Array schedule outer slots"),
          "Geo Array schedule outer slots"
        )
        # The schedule builder also retains a prefix vector; preflight keeps a
        # compact level-count vector while deriving the charge.
        2.times do
          interval_scratch = checked_add(interval_scratch, instance_sizeof(Array(UInt64)).to_u64, "Geo Array level scratch")
          interval_scratch = checked_add(
            interval_scratch,
            checked_multiply(depth.to_u64, sizeof(UInt64).to_u64, "Geo Array level scratch"),
            "Geo Array level scratch"
          )
        end
        # Stage validation calls topology.sizes(level), which returns a
        # detached copy. Only one level copy is live for each comparison, so
        # charge the largest level plus its Array header.
        largest_level = 0_u64
        level_sizes.each do |sizes|
          level_size = sizes.size.to_u64
          largest_level = level_size if level_size > largest_level
        end
        interval_scratch = checked_add(interval_scratch, instance_sizeof(Array(UInt64)).to_u64, "Geo Array readback level copy")
        interval_scratch = checked_add(
          interval_scratch,
          checked_multiply(largest_level, sizeof(UInt64).to_u64, "Geo Array readback level copy"),
          "Geo Array readback level copy"
        )
        {schedule_charge, interval_scratch}
      end

      private def self.input_snapshot_charge(
        rows : Int32,
        level_sizes : Array(Array(UInt64)),
        points : Int32,
        mark_count : Int32,
        depth : Int32,
        schedule_charge : UInt64,
        interval_scratch : UInt64,
      ) : UInt64
        total = instance_sizeof(GeoArrayPartWriteInput).to_u64
        total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64 + rows.to_u64 * 8_u64, "Geo Array key snapshot")
        total = checked_add(total, instance_sizeof(Array(Array(UInt64))).to_u64, "Geo Array size snapshots")
        total = checked_add(total, depth.to_u64 * sizeof(Pointer(Array(UInt64))).to_u64, "Geo Array size snapshots")
        size_values = 0_u64
        level_sizes.each do |sizes|
          total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64, "Geo Array size snapshot")
          size_values = checked_add(size_values, sizes.size.to_u64, "Geo Array size snapshot count")
        end
        total = checked_add(total, checked_multiply(size_values, 8_u64, "Geo Array size snapshot values"), "Geo Array size snapshot values")
        2.times do
          total = checked_add(total, instance_sizeof(Array(Float64)).to_u64, "Geo Array Point snapshot")
        end
        total = checked_add(total, checked_multiply(points.to_u64, 16_u64, "Geo Array Point snapshots"), "Geo Array Point snapshots")
        total = checked_add(total, schedule_charge, "Geo Array schedule snapshots")
        total = checked_add(total, interval_scratch, "Geo Array schedule scratch")
        total = checked_add(total, checked_multiply(mark_count.to_u64 + 1_u64, 24_u64, "Geo Array primary index snapshots"), "Geo Array primary index snapshots")
        total
      end

      private def self.build_schedules(
        level_sizes : Array(Array(UInt64)),
        rows_per_mark : Int32,
        mark_count : Int32,
        depth : Int32,
      ) : {Array(TupleLeafMarkSchedule), TupleLeafMarkSchedule}
        starts = Array(Array(UInt64)).new(depth) { Array(UInt64).new(mark_count) }
        counts = Array(Array(UInt64)).new(depth) { Array(UInt64).new(mark_count) }
        point_starts = Array(UInt64).new(mark_count)
        point_counts = Array(UInt64).new(mark_count)
        level_prefixes = Array(UInt64).new(depth, 0_u64)

        outer_start = 0
        mark_index = 0
        points_prefix = 0_u64
        while mark_index < mark_count
          outer_rows = {rows_per_mark, level_sizes[0].size - outer_start}.min
          current_start = outer_start.to_u64
          current_count = outer_rows.to_u64
          level = 0
          while level < depth
            starts[level] << current_start
            counts[level] << current_count
            child_count = sum_range(level_sizes[level], current_start, current_count, "Geo Array level #{level} mark")
            if level + 1 < depth
              current_start = level_prefixes[level + 1]
              current_count = child_count
              level_prefixes[level + 1] = checked_add(
                level_prefixes[level + 1], child_count, "Geo Array nested level prefix"
              )
            else
              point_starts << points_prefix
              point_counts << child_count
              points_prefix = checked_add(points_prefix, child_count, "Geo Array Point prefix")
            end
            level += 1
          end
          outer_start += outer_rows
          mark_index += 1
        end

        schedules = Array(TupleLeafMarkSchedule).new(depth)
        depth.times do |level|
          schedules << TupleLeafMarkSchedule.from_intervals(
            level_sizes[0].size.to_u64, rows_per_mark, starts[level], counts[level]
          )
        end
        point_schedule = TupleLeafMarkSchedule.from_intervals(
          level_sizes[0].size.to_u64, rows_per_mark, point_starts, point_counts
        )
        {schedules, point_schedule}
      end

      private def self.validate_staged_part(
        stage : String,
        input : GeoArrayPartWriteInput,
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
          raise CorruptPartError.new("staged Geo Array checksum inventory differs")
        end
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        expected_files = expected_checksum_files + [
          "checksums.txt", "columns.txt", "columns_substreams.txt",
          "default_compression_codec.txt", "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged Geo Array file inventory differs")
        end
        metadata_checks = [
          {"columns.txt", input.columns_metadata, "staged Geo Array columns metadata differs"},
          {"columns_substreams.txt", input.substreams_metadata, "staged Geo Array substream metadata differs"},
          {"serialization.json", input.serialization_metadata, "staged Geo Array serialization metadata differs"},
          {"count.txt", input.keys.size.to_s, "staged Geo Array row count differs"},
          {"default_compression_codec.txt", "CODEC(LZ4)", "staged Geo Array compression codec differs"},
          {"metadata_version.txt", "0", "staged Geo Array metadata version differs"},
        ]
        metadata_checks.each do |name, expected, message|
          path = File.join(stage, name)
          raise CorruptPartError.new("staged Geo Array metadata must not be a symbolic link") if File.symlink?(path)
          raise CorruptPartError.new(message) unless File.file?(path) && File.read(path) == expected
        end

        index = PrimaryKeyIndex.open(stage, input.mark_count, checksums)
        expected_index = Array(UInt64).new(input.mark_count + 1)
        row = 0
        while row < input.keys.size
          expected_index << input.keys[row]
          row += input.rows_per_mark
        end
        expected_index << input.keys.last
        raise CorruptPartError.new("staged Geo Array primary index differs from input") unless index.keys == expected_index

        expected_mark_rows = Array(UInt64).new(input.mark_count) do |mark_index|
          input.size_schedules[0].mark(mark_index, TupleLeafMarkSchedule::Axis::Outer).outer_rows.to_u64
        end
        key_part = WidePart.open_typed(stage, input.key_name)
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Geo Array primary-key mark schedule differs")
        end
        mark_index = 0
        start = 0
        while mark_index < input.mark_count
          actual_keys = key_part.read_uint64_mark_range(input.key_name, mark_index, 1)
          rows = expected_mark_rows[mark_index].to_i32
          unless actual_keys.size == rows
            raise CorruptPartError.new("staged Geo Array primary-key readback row count differs")
          end
          rows.times do |offset|
            unless actual_keys[offset] == input.keys[start + offset]
              raise CorruptPartError.new("staged Geo Array primary-key readback differs")
            end
          end
          start += rows
          mark_index += 1
        end

        part = WidePart.open_typed(stage, input.value_name)
        unless part.column_type == input.type_plan.type_name && part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged Geo Array declaration or outer row count differs")
        end
        unless part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Geo Array physical mark schedule differs")
        end
        decoded = part.read_geo_array_mark_range(input.value_name, 0, input.mark_count)
        unless decoded.type_name == input.type_plan.type_name &&
               decoded.row_count == input.keys.size && decoded.point_count == input.x_values.size
          raise CorruptPartError.new("staged Geo Array topology or Point count differs")
        end
        input.level_sizes.each_with_index do |expected_sizes, level|
          unless decoded.topology.sizes(level) == expected_sizes
            raise CorruptPartError.new("staged Geo Array nested size topology differs")
          end
        end
        unless decoded.point_count == input.x_values.size && input.x_values.size == input.y_values.size
          raise CorruptPartError.new("staged Geo Array flattened Point count differs")
        end
        input.x_values.each_with_index do |x, point_index|
          actual = decoded.point_at(point_index)
          unless actual.x_bits == x.unsafe_as(UInt64) && actual.y_bits == input.y_values[point_index].unsafe_as(UInt64)
            raise CorruptPartError.new("staged Geo Array raw Point coordinates differ")
          end
        end

        expected_records.each do |record|
          entry = checksums.entry(record.name) || raise CorruptPartError.new("staged Geo Array checksum record is missing")
          unless entry.physical_size == record.physical_size && entry.file_hash == record.file_hash &&
                 entry.compressed == record.compressed && entry.uncompressed_size == record.uncompressed_size
            raise CorruptPartError.new("staged Geo Array checksum declaration differs")
          end
        end
        nil
      end

      private def self.preflight_stream_budgets(
        row_count : Int32,
        type_plan : GeoArrayColumnType,
        value_name : String,
        logical_streams : Array(String),
        size_schedules : Array(TupleLeafMarkSchedule),
        point_schedule : TupleLeafMarkSchedule,
        rows_per_mark : Int32,
        mark_count : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64)}
        compressed_sizes = Array(Int64).new(logical_streams.size, 0_i64)
        raw_sizes = Array(UInt64).new(logical_streams.size, 0_u64)
        logical_streams.each_with_index do |stream, index|
          schedule = if index == 0
                       size_schedules[0]
                     elsif index <= type_plan.depth
                       size_schedules[index - 1]
                     else
                       point_schedule
                     end
          axis = if index <= 1
                   TupleLeafMarkSchedule::Axis::Outer
                 else
                   TupleLeafMarkSchedule::Axis::Leaf
                 end
          width = if index == 0
                    8
                  else
                    type_plan.stream_width(value_name, stream) ||
                      raise ArgumentError.new("Geo Array physical stream width is unavailable")
                  end
          compressed_total = 0_i64
          raw_total = 0_u64
          mark_index = 0
          while mark_index < mark_count
            mark = schedule.mark(mark_index, axis)
            count = axis == TupleLeafMarkSchedule::Axis::Outer ? mark.outer_rows : mark.leaf_count
            raw_bytes = checked_multiply(count.to_u64, width.to_u64, "Geo Array stream frame bytes")
            if raw_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 ||
               raw_bytes > WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_u64
              raise ArgumentError.new("Geo Array stream granule exceeds reader limit")
            end
            raw_total = checked_add(raw_total, raw_bytes, "Geo Array raw stream bytes")
            if raw_total > MAX_DATA_FILE_BYTES.to_u64
              raise ArgumentError.new("Geo Array raw stream exceeds reader limit")
            end
            unless raw_bytes == 0
              frame_size = infrastructure.checked_string_frame_size(raw_bytes.to_i64, "Geo Array stream #{stream}")
              if frame_size > MAX_DATA_FILE_BYTES - compressed_total
                raise ArgumentError.new("Geo Array compressed stream exceeds reader limit")
              end
              compressed_total += frame_size
            end
            mark_index += 1
          end
          compressed_sizes[index] = compressed_total
          raw_sizes[index] = raw_total
        end
        {compressed_sizes, raw_sizes}
      end

      private def self.columns_metadata(key_name : String, value_name : String, type_plan : GeoArrayColumnType) : String
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

      private def self.serialization_metadata(key_name : String, keys : Slice(UInt64)) : String
        defaults = keys.count { |key| key == 0_u64 }
        "{\"columns\":[{\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{defaults},\"num_rows\":#{keys.size}}]," +
          "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Geo Array metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Geo Array metadata line exceeds reader limit")
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
        raw_uncompressed = [0_u64, 0_u64, 0_u64]
        logical_streams.each_with_index do |logical, index|
          base = StreamName.hash(logical)
          names << "#{base}.bin"
          sizes << compressed_sizes[index].to_u64
          compressed << true
          raw_uncompressed << raw_sizes[index]
          names << "#{base}.mrk2"
          sizes << mark_file_size.to_u64
          compressed << false
          raw_uncompressed << 0_u64
        end
        raise ArgumentError.new("Geo Array checksum entry count exceeds reader limit") if names.size > PartChecksums::MAX_ENTRIES

        payload_size = var_uint_size(names.size.to_u64)
        names.each_with_index do |name, index|
          payload_size += var_uint_size(name.bytesize.to_u64) + name.bytesize.to_u64
          payload_size += var_uint_size(sizes[index]) + 17_u64
          payload_size += var_uint_size(raw_uncompressed[index]) + 16_u64 if compressed[index]
        end
        raise ArgumentError.new("Geo Array checksums payload exceeds writer limit") if payload_size > Int64::MAX.to_u64
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "Geo Array checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        raise ArgumentError.new("Geo Array checksums file exceeds reader limit") if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
        nil
      end

      private def self.checked_file_size(mark_count : Int32, width : Int64, label : String) : Int64
        count = mark_count.to_i64 + 1_i64
        raise ArgumentError.new("#{label} exceeds native file limit") if count > Int64::MAX // width
        count * width
      end

      private def self.sum_range(values : Array(UInt64), start : UInt64, count : UInt64, label : String) : UInt64
        if start > values.size.to_u64 || count > values.size.to_u64 - start
          raise ArgumentError.new("#{label} lies outside its parent vector")
        end
        total = 0_u64
        index = start.to_i
        finish = index + count.to_i
        while index < finish
          value = values[index]
          total = checked_add(total, value, "#{label} total")
          index += 1
        end
        total
      end

      private def self.checked_add(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows UInt64") if right != 0 && left > UInt64::MAX // right
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
