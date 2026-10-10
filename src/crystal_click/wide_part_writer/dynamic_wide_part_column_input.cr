module CrystalClick
  module WidePartWriter
    # Adapter for the existing Dynamic BinaryBulk owner. It retains the
    # descriptor-derived plan while sharing the publication operation's write
    # and read budgets with every other value column.
    private class DynamicWidePartColumnInput
      def self.prepare(
        name : String,
        type : BinaryDataType,
        structures : Hash(String, DynamicStructure),
        granules : Array(Array(BinaryValue)),
        json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))?,
        json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))?,
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        # Render the descriptor under the operation budget before consulting
        # summary predicates or constructing the Dynamic structure plan.
        declaration = bounded_type_name(type, context)
        unless context.profile.single_stream? || context.profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported Dynamic String profile")
        end
        unless type.contains_dynamic?
          raise UnsupportedFormatError.new("Dynamic bulk requires a Dynamic-bearing descriptor")
        end
        if type.contains_json?
          raise UnsupportedFormatError.new("JSON is outside the admitted Dynamic bulk profile")
        end
        parent_rows = preflight_granules!(granules, context.rows_per_mark)
        dynamic_plan = BinaryDynamicBulkPlan.new_with_budget(
          type,
          structures,
          context.codec_budget,
          context.profile,
          json_object_plans,
          json_object_leaf_plans: json_object_leaf_plans,
        )
        unless dynamic_plan.type == type && dynamic_plan.profile == context.profile
          raise UnsupportedFormatError.new("Dynamic structure plan differs from the admitted descriptor or profile")
        end
        BinaryBulkTypePlan.new(
          type, context.profile, dynamic_plan, context.limits, true
        ).role_count

        physical = BinaryDynamicBulkPhysicalPlan.new(
          dynamic_plan, name, context.limits, context.name_context
        )
        physical_names = physical.stream_names
        streams = physical_names.values.sort!
        unless streams.size > 0 && streams.size == physical_names.size &&
               streams.uniq.size == streams.size
          raise UnsupportedFormatError.new("Dynamic physical plan has an empty or duplicate value roster")
        end

        values = detach_granules(granules)
        encode = ->(rows_per_mark : Array(UInt64), codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          expected_rows = parent_rows.map(&.to_u64)
          unless rows_per_mark == expected_rows
            raise ArgumentError.new("Dynamic encoder grid differs from its prepared parent grid")
          end
          DynamicBulkColumnWriter.encode(
            dynamic_plan,
            physical,
            values,
            rows_per_mark,
            context.frame_bytes,
            context.limits,
            context.transport_limits,
            codec_budget: codec_budget,
            transport_budget: transport_budget,
          )
        }
        validate = ->(path : String, codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          validate_staged!(
            path, name, type, declaration, streams, parent_rows, values,
            context, codec_budget, transport_budget
          )
        }

        WidePartPreparedColumn.new(
          String.new(name.to_slice), declaration, streams, parent_rows, encode, validate
        )
      end

      private def self.bounded_type_name(
        type : BinaryDataType,
        context : WidePartOperationContext,
      ) : String
        bounds = BinaryTypeNameBudget.measure(type, context.codec_budget)
        name = BinaryTypeNameBudget.materialize(type, context.codec_budget, bounds)
        context.codec_budget.ensure_wire_bytes(name.bytesize.to_u64)
        context.codec_budget.charge_wire_bytes(name.bytesize.to_u64)
        String.new(name.to_slice)
      end

      private def self.preflight_granules!(
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
      ) : Array(Int32)
        if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
          raise ArgumentError.new("Dynamic parent mark count is outside the writer limit")
        end
        rows = Array(Int32).new(granules.size)
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("Dynamic parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final Dynamic parent granule may be short")
          end
          rows << granule.size.to_i32
        end
        rows
      end

      private def self.detach_granules(
        granules : Array(Array(BinaryValue)),
      ) : Array(Array(BinaryValue))
        detached = Array(Array(BinaryValue)).new(granules.size)
        granules.each { |granule| detached << granule.dup }
        detached
      end

      private def self.validate_staged!(
        path : String,
        name : String,
        type : BinaryDataType,
        declaration : String,
        streams : Array(String),
        parent_rows : Array(Int32),
        granules : Array(Array(BinaryValue)),
        context : WidePartOperationContext,
        codec_budget : BinaryCodecBudget,
        transport_budget : CompressedStreamBudget,
      ) : Nil
        reader = DynamicBulkColumnReader.open(
          path, name, type, context.limits, context.transport_limits,
          codec_budget, transport_budget
        )
        expected_rows = parent_rows.map(&.to_u64)
        unless reader.row_count == expected_rows.sum(0_u64) &&
               reader.mark_count == expected_rows.size &&
               reader.schema_declaration == declaration &&
               reader.source_declaration == declaration &&
               reader.ordinary_profile == context.profile &&
               reader.physical_stream_names == streams &&
               reader.mark_row_counts == expected_rows
          raise CorruptPartError.new("staged Dynamic declaration, roster or grid differs from input")
        end

        actual = reader.read_marks(0, reader.mark_count)
        unless actual.size == granules.size
          raise CorruptPartError.new("staged Dynamic reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows_for_mark, mark|
          actual_rows = actual[mark]
          unless actual_rows.size == expected_rows_for_mark.size
            raise CorruptPartError.new("staged Dynamic reader returned the wrong parent row count")
          end
          expected_rows_for_mark.each_with_index do |expected, row|
            WidePartValueComparison.binary!(actual_rows[row], expected)
          end
        end
        nil
      end
    end
  end
end
