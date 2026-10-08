module CrystalClick
  # Paired codec for flattened Object rows across metadata, typed lanes,
  # Dynamic lanes, and the shared MAP. It does not parse or render JSON text.
  module ObjectDocumentCodec
    DEFAULT_LIMITS = BinaryBulkCodec::DEFAULT_LIMITS
    DEFAULT_MODE   = DynamicDiscriminatorCodec::DEFAULT_MODE

    alias RootDynamicJsonLeafPlans = Hash(
      String,
      Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
    )
    alias PhysicalRootDynamicJsonObjectLeafLoader = Proc(
      String,
      BinaryDynamicJsonLeafKey,
      DynamicJsonObjectBinding,
      StorageOccurrenceGrid,
      Int32,
      BinaryCodecBudget,
      Array(Array(ObjectDocument)),
    )

    def self.encode(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      mode : UInt64 = DEFAULT_MODE,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDocumentStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(
        plan,
        granules,
        budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile,
        inferred_actual_root_depth: inferred_actual_root_depth,
      )
    end

    def self.encode_with_budget(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      budget : BinaryCodecBudget,
      mode : UInt64 = DEFAULT_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDocumentStreams
      encode_core_with_budget(
        plan,
        granules,
        budget,
        mode,
        profile,
        shared_profile,
        nil,
        2,
        inferred_actual_root_depth || plan.inferred_actual_root_depth,
      )
    end

    # Explicit child-site composition keeps the parent physical row grid
    # separate from these flattened logical Object occurrences. The outer
    # discriminator header carries the selected mode; the ordinary root API
    # and its nonempty-mark guard are intact.
    def self.encode_child_site_with_budget(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      typed_descriptor_root_depth : Int32 = 2,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDocumentStreams
      encode_core_with_budget(
        plan,
        granules,
        budget,
        mode,
        profile,
        shared_profile,
        grid,
        typed_descriptor_root_depth,
        inferred_actual_root_depth || plan.inferred_actual_root_depth,
      )
    end

    private def self.encode_core_with_budget(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      budget : BinaryCodecBudget,
      mode : UInt64,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      occurrence_grid : StorageOccurrenceGrid?,
      typed_descriptor_root_depth : Int32,
      inferred_actual_root_depth : Int32,
    ) : ObjectDocumentStreams
      unless budget.writing?
        raise ArgumentError.new("Object document encode requires a writing budget")
      end
      unless typed_descriptor_root_depth >= 2
        raise UnsupportedFormatError.new("Object typed descriptor root depth must be at least 2 (got #{typed_descriptor_root_depth})")
      end
      budget.ensure_depth(typed_descriptor_root_depth) if plan.typed_path_count > 0
      if inferred_actual_root_depth <= 0 || inferred_actual_root_depth > budget.limits.max_depth
        raise UnsupportedFormatError.new("inferred Dynamic actual root depth exceeds the configured limit")
      end
      budget.ensure_depth(inferred_actual_root_depth)
      reject_json_plan!(plan)
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end
      validate_write_structure(plan.structures)
      if grid = occurrence_grid
        grid.validate_for!(granules.size, budget)
        granules.each_with_index do |mark_rows, mark_index|
          unless mark_rows.size.to_u64 == grid.logical_occurrences_at(mark_index)
            raise UnsupportedFormatError.new("Object child rows disagree with the occurrence grid")
          end
        end
      end
      typed_dynamic_write_plans = Hash(String, BinaryDynamicBulkPlan).new
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        if plan.has_typed_dynamic?(path)
          unless type.contains_dynamic? && ObjectRecursiveDeclaration.account_descriptor(type, budget, budget.limits, typed_descriptor_root_depth)
            raise UnsupportedFormatError.new("typed Object Dynamic path is outside the recursive declaration grammar")
          end
          structures = plan.typed_dynamic_sites_for(path, budget)
          json_leaf_plans = plan.typed_dynamic_json_object_leaf_plans_for(path, budget)
          typed_dynamic_write_plans[path] = ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
            type,
            structures,
            budget,
            profile,
            typed_descriptor_root_depth,
            json_leaf_plans.empty? ? nil : json_leaf_plans,
          )
        elsif type.contains_dynamic?
          raise UnsupportedFormatError.new("Object typed containers containing Dynamic are not admitted")
        end
        if type.contains_variant?
          type_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
          type_context.validate_type_tree(type, typed_descriptor_root_depth)
          validate_variant_typed_field!(type, budget.limits, typed_descriptor_root_depth)
        end
        validate_low_cardinality_typed_field!(type, budget.limits, typed_descriptor_root_depth)
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
      shared_path_bytes = 0_u64
      granules.each do |mark_rows|
        if mark_rows.empty? && occurrence_grid.nil?
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
            shared_path_bytes = checked_add(shared_path_bytes, path.bytesize.to_u64, true)
          end
        end
      end

      row_counts = Array(UInt64).new(mark_count)
      granules.each do |mark_rows|
        row_counts << mark_rows.size.to_u64
      end

      # Encode metadata first using this operation's budget. No child output is
      # published if a later lane fails.
      metadata = ObjectDynamicStructureCodec.encode_with_budget(
        plan.structures,
        budget,
        inferred_actual_root_depth: inferred_actual_root_depth,
      )
      typed_lanes = Hash(String, BinaryBulkStreams).new
      typed_dynamic_lanes = Hash(String, BinaryDynamicBulkStreams).new
      typed_dynamic_statistics_offsets = Hash(String, Int32).new
      typed_dynamic_site_statistics_offsets = Hash(String, Hash(String, Int32)).new
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
            type_context.validate_type_tree(value.type, typed_descriptor_root_depth)
            if plan.has_typed_dynamic?(path)
              ObjectDeclaredDynamicDeclaration.validate_selected_values!(
                value,
                type,
                budget,
                true,
                typed_descriptor_root_depth,
                allow_shared_json: true,
              )
            end
            values << value
          end
          lane_granules << values
        end
        if plan.has_typed_dynamic?(path)
          dynamic_plan = typed_dynamic_write_plans[path]
          structures = dynamic_plan.encode_structure_streams(budget)
          json_object_writer = if dynamic_plan.has_json_object_bindings?
                                 BinaryDynamicBulkJsonObjectWriter.new(
                                   dynamic_plan,
                                   budget,
                                   lane_granules,
                                   inherited_grid: occurrence_grid,
                                   initial_descriptor_depth: typed_descriptor_root_depth,
                                 )
                               end
          data = BinaryBulkEncoder.encode(
            type,
            lane_granules,
            budget,
            profile,
            dynamic_plan,
            json_object_writer: json_object_writer,
            shared_value_depth_origin: typed_descriptor_root_depth,
          )
          json_leaf_streams = json_object_writer.try(&.finish_leaf_streams(
            profile,
            child_shared_profile: BinaryBulkProfile.single_stream,
          )) ||
                              Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new
          typed_dynamic_lanes[path] = BinaryDynamicBulkStreams.new(
            structures,
            data,
            budget: budget,
            json_object_leaf_streams: json_leaf_streams,
          )
          site_offsets = Hash(String, Int32).new
          site_paths = dynamic_plan.site_paths
          unless site_paths.size == dynamic_plan.site_count
            raise UnsupportedFormatError.new("typed Dynamic site roster changed during encoding")
          end
          site_paths.each do |site_path|
            site_offsets[site_path] = dynamic_plan.statistics_offset_for(site_path)
          end
          typed_dynamic_site_statistics_offsets[path] = site_offsets
          if dynamic_plan.site_count == 1 && dynamic_plan.has_site?("root")
            typed_dynamic_statistics_offsets[path] = dynamic_plan.statistics_offset_for("root")
          end
        else
          typed_lanes[path] = BinaryBulkCodec.encode_with_budget(type, lane_granules, budget, profile: profile)
        end
      end

      dynamic_lanes = Hash(String, DynamicValueStreams).new
      object = plan.structures.object
      object.dynamic_path_count.times do |dynamic_index|
        path = object.dynamic_path_at(dynamic_index)
        json_leaf_plans = plan.root_dynamic_json_object_leaf_plans_for(path, budget)
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
        if grid = occurrence_grid
          dynamic_lanes[path] = DynamicValueCodec.encode_child_site_with_budget(
            plan.structures.dynamic_for(path),
            dynamic_granules,
            grid,
            budget,
            mode: mode,
            profile: profile,
            json_object_leaf_plans: json_leaf_plans,
            inferred_actual_root_depth: inferred_actual_root_depth,
            child_shared_profile: shared_profile,
          )
        else
          dynamic_lanes[path] = DynamicValueCodec.encode_with_budget(
            plan.structures.dynamic_for(path),
            dynamic_granules,
            budget,
            mode: mode,
            profile: profile,
            json_object_leaf_plans: json_leaf_plans,
            inferred_actual_root_depth: inferred_actual_root_depth,
            child_shared_profile: shared_profile,
          )
        end
      end

      # Parent preflight counted every shared entry before this nested matrix
      # is allocated. The shared helper separately reserves all pending value
      # envelopes before it copies any framed String.
      shared_wrapper_nodes = checked_add(total_rows, checked_multiply(shared_entries, 3_u64, true), true)
      budget.ensure_future_nodes(shared_wrapper_nodes)
      budget.ensure_future_elements(checked_multiply(shared_entries, 3_u64, true))
      advanced_shared_rows = [] of Array(ObjectSharedMapRow)
      shared_lanes : BinaryBulkStreams | Array(BinaryBulkStreams)
      if object.shared_data_version >= 2_u64
        # The path byte snapshots below are an additional retained owner. Admit
        # the complete raw path copy set before constructing ObjectSharedMapEntry.
        budget.ensure_wire_bytes(shared_path_bytes)
        budget.charge_wire_bytes(shared_path_bytes)
        advanced_shared_rows = Array(Array(ObjectSharedMapRow)).new(mark_count)
        granules.each do |mark_rows|
          shared_rows = Array(ObjectSharedMapRow).new(mark_rows.size)
          mark_rows.each do |document|
            entries = Array(ObjectSharedMapEntry).new
            document.path_count.times do |path_index|
              path = document.path_at(path_index)
              next if plan.has_typed_path?(path) || object.has_dynamic_path?(path)
              value = document.value_for(path)
              next if value.type.tag == BinaryDataType::TAG_NOTHING && value.is_null?
              entries << ObjectSharedMapEntry.new(path.to_slice, value)
            end
            shared_rows << ObjectSharedMapRow.new(entries)
          end
          advanced_shared_rows << shared_rows
        end
        # Part-level Copy and six bucket lanes are emitted only at the Wide
        # physical boundary, where parent rows and transport budgets exist.
        shared_lanes = [] of BinaryBulkStreams
      else
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
        shared_lanes = if object.shared_data_version == 0_u64
                         ObjectDocumentSharedCodec.encode_with_budget(shared_granules, budget, shared_profile)
                       else
                         ObjectDocumentSharedBucketsCodec.encode_with_budget(
                           shared_granules,
                           ObjectSharedBucketLayout.bucket_count(object),
                           budget,
                           shared_profile
                         )
                       end
      end

      ObjectDocumentStreams.new(
        metadata,
        row_counts,
        typed_lanes,
        dynamic_lanes,
        shared_lanes,
        typed_dynamic_lanes,
        typed_dynamic_statistics_offsets,
        typed_dynamic_site_statistics_offsets,
        typed_dynamic_mode: mode,
        advanced_shared_rows: advanced_shared_rows
      )
    end

    def self.decode(
      typed_schema : Hash(String, BinaryDataType),
      streams : ObjectDocumentStreams,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
      typed_descriptor_root_depth : Int32 = 2,
      root_dynamic_json_object_leaf_plans : RootDynamicJsonLeafPlans = RootDynamicJsonLeafPlans.new,
      inferred_actual_root_depth : Int32 = 1_i32,
      physical_root_dynamic_json_object_leaf_loader : PhysicalRootDynamicJsonObjectLeafLoader? = nil,
    ) : Array(Array(ObjectDocument))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(
        typed_schema,
        streams,
        budget,
        first_mark: first_mark,
        mark_count: mark_count,
        profile: profile,
        shared_profile: shared_profile,
        typed_dynamic_json_object_leaf_plans: typed_dynamic_json_object_leaf_plans,
        typed_descriptor_root_depth: typed_descriptor_root_depth,
        root_dynamic_json_object_leaf_plans: root_dynamic_json_object_leaf_plans,
        inferred_actual_root_depth: inferred_actual_root_depth,
        physical_root_dynamic_json_object_leaf_loader: physical_root_dynamic_json_object_leaf_loader,
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
      typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
      typed_descriptor_root_depth : Int32 = 2,
      root_dynamic_json_object_leaf_plans : RootDynamicJsonLeafPlans = RootDynamicJsonLeafPlans.new,
      inferred_actual_root_depth : Int32 = 1_i32,
      physical_root_dynamic_json_object_leaf_loader : PhysicalRootDynamicJsonObjectLeafLoader? = nil,
    ) : Array(Array(ObjectDocument))
      decode_core_with_budget(
        typed_schema,
        streams,
        budget,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        typed_dynamic_json_object_leaf_plans,
        typed_descriptor_root_depth,
        root_dynamic_json_object_leaf_plans,
        inferred_actual_root_depth,
        physical_root_dynamic_json_object_leaf_loader,
        nil,
      )
    end

    # Explicit child-site decoder. Stream row counts remain logical child
    # occurrences; `grid` independently certifies the positive parent rows.
    def self.decode_child_site_with_budget(
      typed_schema : Hash(String, BinaryDataType),
      streams : ObjectDocumentStreams,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
      typed_descriptor_root_depth : Int32 = 2,
      root_dynamic_json_object_leaf_plans : RootDynamicJsonLeafPlans = RootDynamicJsonLeafPlans.new,
      inferred_actual_root_depth : Int32 = 1_i32,
      physical_root_dynamic_json_object_leaf_loader : PhysicalRootDynamicJsonObjectLeafLoader? = nil,
    ) : Array(Array(ObjectDocument))
      decode_core_with_budget(
        typed_schema,
        streams,
        budget,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        typed_dynamic_json_object_leaf_plans,
        typed_descriptor_root_depth,
        root_dynamic_json_object_leaf_plans,
        inferred_actual_root_depth,
        physical_root_dynamic_json_object_leaf_loader,
        grid,
      )
    end

    private def self.decode_core_with_budget(
      typed_schema : Hash(String, BinaryDataType),
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))),
      typed_descriptor_root_depth : Int32,
      root_dynamic_json_object_leaf_plans : RootDynamicJsonLeafPlans,
      inferred_actual_root_depth : Int32,
      physical_root_dynamic_json_object_leaf_loader : PhysicalRootDynamicJsonObjectLeafLoader?,
      occurrence_grid : StorageOccurrenceGrid?,
    ) : Array(Array(ObjectDocument))
      if budget.writing?
        raise ArgumentError.new("Object document decode requires a reading budget")
      end
      unless typed_descriptor_root_depth >= 2
        raise CorruptPartError.new("Object typed descriptor root depth must be at least 2 (got #{typed_descriptor_root_depth})")
      end
      budget.ensure_depth(typed_descriptor_root_depth) unless typed_schema.empty?
      if inferred_actual_root_depth <= 0 || inferred_actual_root_depth > budget.limits.max_depth
        corrupt!("inferred Dynamic actual root depth exceeds the configured limit")
      end
      budget.ensure_depth(inferred_actual_root_depth)
      validate_typed_json_binding_input!(typed_dynamic_json_object_leaf_plans, typed_schema, budget)

      real_marks = streams.mark_count
      if grid = occurrence_grid
        grid.validate_for!(real_marks, budget)
      end
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
      typed_dynamic_count = 0
      typed_schema.each_value do |type|
        # Bound raw schema recursion before contains_dynamic? traverses it.
        schema_context.validate_type_tree(type, typed_descriptor_root_depth)
        if type.contains_json?
          raise UnsupportedFormatError.new("root JSON is outside the persisted Object declaration grammar")
        end
        if type.contains_qbit?
          raise UnsupportedFormatError.new("Object typed QBit descriptor is outside the persisted Object declaration grammar")
        end
        if type.contains_dynamic?
          unless ObjectRecursiveDeclaration.account_descriptor(type, budget, budget.limits, typed_descriptor_root_depth)
            raise UnsupportedFormatError.new("Object typed Dynamic descriptor is outside the recursive declaration grammar")
          end
          typed_dynamic_count += 1
        end
        validate_variant_typed_field!(type, budget.limits, typed_descriptor_root_depth)
        validate_low_cardinality_typed_field!(type, budget.limits, typed_descriptor_root_depth)
      end
      typed_dynamic_json_object_leaf_plans.each do |path, leaf_plans|
        type = typed_schema[path]?
        unless type && type.contains_dynamic? && !leaf_plans.empty?
          corrupt!("typed Dynamic JSON Object binding names an unknown or non-Dynamic field")
        end
      end

      structure_set = ObjectDynamicStructureCodec.decode_with_budget(
        streams.structures,
        budget,
        inferred_actual_root_depth: inferred_actual_root_depth,
      )
      validate_read_structure(structure_set)
      object = structure_set.object
      validate_root_json_binding_input!(root_dynamic_json_object_leaf_plans, object, budget)
      typed_schema.each_key do |path|
        if object.has_dynamic_path?(path)
          corrupt!("typed and Dynamic Object paths must be disjoint")
        end
      end

      if streams.typed_path_count != typed_schema.size - typed_dynamic_count
        corrupt!("ordinary typed Object lane keys do not exactly match the supplied schema")
      end
      if streams.typed_dynamic_path_count != typed_dynamic_count
        corrupt!("typed Dynamic Object lane keys do not exactly match the supplied schema")
      end
      typed_schema.each do |path, type|
        if type.contains_dynamic?
          unless streams.has_typed_dynamic_path?(path)
            corrupt!("typed Dynamic Object lane is missing schema path #{path.inspect}")
          end
        elsif !streams.has_typed_path?(path)
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
      if object.shared_data_version <= 1_u64
        expected_shared_buckets = ObjectSharedBucketLayout.bucket_count(object)
        unless streams.shared_bucket_count == expected_shared_buckets && streams.advanced_shared_mark_count == 0
          corrupt!("shared Object lane roster does not match its metadata")
        end
        expected_shared_buckets.times do |bucket_index|
          unless streams.shared_bucket(bucket_index).mark_count == real_marks
            corrupt!("shared Object lane mark grid does not match the outer row grid")
          end
        end
      else
        unless streams.shared_bucket_count == 0 && streams.advanced_shared_mark_count == real_marks
          corrupt!("advanced shared Object rows do not match the outer mark grid")
        end
      end

      rows_per_mark = Array(UInt64).new(real_marks)
      total_rows = 0_u64
      real_marks.times do |mark_index|
        rows = streams.row_count_at(mark_index)
        if rows == 0_u64 && occurrence_grid.nil?
          corrupt!("Object real marks must contain at least one row")
        end
        if rows > Int32::MAX.to_u64
          corrupt!("Object outer row count exceeds the supported in-memory domain")
        end
        if grid = occurrence_grid
          unless rows == grid.logical_occurrences_at(mark_index)
            corrupt!("Object logical rows disagree with the occurrence grid")
          end
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
          expected_rows = if grid = occurrence_grid
                            grid.logical_occurrences_at(mark_index)
                          else
                            rows_per_mark[mark_index]
                          end
          unless discriminator.mark_at(mark_index).rows == expected_rows
            if occurrence_grid
              corrupt!("Dynamic discriminator rows disagree with the Object occurrence grid")
            else
              corrupt!("Dynamic discriminator rows disagree with the Object outer row grid")
            end
          end
        end
      end

      typed_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new
      typed_schema.each do |path, type|
        next unless type.contains_dynamic?
        dynamic_streams = streams.typed_dynamic_for(path)
        json_leaf_plans = typed_dynamic_json_object_leaf_plans[path]?
        dynamic_plan = ObjectDeclaredDynamicDeclaration.prepare_read_sites_plan(
          type,
          dynamic_streams.structures,
          budget,
          profile,
          typed_descriptor_root_depth,
          json_leaf_plans,
        )
        typed_dynamic_plans[path] = dynamic_plan
      end

      typed_rows = Hash(String, Array(Array(BinaryValue))).new
      typed_schema.each do |path, type|
        if type.contains_dynamic?
          dynamic_streams = streams.typed_dynamic_for(path)
          dynamic_plan = typed_dynamic_plans[path]
          if dynamic_plan.has_json_object_bindings?
            physical_rows_per_mark = occurrence_grid.try do |grid|
              copy_occurrence_grid_physical_rows(grid, budget)
            end
            json_object_reader = BinaryDynamicBulkJsonObjectReader.new(
              dynamic_plan,
              dynamic_streams,
              rows_per_mark,
              budget,
              profile,
              physical_rows_per_mark: physical_rows_per_mark,
              initial_descriptor_depth: typed_descriptor_root_depth,
              child_shared_profile: BinaryBulkProfile.single_stream,
            )
            complete_rows = BinaryBulkDecoder.decode(
              type,
              dynamic_streams.data,
              rows_per_mark,
              budget,
              0,
              nil,
              profile,
              dynamic_plan,
              json_object_reader,
              typed_descriptor_root_depth,
            )
            selected_group_records = selected_count.to_u64
            budget.preflight_children(selected_group_records) if selected_group_records > 0_u64
            budget.ensure_future_nodes(selected_group_records)
            budget.ensure_future_elements(selected_group_records)
            selected_group_records.times { budget.charge_node }
            budget.charge_elements(selected_group_records) if selected_group_records > 0_u64
            selected_values = Array(Array(BinaryValue)).new(selected_count)
            selected_count.times do |window_offset|
              selected_values << complete_rows[selected_first + window_offset]
            end
            typed_rows[path] = selected_values
          else
            typed_rows[path] = BinaryBulkDecoder.decode(
              type,
              dynamic_streams.data,
              rows_per_mark,
              budget,
              selected_first,
              selected_count,
              profile,
              dynamic_plan,
              nil,
              typed_descriptor_root_depth,
            )
          end
          typed_rows[path].each do |mark_values|
            mark_values.each do |value|
              ObjectDeclaredDynamicDeclaration.validate_selected_values!(
                value,
                type,
                budget,
                false,
                typed_descriptor_root_depth,
                allow_shared_json: true,
              )
            end
          end
        else
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
      end

      dynamic_rows = Hash(String, Array(Array(BinaryValue))).new
      object.dynamic_path_count.times do |dynamic_index|
        path = object.dynamic_path_at(dynamic_index)
        json_leaf_plans = root_dynamic_json_object_leaf_plans[path]? ||
                          [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)
        physical_loader : Proc(
          BinaryDynamicJsonLeafKey,
          DynamicJsonObjectBinding,
          StorageOccurrenceGrid,
          Int32,
          BinaryCodecBudget,
          Array(Array(ObjectDocument)),
        )? = if physical_root_dynamic_json_object_leaf_loader && !json_leaf_plans.empty?
          ->(key : BinaryDynamicJsonLeafKey, binding : DynamicJsonObjectBinding, grid : StorageOccurrenceGrid, json_depth : Int32, child_budget : BinaryCodecBudget) {
            physical_root_dynamic_json_object_leaf_loader.call(
              path,
              key,
              binding,
              grid,
              json_depth,
              child_budget,
            )
          }
        end
        if grid = occurrence_grid
          dynamic_rows[path] = DynamicValueCodec.decode_child_site_with_budget(
            structure_set.dynamic_for(path),
            streams.dynamic_for(path),
            grid,
            budget,
            first_mark: selected_first,
            mark_count: selected_count,
            profile: profile,
            json_object_leaf_plans: json_leaf_plans,
            inferred_actual_root_depth: inferred_actual_root_depth,
            child_shared_profile: shared_profile,
            physical_json_object_leaf_loader: physical_loader,
          )
        else
          dynamic_rows[path] = DynamicValueCodec.decode_with_budget(
            structure_set.dynamic_for(path),
            streams.dynamic_for(path),
            budget,
            first_mark: selected_first,
            mark_count: selected_count,
            profile: profile,
            json_object_leaf_plans: json_leaf_plans,
            inferred_actual_root_depth: inferred_actual_root_depth,
            child_shared_profile: shared_profile,
            physical_json_object_leaf_loader: physical_loader,
          )
        end
      end

      shared_rows = if object.shared_data_version == 0_u64
                      ObjectDocumentSharedCodec.decode_with_budget(
                        streams.shared,
                        rows_per_mark,
                        object,
                        typed_schema,
                        budget,
                        selected_first,
                        selected_count,
                        shared_profile
                      )
                    elsif object.shared_data_version == 1_u64
                      ObjectDocumentSharedBucketsCodec.decode_with_budget(
                        streams,
                        rows_per_mark,
                        object,
                        typed_schema,
                        budget,
                        selected_first,
                        selected_count,
                        shared_profile
                      )
                    else
                      decode_advanced_shared_rows_with_budget(
                        streams,
                        rows_per_mark,
                        object,
                        typed_schema,
                        budget,
                        selected_first,
                        selected_count
                      )
                    end

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

    private def self.decode_advanced_shared_rows_with_budget(
      streams : ObjectDocumentStreams,
      rows_per_mark : Array(UInt64),
      object : ObjectStructure,
      typed_schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
      first_mark : Int32,
      selected_count : Int32,
    ) : Array(Array(Array(ObjectDocumentSharedCodec::Entry)))
      unless streams.advanced_shared_mark_count == rows_per_mark.size
        corrupt!("advanced shared Object mark grid does not match the outer row grid")
      end

      row_count = 0_u64
      entry_count = 0_u64
      path_bytes = 0_u64
      rows_per_mark.size.times do |mark_index|
        expected = rows_per_mark[mark_index]
        unless streams.advanced_shared_row_count_at(mark_index).to_u64 == expected
          corrupt!("advanced shared Object rows do not match an outer mark")
        end
        next if mark_index < first_mark || mark_index >= first_mark + selected_count
        row_count = checked_add(row_count, expected, false)
        expected.to_i.times do |row_index|
          row = streams.advanced_shared_row_at(mark_index, row_index)
          row.entry_count.times do |entry_index|
            entry = row.entry_at(entry_index)
            value = entry.value
            if value.type.tag == BinaryDataType::TAG_NOTHING || value.is_null?
              corrupt!("advanced shared Object rows cannot contain top-level NULL values")
            end
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              corrupt!("advanced shared Object rows cannot contain top-level Nullable values")
            end
            if raw_path_conflicts?(entry, typed_schema, object)
              corrupt!("shared Object path overlaps a typed or Dynamic path")
            end
            entry_count = checked_add(entry_count, 1_u64, false)
            path_bytes = checked_add(path_bytes, entry.path_byte_size.to_u64, false)
          end
        end
      end

      # One output group, row array, and shared entry per retained element;
      # admit all path snapshots and container work before allocating them.
      nodes = checked_add(selected_count.to_u64, checked_add(row_count, entry_count, false), false)
      edges = checked_add(selected_count.to_u64, checked_add(row_count, entry_count, false), false)
      budget.ensure_future_nodes(nodes)
      budget.ensure_future_elements(edges)
      budget.ensure_wire_bytes(path_bytes)
      nodes.times { budget.charge_node }
      budget.charge_elements(edges)
      budget.charge_wire_bytes(path_bytes)

      output = Array(Array(Array(ObjectDocumentSharedCodec::Entry))).new(selected_count)
      selected_count.times do |mark_offset|
        mark_index = first_mark + mark_offset
        rows = Array(Array(ObjectDocumentSharedCodec::Entry)).new(streams.advanced_shared_row_count_at(mark_index))
        streams.advanced_shared_row_count_at(mark_index).times do |row_index|
          source_row = streams.advanced_shared_row_at(mark_index, row_index)
          entries = Array(ObjectDocumentSharedCodec::Entry).new(source_row.entry_count)
          source_row.entry_count.times do |entry_index|
            entry = source_row.entry_at(entry_index)
            path = String.build(entry.path_byte_size) do |io|
              entry.path_byte_size.times { |byte_index| io.write_byte(entry.path_byte_at(byte_index)) }
            end
            entries << {path, entry.value}
          end
          rows << entries
        end
        output << rows
      end
      output
    end

    private def self.reject_json_plan!(plan : ObjectDocumentPlan) : Nil
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        if plan.typed_type_for(path).contains_json?
          raise UnsupportedFormatError.new("root JSON is outside the persisted Object declaration grammar")
        end
      end
      nil
    end

    private def self.raw_path_conflicts?(
      entry : ObjectSharedMapEntry,
      typed_schema : Hash(String, BinaryDataType),
      object : ObjectStructure,
    ) : Bool
      typed_schema.each_key do |path|
        return true if raw_path_matches?(entry, path)
      end
      object.dynamic_path_count.times do |index|
        return true if raw_path_matches?(entry, object.dynamic_path_at(index))
      end
      false
    end

    private def self.raw_path_matches?(entry : ObjectSharedMapEntry, path : String) : Bool
      bytes = path.to_slice
      return false unless bytes.size == entry.path_byte_size
      bytes.size.times do |index|
        return false unless bytes[index] == entry.path_byte_at(index)
      end
      true
    end

    private def self.validate_typed_json_binding_input!(
      bindings : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))),
      typed_schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
    ) : Nil
      if bindings.size > typed_schema.size
        corrupt!("typed Dynamic JSON Object binding roster exceeds the supplied schema")
      end
      record_count = bindings.size.to_u64
      bindings.each do |_path, leaves|
        record_count = checked_add(record_count, leaves.size.to_u64, false)
      end
      unless record_count <= budget.limits.max_nodes.to_u64 && record_count <= budget.limits.max_elements.to_u64
        corrupt!("typed Dynamic JSON Object binding roster exceeds codec limits")
      end
      budget.preflight_children(record_count) if record_count > 0_u64

      path_elements = 0_u64
      key_bytes = 0_u64
      bindings.each do |path, leaves|
        unless typed_schema.has_key?(path)
          corrupt!("typed Dynamic JSON Object binding names an unknown schema field")
        end
        if leaves.empty?
          corrupt!("typed Dynamic JSON Object binding roster cannot be empty")
        end
        key_bytes = checked_add(key_bytes, path.bytesize.to_u64, false)
        leaves.each do |entry|
          key = entry[0]
          path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64, false)
          key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64, false)
          key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64, false), false)
        end
      end
      element_count = checked_add(record_count, path_elements, false)
      unless path_elements <= budget.limits.max_elements.to_u64 && key_bytes <= budget.limits.max_bytes.to_u64
        corrupt!("typed Dynamic JSON Object binding keys exceed codec limits")
      end
      budget.ensure_future_elements(element_count)
      budget.ensure_wire_bytes(key_bytes)
      record_count.times { budget.charge_node }
      budget.charge_elements(element_count) if element_count > 0_u64
      budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      nil
    end

    private def self.validate_root_json_binding_input!(
      bindings : RootDynamicJsonLeafPlans,
      object : ObjectStructure,
      budget : BinaryCodecBudget,
    ) : Nil
      if bindings.size > object.dynamic_path_count
        corrupt!("inferred Dynamic JSON Object binding roster exceeds the Object path roster")
      end
      record_count = bindings.size.to_u64
      path_bytes = 0_u64
      key_bytes = 0_u64
      path_elements = 0_u64
      bindings.each do |path, leaves|
        unless object.has_dynamic_path?(path)
          corrupt!("inferred Dynamic JSON Object binding names an unknown Dynamic path")
        end
        if leaves.empty?
          corrupt!("inferred Dynamic JSON Object binding roster cannot be empty")
        end
        path_bytes = checked_add(path_bytes, path.bytesize.to_u64, false)
        record_count = checked_add(record_count, leaves.size.to_u64, false)
        leaves.each do |entry|
          key = entry[0]
          path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64, false)
          key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64, false)
          key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64, false), false)
        end
      end
      unless record_count <= budget.limits.max_nodes.to_u64 && record_count <= budget.limits.max_elements.to_u64
        corrupt!("inferred Dynamic JSON Object binding roster exceeds codec limits")
      end
      unless path_elements <= budget.limits.max_elements.to_u64 &&
             checked_add(path_bytes, key_bytes, false) <= budget.limits.max_bytes.to_u64
        corrupt!("inferred Dynamic JSON Object binding keys exceed codec limits")
      end
      budget.preflight_children(record_count) if record_count > 0_u64
      budget.ensure_future_elements(checked_add(record_count, path_elements, false))
      budget.ensure_wire_bytes(checked_add(path_bytes, key_bytes, false))
      record_count.times { budget.charge_node }
      budget.charge_elements(checked_add(record_count, path_elements, false)) if record_count > 0_u64 || path_elements > 0_u64
      key_and_path_bytes = checked_add(path_bytes, key_bytes, false)
      budget.charge_wire_bytes(key_and_path_bytes) if key_and_path_bytes > 0_u64
      nil
    end

    # A nested Object's generic JSON reader consumes logical row counts (Q),
    # while the child Object codec and its row marks belong to the inherited
    # physical parent domain (P). The detached vector is another retained
    # operation allocation, so account it without changing the shared budget.
    private def self.copy_occurrence_grid_physical_rows(
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      count = grid.mark_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      rows = Array(UInt64).new(grid.mark_count)
      grid.mark_count.times do |mark|
        budget.charge_node
        budget.charge_elements(1_u64)
        rows << grid.physical_rows_at(mark)
      end
      rows
    end

    private def self.validate_low_cardinality_typed_field!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int = 2,
    ) : Nil
      if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type) &&
         ObjectRecursiveDeclaration.measure_descriptor(type, limits, root_depth).nil?
        raise UnsupportedFormatError.new("Object typed LowCardinality fields are not admitted")
      end
      nil
    end

    private def self.validate_variant_typed_field!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      root_depth : Int = 2,
    ) : Nil
      if type.contains_variant? && ObjectRecursiveDeclaration.measure_descriptor(type, limits, root_depth).nil?
        raise UnsupportedFormatError.new("Object typed Variant descriptor is outside the admitted declaration grammar")
      end
      nil
    end

    private def self.validate_write_structure(structure_set : ObjectDynamicStructureSet) : Nil
      object = structure_set.object
      ObjectSharedBucketLayout.validate!(object)
      unless structure_set.dynamic_count == object.dynamic_path_count
        raise UnsupportedFormatError.new("Dynamic structure set does not match Object metadata")
      end
      nil
    end

    private def self.validate_read_structure(structure_set : ObjectDynamicStructureSet) : Nil
      object = structure_set.object
      ObjectSharedBucketLayout.validate!(object)
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
