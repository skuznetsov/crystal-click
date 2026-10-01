module CrystalClick
  module WidePartWriter
    # Scalar and BASIC Nullable QBit part writer. It owns QBit-specific schema,
    # stream planning, preflight, transposition and readback policy; framing,
    # checksums, indexes, metadata writes and publication stay shared.
    private class QBitPartWriter
      SERIALIZATION_METADATA = "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"

      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        value_count : Int32,
        nullable : Bool,
        value_at : Proc(Int32, QBitValue?),
        rows_per_mark : Int32,
        infrastructure : QBitPartInfrastructure,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type_name, value_count,
          nullable, value_at, rows_per_mark, infrastructure
        )
        stage = infrastructure.stage_factory.call(input.parent)
        begin
          records = [] of ChecksumRecord
          records.concat(infrastructure.write_uint64_stream(
            stage, input.key_name, input.keys.to_unsafe.to_slice(input.keys.size), input.rows_per_mark
          ))

          stream_index = 1
          while stream_index < input.logical_streams.size
            logical_name = input.logical_streams[stream_index]
            width = input.stream_widths[stream_index]
            nullable_map = input.column_type.nullable && logical_name == "#{input.value_name}.null"
            plane_index = stream_index - 1 - (input.column_type.nullable ? 1 : 0)
            records.concat(infrastructure.write_fixed_width_stream(
              stage, logical_name, input.keys.size, width, input.rows_per_mark
            ) do |raw, source_row, output_row|
              value = input.values[source_row]
              offset = output_row * width
              if nullable_map
                raw[offset] = value.nil? ? 1_u8 : 0_u8
              elsif value
                QBitPlaneCodec.encode_plane_row(value, plane_index, raw, offset)
              else
                QBitPlaneCodec.encode_zero_plane_row(input.column_type.value_type, plane_index, raw, offset)
              end
              nil
            end)
            stream_index += 1
          end

          records << infrastructure.write_primary_index(
            stage, input.keys.to_unsafe.to_slice(input.keys.size), input.rows_per_mark
          )
          records << infrastructure.write_checksummed_file(stage, "count.txt", input.keys.size.to_s)
          records << infrastructure.write_checksummed_file(stage, "serialization.json", input.serialization_metadata)
          infrastructure.write_plain_metadata(stage, "columns.txt", input.columns_metadata)
          infrastructure.write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
          infrastructure.write_plain_metadata(stage, "metadata_version.txt", "0")
          infrastructure.write_plain_metadata(stage, "columns_substreams.txt", input.substreams_metadata)
          checksums_file = infrastructure.write_checksums(stage, records)

          infrastructure.before_validation_hook(stage, input)
          validate_staged_part(stage, input, infrastructure, records, checksums_file)
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
        value_count : Int32,
        nullable : Bool,
        value_at : Proc(Int32, QBitValue?),
        rows_per_mark : Int32,
        infrastructure : QBitPartInfrastructure,
      ) : QBitPartWriteInput
        raise ArgumentError.new("destination must not be empty") if destination.empty?
        infrastructure.validate_column_name(key_name)
        infrastructure.validate_column_name(value_name)
        raise ArgumentError.new("column names must be distinct") if key_name == value_name
        raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != value_count
        raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

        column_type = QBitColumnType.for_type(type_name) ||
                      raise ArgumentError.new("unsupported or non-canonical QBit type")
        raise ArgumentError.new("QBit input nullability does not match schema") unless column_type.nullable == nullable
        qbit_type = column_type.value_type

        previous = keys[0]
        keys.each_with_index do |key, index|
          raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
          previous = key
        end

        value_count.times do |index|
          value = value_at.call(index)
          if nullable
            if value && value.type != qbit_type
              raise ArgumentError.new("QBit values do not match exact element identity and parameters")
            end
          else
            raise ArgumentError.new("non-nullable QBit values must not contain NULL") unless value
            unless value.not_nil!.type == qbit_type
              raise ArgumentError.new("QBit values do not match exact element identity and parameters")
            end
          end
        end

        mark_count = infrastructure.checked_mark_count(keys.size, rows_per_mark)
        mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
        raise ArgumentError.new("QBit mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
        index_size = (mark_count.to_i64 + 1_i64) * 8_i64
        raise ArgumentError.new("QBit primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES

        physical_streams = column_type.physical_streams(value_name)
        if physical_streams.size > WidePart::MAX_METADATA_SUBSTREAMS
          raise ArgumentError.new("QBit substream count exceeds reader limit")
        end
        checksum_entries = (physical_streams.size.to_u64 + 1_u64) * 2_u64 + 3_u64
        if checksum_entries > PartChecksums::MAX_ENTRIES.to_u64
          raise ArgumentError.new("QBit checksum entry count exceeds reader limit")
        end

        logical_streams = [key_name] of String
        stream_widths = [8] of Int32
        physical_streams.each do |name, width|
          if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise ArgumentError.new("QBit physical stream name exceeds reader limit")
          end
          logical_streams << name
          stream_widths << width
        end
        stream_bases = logical_streams.map { |name| StreamName.hash(name) }
        raise ArgumentError.new("QBit physical stream names must be distinct") unless stream_bases.uniq.size == stream_bases.size

        mark_rows = [] of Int32
        remaining = keys.size
        while remaining > 0
          rows = {rows_per_mark, remaining}.min
          mark_rows << rows
          remaining -= rows
        end
        raise ArgumentError.new("QBit mark schedule differs") unless mark_rows.size == mark_count

        compressed_sizes = [] of Int64
        raw_sizes = [] of UInt64
        stream_widths.each_with_index do |width, stream_index|
          compressed_size, raw_size = fixed_stream_budget(
            keys.size, rows_per_mark, mark_rows, width,
            stream_index == 0 ? "QBit UInt64 key" : "QBit physical stream", infrastructure
          )
          compressed_sizes << compressed_size
          raw_sizes << raw_size
        end

        # Bound the aggregate materialized QBit rows together with the key
        # snapshot before retaining either caller input. Per-mark reader
        # readback repeats the same charge on each selected range.
        aggregate_charge = column_type.materialization_charge(keys.size.to_u64)
        # The scalar reader charge models Array(QBitValue), while this writer
        # retains Array(QBitValue?) for one shared scalar/nullable path. Count
        # the actual optional-slot delta in the retained snapshot shape.
        if !nullable && sizeof(QBitValue?) > sizeof(QBitValue)
          optional_slot_delta = (sizeof(QBitValue?) - sizeof(QBitValue)).to_u64
          aggregate_charge = checked_add(
            aggregate_charge,
            checked_multiply(keys.size.to_u64, optional_slot_delta, "QBit optional snapshot slots"),
            "QBit aggregate materialization"
          )
        end
        key_snapshot_bytes = checked_multiply(keys.size.to_u64, 8_u64, "QBit key snapshot")
        aggregate_charge = checked_add(aggregate_charge, key_snapshot_bytes, "QBit aggregate materialization")
        if aggregate_charge > QBitColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("QBit aggregate materialization exceeds 64 MiB per-range limit")
        end

        columns_metadata = columns_metadata(key_name, value_name, column_type)
        substreams_metadata = substreams_metadata(key_name, value_name, physical_streams)
        serialization_metadata = SERIALIZATION_METADATA
        validate_metadata_limits(columns_metadata, substreams_metadata, serialization_metadata)
        validate_checksums_file_budget(
          logical_streams, compressed_sizes, raw_sizes, mark_file_size,
          keys.size, index_size, serialization_metadata.bytesize.to_u64, infrastructure
        )

        target = File.expand_path(destination)
        parent = File.dirname(target)
        raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
        raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

        # Snapshot only after exact types, physical plans, aggregate charges,
        # frames, metadata and checksum-file limits have passed.
        keys_copy = Array(UInt64).new(keys.size) { |index| keys[index] }
        values_copy = Array(QBitValue?).new(value_count) { |index| value_at.call(index) }
        previous_copy = keys_copy[0]
        keys_copy.each_with_index do |key, index|
          raise ArgumentError.new("primary key snapshot is not nondecreasing") if index > 0 && key < previous_copy
          previous_copy = key
        end
        values_copy.each do |value|
          if nullable
            if value && value.type != qbit_type
              raise ArgumentError.new("QBit value snapshot differs from exact element identity and parameters")
            end
          else
            raise ArgumentError.new("non-nullable QBit value snapshot contains NULL") unless value
            unless value.not_nil!.type == qbit_type
              raise ArgumentError.new("QBit value snapshot differs from exact element identity and parameters")
            end
          end
        end

        QBitPartWriteInput.new(
          target, parent, key_name, keys_copy, value_name, column_type, values_copy,
          logical_streams, stream_widths, compressed_sizes, raw_sizes,
          mark_count, mark_file_size, index_size, rows_per_mark,
          columns_metadata, substreams_metadata, serialization_metadata
        )
      end

      private def self.validate_staged_part(
        stage : String,
        input : QBitPartWriteInput,
        infrastructure : QBitPartInfrastructure,
        expected_records : Array(ChecksumRecord),
        checksums_file : ChecksumRecord,
      ) : Nil
        checksums = PartChecksums.open(stage)
        expected_checksum_names = [] of String
        input.logical_streams.each do |logical_name|
          base_name = StreamName.hash(logical_name)
          expected_checksum_names << "#{base_name}.bin"
          expected_checksum_names << "#{base_name}.mrk2"
        end
        expected_checksum_names.concat(["primary.idx", "count.txt", "serialization.json"])
        unless expected_checksum_names.uniq.size == expected_checksum_names.size &&
               checksums.entries.keys.sort == expected_checksum_names.sort
          raise CorruptPartError.new("staged QBit checksum inventory differs from the expected stream schedule")
        end
        # The public PartChecksums reader intentionally omits the serialized
        # uncompressed hash. Bind the complete declaration envelope to the
        # immutable records used to produce it, then compare every exposed
        # field below. The checksum-file hash is checked in bounded chunks.
        infrastructure.validate_checksum_hash(stage, checksums_file.name, checksums_file.file_hash)
        expected_records.each do |record|
          entry = checksums.entry(record.name) ||
                  raise CorruptPartError.new("staged QBit checksum entry is missing for #{record.name}")
          unless entry.physical_size == record.physical_size && entry.file_hash == record.file_hash &&
                 entry.compressed == record.compressed && entry.uncompressed_size == record.uncompressed_size
            raise CorruptPartError.new("staged QBit checksum declaration differs for #{record.name}")
          end
        end
        input.logical_streams.each_with_index do |logical_name, index|
          base_name = StreamName.hash(logical_name)
          assert_checksum_entry(
            checksums, "#{base_name}.bin", input.compressed_sizes[index].to_u64,
            true, input.raw_sizes[index], logical_name
          )
          assert_checksum_entry(
            checksums, "#{base_name}.mrk2", input.mark_file_size.to_u64,
            false, nil, "#{logical_name} mark schedule"
          )
        end
        assert_checksum_entry(checksums, "primary.idx", input.index_size.to_u64, false, nil, "primary index")
        assert_checksum_entry(
          checksums, "count.txt", input.keys.size.to_s.bytesize.to_u64,
          false, nil, "row count"
        )
        assert_checksum_entry(
          checksums, "serialization.json", input.serialization_metadata.bytesize.to_u64,
          false, nil, "serialization metadata"
        )

        expected_files = expected_checksum_names + [
          "checksums.txt",
          "columns.txt",
          "columns_substreams.txt",
          "default_compression_codec.txt",
          "metadata_version.txt",
        ]
        unless Dir.children(stage).sort == expected_files.sort
          raise CorruptPartError.new("staged QBit file inventory differs from the expected part layout")
        end
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end

        assert_file_content(stage, "columns.txt", input.columns_metadata, "columns")
        assert_file_content(stage, "columns_substreams.txt", input.substreams_metadata, "substream")
        assert_file_content(stage, "count.txt", input.keys.size.to_s, "row count")
        assert_file_content(stage, "serialization.json", input.serialization_metadata, "serialization")
        assert_file_content(stage, "default_compression_codec.txt", "CODEC(LZ4)", "default compression codec")
        assert_file_content(stage, "metadata_version.txt", "0", "metadata version")

        key_part = WidePart.open(stage, input.key_name)
        value_part = WidePart.open_typed(stage, input.value_name)
        unless key_part.row_count == input.keys.size.to_u64 && value_part.row_count == input.keys.size.to_u64
          raise CorruptPartError.new("staged QBit row count differs from input")
        end
        unless value_part.column_type == input.column_type.type_name
          raise CorruptPartError.new("staged QBit type differs from exact input schema")
        end

        expected_mark_rows = [] of UInt64
        start_row = 0
        mark_index = 0
        while start_row < input.keys.size
          rows = {input.rows_per_mark, input.keys.size - start_row}.min
          expected_mark_rows << rows.to_u64
          observed_keys = key_part.read_uint64_mark_range(input.key_name, mark_index, 1)
          unless observed_keys.size == rows
            raise CorruptPartError.new("staged QBit key mark row count differs")
          end
          rows.times do |offset|
            unless observed_keys[offset] == input.keys[start_row + offset]
              raise CorruptPartError.new("staged QBit key stream differs from input")
            end
          end

          row_charge = input.column_type.materialization_charge(rows.to_u64)
          key_readback_bytes = checked_multiply(rows.to_u64, 8_u64, "QBit staged key readback")
          row_charge = checked_add(row_charge, key_readback_bytes, "QBit staged readback")
          if row_charge > QBitColumnType::MAX_MATERIALIZED_BYTES
            raise CorruptPartError.new("staged QBit readback mark exceeds materialization budget")
          end
          validate_qbit_mark_readback(value_part, input, mark_index, start_row, rows, row_charge)
          start_row += rows
          mark_index += 1
        end
        unless key_part.mark_row_counts == expected_mark_rows && value_part.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("staged QBit mark schedule differs from input")
        end

        expected_index = Array(UInt64).new(input.mark_count + 1)
        row = 0
        while row < input.keys.size
          expected_index << input.keys[row]
          row += input.rows_per_mark
        end
        expected_index << input.keys.last
        index = PrimaryKeyIndex.open(stage, input.mark_count, checksums)
        unless index.keys == expected_index
          raise CorruptPartError.new("staged QBit primary index differs from input")
        end
        # Size checks and frame decoding above are not a substitute for the
        # persisted physical CityHash. Verify every declared file after logical
        # readback so a hostile same-width data mutation is diagnosed by the
        # raw-bit comparison first.
        checksums.entries.each do |name, entry|
          infrastructure.validate_checksum_hash(stage, name, entry.file_hash)
        end
        nil
      end

      private def self.validate_qbit_mark_readback(
        value_part : WidePart,
        input : QBitPartWriteInput,
        mark_index : Int32,
        start_row : Int32,
        rows : Int32,
        row_charge : UInt64,
      ) : Nil
        if input.column_type.nullable
          validate_nullable_qbit_values(value_part, input, mark_index, start_row, rows, row_charge)
          validate_qbit_dense_rows(value_part, input, mark_index, start_row, rows, row_charge)
        else
          observed = value_part.read_qbit_mark_range(
            input.value_name, mark_index.to_u64, 1_u64, max_materialized_bytes: row_charge
          )
          unless observed.size == rows
            raise CorruptPartError.new("staged QBit value mark row count differs")
          end
          rows.times do |offset|
            expected = input.values[start_row + offset].not_nil!
            unless observed[offset] == expected
              raise CorruptPartError.new("staged QBit raw value bits differ from input")
            end
          end
        end
        nil
      end

      private def self.validate_nullable_qbit_values(
        value_part : WidePart,
        input : QBitPartWriteInput,
        mark_index : Int32,
        start_row : Int32,
        rows : Int32,
        row_charge : UInt64,
      ) : Nil
        observed = value_part.read_nullable_qbit_mark_range(
          input.value_name, mark_index.to_u64, 1_u64, max_materialized_bytes: row_charge
        )
        unless observed.size == rows
          raise CorruptPartError.new("staged Nullable(QBit) mark row count differs")
        end
        rows.times do |offset|
          expected = input.values[start_row + offset]
          unless observed[offset] == expected
            raise CorruptPartError.new("staged Nullable(QBit) raw value bits or null map differ from input")
          end
        end
        nil
      end

      private def self.validate_qbit_dense_rows(
        value_part : WidePart,
        input : QBitPartWriteInput,
        mark_index : Int32,
        start_row : Int32,
        rows : Int32,
        row_charge : UInt64,
      ) : Nil
        observed = value_part.read_qbit_dense_mark_range(
          input.value_name, mark_index.to_u64, 1_u64, max_materialized_bytes: row_charge
        )
        unless observed.size == rows
          raise CorruptPartError.new("staged Nullable(QBit) dense mark row count differs")
        end
        zero = Bytes.new(input.column_type.value_type.raw_row_bytes, 0_u8)
        zero_value = QBitValue.new(input.column_type.value_type, zero)
        rows.times do |offset|
          expected = input.values[start_row + offset] || zero_value
          unless observed[offset] == expected
            raise CorruptPartError.new("staged QBit dense raw bits or zero NULL placeholder differ")
          end
        end
        nil
      end

      private def self.assert_file_content(
        stage : String,
        name : String,
        expected : String,
        label : String,
      ) : Nil
        path = File.join(stage, name)
        if File.symlink?(path)
          raise CorruptPartError.new("staged QBit #{label} metadata must not be a symbolic link")
        end

        expected_size = expected.bytesize.to_i64
        size = File.size(path)
        unless size == expected_size
          raise CorruptPartError.new("staged QBit #{label} metadata size differs")
        end

        File.open(path) do |file|
          bytes = Bytes.new(expected.bytesize)
          file.read_fully(bytes) unless bytes.empty?
          trailing_byte = file.read_byte
          final_size = File.size(path)
          unless trailing_byte.nil? && final_size == size && String.new(bytes) == expected
            raise CorruptPartError.new("staged QBit #{label} metadata differs")
          end
        end
        nil
      rescue ex : IO::Error
        raise CorruptPartError.new("staged QBit #{label} metadata could not be read")
      end

      private def self.assert_checksum_entry(
        checksums : PartChecksums,
        name : String,
        physical_size : UInt64,
        compressed : Bool,
        uncompressed_size : UInt64?,
        label : String,
      ) : Nil
        entry = checksums.entry(name) || raise CorruptPartError.new("staged QBit checksum entry is missing for #{label}")
        unless entry.physical_size == physical_size && entry.compressed == compressed &&
               entry.uncompressed_size == uncompressed_size
          raise CorruptPartError.new("staged QBit checksum size or frame declaration differs for #{label}")
        end
        nil
      end

      private def self.fixed_stream_budget(
        row_count : Int32,
        rows_per_mark : Int32,
        mark_rows : Array(Int32),
        width : Int32,
        label : String,
        infrastructure : QBitPartInfrastructure,
      ) : {Int64, UInt64}
        raise ArgumentError.new("#{label} width must be positive") if width <= 0
        compressed_size = 0_i64
        raw_size = 0_u64
        rows_seen = 0
        mark_rows.each do |rows|
          raise ArgumentError.new("#{label} mark schedule exceeds rows per mark") if rows <= 0 || rows > rows_per_mark
          bytes = rows.to_i64 * width.to_i64
          frame_size = infrastructure.checked_frame_size(bytes, label)
          if frame_size > MAX_DATA_FILE_BYTES - compressed_size
            raise ArgumentError.new("#{label} stream exceeds reader limit")
          end
          compressed_size += frame_size
          raw_size = checked_add(raw_size, bytes.to_u64, "#{label} raw bytes")
          rows_seen += rows
        end
        raise ArgumentError.new("#{label} mark schedule differs") unless rows_seen == row_count
        {compressed_size, raw_size}
      end

      private def self.validate_metadata_limits(columns : String, substreams : String, serialization : String) : Nil
        {columns, substreams, serialization}.each do |metadata|
          if metadata.bytesize > WidePart::MAX_METADATA_FILE_BYTES
            raise ArgumentError.new("QBit metadata exceeds reader limit")
          end
          metadata.each_line do |line|
            if line.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise ArgumentError.new("QBit metadata line exceeds reader limit")
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
        infrastructure : QBitPartInfrastructure,
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

        raise ArgumentError.new("QBit checksum entry count exceeds reader limit") if names.size > PartChecksums::MAX_ENTRIES
        payload_size = var_uint_size(names.size.to_u64)
        names.each_with_index do |name, index|
          payload_size += var_uint_size(name.bytesize.to_u64) + name.bytesize.to_u64
          payload_size += var_uint_size(physical_sizes[index]) + 16_u64 + 1_u64
          if compressed[index]
            payload_size += var_uint_size(raw_uncompressed[index]) + 16_u64
          end
        end
        raise ArgumentError.new("QBit checksums payload exceeds writer limit") if payload_size > Int64::MAX.to_u64
        frame_size = infrastructure.checked_frame_size(payload_size.to_i64, "QBit checksums")
        total_size = PartChecksums::CHECKSUMS_HEADER.size.to_i64 + frame_size
        if total_size > PartChecksums::MAX_CHECKSUM_FILE_BYTES
          raise ArgumentError.new("QBit checksums file exceeds writer limit")
        end
      end

      private def self.columns_metadata(key_name : String, value_name : String, type : QBitColumnType) : String
        "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{type.type_name}\n"
      end

      private def self.substreams_metadata(
        key_name : String,
        value_name : String,
        physical_streams : Array(Tuple(String, Int32)),
      ) : String
        String.build do |metadata|
          metadata << "columns substreams version: 1\n2 columns:\n"
          metadata << "1 substreams for column `#{key_name}`:\n\t#{key_name}\n"
          metadata << "#{physical_streams.size} substreams for column `#{value_name}`:\n"
          physical_streams.each do |name, _width|
            metadata << "\t#{name}\n"
          end
        end
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

      private def self.checked_add(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows UInt64") if left > UInt64::MAX - right
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
        return 0_u64 if left == 0_u64 || right == 0_u64
        raise ArgumentError.new("#{label} overflows UInt64") if left > UInt64::MAX // right
        left * right
      end
    end
  end
end
