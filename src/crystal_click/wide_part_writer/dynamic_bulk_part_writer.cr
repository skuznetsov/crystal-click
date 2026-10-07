module CrystalClick
  module WidePartWriter
    # Generic Dynamic-bearing adapter over the common two-column publisher.
    # Dynamic, ordinary, LC and Variant lanes keep their existing codecs.
    private class DynamicBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        structures : Hash(String, DynamicStructure),
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      ) : String
        input = preflight(
          destination, key_name, keys, value_name, type, structures, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits
        )
        transport_budget = CompressedStreamBudget.new(transport_limits, true)
        files = DynamicBulkColumnWriter.encode(
          input.dynamic_plan, input.physical, granules, input.part.expected_rows,
          frame_bytes, limits, transport_limits,
          codec_budget: input.codec_budget, transport_budget: transport_budget
        )
        unless files.keys.sort == input.part.logical_names
          raise UnsupportedFormatError.new("encoded Dynamic files differ from the admitted physical roster")
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
        structures : Hash(String, DynamicStructure),
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : DynamicBulkPartInputPlan
        unless rows_per_mark > 0 && rows_per_mark <= MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless keys.size > 0 && keys.size.to_u64 <= WidePart::MAX_ROWS.to_u64
          raise ArgumentError.new("Dynamic part requires a bounded nonempty key stream")
        end
        if metadata_version < 0
          raise ArgumentError.new("metadata version must be nonnegative")
        end
        unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
          raise ArgumentError.new("Dynamic frame size is outside the compressed transport limit")
        end
        if granules.empty? || granules.size > MAX_MARKS
          raise ArgumentError.new("Dynamic part mark count is outside the writer limit")
        end
        expected_marks = (keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless expected_marks == granules.size.to_i64
          raise ArgumentError.new("Dynamic granule count does not match the key mark grid")
        end
        parent_rows = parent_rows!(keys.size, granules, rows_per_mark)

        # Bound recursive names before invoking recursive admission or plans.
        name_budget = BinaryCodecBudget.new(limits, true)
        name_bounds = BinaryTypeNameBudget.measure(type, name_budget)
        canonical = BinaryTypeNameBudget.materialize(type, name_budget, name_bounds)
        unless type.contains_dynamic?
          raise UnsupportedFormatError.new("Dynamic bulk writer requires a Dynamic-bearing descriptor")
        end
        if type.contains_json?
          raise UnsupportedFormatError.new("JSON is outside the admitted Dynamic bulk profile")
        end
        unless profile.single_stream? || profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported Dynamic String profile")
        end
        codec_budget = BinaryCodecBudget.new(limits, true)
        dynamic_plan = BinaryDynamicBulkPlan.new_with_budget(type, structures, codec_budget, profile)
        BinaryBulkTypePlan.new(type, profile, dynamic_plan, limits, true).role_count
        physical = BinaryDynamicBulkPhysicalPlan.new(
          dynamic_plan, value_name, limits, PhysicalStreamPlanContext.new(limits)
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
          raise UnsupportedFormatError.new("Dynamic metadata schema changed its canonical declaration")
        end
        metadata = RecursiveStoragePartMetadata.new(
          key_name, value_name, schema, part.logical_names, keys,
          metadata_version, profile, limits
        )
        DynamicBulkPartInputPlan.new(part, dynamic_plan, physical, codec_budget, metadata, canonical)
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
            raise ArgumentError.new("Dynamic parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final Dynamic parent granule may be short")
          end
          seen_rows += granule.size.to_i64
          rows << granule.size.to_i32
        end
        unless seen_rows == row_count.to_i64
          raise ArgumentError.new("Dynamic row count does not match the key stream")
        end
        rows
      end

      private def self.validate_staged_value!(
        stage : String,
        input : DynamicBulkPartInputPlan,
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        profile : BinaryBulkProfile,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : Nil
        reader = DynamicBulkColumnReader.open(stage, value_name, type, limits, transport_limits)
        unless reader.row_count == input.part.expected_rows.sum(0_u64) &&
               reader.mark_count == input.part.mark_count &&
               reader.schema_declaration == input.canonical_declaration &&
               reader.source_declaration == input.canonical_declaration &&
               reader.ordinary_profile == profile &&
               reader.physical_stream_names == input.part.logical_names &&
               reader.mark_row_counts == input.part.expected_rows
          raise CorruptPartError.new("staged Dynamic declaration, roster or grid differs from input")
        end
        actual_granules = reader.read_marks(0, granules.size)
        unless actual_granules.size == granules.size
          raise CorruptPartError.new("staged Dynamic reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows, mark|
          actual_rows = actual_granules[mark]
          unless actual_rows.size == expected_rows.size
            raise CorruptPartError.new("staged Dynamic reader returned the wrong parent row count")
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
          raise CorruptPartError.new("staged Dynamic BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged Dynamic BinaryValue scalar bytes differ from input")
          end
        end
        actual.child_count.times { |index| compare_binary_value!(actual.child_at(index), expected.child_at(index)) }
        nil
      end
    end
  end
end
