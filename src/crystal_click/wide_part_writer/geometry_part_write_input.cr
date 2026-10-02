module CrystalClick
  module WidePartWriter
    # Detached, budgeted snapshot consumed by one paired Geometry writer.
    # Validation, aggregate reservation and all source-buffer copies complete
    # here before the caller is allowed to request a staging directory.
    private class GeometryPartWriteInput
      CHECKSUM_FILE_RESERVE = 8192_u64

      getter target : String
      getter parent : String
      getter key_name : String
      getter keys : Array(UInt64)
      getter value_name : String
      getter type_plan : GeometryColumnType
      getter tags : Array(UInt8)
      getter level_sizes : Array(Array(UInt64))
      getter x_values : StaticArray(Array(Float64), 7)
      getter y_values : StaticArray(Array(Float64), 7)
      getter logical_streams : Array(String)
      getter compressed_sizes : Array(Int64)
      getter raw_sizes : Array(UInt64)
      getter mark_count : Int32
      getter outer_rows_by_mark : Array(UInt64)
      getter mark_file_size : Int64
      getter index_size : Int64
      getter rows_per_mark : Int32
      getter readback_budget : UInt64
      getter schedule : GeometryPartWriteSchedule
      getter columns_metadata : String
      getter substreams_metadata : String
      getter serialization_metadata : String

      private def initialize(
        @target : String,
        @parent : String,
        @key_name : String,
        @keys : Array(UInt64),
        @value_name : String,
        @type_plan : GeometryColumnType,
        @tags : Array(UInt8),
        @level_sizes : Array(Array(UInt64)),
        @x_values : StaticArray(Array(Float64), 7),
        @y_values : StaticArray(Array(Float64), 7),
        @logical_streams : Array(String),
        @compressed_sizes : Array(Int64),
        @raw_sizes : Array(UInt64),
        @mark_count : Int32,
        @outer_rows_by_mark : Array(UInt64),
        @mark_file_size : Int64,
        @index_size : Int64,
        @rows_per_mark : Int32,
        @readback_budget : UInt64,
        @schedule : GeometryPartWriteSchedule,
        @columns_metadata : String,
        @substreams_metadata : String,
        @serialization_metadata : String,
      )
      end

      def self.build(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        data : WideGeometryColumnData,
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : GeometryPartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("columns must be distinct") if key_name == value_name
        raise ArgumentError.new("keys and Geometry values must have the same nonzero row count") if keys.empty?
        if keys.size.to_u64 > WidePart::MAX_ARRAY_MARK_ROWS || keys.size != data.row_count
          raise ArgumentError.new("keys and Geometry values must have the same bounded outer row count")
        end
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        type_plan = GeometryColumnType.for_type(data.type_name) ||
                    raise ArgumentError.new("Geometry writer requires the exact stock declaration")
        row_count = data.row_count
        mark_count = infrastructure.checked_mark_count(row_count, rows_per_mark)
        raise ArgumentError.new("Geometry mark count exceeds reader limit") if mark_count > MAX_MARKS
        rows_by_mark = outer_rows_by_mark(row_count, rows_per_mark, mark_count)
        mark_file_size = checked_file_size(mark_count, WidePart::MARK_SIZE, "Geometry mark file")
        index_size = checked_file_size(mark_count, 8_i64, "Geometry primary index")
        if mark_file_size > MAX_MARK_FILE_BYTES
          raise ArgumentError.new("Geometry mark file exceeds reader limit")
        end
        if index_size > MAX_PRIMARY_INDEX_BYTES || index_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
          raise ArgumentError.new("Geometry primary index exceeds reader limit")
        end

        previous_key = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous_key
          previous_key = key
        end

        arms, level_counts, point_counts = validate_geometry_owner(data, row_count)
        schedule_charge = GeometryPartWriteSchedule.reserved_charge(mark_count)
        interval_scratch = GeometryPartWriteSchedule.interval_scratch_charge(mark_count)

        physical_streams = type_plan.physical_streams(value_name).map(&.[0])
        logical_streams = [key_name] of String
        logical_streams.concat(physical_streams)
        if physical_streams.size != 25 || physical_streams.size > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("Geometry physical stream inventory differs from the stock profile")
        end
        logical_streams.each do |name|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("Geometry physical stream name exceeds reader limit")
          end
        end
        stream_bases = logical_streams.map { |name| StreamName.hash(name) }
        unless stream_bases.uniq.size == stream_bases.size
          raise ArgumentError.new("Geometry physical stream names must be distinct")
        end
        checksum_count = logical_streams.size * 2 + 3
        if checksum_count > PartChecksums::MAX_ENTRIES
          raise ArgumentError.new("Geometry checksum entry count exceeds reader limit")
        end

        columns_metadata = columns_metadata(key_name, value_name, type_plan)
        substreams_metadata = substreams_metadata(key_name, value_name, physical_streams)
        serialization_metadata = serialization_metadata(key_name, keys)
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)

        # Reserve source owner, detached writer buffers, both retained schedule
        # sets, staged reader result/scratch, and one streaming frame together.
        # The charge is logical bounded storage rather than an RSS prediction.
        reader_summary_charge = type_plan.reader_summary_charge(rows_by_mark) ||
                                raise ArgumentError.new("Geometry reader summary charge exceeds limit")
        reader_tag_scratch_charge = type_plan.reader_tag_scratch_charge(rows_by_mark) ||
                                    raise ArgumentError.new("Geometry reader tag scratch exceeds limit")
        reader_charge = type_plan.reader_materialization_charge(
          rows_by_mark, level_counts, point_counts,
          reader_summary_charge, reader_tag_scratch_charge
        ) || raise ArgumentError.new("Geometry reader materialization charge exceeds limit")
        writer_snapshot_charge = snapshot_charge(
          row_count, keys.size, level_counts, point_counts,
          logical_streams, mark_count, rows_by_mark, schedule_charge,
          interval_scratch, columns_metadata, substreams_metadata,
          serialization_metadata
        )
        aggregate = checked_add(data.retained_logical_charge, writer_snapshot_charge, "Geometry writer aggregate")
        aggregate = checked_add(aggregate, CHECKSUM_FILE_RESERVE, "Geometry writer aggregate")
        if aggregate > GeometryColumnType::MAX_MATERIALIZED_BYTES ||
           reader_charge > GeometryColumnType::MAX_MATERIALIZED_BYTES - aggregate
          raise ArgumentError.new("Geometry writer aggregate materialization exceeds 64 MiB")
        end

        # Schedule allocation is now covered by the aggregate reservation.
        # Every Geometry lane uses the outer table grid but its sparse logical
        # element interval; no arm invents or drops a physical mark row.
        schedule = GeometryPartWriteSchedule.build(data, rows_per_mark, mark_count)
        compressed_sizes, raw_sizes, max_frame_scratch = preflight_stream_budgets(
          type_plan, value_name, logical_streams, schedule, row_count,
          rows_per_mark, mark_count, infrastructure
        )
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          row_count, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        aggregate = checked_add(aggregate, max_frame_scratch, "Geometry writer frame scratch")
        if aggregate > GeometryColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Geometry writer aggregate materialization exceeds 64 MiB")
        end
        readback_budget = GeometryColumnType::MAX_MATERIALIZED_BYTES - aggregate
        if reader_charge > readback_budget
          raise ArgumentError.new("Geometry writer aggregate materialization exceeds 64 MiB")
        end
        aggregate = checked_add(aggregate, reader_charge, "Geometry writer aggregate")
        if aggregate > GeometryColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Geometry writer aggregate materialization exceeds 64 MiB")
        end

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        # This is the first snapshot of caller-owned keys or Geometry buffers.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        tags_copy = data.tags
        level_sizes_copy = snapshot_level_sizes(data, arms)
        x_values, y_values = snapshot_coordinate_lanes(data, arms)

        new(
          target, parent, key_name, keys_copy, value_name, type_plan, tags_copy,
          level_sizes_copy, x_values, y_values, logical_streams,
          compressed_sizes, raw_sizes, mark_count, rows_by_mark, mark_file_size,
          index_size, rows_per_mark, readback_budget, schedule, columns_metadata,
          substreams_metadata, serialization_metadata
        )
      end

      def size_values(arm : WideGeometryArm, level : Int) : Array(UInt64)
        arm.type_name
        arm_index = arm.value.to_i32
        if level < 0 || level >= arm.depth
          raise BoundsError.new("Geometry size level is out of bounds")
        end
        @level_sizes[level_offset(arm_index) + level]
      end

      def x_lane(arm : WideGeometryArm) : Array(Float64)
        arm.type_name
        @x_values[arm.value.to_i32]
      end

      def y_lane(arm : WideGeometryArm) : Array(Float64)
        arm.type_name
        @y_values[arm.value.to_i32]
      end

      private def level_offset(arm_index : Int32) : Int32
        offset = 0
        arm_index.times do |tag|
          arm = WideGeometryArm.for_tag(tag.to_u8) ||
                raise ArgumentError.new("Geometry arm value is invalid")
          offset += arm.depth
        end
        offset
      end

      private def self.validate_geometry_owner(
        data : WideGeometryColumnData,
        row_count : Int32,
      ) : {StaticArray(Int32, 7), Array(Array(UInt64)), Array(UInt64)}
        arms = StaticArray(Int32, 7).new(0)
        row_count.times do |row|
          arm = data.arm_at(row)
          if arm
            arm_index = checked_arm_index(arm.not_nil!)
            arms[arm_index] += 1
          end
        end

        levels = Array(Array(UInt64)).new(7) { [] of UInt64 }
        points = Array(UInt64).new(7, 0_u64)
        arm_order.each_with_index do |arm, arm_index|
          if arm == WideGeometryArm::Point
            points[arm_index] = arms[arm_index].to_u64
            next
          end

          child = data.geo_array_data(arm)
          unless child.type_name == arm.type_name && child.row_count == arms[arm_index]
            raise ArgumentError.new("Geometry child owner does not match its nominal arm rows")
          end
          topology = child.topology
          unless topology.level_counts.size == arm.depth && topology.point_count == child.point_count
            raise ArgumentError.new("Geometry child topology differs from its exact arm descriptor")
          end
          levels[arm_index] = topology.level_counts
          points[arm_index] = child.point_count.to_u64
        end
        {arms, levels, points}
      end

      private def self.snapshot_level_sizes(
        data : WideGeometryColumnData,
        arms : StaticArray(Int32, 7),
      ) : Array(Array(UInt64))
        sizes = [] of Array(UInt64)
        arm_order.each_with_index do |arm, arm_index|
          next if arm == WideGeometryArm::Point
          child = data.geo_array_data(arm)
          unless child.row_count == arms[arm_index]
            raise ArgumentError.new("Geometry child row count changed during snapshot")
          end
          arm.depth.times do |level|
            sizes << child.topology.sizes(level)
          end
        end
        sizes
      end

      private def self.outer_rows_by_mark(
        row_count : Int32,
        rows_per_mark : Int32,
        mark_count : Int32,
      ) : Array(UInt64)
        Array(UInt64).new(mark_count) do |mark_index|
          start = mark_index * rows_per_mark
          {rows_per_mark, row_count - start}.min.to_u64
        end
      end

      private def self.snapshot_coordinate_lanes(
        data : WideGeometryColumnData,
        arms : StaticArray(Int32, 7),
      ) : {StaticArray(Array(Float64), 7), StaticArray(Array(Float64), 7)}
        x_values = StaticArray(Array(Float64), 7).new([] of Float64)
        y_values = StaticArray(Array(Float64), 7).new([] of Float64)
        arm_order.each_with_index do |arm, arm_index|
          point_count = if arm == WideGeometryArm::Point
                          arms[arm_index]
                        else
                          data.geo_array_data(arm).point_count
                        end
          xs = [] of Float64
          ys = [] of Float64
          point_count.times do |point_index|
            point = if arm == WideGeometryArm::Point
                      data.point_at(point_index)
                    else
                      data.geo_array_data(arm).point_at(point_index)
                    end
            xs << point.x
            ys << point.y
          end
          x_values[arm_index] = xs
          y_values[arm_index] = ys
        end
        {x_values, y_values}
      end

      private def self.snapshot_charge(
        rows : Int32,
        key_count : Int32,
        level_counts : Array(Array(UInt64)),
        point_counts : Array(UInt64),
        streams : Array(String),
        mark_count : Int32,
        rows_by_mark : Array(UInt64),
        schedule_charge : UInt64,
        interval_scratch : UInt64,
        columns_metadata : String,
        substreams_metadata : String,
        serialization_metadata : String,
      ) : UInt64
        total = instance_sizeof(GeometryPartWriteInput).to_u64
        total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64, "Geometry key snapshot")
        total = checked_add(total, checked_multiply(key_count.to_u64, 8_u64, "Geometry key snapshot"), "Geometry key snapshot")
        total = checked_add(total, instance_sizeof(Array(UInt8)).to_u64, "Geometry discriminator snapshot")
        total = checked_add(total, rows.to_u64, "Geometry discriminator snapshot")
        total = checked_add(total, instance_sizeof(Array(Array(UInt64))).to_u64, "Geometry size snapshot collection")

        size_slots = 0_u64
        size_values = 0_u64
        level_counts.each do |counts|
          next if counts.empty?
          size_slots += counts.size.to_u64
          counts.each { |count| size_values = checked_add(size_values, count, "Geometry size snapshot cardinality") }
        end
        total = checked_add(total, size_slots * sizeof(Pointer(Array(UInt64))).to_u64, "Geometry size snapshot slots")
        total = checked_add(total, size_slots * instance_sizeof(Array(UInt64)).to_u64, "Geometry size snapshot headers")
        total = checked_add(total, checked_multiply(size_values, sizeof(UInt64).to_u64, "Geometry size snapshot values"), "Geometry size snapshot values")

        coordinate_count = 0_u64
        point_counts.each { |count| coordinate_count = checked_add(coordinate_count, count, "Geometry coordinate snapshot count") }
        total = checked_add(total, 14_u64 * instance_sizeof(Array(Float64)).to_u64, "Geometry coordinate snapshot headers")
        total = checked_add(total, checked_multiply(coordinate_count, 16_u64, "Geometry coordinate snapshots"), "Geometry coordinate snapshots")

        total = checked_add(total, instance_sizeof(Array(String)).to_u64, "Geometry stream inventory")
        total = checked_add(total, streams.size.to_u64 * sizeof(String).to_u64, "Geometry stream inventory")
        streams.each { |stream| total = checked_add(total, stream.bytesize.to_u64, "Geometry stream names") }
        total = checked_add(total, 2_u64 * instance_sizeof(Array(UInt64)).to_u64, "Geometry stream budgets")
        total = checked_add(total, streams.size.to_u64 * (sizeof(Int64).to_u64 + sizeof(UInt64).to_u64), "Geometry stream budgets")
        total = checked_add(total, checked_multiply(mark_count.to_u64 + 1_u64, 24_u64, "Geometry primary index snapshot"), "Geometry primary index snapshot")
        total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64, "Geometry outer mark rows")
        total = checked_add(total, checked_multiply(rows_by_mark.size.to_u64, sizeof(UInt64).to_u64, "Geometry outer mark rows"), "Geometry outer mark rows")
        total = checked_add(total, schedule_charge, "Geometry writer schedules")
        total = checked_add(total, interval_scratch, "Geometry writer schedule scratch")
        metadata_bytes = metadata_snapshot_charge(
          columns_metadata, substreams_metadata, serialization_metadata
        )
        total = checked_add(total, metadata_bytes, "Geometry metadata snapshots")
        total = checked_add(total, 64_u64 * sizeof(ChecksumRecord).to_u64 + instance_sizeof(Array(ChecksumRecord)).to_u64, "Geometry checksum records")
        total
      end

      private def self.metadata_snapshot_charge(
        columns : String,
        substreams : String,
        serialization : String,
      ) : UInt64
        total = 3_u64 * instance_sizeof(String).to_u64
        {columns, substreams, serialization}.each do |metadata|
          bytes_with_terminator = checked_add(metadata.bytesize.to_u64, 1_u64, "Geometry metadata snapshots")
          total = checked_add(total, bytes_with_terminator, "Geometry metadata snapshots")
        end
        total
      end

      private def self.preflight_stream_budgets(
        type_plan : GeometryColumnType,
        value_name : String,
        logical_streams : Array(String),
        schedule : GeometryPartWriteSchedule,
        row_count : Int32,
        rows_per_mark : Int32,
        mark_count : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : {Array(Int64), Array(UInt64), UInt64}
        compressed_sizes = Array(Int64).new(logical_streams.size, 0_i64)
        raw_sizes = Array(UInt64).new(logical_streams.size, 0_u64)
        maximum_frame_scratch = 0_u64

        logical_streams.each_with_index do |stream, stream_index|
          compressed_total = 0_i64
          raw_total = 0_u64
          mark_index = 0
          while mark_index < mark_count
            mark = if stream_index == 0
                     schedule.key_schedule.mark(mark_index, TupleLeafMarkSchedule::Axis::Outer)
                   elsif stream == type_plan.discriminator_stream(value_name)
                     schedule.key_schedule.mark(mark_index, TupleLeafMarkSchedule::Axis::Outer)
                   else
                     stream_schedule(type_plan, value_name, stream, schedule).mark(mark_index)
                   end
            raw_bytes = if stream_index == 0
                          checked_multiply(mark.outer_rows.to_u64, 8_u64, "Geometry primary-key frame")
                        elsif stream == type_plan.discriminator_stream(value_name)
                          mark.outer_rows.to_u64 + (mark_index == 0 ? 8_u64 : 0_u64)
                        else
                          width = type_plan.stream_width(value_name, stream) ||
                                  raise ArgumentError.new("Geometry physical stream width is unavailable")
                          checked_multiply(mark.leaf_count.to_u64, width.to_u64, "Geometry child frame")
                        end
            if raw_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 ||
               raw_bytes > WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_u64
              raise ArgumentError.new("Geometry stream granule exceeds reader limit")
            end
            raw_total = checked_add(raw_total, raw_bytes, "Geometry raw stream bytes")
            raise ArgumentError.new("Geometry raw stream exceeds reader limit") if raw_total > MAX_DATA_FILE_BYTES.to_u64
            unless raw_bytes == 0
              frame_size = infrastructure.checked_string_frame_size(raw_bytes.to_i64, "Geometry stream #{stream}")
              if frame_size > MAX_DATA_FILE_BYTES - compressed_total
                raise ArgumentError.new("Geometry compressed stream exceeds reader limit")
              end
              compressed_total += frame_size
              scratch = checked_add(raw_bytes, frame_size.to_u64, "Geometry frame scratch")
              maximum_frame_scratch = scratch if scratch > maximum_frame_scratch
            end
            mark_index += 1
          end
          compressed_sizes[stream_index] = compressed_total
          raw_sizes[stream_index] = raw_total
        end
        {compressed_sizes, raw_sizes, maximum_frame_scratch}
      end

      private def self.stream_schedule(
        type_plan : GeometryColumnType,
        value_name : String,
        stream : String,
        schedule : GeometryPartWriteSchedule,
      ) : TupleLeafMarkSchedule
        arm_order.each do |arm|
          child_name = "#{value_name}.#{arm.type_name}"
          if arm == WideGeometryArm::Point
            point_plan = PointColumnType.for_type(arm.type_name) ||
                         raise ArgumentError.new("Geometry Point descriptor is unavailable")
            point_plan.coordinate_streams(child_name).each do |candidate|
              return schedule.coordinate_schedule(arm) if candidate == stream
            end
          else
            child_plan = GeoArrayColumnType.for_type(arm.type_name) ||
                         raise ArgumentError.new("Geometry Geo Array descriptor is unavailable")
            child_plan.size_streams(child_name).each_with_index do |candidate, level|
              return schedule.size_schedule(arm, level) if candidate == stream
            end
            child_plan.coordinate_streams(child_name).each do |candidate|
              return schedule.coordinate_schedule(arm) if candidate == stream
            end
          end
        end
        raise ArgumentError.new("Geometry stream has no sparse arm schedule")
      end

      private def self.columns_metadata(key_name : String, value_name : String, type_plan : GeometryColumnType) : String
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
        "{\"columns\":[{\"exact_num_defaults\":true,\"kind\":\"Default\",\"name\":\"#{key_name}\",\"num_defaults\":#{defaults},\"num_rows\":#{keys.size}}]," +
          "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("Geometry metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("Geometry metadata line exceeds reader limit")
            end
          end
        end
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
        raise ArgumentError.new("Geometry checksum entry count exceeds reader limit") if names.size > PartChecksums::MAX_ENTRIES

        payload_size = var_uint_size(names.size.to_u64)
        names.each_with_index do |name, index|
          payload_size = checked_add(payload_size, var_uint_size(name.bytesize.to_u64) + name.bytesize.to_u64, "Geometry checksums payload")
          payload_size = checked_add(payload_size, var_uint_size(sizes[index]) + 17_u64, "Geometry checksums payload")
          if compressed[index]
            payload_size = checked_add(payload_size, var_uint_size(raw_uncompressed[index]) + 16_u64, "Geometry checksums payload")
          end
        end
        frame_size = infrastructure.checked_string_frame_size(payload_size.to_i64, "Geometry checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        raise ArgumentError.new("Geometry checksums file exceeds reader limit") if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
        if total_size.to_u64 > CHECKSUM_FILE_RESERVE
          raise ArgumentError.new("Geometry checksums file exceeds reserved writer snapshot budget")
        end
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

      private def self.checked_arm_index(arm : WideGeometryArm) : Int32
        arm.type_name
        arm.value.to_i32
      end

      private def self.checked_file_size(mark_count : Int32, width : Int64, label : String) : Int64
        count = mark_count.to_i64 + 1_i64
        raise ArgumentError.new("#{label} exceeds native file limit") if count > Int64::MAX // width
        count * width
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
