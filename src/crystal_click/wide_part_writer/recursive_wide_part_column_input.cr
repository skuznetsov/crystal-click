module CrystalClick
  module WidePartWriter
    # Adapts one recursively composed Tuple/Array value column to the shared
    # Wide publisher while retaining RecursiveStorageColumnPlan as the roster
    # and leaf-owner authority.
    private class RecursiveWidePartColumnInput
      def self.prepare(
        name : String,
        schema : StorageColumnSchema,
        object_plans : Hash(String, ObjectDocumentPlan),
        granules : Array(Array(StorageColumnValue)),
        dynamic_plans : Hash(String, BinaryDynamicBulkPlan)?,
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        # RecursiveStorageColumnWriter currently has no advanced shared-JSON
        # policy path. Refuse nondefault operation settings instead of silently
        # dropping behavior for nested Object sites.
        if context.shared_json_policy || context.shared_target_chunk_rows != 1
          raise ArgumentError.new("recursive Wide columns do not admit shared advanced JSON write policy overrides")
        end
        # The persisted serialization.json carries one global String profile,
        # not an independent profile for Object's shared MAP payload. The
        # recursive reader therefore reconstructs those lanes with the stock
        # profile; preserve the existing recursive writer's fail-closed
        # boundary instead of publishing a roster that cannot be inferred.
        unless context.shared_profile.single_stream?
          raise UnsupportedFormatError.new("recursive Object shared data requires the stock single-stream profile")
        end
        schema.validate_source_tree!(context.limits)

        # Recursive JSON-free leaves still need their nominal physical owner.
        # In particular, logical Nested support in ObjectRecursiveDeclaration
        # does not qualify an arbitrary Nested declaration as a Wide part
        # layout. Reuse the same exact owner gate as the static adapter before
        # constructing any physical stream plan.
        require_nominal_nested_owners!(schema)

        # WidePartColumn already detached the caller's mark arrays; the
        # contained StorageColumnValue/ObjectDocument/BinaryValue owners are
        # immutable, so this adapter retains that bounded snapshot directly.
        owned_granules = granules
        parent_rows = validate_parent_grid!(owned_granules, context.rows_per_mark)
        detached_object_plans = copy_object_plans(object_plans)
        detached_dynamic_plans = copy_dynamic_plans(dynamic_plans || Hash(String, BinaryDynamicBulkPlan).new)
        plan = RecursiveStorageColumnPlan.new(
          name,
          schema,
          detached_object_plans,
          context.profile,
          context.shared_profile,
          true,
          context.mode,
          context.frame_bytes,
          context.limits,
          context.transport_limits,
          detached_dynamic_plans,
          nil,
          context.name_context,
        )
        stream_names = plan.physical_stream_names

        encode = ->(key_rows : Array(UInt64), codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          validate_runtime_grid!(owned_granules, key_rows, context.rows_per_mark)
          files = RecursiveStorageColumnWriter.encode(
            plan,
            owned_granules,
            codec_budget,
            transport_budget,
          )
          pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: stream_names.size)
          stream_names.each do |stream_name|
            pairs[stream_name] = files.pair_for(stream_name)
          end
          pairs
        }

        validate = ->(part_path : String, codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          reader = RecursiveStorageColumnReader.open(
            part_path,
            name,
            schema,
            context.transport_limits,
            codec_budget,
            transport_budget,
          )
          unless reader.physical_stream_names == stream_names
            raise CorruptPartError.new("staged recursive physical roster differs from input plan")
          end
          actual = reader.read_marks(0, reader.mark_count)
          compare_granules!(actual, owned_granules)
        }

        WidePartPreparedColumn.new(
          name,
          schema.declaration,
          stream_names,
          parent_rows,
          encode,
          validate,
        )
      end

      private def self.require_nominal_nested_owners!(schema : StorageColumnSchema) : Nil
        if type = schema.bulk_type_or_nil
          return nil unless type.contains_nested?

          declaration = schema.declaration
          unless type.tag == BinaryDataType::TAG_NESTED && !WideNestedTypePlan.for_type(declaration).nil?
            raise UnsupportedFormatError.new("recursive Nested BinaryBulk requires its exact nominal Nested storage plan")
          end
          return nil
        end

        schema.child_count.times do |index|
          require_nominal_nested_owners!(schema.child_at(index))
        end
        nil
      end

      private def self.copy_object_plans(
        plans : Hash(String, ObjectDocumentPlan),
      ) : Hash(String, ObjectDocumentPlan)
        copied = Hash(String, ObjectDocumentPlan).new(initial_capacity: plans.size)
        plans.each do |key, plan|
          detached_key = String.new(key.to_slice)
          if copied.has_key?(detached_key)
            raise ArgumentError.new("recursive Object plan keys must be unique")
          end
          copied[detached_key] = plan
        end
        copied
      end

      private def self.copy_dynamic_plans(
        plans : Hash(String, BinaryDynamicBulkPlan),
      ) : Hash(String, BinaryDynamicBulkPlan)
        copied = Hash(String, BinaryDynamicBulkPlan).new(initial_capacity: plans.size)
        plans.each do |key, plan|
          detached_key = String.new(key.to_slice)
          if copied.has_key?(detached_key)
            raise ArgumentError.new("recursive Dynamic plan keys must be unique")
          end
          copied[detached_key] = plan
        end
        copied
      end

      private def self.validate_parent_grid!(
        granules : Array(Array(StorageColumnValue)),
        rows_per_mark : Int32,
      ) : Array(Int32)
        if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
          raise ArgumentError.new("recursive value column requires a bounded nonempty mark grid")
        end
        parent_rows = Array(Int32).new(granules.size)
        total_rows = 0_i64
        granules.each_with_index do |rows, index|
          if rows.empty? || rows.size > rows_per_mark
            raise ArgumentError.new("recursive parent mark row count is outside the admitted range")
          end
          if index < granules.size - 1 && rows.size != rows_per_mark
            raise ArgumentError.new("only the final recursive parent mark may be short")
          end
          if rows.size.to_i64 > WidePart::MAX_ROWS.to_i64 - total_rows
            raise ArgumentError.new("recursive row count exceeds the part limit")
          end
          total_rows += rows.size.to_i64
          parent_rows << rows.size.to_i32
        end
        parent_rows
      end

      private def self.validate_runtime_grid!(
        granules : Array(Array(StorageColumnValue)),
        key_rows : Array(UInt64),
        rows_per_mark : Int32,
      ) : Nil
        unless key_rows.size == granules.size
          raise ArgumentError.new("recursive input mark count differs from the shared key grid")
        end
        key_rows.each_with_index do |rows, index|
          unless rows == granules[index].size.to_u64 && rows <= rows_per_mark.to_u64
            raise ArgumentError.new("recursive input parent rows differ from the shared key grid")
          end
        end
        nil
      end

      private def self.compare_granules!(
        actual : Array(Array(StorageColumnValue)),
        expected : Array(Array(StorageColumnValue)),
      ) : Nil
        unless actual.size == expected.size
          raise CorruptPartError.new("staged recursive mark count differs from input")
        end
        actual.each_with_index do |rows, mark_index|
          expected_rows = expected[mark_index]
          unless rows.size == expected_rows.size
            raise CorruptPartError.new("staged recursive parent row count differs from input")
          end
          rows.each_with_index do |value, row_index|
            WidePartValueComparison.storage!(value, expected_rows[row_index])
          end
        end
        nil
      end
    end
  end
end
