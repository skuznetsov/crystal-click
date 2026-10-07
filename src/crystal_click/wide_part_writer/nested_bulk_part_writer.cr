module CrystalClick
  module WidePartWriter
    # Nominal Nested adapter for the shared two-column publication owner.
    # Descriptor admission, codec roles, and value readback remain Nested-only.
    private class NestedBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits
        )

        files = NestedBulkColumnWriter.encode(
          type, profile, input.physical, granules, input.part.expected_rows,
          frame_bytes, limits, transport_limits
        )
        unless files.keys.sort == input.part.logical_names
          raise UnsupportedFormatError.new("encoded Nested files differ from the admitted physical roster")
        end

        TwoColumnBulkPartWriter.write(
          input.part, keys, input.metadata, files, rows_per_mark, limits, transport_limits
        ) do |stage|
          validate_staged_value!(
            stage, input, value_name, type, granules, profile, limits, transport_limits
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
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : NestedBulkPartInputPlan
        ensure_supported_platform!
        validate_column_name!(key_name)
        validate_column_name!(value_name)
        raise ArgumentError.new("key and Nested column names must differ") if key_name == value_name
        raise ArgumentError.new("metadata version must be nonnegative") if metadata_version < 0
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS
          raise ArgumentError.new("a Nested part requires a bounded nonempty key stream")
        end
        raise ArgumentError.new("a Nested part requires at least one real mark") if granules.empty?

        unless type.tag == BinaryDataType::TAG_NESTED
          raise UnsupportedFormatError.new("Nested bulk writer requires a nominal Nested descriptor")
        end

        # Keep the legacy Nested-only descriptor and String-profile admission
        # before any role metadata or encoded lane allocation.
        name_budget = BinaryCodecBudget.new(limits, true)
        name_bounds = BinaryTypeNameBudget.measure(type, name_budget)
        canonical = BinaryTypeNameBudget.materialize(type, name_budget, name_bounds)
        name_budget.ensure_wire_bytes(name_bounds[1])
        name_budget.charge_wire_bytes(name_bounds[1])

        BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
        unless profile.single_stream? || profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported Nested String profile")
        end
        unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
          raise ArgumentError.new("Nested frame size is outside the compressed transport limit")
        end

        if granules.size > MAX_MARKS
          raise ArgumentError.new("Nested mark count exceeds writer limit")
        end
        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == granules.size.to_i64
          raise ArgumentError.new("Nested granule count does not match the key mark grid")
        end
        parent_rows = parent_rows!(keys.size, granules, rows_per_mark)

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
          raise UnsupportedFormatError.new("Nested metadata schema changed its canonical declaration")
        end
        metadata = RecursiveStoragePartMetadata.new(
          key_name, value_name, schema, part.logical_names, keys,
          metadata_version, profile, limits
        )
        NestedBulkPartInputPlan.new(part, physical, metadata, canonical)
      end

      private def self.parent_rows!(
        row_count : Int,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
      ) : Array(Int32)
        rows = Array(Int32).new(granules.size)
        seen_rows = 0_i64
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("Nested parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final Nested parent granule may be short")
          end
          seen_rows += granule.size.to_i64
          rows << granule.size.to_i32
        end
        unless seen_rows == row_count.to_i64
          raise ArgumentError.new("Nested row count does not match the key stream")
        end
        rows
      end

      private def self.validate_staged_value!(
        stage : String,
        input : NestedBulkPartInputPlan,
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : Nil
        reader = NestedBulkColumnReader.open(stage, value_name, type, limits, transport_limits)
        unless reader.row_count == input.part.expected_rows.sum(0_u64) &&
               reader.mark_count == input.part.mark_count &&
               reader.schema_declaration == input.canonical_declaration &&
               reader.source_declaration == input.canonical_declaration &&
               reader.ordinary_profile == profile &&
               reader.physical_stream_names == input.part.logical_names
          raise CorruptPartError.new("staged Nested declaration or physical grid differs from input")
        end
        unless reader.mark_row_counts == input.part.expected_rows
          raise CorruptPartError.new("staged Nested parent row grid differs from input")
        end

        actual_granules = reader.read_marks(0, granules.size)
        unless actual_granules.size == granules.size
          raise CorruptPartError.new("staged Nested reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows, mark|
          actual_rows = actual_granules[mark]
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged Nested reader returned the wrong parent row count")
          end
          expected_rows.each_with_index do |expected, row|
            compare_binary_value!(actual_rows[row], expected)
          end
        end
        nil
      end

      private def self.compare_binary_value!(actual : BinaryValue, expected : BinaryValue) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged Nested BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged Nested BinaryValue scalar bytes differ from input")
          end
        end
        actual.child_count.times { |index| compare_binary_value!(actual.child_at(index), expected.child_at(index)) }
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
