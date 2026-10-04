module CrystalClick
  # Paired codec for flattened Object rows across metadata, typed lanes,
  # Dynamic lanes, and the shared MAP. It does not parse or render JSON text.
  module ObjectDocumentCodec
    DEFAULT_LIMITS = BinaryBulkCodec::DEFAULT_LIMITS
    DEFAULT_MODE   = DynamicDiscriminatorCodec::DEFAULT_MODE

    def self.encode(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      mode : UInt64 = DEFAULT_MODE,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : ObjectDocumentStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(plan, granules, budget, mode: mode, profile: profile, shared_profile: shared_profile)
    end

    def self.encode_with_budget(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      budget : BinaryCodecBudget,
      mode : UInt64 = DEFAULT_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : ObjectDocumentStreams
      unless budget.writing?
        raise ArgumentError.new("Object document encode requires a writing budget")
      end
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end
      validate_write_structure(plan.structures)
      plan.typed_path_count.times do |index|
        type = plan.typed_type_for(plan.typed_path_at(index))
        if type.contains_variant?
          type_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
          type_context.validate_type_tree(type)
          reject_variant_typed_field!(type)
        end
        validate_low_cardinality_typed_field!(type, budget.limits)
      end

      mark_count = granules.size
      if mark_count > Int32::MAX - 1
        raise UnsupportedFormatError.new("Object document mark grid exceeds the supported domain")
      end

      # Charge the complete outer row grid and document/path visits before
      # allocating row-count or per-lane collections.
      budget.ensure_future_nodes(mark_count.to_u64)
      budget.ensure_future_elements(mark_count.to_u64)
      total_rows = 0_u64
      shared_entries = 0_u64
      granules.each do |mark_rows|
        if mark_rows.empty?
          raise ArgumentError.new("Object document real marks must contain at least one row")
        end
        if mark_rows.size > Int32::MAX
          raise UnsupportedFormatError.new("Object document mark row count exceeds the supported domain")
        end
        budget.charge_node
        budget.charge_elements(1_u64)
        row_count = mark_rows.size.to_u64
        total_rows = checked_add(total_rows, row_count, true)
        mark_rows.each do |document|
          budget.charge_node
          budget.preflight_children(document.path_count.to_u64) if document.path_count > 0
          document.path_count.times do |path_index|
            path = document.path_at(path_index)
            next if plan.has_typed_path?(path) || plan.structures.object.has_dynamic_path?(path)
            value = document.value_for(path)
            if value.type.tag == BinaryDataType::TAG_NOTHING
              unless value.is_null?
                raise UnsupportedFormatError.new("non-typed Nothing values must use the NULL sentinel")
              end
              next
            end
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              raise UnsupportedFormatError.new("non-typed top-level Nullable values are outside the canonical profile")
            end
            shared_entries = checked_add(shared_entries, 1_u64, true)
          end
        end
      end

      row_counts = Array(UInt64).new(mark_count)
      granules.each do |mark_rows|
        row_counts << mark_rows.size.to_u64
      end

      # Encode metadata first using this operation's budget. No child output is
      # published if a later lane fails.
      metadata = ObjectDynamicStructureCodec.encode_with_budget(plan.structures, budget)
      typed_lanes = Hash(String, BinaryBulkStreams).new
      plan.typed_path_count.times do |typed_index|
        path = plan.typed_path_at(typed_index)
        type = plan.typed_type_for(path)
        lane_granules = Array(Array(BinaryValue)).new(mark_count)
        granules.each do |mark_rows|
          budget.ensure_future_nodes(mark_rows.size.to_u64)
          values = Array(BinaryValue).new(mark_rows.size)
          mark_rows.each do |document|
            unless document.has_path?(path)
              raise UnsupportedFormatError.new("typed Object field is missing: #{path.inspect}")
            end
            value = document.value_for(path)
            # The bulk writer compares nominal types recursively. Visit the
            # supplied tree first under the shared aggregate budget so a deep
            # mismatching descriptor cannot bypass its bound during equality.
            type_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
            type_context.validate_type_tree(value.type)
            values << value
          end
          lane_granules << values
        end
        typed_lanes[path] = BinaryBulkCodec.encode_with_budget(type, lane_granules, budget, profile: profile)
      end

      dynamic_lanes = Hash(String, DynamicValueStreams).new
      object = plan.structures.object
      object.dynamic_path_count.times do |dynamic_index|
        path = object.dynamic_path_at(dynamic_index)
        dynamic_granules = Array(Array(BinaryValue)).new(mark_count)
        granules.each do |mark_rows|
          budget.ensure_future_nodes(mark_rows.size.to_u64)
          values = Array(BinaryValue).new(mark_rows.size)
          mark_rows.each do |document|
            if document.has_path?(path)
              values << document.value_for(path)
            else
              values << BinaryValue.null
            end
          end
          dynamic_granules << values
        end
        dynamic_lanes[path] = DynamicValueCodec.encode_with_budget(
          plan.structures.dynamic_for(path),
          dynamic_granules,
          budget,
          mode: mode,
          profile: profile
        )
      end

      # Parent preflight counted every shared entry before this nested matrix
      # is allocated. The shared helper separately reserves all pending value
      # envelopes before it copies any framed String.
      shared_wrapper_nodes = checked_add(total_rows, checked_multiply(shared_entries, 3_u64, true), true)
      budget.ensure_future_nodes(shared_wrapper_nodes)
      budget.ensure_future_elements(checked_multiply(shared_entries, 3_u64, true))
      shared_granules = Array(Array(Array(ObjectDocumentSharedCodec::Entry))).new(mark_count)
      granules.each do |mark_rows|
        shared_rows = Array(Array(ObjectDocumentSharedCodec::Entry)).new(mark_rows.size)
        mark_rows.each do |document|
          entries = Array(ObjectDocumentSharedCodec::Entry).new
          document.path_count.times do |path_index|
            path = document.path_at(path_index)
            next if plan.has_typed_path?(path) || object.has_dynamic_path?(path)
            value = document.value_for(path)
            next if value.type.tag == BinaryDataType::TAG_NOTHING && value.is_null?
            entries << {path, value}
          end
          shared_rows << entries
        end
        shared_granules << shared_rows
      end
      shared_lanes = ObjectDocumentSharedCodec.encode_with_budget(shared_granules, budget, shared_profile)

      ObjectDocumentStreams.new(metadata, row_counts, typed_lanes, dynamic_lanes, shared_lanes)
    end

    def self.decode(
      typed_schema : Hash(String, BinaryDataType),
      streams : ObjectDocumentStreams,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(ObjectDocument))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(
        typed_schema,
        streams,
        budget,
        first_mark: first_mark,
        mark_count: mark_count,
        profile: profile,
        shared_profile: shared_profile
      )
    end

    def self.decode_with_budget(
      typed_schema : Hash(String, BinaryDataType),
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(ObjectDocument))
      if budget.writing?
        raise ArgumentError.new("Object document decode requires a reading budget")
      end

      real_marks = streams.mark_count
      selected_first, selected_count = validate_selection(first_mark, mark_count, real_marks)

      # The outer row-grid is count-derived metadata. Admit and charge its
      # complete record set before schema traversal, metadata decoding, or any
      # allocation proportional to the caller-controlled mark count.
      budget.preflight_children(real_marks.to_u64)
      real_marks.times { budget.charge_node }

      # Schema descriptors and path records are caller-controlled collections;
      # bound and walk each descriptor before a plan or lane roster is copied.
      schema_context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      typed_schema.size.times do
        budget.preflight_children(1_u64)
      end
      typed_schema.each_value do |type|
        schema_context.validate_type_tree(type)
        reject_variant_typed_field!(type)
        validate_low_cardinality_typed_field!(type, budget.limits)
      end

      structure_set = ObjectDynamicStructureCodec.decode_with_budget(streams.structures, budget)
      validate_read_structure(structure_set)
      object = structure_set.object

      if streams.typed_path_count != typed_schema.size
        corrupt!("typed Object lane keys do not exactly match the supplied schema")
      end
      typed_schema.each_key do |path|
        unless streams.has_typed_path?(path)
          corrupt!("typed Object lane is missing schema path #{path.inspect}")
        end
      end
      if streams.dynamic_path_count != object.dynamic_path_count
        corrupt!("Dynamic Object lane keys do not exactly match metadata paths")
      end
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        unless streams.has_dynamic_path?(path)
          corrupt!("Dynamic Object lane is missing metadata path #{path.inspect}")
        end
      end
      if streams.shared.mark_count != real_marks
        corrupt!("shared Object lane mark grid does not match the outer row grid")
      end

      rows_per_mark = Array(UInt64).new(real_marks)
      total_rows = 0_u64
      real_marks.times do |mark_index|
        rows = streams.row_count_at(mark_index)
        if rows == 0_u64
          corrupt!("Object real marks must contain at least one row")
        end
        if rows > Int32::MAX.to_u64
          corrupt!("Object outer row count exceeds the supported in-memory domain")
        end
        total_rows = checked_add(total_rows, rows, false)
        rows_per_mark << rows
      end

      # Validate every complete Dynamic outer row grid before selection, even
      # when the caller selects zero marks. Child bodies remain selected-only.
      object.dynamic_path_count.times do |dynamic_index|
        path = object.dynamic_path_at(dynamic_index)
        discriminator = streams.dynamic_for(path).discriminators
        unless discriminator.mark_count == real_marks + 1
          corrupt!("Dynamic discriminator mark grid does not match the Object row grid")
        end
        real_marks.times do |mark_index|
          unless discriminator.mark_at(mark_index).rows == rows_per_mark[mark_index]
            corrupt!("Dynamic discriminator rows disagree with the Object outer row grid")
          end
        end
      end

      plan = begin
        ObjectDocumentPlan.new(structure_set, typed_schema)
      rescue ex : ArgumentError
        raise CorruptPartError.new("invalid Object typed schema: #{ex.message}")
      end

      typed_rows = Hash(String, Array(Array(BinaryValue))).new
      typed_schema.each do |path, type|
        typed_rows[path] = BinaryBulkCodec.decode_with_budget(
          type,
          streams.typed_for(path),
          rows_per_mark,
          budget,
          first_mark: selected_first,
          mark_count: selected_count,
          profile: profile
        )
      end

      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new
      object.dynamic_path_count.times do |dynamic_index|
        path = object.dynamic_path_at(dynamic_index)
        dynamic_rows[path] = DynamicValueCodec.decode_with_budget(
          structure_set.dynamic_for(path),
          streams.dynamic_for(path),
          budget,
          first_mark: selected_first,
          mark_count: selected_count,
          profile: profile
        )
      end

      shared_rows = ObjectDocumentSharedCodec.decode_with_budget(
        streams.shared,
        rows_per_mark,
        object,
        typed_schema,
        budget,
        selected_first,
        selected_count,
        shared_profile
      )

      selected_rows = 0_u64
      selected_count.times do |window_offset|
        selected_rows = checked_add(selected_rows, rows_per_mark[selected_first + window_offset], false)
      end
      assembly_fields = 0_u64
      selected_count.times do |window_offset|
        selected_index = window_offset
        rows = rows_per_mark[selected_first + window_offset].to_i
        rows.times do |row_index|
          fields = typed_schema.size.to_u64
          object.dynamic_path_count.times do |dynamic_index|
            value = dynamic_rows[object.dynamic_path_at(dynamic_index)][selected_index][row_index]
            fields = checked_add(fields, 1_u64, false) unless value.type.tag == BinaryDataType::TAG_NOTHING && value.is_null?
          end
          shared_rows[selected_index][row_index].each do |_entry|
            fields = checked_add(fields, 1_u64, false)
          end
          assembly_fields = checked_add(assembly_fields, fields, false)
        end
      end
      budget.ensure_future_nodes(selected_rows)
      budget.ensure_future_elements(assembly_fields)

      result = Array(Array(ObjectDocument)).new(selected_count)
      selected_count.times do |window_offset|
        selected_index = window_offset
        row_count = rows_per_mark[selected_first + window_offset].to_i
        documents = Array(ObjectDocument).new(row_count)
        row_count.times do |row_index|
          fields = Hash(String, BinaryValue).new
          typed_schema.each_key do |path|
            fields[path] = typed_rows[path][selected_index][row_index]
          end
          object.dynamic_path_count.times do |dynamic_index|
            path = object.dynamic_path_at(dynamic_index)
            value = dynamic_rows[path][selected_index][row_index]
            unless value.type.tag == BinaryDataType::TAG_NOTHING && value.is_null?
              fields[path] = value
            end
          end
          shared_rows[selected_index][row_index].each do |entry|
            fields[entry[0]] = entry[1]
          end
          budget.charge_node
          budget.charge_elements(fields.size.to_u64) if fields.size > 0
          begin
            documents << ObjectDocument.new(fields)
          rescue ex : ArgumentError
            raise CorruptPartError.new("invalid assembled Object document: #{ex.message}")
          end
        end
        result << documents
      end
      result
    end

    private def self.validate_low_cardinality_typed_field!(type : BinaryDataType, limits : BinaryCodecLimits) : Nil
      if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type) &&
         ObjectRecursiveDeclaration.measure_descriptor(type, limits, 2).nil?
        raise UnsupportedFormatError.new("Object typed LowCardinality fields are not admitted")
      end
      nil
    end

    private def self.reject_variant_typed_field!(type : BinaryDataType) : Nil
      if type.contains_variant?
        raise UnsupportedFormatError.new("Object typed Variant fields are not admitted")
      end
      nil
    end

    private def self.validate_write_structure(structure_set : ObjectDynamicStructureSet) : Nil
      object = structure_set.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("Object document composition supports only Object V3 with one MAP bucket")
      end
      unless structure_set.dynamic_count == object.dynamic_path_count
        raise UnsupportedFormatError.new("Dynamic structure set does not match Object metadata")
      end
      nil
    end

    private def self.validate_read_structure(structure_set : ObjectDynamicStructureSet) : Nil
      object = structure_set.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("Object document composition supports only Object V3 with one MAP bucket")
      end
      unless structure_set.dynamic_count == object.dynamic_path_count
        corrupt!("Dynamic structure set does not match Object metadata")
      end
    end

    private def self.validate_selection(first_mark : Int, mark_count : Int?, real_marks : Int32) : {Int32, Int32}
      first = first_mark.to_i128
      marks = real_marks.to_i128
      if first < 0_i128 || first > marks
        raise ArgumentError.new("Object document selected mark range is outside the physical grid")
      end
      count = mark_count.try(&.to_i128) || (marks - first)
      if count < 0_i128 || count > marks - first
        raise ArgumentError.new("Object document selected mark range is outside the physical grid")
      end
      {first.to_i32, count.to_i32}
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right > UInt64::MAX - left
        if writing
          raise UnsupportedFormatError.new("Object document aggregate count overflows UInt64")
        else
          raise CorruptPartError.new("Object document aggregate count overflows UInt64")
        end
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        if writing
          raise UnsupportedFormatError.new("Object document aggregate count overflows UInt64")
        else
          raise CorruptPartError.new("Object document aggregate count overflows UInt64")
        end
      end
      left * right
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
