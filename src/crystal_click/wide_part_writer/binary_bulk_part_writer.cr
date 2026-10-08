module CrystalClick
  module WidePartWriter
    # Shared static BinaryBulk two-column publication owner. Nominal adapters
    # retain their own admission guards and hand this class an already
    # canonical declaration; lane discovery, staging, and readback are shared.
    private class BinaryBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        family : String,
        &admit_declaration : -> String
      ) : String
        # Keep the common prefix ahead of nominal type admission. In
        # particular, the legacy Nested wrapper used to reject malformed part
        # envelopes before consulting the Nested descriptor guard.
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and #{family} column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS.to_u64
          raise ArgumentError.new("a #{family} part requires a bounded nonempty key stream")
        end
        if granules.empty?
          raise ArgumentError.new("a #{family} part requires at least one real mark")
        end

        canonical = yield
        input = preflight(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, metadata_version, limits, transport_limits,
          family, canonical
        )
        files = BinaryBulkColumnWriter.encode(
          type, profile, input.physical, granules, input.part.expected_rows,
          frame_bytes, limits, transport_limits
        )
        unless files.keys.sort == input.part.logical_names
          raise UnsupportedFormatError.new("encoded #{family} files differ from the admitted physical roster")
        end

        TwoColumnBulkPartWriter.write(
          input.part, keys, input.metadata, files, rows_per_mark, limits, transport_limits
        ) do |stage|
          validate_staged_value!(
            stage, input, value_name, type, granules, profile, limits,
            transport_limits, family
          )
        end
      end

      private def self.preflight(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        family : String,
        canonical : String,
      ) : BinaryBulkPartInputPlan
        if granules.size > MAX_MARKS
          raise ArgumentError.new("#{family} mark count exceeds writer limit")
        end
        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == granules.size.to_i64
          raise ArgumentError.new("#{family} granule count does not match the key mark grid")
        end
        parent_rows = parent_rows!(keys.size, granules, rows_per_mark, family)

        physical = BinaryBulkPhysicalPlan.new(
          type, value_name, profile, limits, PhysicalStreamPlanContext.new(limits)
        )
        role_names = physical.stream_names
        role_bindings = Hash(String, TwoColumnBulkPartRoleBinding).new(initial_capacity: role_names.size)
        role_names.each do |role, logical_name|
          role_bindings[role] = TwoColumnBulkPartRoleBinding.new(
            logical_name,
            physical.data_file_for(role, true),
            physical.marks_file_for(role, true)
          )
        end

        part = TwoColumnBulkPartInput.prepare(
          destination, key_name, keys, value_name, parent_rows,
          rows_per_mark, metadata_version, role_bindings
        )
        schema = StorageColumnSchema.bulk(type, canonical)
        unless schema.declaration == canonical
          raise UnsupportedFormatError.new("#{family} metadata schema changed its canonical declaration")
        end
        metadata = RecursiveStoragePartMetadata.new(
          key_name, value_name, schema, part.logical_names, keys,
          metadata_version, profile, limits
        )
        BinaryBulkPartInputPlan.new(part, physical, metadata, canonical)
      end

      private def self.parent_rows!(
        row_count : Int,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        family : String,
      ) : Array(Int32)
        rows = Array(Int32).new(granules.size)
        seen_rows = 0_i64
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("#{family} parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final #{family} parent granule may be short")
          end
          seen_rows += granule.size.to_i64
          rows << granule.size.to_i32
        end
        unless seen_rows == row_count.to_i64
          raise ArgumentError.new("#{family} row count does not match the key stream")
        end
        rows
      end

      private def self.validate_staged_value!(
        stage : String,
        input : BinaryBulkPartInputPlan,
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        family : String,
      ) : Nil
        reader = BinaryBulkColumnReader.open(stage, value_name, type, limits, transport_limits)
        unless reader.row_count == input.part.expected_rows.sum(0_u64) &&
               reader.mark_count == input.part.mark_count &&
               reader.schema_declaration == input.canonical_declaration &&
               reader.source_declaration == input.canonical_declaration &&
               reader.ordinary_profile == profile &&
               reader.physical_stream_names == input.part.logical_names &&
               reader.mark_row_counts == input.part.expected_rows
          raise CorruptPartError.new("staged #{family} declaration, roster or grid differs from input")
        end

        actual_granules = reader.read_marks(0, granules.size)
        unless actual_granules.size == granules.size
          raise CorruptPartError.new("staged #{family} reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows, mark|
          actual_rows = actual_granules[mark]
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged #{family} reader returned the wrong parent row count")
          end
          expected_rows.each_with_index do |expected, row|
            compare_binary_value!(actual_rows[row], expected, family)
          end
        end
        nil
      end

      private def self.compare_binary_value!(
        actual : BinaryValue,
        expected : BinaryValue,
        family : String,
      ) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged #{family} BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged #{family} BinaryValue scalar bytes differ from input")
          end
        end
        actual.child_count.times do |index|
          compare_binary_value!(actual.child_at(index), expected.child_at(index), family)
        end
        nil
      end

      private def self.validate_column_name!(name : String) : Nil
        unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES &&
               /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
          raise ArgumentError.new("column name must be a bounded ASCII identifier")
        end
        nil
      end

      private def self.ensure_supported_platform! : Nil
        {% if flag?(:darwin) %}
          nil
        {% else %}
          raise UnsupportedFormatError.new("atomic exclusive Wide-part publication is unsupported on this platform")
        {% end %}
      end
    end
  end
end
