module CrystalClick
  module WidePartWriter
    # Adapts one explicit Object schema/plan/value grid to the shared Wide
    # publisher without taking ownership of publication or filename policy.
    private class ObjectWidePartColumnInput
      def self.prepare(
        name : String,
        schema : ObjectDocumentSchema,
        plan : ObjectDocumentPlan,
        granules : Array(Array(ObjectDocument)),
        shared_json_policy : ObjectSharedAdvancedJsonWritePolicy?,
        shared_target_chunk_rows : Int32?,
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        raise ArgumentError.new("Object value column name must not be empty") if name.empty?
        unless same_limits?(schema.limits, context.limits)
          raise ArgumentError.new("Object schema limits differ from the Wide operation")
        end
        schema.validate_plan(plan)

        # WidePartColumn already detached the caller's mark arrays; immutable
        # ObjectDocument values make that retained snapshot safe to share.
        owned_granules = granules
        parent_rows = validate_parent_grid!(owned_granules, context.rows_per_mark)
        escaped_prefix = PhysicalStreamName.escape(name, context.name_context)
        physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
          escaped_prefix,
          plan,
          context.profile,
          context.shared_profile,
          context.limits,
          0_u64,
          context.name_context,
        )
        stream_names = physical_plan.stream_names
        selected_policy = shared_json_policy || context.shared_json_policy
        selected_chunk_rows = shared_target_chunk_rows || context.shared_target_chunk_rows
        unless selected_chunk_rows > 0
          raise ArgumentError.new("Object shared advanced target chunk rows must be positive")
        end

        encode = ->(key_rows : Array(UInt64), codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          validate_runtime_grid!(owned_granules, key_rows, context.rows_per_mark)
          files = ObjectDocumentColumnWriter.encode_at_physical_site(
            escaped_prefix,
            plan,
            physical_plan,
            owned_granules,
            codec_budget,
            transport_budget,
            context.profile,
            context.shared_profile,
            context.mode,
            true,
            context.frame_bytes,
            0_u64,
            selected_policy,
            selected_chunk_rows,
          )
          pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: stream_names.size)
          stream_names.each do |stream_name|
            pairs[stream_name] = files.pair_for(stream_name)
          end
          pairs
        }

        validate = ->(part_path : String, codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          actual = ObjectDocumentFileReader.read(
            part_path,
            name,
            schema.typed_paths,
            0,
            nil,
            context.profile,
            context.shared_profile,
            true,
            context.limits,
            context.read_transport_limits,
            codec_budget,
            transport_budget,
          )
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

      private def self.validate_parent_grid!(
        granules : Array(Array(ObjectDocument)),
        rows_per_mark : Int32,
      ) : Array(Int32)
        if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
          raise ArgumentError.new("Object value column requires a bounded nonempty mark grid")
        end
        parent_rows = Array(Int32).new(granules.size)
        total_rows = 0_i64
        granules.each_with_index do |rows, index|
          if rows.empty? || rows.size > rows_per_mark
            raise ArgumentError.new("Object parent mark row count is outside the admitted range")
          end
          if index < granules.size - 1 && rows.size != rows_per_mark
            raise ArgumentError.new("only the final Object parent mark may be short")
          end
          if rows.size.to_i64 > WidePart::MAX_ROWS.to_i64 - total_rows
            raise ArgumentError.new("Object row count exceeds the part limit")
          end
          total_rows += rows.size.to_i64
          parent_rows << rows.size.to_i32
        end
        parent_rows
      end

      private def self.validate_runtime_grid!(
        granules : Array(Array(ObjectDocument)),
        key_rows : Array(UInt64),
        rows_per_mark : Int32,
      ) : Nil
        unless key_rows.size == granules.size
          raise ArgumentError.new("Object input mark count differs from the shared key grid")
        end
        key_rows.each_with_index do |rows, index|
          unless rows == granules[index].size.to_u64 && rows <= rows_per_mark.to_u64
            raise ArgumentError.new("Object input parent rows differ from the shared key grid")
          end
        end
        nil
      end

      private def self.compare_granules!(
        actual : Array(Array(ObjectDocument)),
        expected : Array(Array(ObjectDocument)),
      ) : Nil
        unless actual.size == expected.size
          raise CorruptPartError.new("staged Object mark count differs from input")
        end
        actual.each_with_index do |rows, mark_index|
          expected_rows = expected[mark_index]
          unless rows.size == expected_rows.size
            raise CorruptPartError.new("staged Object parent row count differs from input")
          end
          rows.each_with_index do |document, row_index|
            WidePartValueComparison.document!(document, expected_rows[row_index])
          end
        end
        nil
      end

      private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
        left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
          left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
      end
    end
  end
end
