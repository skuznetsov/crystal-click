module CrystalClick
  module WidePartWriter
    # Adapter for the generic static BinaryBulk physical owner. Nominal static
    # Nested nodes retain their recursive identity; other contextual and
    # nominal owners remain behind their existing admission paths.
    private class StaticWidePartColumnInput
      def self.prepare(
        name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        prepare_with_profile(name, type, granules, context, context.profile, false)
      end

      def self.prepare_projection_aggregate(
        aggregate : WidePartProjectionAggregate,
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        descriptor = aggregate.descriptor
        type = descriptor.type
        if descriptor.count?
          if context.rows_per_mark.to_u64 > WideAggregateCountStoragePlan::MAX_MARK_RANGE_ROWS
            raise ArgumentError.new("count projection rows_per_mark is outside the admitted range")
          end
        else
          plan = BinaryAggregateFunctionStatePlan.for_type(type)
          if descriptor.sum?
            unless plan.state_width == sizeof(UInt64)
              raise UnsupportedFormatError.new("sum projection requires the fixed UInt64 AggregateFunction state")
            end
          elsif descriptor.minmax?
            layout = plan.minmax_layout ||
                     raise UnsupportedFormatError.new("min/max projection requires the existing fixed-value state plan")
            unless layout.input_type.tag == BinaryDataType::TAG_UINT64 && layout.state_kind.fixed? && !plan.nullable_argument?
              raise UnsupportedFormatError.new("min/max projection requires the present UInt64 SingleValueData state")
            end
          else
            raise UnsupportedFormatError.new("aggregate projection function is outside the admitted profile")
          end
        end

        granules = aggregate_projection_granules(
          aggregate.values, context.rows_per_mark, descriptor.function_name
        ) do |value|
          if descriptor.count?
            BinaryValue.aggregate_count_state(type, value)
          else
            presence_bytes = descriptor.minmax? ? 1 : 0
            state_bytes = Bytes.new(presence_bytes + sizeof(UInt64))
            if presence_bytes == 1
              state_bytes[0] = 1_u8
            end
            IO::ByteFormat::LittleEndian.encode(value, state_bytes[presence_bytes, sizeof(UInt64)])
            BinaryValue.aggregate_function_state(type, state_bytes)
          end
        end
        prepare_with_profile(
          descriptor.column_name, type, granules, context,
          BinaryBulkProfile.with_size_stream, descriptor.count?
        )
      end

      private def self.aggregate_projection_granules(
        values : Array(UInt64),
        rows_per_mark : Int32,
        aggregate_name : String,
        &encode : UInt64 -> BinaryValue
      ) : Array(Array(BinaryValue))
        # Bound the child grid before expanding the UInt64 inputs into states.
        mark_count = (values.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        unless mark_count > 0 && mark_count <= WidePartWriter::MAX_MARKS
          raise ArgumentError.new("#{aggregate_name} projection mark count is outside the writer limit")
        end
        granules = Array(Array(BinaryValue)).new(mark_count.to_i32)
        offset = 0
        while offset < values.size
          rows = Math.min(rows_per_mark, values.size - offset)
          granules << Array(BinaryValue).new(rows) { |row| yield values[offset + row] }
          offset += rows
        end
        granules
      end

      private def self.prepare_with_profile(
        name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        context : WidePartOperationContext,
        effective_profile : BinaryBulkProfile,
        count_projection : Bool,
      ) : WidePartPreparedColumn
        # Bound and materialize the descriptor before consulting any derived
        # type summaries or nominal admission owner. Descriptor construction
        # itself is immutable, but recursive name rendering remains charged.
        type_name = bounded_type_name(type, context)
        unless effective_profile.single_stream? || effective_profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported static BinaryBulk String profile")
        end
        if type.contains_json?
          raise UnsupportedFormatError.new("JSON requires a bound Object or recursive column owner")
        end
        if type.contains_dynamic?
          raise UnsupportedFormatError.new("Dynamic requires its bound Dynamic column owner")
        end
        if type.geometry_storage_variant?
          raise UnsupportedFormatError.new("Geometry storage Variants require their nominal physical owner")
        end

        if PointColumnType.for_type(type_name) || GeoArrayColumnType.for_type(type_name) ||
           GeometryColumnType.for_type(type_name)
          raise UnsupportedFormatError.new("Geo, Point and Geometry columns require their nominal physical owners")
        end
        # The count-projection entry supplies the exact no-argument root type.
        declaration = count_projection ? type_name : admitted_declaration(type, type_name, context)
        unless declaration == type_name
          raise UnsupportedFormatError.new("static BinaryBulk nominal declaration differs from the canonical type")
        end
        BinaryBulkTypePlan.new(type, effective_profile, nil, context.limits, true).role_count

        parent_rows = preflight_granules!(granules, context.rows_per_mark)
        physical = BinaryBulkPhysicalPlan.new(
          type, name, effective_profile, context.limits, context.name_context
        )
        streams = physical.stream_names.values.sort!
        unless streams.size > 0 && streams.size == physical.stream_names.size
          raise UnsupportedFormatError.new("static BinaryBulk physical plan has no value streams")
        end
        values = detach_granules(granules)
        encode = ->(rows_per_mark : Array(UInt64), codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          BinaryBulkColumnWriter.encode(
            type, effective_profile, physical, values, rows_per_mark,
            context.frame_bytes, context.limits, context.transport_limits,
            codec_budget, transport_budget
          )
        }
        validate = ->(path : String, codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          validate_staged!(
            path, name, type, declaration, streams, parent_rows, values,
            effective_profile, context, codec_budget, transport_budget
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

      private def self.admitted_declaration(
        type : BinaryDataType,
        canonical : String,
        context : WidePartOperationContext,
      ) : String
        if type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE ||
           (type.tag == BinaryDataType::TAG_NULLABLE &&
           type.child_at(0).tag == BinaryDataType::TAG_SIMPLE_AGGREGATE)
          return SimpleAggregateBulkColumnDeclaration.new(type, context.limits).declaration
        end
        if contains_tag?(type, BinaryDataType::TAG_SIMPLE_AGGREGATE)
          raise UnsupportedFormatError.new("static BinaryBulk only admits its nominal root SimpleAggregate owner")
        end
        if type.contains_aggregate_function?
          declaration = BinaryAggregateFunctionBulkColumnDeclaration.new(type, context.limits)
          return declaration.declaration
        end
        if type.contains_qbit?
          declaration = BinaryQBitBulkColumnDeclaration.new(type, context.limits)
          return declaration.declaration
        end
        if type.contains_custom_geo?
          declaration = BinaryCustomGeoBulkColumnDeclaration.new(type, context.limits)
          if type.tag == BinaryDataType::TAG_CUSTOM && !context.profile.with_size_stream?
            raise UnsupportedFormatError.new("bare Custom Geo requires String serialization version 1")
          end
          return declaration.declaration
        end
        canonical
      end

      private def self.contains_tag?(type : BinaryDataType, tag : UInt8) : Bool
        return true if type.tag == tag
        type.child_count.times do |index|
          return true if contains_tag?(type.child_at(index), tag)
        end
        false
      end

      private def self.preflight_granules!(
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
      ) : Array(Int32)
        if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
          raise ArgumentError.new("static BinaryBulk mark count is outside the writer limit")
        end
        rows = Array(Int32).new(granules.size)
        granules.each_with_index do |granule, index|
          if granule.empty? || granule.size > rows_per_mark
            raise ArgumentError.new("static BinaryBulk parent granule size is outside the admitted range")
          end
          if index < granules.size - 1 && granule.size != rows_per_mark
            raise ArgumentError.new("only the final static BinaryBulk parent granule may be short")
          end
          rows << granule.size.to_i32
        end
        rows
      end

      private def self.detach_granules(granules : Array(Array(BinaryValue))) : Array(Array(BinaryValue))
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
        effective_profile : BinaryBulkProfile,
        context : WidePartOperationContext,
        codec_budget : BinaryCodecBudget,
        transport_budget : CompressedStreamBudget,
      ) : Nil
        reader = BinaryBulkColumnReader.open(
          path, name, type, context.limits, context.read_transport_limits,
          codec_budget, transport_budget
        )
        expected_rows = parent_rows.map(&.to_u64)
        unless reader.row_count == expected_rows.sum(0_u64) &&
               reader.mark_count == expected_rows.size &&
               reader.schema_declaration == declaration &&
               reader.source_declaration == declaration &&
               reader.ordinary_profile == effective_profile &&
               reader.physical_stream_names == streams &&
               reader.mark_row_counts == expected_rows
          raise CorruptPartError.new("staged static BinaryBulk declaration, roster or grid differs from input")
        end
        actual = reader.read_marks(0, reader.mark_count)
        unless actual.size == granules.size
          raise CorruptPartError.new("staged static BinaryBulk reader returned the wrong mark count")
        end
        granules.each_with_index do |expected_rows_for_mark, mark|
          actual_rows = actual[mark]
          unless actual_rows.size == expected_rows_for_mark.size
            raise CorruptPartError.new("staged static BinaryBulk reader returned the wrong parent row count")
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
