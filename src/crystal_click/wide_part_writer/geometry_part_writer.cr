module CrystalClick
  module WidePartWriter
    # Owns the staged write, exact readback validation and exclusive publish
    # for one paired UInt64 key + stock Geometry part.
    private class GeometryPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        data : WideGeometryColumnData,
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
        before_validation_hook : Proc(String, Nil),
      ) : String
        input = GeometryPartWriteInput.build(
          destination, key_name, keys, value_name, data, rows_per_mark, infrastructure
        )
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size),
            input.rows_per_mark, input.schedule.key_schedule, TupleLeafMarkSchedule::Axis::Outer
          ))
          records.concat(write_discriminator_stream(stage, input))
          records.concat(write_arm_streams(stage, input, infrastructure))

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

          checksums_file_hash = CityHashV1.file_hash(File.read(File.join(stage, "checksums.txt")).to_slice)
          before_validation_hook.call(stage)
          validate_staged_part(stage, input, records, checksums_file_hash)
          infrastructure.publish_exclusively(stage, input.target)
          input.target
        ensure
          FileUtils.rm_rf(stage) if Dir.exists?(stage)
        end
      end

      private def self.write_discriminator_stream(
        stage : String,
        input : GeometryPartWriteInput,
      ) : Array(ChecksumRecord)
        logical_name = input.type_plan.discriminator_stream(input.value_name)
        data_name, marks_name, data_path, marks_path = stream_paths(stage, logical_name)
        data_hash = CityHashV1::FileHasher.new
        raw_hash = CityHashV1::FileHasher.new
        mark_bytes = IO::Memory.new
        data_size = 0_u64
        raw_size = 0_u64

        File.open(data_path, "wb") do |data_file|
          input.mark_count.times do |mark_index|
            mark = input.schedule.key_schedule.mark(mark_index, TupleLeafMarkSchedule::Axis::Outer)
            raw_memory = IO::Memory.new
            if mark_index == 0
              StreamEncoding.write_uint64_le(raw_memory, 0_u64)
            end
            tag_pointer = input.tags.to_unsafe + mark.outer_start.to_i
            raw_memory.write(tag_pointer.to_slice(mark.outer_rows.to_i))
            raw = raw_memory.to_slice

            StreamEncoding.write_uint64_le(mark_bytes, data_size)
            # The physical discriminator contains the fixed mode word once.
            # ClickHouse starts the first row mark after this inline prefix.
            StreamEncoding.write_uint64_le(mark_bytes, mark_index == 0 ? 8_u64 : 0_u64)
            StreamEncoding.write_uint64_le(mark_bytes, mark.outer_rows.to_u64)

            frame = StreamEncoding.encode_lz4_frame(raw)
            if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
              raise ArgumentError.new("Geometry discriminator stream exceeds reader limit")
            end
            data_file.write(frame)
            data_hash.update(frame)
            raw_hash.update(raw)
            data_size += frame.size.to_u64
            raw_size += raw.size.to_u64
          end
        end

        StreamEncoding.write_uint64_le(mark_bytes, data_size)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        marks = mark_bytes.to_slice
        if marks.size.to_i64 > MAX_MARK_FILE_BYTES
          raise ArgumentError.new("Geometry discriminator marks exceed reader limit")
        end
        File.write(marks_path, marks)
        [
          ChecksumRecord.new(data_name, data_size, data_hash.finish, true, raw_size, raw_hash.finish),
          ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
        ]
      end

      private def self.write_arm_streams(
        stage : String,
        input : GeometryPartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Array(ChecksumRecord)
        records = [] of ChecksumRecord
        arm_order.each do |arm|
          child_name = "#{input.value_name}.#{arm.type_name}"
          if arm != WideGeometryArm::Point
            child_plan = GeoArrayColumnType.for_type(arm.type_name) ||
                         raise ArgumentError.new("Geometry Geo Array descriptor is unavailable")
            child_plan.size_streams(child_name).each_with_index do |stream, level|
              values = input.size_values(arm, level)
              records.concat(infrastructure.write_uint64_stream(
                stage, stream, values.to_unsafe.to_slice(values.size),
                input.rows_per_mark, input.schedule.size_schedule(arm, level)
              ))
            end
          end

          point_plan = PointColumnType.for_type("Point") ||
                       raise ArgumentError.new("Geometry Point descriptor is unavailable")
          x_stream, y_stream = point_plan.coordinate_streams(child_name)
          coordinate_type = point_plan.coordinate_type
          schedule = input.schedule.coordinate_schedule(arm)
          x_values = input.x_lane(arm)
          y_values = input.y_lane(arm)
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, x_stream, coordinate_type, x_values.as(TupleLeafBuffers), nil,
            schedule, infrastructure
          ))
          records.concat(TupleLeafStreamWriter.write_leaf(
            stage, y_stream, coordinate_type, y_values.as(TupleLeafBuffers), nil,
            schedule, infrastructure
          ))
        end
        records
      end

      private def self.validate_staged_part(
        stage : String,
        input : GeometryPartWriteInput,
        expected_records : Array(ChecksumRecord),
        expected_checksums_file_hash : {UInt64, UInt64},
      ) : Nil
        manifest_path = File.join(stage, "checksums.txt")
        raise CorruptPartError.new("checksums.txt must not be a symbolic link") if File.symlink?(manifest_path)
        if File.size(manifest_path).to_u64 > GeometryPartWriteInput::CHECKSUM_FILE_RESERVE
          raise CorruptPartError.new("staged Geometry checksum manifest exceeds reserved budget")
        end
        checksums = PartChecksums.open(stage)
        expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"] of String
        input.logical_streams.each do |logical|
          base = StreamName.hash(logical)
          expected_checksum_files << "#{base}.bin"
          expected_checksum_files << "#{base}.mrk2"
        end
        unless checksums.entries.keys.sort == expected_checksum_files.sort
          raise CorruptPartError.new("staged Geometry checksum inventory differs")
        end
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        expected_files = expected_checksum_files + [
          "checksums.txt", "columns.txt", "columns_substreams.txt",
          "default_compression_codec.txt", "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged Geometry file inventory differs")
        end
        checksums.entries.each_key do |name|
          path = File.join(stage, name)
          raise CorruptPartError.new("staged Geometry file must not be a symbolic link") if File.symlink?(path)
        end

        metadata_checks = [
          {"columns.txt", input.columns_metadata, "staged Geometry columns metadata differs"},
          {"columns_substreams.txt", input.substreams_metadata, "staged Geometry substream metadata differs"},
          {"serialization.json", input.serialization_metadata, "staged Geometry serialization metadata differs"},
          {"count.txt", input.keys.size.to_s, "staged Geometry row count differs"},
          {"default_compression_codec.txt", "CODEC(LZ4)", "staged Geometry compression codec differs"},
          {"metadata_version.txt", "0", "staged Geometry metadata version differs"},
        ]
        metadata_checks.each do |name, expected, message|
          path = File.join(stage, name)
          raise CorruptPartError.new("staged Geometry metadata must not be a symbolic link") if File.symlink?(path)
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
        raise CorruptPartError.new("staged Geometry primary index differs from input") unless index.keys == expected_index

        expected_mark_rows = input.outer_rows_by_mark
        key_part = WidePart.open_typed(stage, input.key_name)
        unless key_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Geometry primary-key mark schedule differs")
        end
        validate_key_values(key_part, input, expected_mark_rows)

        part = WidePart.open_typed(stage, input.value_name)
        unless part.column_type == input.type_plan.type_name && part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged Geometry declaration or outer row count differs")
        end
        unless part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged Geometry physical mark schedule differs")
        end

        readback_charge = part.geometry_mark_range_materialization_charge(
          input.value_name, 0, input.mark_count, input.readback_budget
        )
        if readback_charge > input.readback_budget
          raise CorruptPartError.new("staged Geometry readback exceeds aggregate materialization budget")
        end
        part.validate_geometry_mark_range_structure(
          input.value_name, 0, input.mark_count, input.readback_budget
        )
        decoded = part.read_geometry_mark_range(
          input.value_name, 0, input.mark_count, input.readback_budget
        )
        unless decoded.type_name == input.type_plan.type_name && decoded.row_count == input.keys.size
          raise CorruptPartError.new("staged Geometry declaration or decoded row count differs")
        end
        unless decoded.tags == input.tags
          raise CorruptPartError.new("staged Geometry discriminator tags differ")
        end

        arm_order.each do |arm|
          if arm == WideGeometryArm::Point
            validate_coordinates(decoded, input, arm)
          else
            child = decoded.geo_array_data(arm)
            plan = GeoArrayColumnType.for_type(arm.type_name) ||
                   raise CorruptPartError.new("staged Geometry arm descriptor is unavailable")
            unless child.type_name == arm.type_name && child.row_count == decoded.arm_count(arm)
              raise CorruptPartError.new("staged Geometry nominal arm rows differ")
            end
            plan.depth.times do |level|
              unless child.topology.sizes(level) == input.size_values(arm, level)
                raise CorruptPartError.new("staged Geometry nested size topology differs")
              end
            end
            validate_coordinates(decoded, input, arm)
          end
        end

        expected_records.each do |record|
          entry = checksums.entry(record.name) || raise CorruptPartError.new("staged Geometry checksum record is missing")
          unless entry.physical_size == record.physical_size && entry.file_hash == record.file_hash &&
                 entry.compressed == record.compressed && entry.uncompressed_size == record.uncompressed_size
            raise CorruptPartError.new("staged Geometry checksum declaration differs")
          end
        end
        actual_checksums_file_hash = CityHashV1.file_hash(File.read(File.join(stage, "checksums.txt")).to_slice)
        unless actual_checksums_file_hash == expected_checksums_file_hash
          raise CorruptPartError.new("staged Geometry checksum manifest differs")
        end
        nil
      end

      private def self.validate_key_values(
        key_part : WidePart,
        input : GeometryPartWriteInput,
        expected_mark_rows : Array(UInt64),
      ) : Nil
        mark_index = 0
        start = 0
        while mark_index < input.mark_count
          actual = key_part.read_uint64_mark_range(input.key_name, mark_index, 1)
          rows = expected_mark_rows[mark_index].to_i32
          unless actual.size == rows
            raise CorruptPartError.new("staged Geometry primary-key readback row count differs")
          end
          rows.times do |offset|
            unless actual[offset] == input.keys[start + offset]
              raise CorruptPartError.new("staged Geometry primary-key readback differs")
            end
          end
          start += rows
          mark_index += 1
        end
      end

      private def self.validate_coordinates(
        decoded : WideGeometryColumnData,
        input : GeometryPartWriteInput,
        arm : WideGeometryArm,
      ) : Nil
        x_values = input.x_lane(arm)
        y_values = input.y_lane(arm)
        point_count = arm == WideGeometryArm::Point ? decoded.arm_count(arm) : decoded.geo_array_data(arm).point_count
        unless point_count == x_values.size && x_values.size == y_values.size
          raise CorruptPartError.new("staged Geometry Point lane cardinality differs")
        end
        point_count.times do |point_index|
          point = if arm == WideGeometryArm::Point
                    decoded.point_at(point_index)
                  else
                    decoded.geo_array_data(arm).point_at(point_index)
                  end
          unless point.x_bits == x_values[point_index].unsafe_as(UInt64) &&
                 point.y_bits == y_values[point_index].unsafe_as(UInt64)
            raise CorruptPartError.new("staged Geometry Point values differ")
          end
        end
      end

      private def self.stream_paths(stage : String, logical_name : String) : {String, String, String, String}
        base = StreamName.hash(logical_name)
        data_name = "#{base}.bin"
        marks_name = "#{base}.mrk2"
        {data_name, marks_name, File.join(stage, data_name), File.join(stage, marks_name)}
      end

      private def self.arm_order : StaticArray(WideGeometryArm, 7)
        StaticArray[
          WideGeometryArm::LineString,
          WideGeometryArm::MultiLineString,
          WideGeometryArm::MultiPolygon,
          WideGeometryArm::Point,
          WideGeometryArm::Polygon,
          WideGeometryArm::Ring,
          WideGeometryArm::MultiPoint,
        ]
      end
    end
  end
end
