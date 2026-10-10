module CrystalClick
  module WidePartWriter
    # Adapter for the existing static BinaryBulk physical owner. Nominal
    # declarations remain with their existing narrow admission classes.
    private class StaticWidePartColumnInput
      def self.prepare(
        name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        context : WidePartOperationContext,
      ) : WidePartPreparedColumn
        # Bound and materialize the descriptor before consulting any derived
        # type summaries or nominal admission owner. Descriptor construction
        # itself is immutable, but recursive name rendering remains charged.
        type_name = bounded_type_name(type, context)
        unless context.profile.single_stream? || context.profile.with_size_stream?
          raise UnsupportedFormatError.new("unsupported static BinaryBulk String profile")
        end
        if type.contains_json?
          raise UnsupportedFormatError.new("JSON requires a bound Object or recursive column owner")
        end
        if type.contains_dynamic?
          raise UnsupportedFormatError.new("Dynamic requires its bound Dynamic column owner")
        end
        if type.contains_nested? && type.tag != BinaryDataType::TAG_NESTED
          raise UnsupportedFormatError.new("Nested BinaryBulk requires its exact nominal Nested storage plan")
        end
        if type.geometry_storage_variant?
          raise UnsupportedFormatError.new("Geometry storage Variants require their nominal physical owner")
        end

        if PointColumnType.for_type(type_name) || GeoArrayColumnType.for_type(type_name) ||
           GeometryColumnType.for_type(type_name)
          raise UnsupportedFormatError.new("Geo, Point and Geometry columns require their nominal physical owners")
        end
        declaration = admitted_declaration(type, type_name, context)
        unless declaration == type_name
          raise UnsupportedFormatError.new("static BinaryBulk nominal declaration differs from the canonical type")
        end
        if type.contains_nested? &&
           (type.tag != BinaryDataType::TAG_NESTED || WideNestedTypePlan.for_type(declaration).nil?)
          raise UnsupportedFormatError.new("Nested BinaryBulk requires its exact nominal Nested storage plan")
        end
        BinaryBulkTypePlan.new(type, context.profile, nil, context.limits, true).role_count

        parent_rows = preflight_granules!(granules, context.rows_per_mark)
        physical = BinaryBulkPhysicalPlan.new(
          type, name, context.profile, context.limits, context.name_context
        )
        streams = physical.stream_names.values.sort!
        unless streams.size > 0 && streams.size == physical.stream_names.size
          raise UnsupportedFormatError.new("static BinaryBulk physical plan has no value streams")
        end
        values = detach_granules(granules)
        encode = ->(rows_per_mark : Array(UInt64), codec_budget : BinaryCodecBudget, transport_budget : CompressedStreamBudget) {
          BinaryBulkColumnWriter.encode(
            type, context.profile, physical, values, rows_per_mark,
            context.frame_bytes, context.limits, context.transport_limits,
            codec_budget, transport_budget
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
        context : WidePartOperationContext,
        codec_budget : BinaryCodecBudget,
        transport_budget : CompressedStreamBudget,
      ) : Nil
        reader = BinaryBulkColumnReader.open(
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
