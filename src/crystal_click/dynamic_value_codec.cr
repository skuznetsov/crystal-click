module CrystalClick
  # Paired logical-value codec for the admitted Dynamic V3 discriminator and
  # decompressed bulk-arm profile. Physical compression and outer mark parsing
  # remain the responsibility of the storage adapter.
  class DynamicValueCodec
    DEFAULT_LIMITS = BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1_000_000,
      max_elements: 3_000_000,
      max_bytes: 64 * 1024 * 1024
    )

    NULL_TAG = DynamicDiscriminatorCodec::NULL_TAG

    def self.encode(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      mode : UInt64 = DynamicDiscriminatorCodec::DEFAULT_MODE,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
    ) : DynamicValueStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(
        structure,
        granules,
        budget,
        mode: mode,
        profile: profile,
        json_object_leaf_plans: json_object_leaf_plans,
        inferred_actual_root_depth: inferred_actual_root_depth,
        child_shared_profile: child_shared_profile,
      )
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. The same budget flows through discriminator, all arm
    # codecs, and every typed SharedVariant envelope.
    def self.encode_with_budget(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      mode : UInt64 = DynamicDiscriminatorCodec::DEFAULT_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
    ) : DynamicValueStreams
      encode_core_with_budget(
        structure,
        granules,
        budget,
        mode,
        profile,
        nil,
        json_object_leaf_plans,
        inferred_actual_root_depth,
        child_shared_profile,
      )
    end

    # Child-site entry point. Zero-length granules are accepted only when
    # their logical counts are supplied by an immutable occurrence grid; all
    # arm codecs continue to share the caller's budget.
    def self.encode_child_site_with_budget(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
    ) : DynamicValueStreams
      encode_core_with_budget(
        structure,
        granules,
        budget,
        mode,
        profile,
        grid,
        json_object_leaf_plans,
        inferred_actual_root_depth,
        child_shared_profile,
      )
    end

    private def self.encode_core_with_budget(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      mode : UInt64,
      profile : BinaryBulkProfile,
      occurrence_grid : StorageOccurrenceGrid?,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      inferred_actual_root_depth : Int32,
      child_shared_profile : BinaryBulkProfile,
    ) : DynamicValueStreams
      unless budget.writing?
        raise ArgumentError.new("Dynamic value encode requires a writing budget")
      end
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end
      if grid = occurrence_grid
        grid.validate_for!(granules.size, budget)
      end

      real_marks = checked_mark_count(granules.size, budget)
      variant_count = structure.canonical_variant_count.to_u64
      mark_records = real_marks + 1_u64
      budget.ensure_depth(inferred_actual_root_depth)
      # Validate the complete descriptor tree before cached recursive shape
      # summaries such as contains_json? inspect it. JSON is provisionally
      # allowed here; exact ordinary-arm ownership is checked by the roster.
      validate_descriptor_trees(
        structure,
        budget,
        inferred_actual_root_depth,
        allow_json: !json_object_leaf_plans.empty?,
      )
      json_roster = if has_json_actual?(structure) || !json_object_leaf_plans.empty?
                      DynamicJsonObjectBindingRoster.for_root(
                        structure,
                        json_object_leaf_plans,
                        budget,
                        inferred_actual_root_depth,
                      )
                    else
                      nil
                    end
      total_rows = 0_u64
      granules.each_with_index do |granule, mark_index|
        if granule.empty? && occurrence_grid.nil?
          raise ArgumentError.new("Dynamic value real granules must contain rows")
        end
        if grid = occurrence_grid
          unless granule.size.to_u64 == grid.logical_occurrences_at(mark_index)
            raise UnsupportedFormatError.new("Dynamic child rows disagree with the occurrence grid")
          end
        end
        if granule.size > Int32::MAX
          raise UnsupportedFormatError.new("Dynamic mark row count exceeds the supported domain")
        end
        rows = granule.size.to_u64
        if total_rows > UInt64::MAX - rows
          raise UnsupportedFormatError.new("Dynamic value row count overflows UInt64")
        end
        total_rows += rows
      end

      # Validate value and roster descriptors before name-based routing. The
      # encoder's historical budget contract charges descriptor traversal but
      # not SQL display-name materialization.
      validate_value_descriptor_trees(granules, budget, inferred_actual_root_depth)

      # The discriminator will charge these same logical records and edges.
      # This early lower bound protects the tag matrix from being the first
      # count-derived allocation that discovers an impossible operation.
      preflight_discriminator_work(budget, mark_records, real_marks, total_rows, variant_count)

      variant_names = structure.canonical_variant_names
      routes = Hash(String, Tuple(BinaryDataType, UInt8)).new
      structure.type_count.times do |index|
        type = structure.type_at(index)
        name = type.name
        canonical_index = variant_names.index(name) || raise UnsupportedFormatError.new("Dynamic type is absent from its canonical roster")
        routes[name] = {type, canonical_index.to_u8}
      end
      shared_index = structure.shared_index
      ordinary_types = Array(BinaryDataType?).new(variant_names.size, nil)
      routes.each_value do |route|
        type, canonical_index = route
        ordinary_types[canonical_index] = type
      end

      tags = Array(Array(UInt8)).new(granules.size)
      granules.each do |granule|
        mark_tags = Array(UInt8).new(granule.size)
        granule.each do |value|
          type = value.type
          if type.tag == BinaryDataType::TAG_NOTHING
            unless value.is_null?
              raise UnsupportedFormatError.new("top-level Nothing is admitted only as Dynamic NULL")
            end
            mark_tags << NULL_TAG
          elsif type.tag == BinaryDataType::TAG_NULLABLE
            raise UnsupportedFormatError.new("top-level Nullable is outside the Dynamic V3 canonical profile")
          else
            name = type.name
            mark_tags << route_index(type, name, routes, shared_index.to_u8)
          end
        end
        tags << mark_tags
      end

      discriminator = if grid = occurrence_grid
                        DynamicDiscriminatorCodec.encode_child_site_with_budget(
                          structure, tags, grid, budget, mode: mode
                        )
                      else
                        DynamicDiscriminatorCodec.encode_with_budget(structure, tags, budget, mode: mode)
                      end
      arms = Hash(String, BinaryBulkStreams).new

      # SharedVariant is emitted first so its aggregate envelope framing can
      # be preflighted before retaining any encoded String copies. Other arms
      # are independent lanes, emitted in canonical order below.
      shared_name = DynamicStructure::SHARED_VARIANT_NAME
      json_object_leaf_streams = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new
      shared_streams = encode_arm(
        granules,
        tags,
        shared_index,
        ordinary_types[shared_index],
        shared_name,
        budget,
        profile,
        child_shared_profile,
        occurrence_grid,
        inferred_actual_root_depth,
        json_roster,
        json_object_leaf_streams,
      )
      arms[shared_name] = shared_streams

      variant_names.each_with_index do |name, arm_index|
        next if arm_index == shared_index
        type = ordinary_types[arm_index] || raise UnsupportedFormatError.new("Dynamic canonical arm has no descriptor")
        arm_streams = encode_arm(
          granules,
          tags,
          arm_index,
          type,
          name,
          budget,
          profile,
          child_shared_profile,
          occurrence_grid,
          inferred_actual_root_depth,
          json_roster,
          json_object_leaf_streams,
        )
        arms[name] = arm_streams
      end

      DynamicValueStreams.new(
        discriminator,
        arms,
        budget: budget,
        json_object_leaf_streams: json_object_leaf_streams,
      )
    end

    def self.decode(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
      physical_json_object_leaf_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32,
        BinaryCodecBudget, Array(Array(ObjectDocument)),
      )? = nil,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(
        structure,
        streams,
        budget,
        first_mark: first_mark,
        mark_count: mark_count,
        profile: profile,
        json_object_leaf_plans: json_object_leaf_plans,
        inferred_actual_root_depth: inferred_actual_root_depth,
        child_shared_profile: child_shared_profile,
        physical_json_object_leaf_loader: physical_json_object_leaf_loader,
      )
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. All selected arm values and envelopes are validated
    # before any logical rows are returned.
    def self.decode_with_budget(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
      physical_json_object_leaf_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32,
        BinaryCodecBudget, Array(Array(ObjectDocument)),
      )? = nil,
    ) : Array(Array(BinaryValue))
      decode_core_with_budget(
        structure,
        streams,
        budget,
        first_mark,
        mark_count,
        profile,
        nil,
        json_object_leaf_plans,
        inferred_actual_root_depth,
        child_shared_profile,
        physical_json_object_leaf_loader,
      )
    end

    # Child-site decoder that validates its complete physical/logical mark grid
    # even when the requested window contains no marks.
    def self.decode_child_site_with_budget(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)) = [] of Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan),
      inferred_actual_root_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
      physical_json_object_leaf_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32,
        BinaryCodecBudget, Array(Array(ObjectDocument)),
      )? = nil,
    ) : Array(Array(BinaryValue))
      decode_core_with_budget(
        structure,
        streams,
        budget,
        first_mark,
        mark_count,
        profile,
        grid,
        json_object_leaf_plans,
        inferred_actual_root_depth,
        child_shared_profile,
        physical_json_object_leaf_loader,
      )
    end

    private def self.decode_core_with_budget(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
      occurrence_grid : StorageOccurrenceGrid?,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      inferred_actual_root_depth : Int32,
      child_shared_profile : BinaryBulkProfile,
      physical_json_object_leaf_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32,
        BinaryCodecBudget, Array(Array(ObjectDocument)),
      )?,
    ) : Array(Array(BinaryValue))
      if budget.writing?
        raise ArgumentError.new("Dynamic value decode requires a reading budget")
      end

      if inferred_actual_root_depth <= 0 || inferred_actual_root_depth > budget.limits.max_depth
        corrupt!("inferred Dynamic actual root depth exceeds the configured limit")
      end

      # Reject unbound JSON and validate the complete bound descriptor roster
      # before inspecting the stream's mark grid. The type-tree walk is bounded
      # at the inherited origin before cached shape summaries are consulted.
      validate_descriptor_trees(
        structure,
        budget,
        inferred_actual_root_depth,
        allow_json: !json_object_leaf_plans.empty?,
      )
      variant_count = structure.canonical_variant_count
      has_json_actual = has_json_actual?(structure)
      if physical_json_object_leaf_loader && !has_json_actual
        corrupt!("physical Dynamic JSON Object loader has no bound JSON actual leaves")
      end
      json_roster = if has_json_actual || !json_object_leaf_plans.empty? || streams.json_object_leaf_count > 0 || !physical_json_object_leaf_loader.nil?
                      DynamicJsonObjectBindingRoster.for_root(
                        structure,
                        json_object_leaf_plans,
                        budget,
                        inferred_actual_root_depth,
                      )
                    else
                      nil
                    end

      mark_records = streams.discriminators.mark_count
      if mark_records == 0
        corrupt!("Dynamic discriminator mark grid has no terminal mark")
      end
      if grid = occurrence_grid
        grid.validate_for!(mark_records - 1, budget)
      end

      if streams.arm_count != variant_count
        corrupt!("Dynamic arm set does not match the canonical roster")
      end
      budget.ensure_future_nodes(variant_count.to_u64)
      budget.ensure_future_elements(variant_count.to_u64)
      variant_names = structure.canonical_variant_names
      variant_names.each do |name|
        unless streams.has_arm?(name)
          corrupt!("Dynamic arm set is missing a canonical lane")
        end
      end

      real_marks = mark_records - 1
      expected_leaf_keys = json_roster.try(&.json_object_leaf_keys(budget)) || [] of BinaryDynamicJsonLeafKey
      has_json_bindings = !expected_leaf_keys.empty?
      if physical_json_object_leaf_loader
        unless streams.json_object_leaf_count == 0
          corrupt!("physical Dynamic JSON child reader cannot mix normalized and physical Object streams")
        end
      elsif expected_leaf_keys.empty?
        if streams.json_object_leaf_count != 0
          corrupt!("Dynamic JSON Object child keys do not exactly match the bound actual leaves")
        end
      elsif !same_leaf_key_roster?(expected_leaf_keys, streams.json_object_leaf_keys(budget))
        corrupt!("Dynamic JSON Object child keys do not exactly match the bound actual leaves")
      end
      selected_first, selected_count = validate_selection(first_mark, mark_count, real_marks)
      full_schedules = [] of DynamicMarkSchedule
      selected_schedules = if has_json_bindings
                             full_schedules = if grid = occurrence_grid
                                                DynamicDiscriminatorCodec.decode_child_site_with_budget(
                                                  structure,
                                                  streams.discriminators,
                                                  grid,
                                                  budget,
                                                  first_mark: 0,
                                                  mark_count: real_marks,
                                                )
                                              else
                                                DynamicDiscriminatorCodec.decode_with_budget(
                                                  structure,
                                                  streams.discriminators,
                                                  budget,
                                                  first_mark: 0,
                                                  mark_count: real_marks,
                                                )
                                              end
                             slice_schedules(full_schedules, selected_first, selected_count, budget)
                           else
                             if grid = occurrence_grid
                               DynamicDiscriminatorCodec.decode_child_site_with_budget(
                                 structure,
                                 streams.discriminators,
                                 grid,
                                 budget,
                                 first_mark: first_mark,
                                 mark_count: mark_count,
                               )
                             else
                               DynamicDiscriminatorCodec.decode_with_budget(
                                 structure,
                                 streams.discriminators,
                                 budget,
                                 first_mark: first_mark,
                                 mark_count: mark_count,
                               )
                             end
                           end
      selected_marks = selected_schedules.size
      shared_index = structure.shared_index

      # The generic arm decoder expects one count per physical mark. For
      # ordinary arms, selected-window schedules populate their absolute mark
      # slots and leave unselected counts at zero; JSON arms are decoded over
      # the complete domain above so all bound child rows and unused marks are
      # validated before the requested window is returned.
      budget.ensure_future_nodes(variant_count.to_u64)
      budget.ensure_future_elements(variant_count.to_u64)
      decoded_arms = Array(Array(Array(BinaryValue))).new(variant_count)
      shared_string = BinaryDataType.primitive("String")
      variant_names.each_with_index do |name, arm_index|
        type = if arm_index == shared_index
                 shared_string
               else
                 type_for_name(structure, name) || corrupt_type!("Dynamic canonical arm has no descriptor")
               end
        budget.ensure_future_nodes(real_marks.to_u64)
        budget.ensure_future_elements(real_marks.to_u64)
        arm_depth_origin = if arm_index == shared_index
                             1
                           else
                             inferred_actual_root_depth
                           end
        arm_rows = if has_json_bindings && type.contains_json?
                     rows_per_mark = arm_rows_per_mark(full_schedules, arm_index, real_marks, budget)
                     root_key = BinaryDynamicJsonLeafKey.new("root", arm_index, [] of Int32)
                     child_leaf_streams = if physical_json_object_leaf_loader
                                            Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new
                                          else
                                            streams.json_object_leaf_streams_for_arm(arm_index, budget)
                                          end
                     physical_rows = physical_rows_per_mark(occurrence_grid, streams.discriminators, real_marks, budget)
                     reader = BinaryDynamicBulkJsonObjectReader.for_root(
                       json_roster.not_nil!,
                       budget,
                       type,
                       arm_index,
                       streams.arm(name),
                       rows_per_mark,
                       child_leaf_streams,
                       profile,
                       physical_rows,
                       physical_json_object_leaf_loader,
                       inferred_actual_root_depth,
                       child_shared_profile,
                     )
                     all_arm_rows = BinaryBulkCodec.decode_with_budget(
                       type,
                       streams.arm(name),
                       rows_per_mark,
                       budget,
                       first_mark: 0,
                       mark_count: real_marks,
                       profile: profile,
                       json_object_reader: reader,
                       json_leaf_key: root_key,
                       shared_value_depth_origin: inferred_actual_root_depth,
                     )
                     slice_rows(all_arm_rows, selected_first, selected_count, budget)
                   else
                     rows_per_mark = arm_rows_per_mark(selected_schedules, arm_index, real_marks, budget)
                     BinaryBulkCodec.decode_with_budget(
                       type,
                       streams.arm(name),
                       rows_per_mark,
                       budget,
                       first_mark: selected_first,
                       mark_count: selected_count,
                       profile: profile,
                       shared_value_depth_origin: arm_depth_origin,
                     )
                   end
        if arm_rows.size != selected_marks
          corrupt!("Dynamic bulk arm selection disagrees with discriminator schedules")
        end
        decoded_arms << arm_rows
      end

      shared_rows = decoded_arms[shared_index]
      budget.ensure_future_nodes(selected_marks.to_u64)
      budget.ensure_future_elements(selected_marks.to_u64)
      logical_shared_rows = Array(Array(BinaryValue)).new(selected_marks)
      selected_marks.times do |mark_index|
        envelope_values = shared_rows[mark_index]
        budget.ensure_future_nodes(envelope_values.size.to_u64)
        budget.ensure_future_elements(envelope_values.size.to_u64)
        logical_values = Array(BinaryValue).new(envelope_values.size)
        envelope_values.each do |envelope|
          unless envelope.type.tag == BinaryDataType::TAG_STRING
            corrupt!("SharedVariant bulk lane did not decode as String")
          end
          logical = BinaryValueCodec.decode_borrowed(envelope.bytes, budget)
          if logical.type.tag == BinaryDataType::TAG_NOTHING || logical.type.tag == BinaryDataType::TAG_NULLABLE || logical.type.contains_json?
            corrupt!("top-level Nothing, Nullable, and JSON SharedVariant envelopes are outside the canonical profile")
          end
          logical_values << logical
        end
        logical_shared_rows << logical_values
      end
      decoded_arms[shared_index] = logical_shared_rows

      total_rows = 0_u64
      selected_schedules.each do |schedule|
        rows = streams.discriminators.mark_at(schedule.mark_index).rows
        if total_rows > UInt64::MAX - rows
          corrupt!("Dynamic selected row count overflows UInt64")
        end
        total_rows += rows
      end
      if total_rows > UInt64::MAX - selected_marks.to_u64 - 1_u64
        corrupt!("Dynamic selected assembly node count overflows UInt64")
      end
      budget.ensure_future_nodes(1_u64 + selected_marks.to_u64 + total_rows)
      budget.ensure_future_elements(selected_marks.to_u64 + total_rows)
      budget.visit_node(1)

      result = Array(Array(BinaryValue)).new(selected_marks)
      selected_schedules.each_with_index do |schedule, selected_index|
        row_count = schedule.row_count
        if schedule.rank_count != row_count
          corrupt!("Dynamic selected rank vector does not match its tags")
        end
        if schedule.variant_count != variant_count
          corrupt!("Dynamic selected schedule variant width is inconsistent")
        end
        budget.charge_node
        budget.charge_elements(1_u64)
        mark_values = Array(BinaryValue).new(row_count)
        row_count.times do |row_index|
          budget.charge_node
          tag = schedule.tag_at(row_index)
          if tag == NULL_TAG
            mark_values << BinaryValue.null
            next
          end
          arm_index = tag.to_i32
          if arm_index < 0 || arm_index >= variant_count
            corrupt!("Dynamic row tag is outside the canonical roster")
          end
          rank = schedule.rank_at(row_index) || corrupt_rank!("non-NULL Dynamic row has no arm rank")
          lane = decoded_arms[arm_index][selected_index]
          if rank < 0 || rank >= lane.size
            corrupt!("Dynamic row rank is outside its selected arm mark")
          end
          mark_values << lane[rank]
        end
        budget.charge_elements(row_count.to_u64)
        result << mark_values
      end
      result
    end

    private def self.validate_selection(
      first_mark : Int,
      mark_count : Int?,
      real_marks : Int32,
    ) : {Int32, Int32}
      first = first_mark.to_i128
      marks = real_marks.to_i128
      if first < 0_i128 || first > marks
        corrupt!("Dynamic selected mark range is outside the real grid")
      end
      count = mark_count.try(&.to_i128) || (marks - first)
      if count < 0_i128 || count > marks - first
        corrupt!("Dynamic selected mark range is outside the real grid")
      end
      {first.to_i32, count.to_i32}
    end

    private def self.same_leaf_key_roster?(
      expected : Array(BinaryDynamicJsonLeafKey),
      actual : Array(BinaryDynamicJsonLeafKey),
    ) : Bool
      expected == actual
    end

    # The discriminator decoder returns detached selected/full schedule rows;
    # keep absolute mark coordinates intact while retaining only the requested
    # outer range for final assembly.
    private def self.slice_schedules(
      schedules : Array(DynamicMarkSchedule),
      first_mark : Int32,
      mark_count : Int32,
      budget : BinaryCodecBudget,
    ) : Array(DynamicMarkSchedule)
      if first_mark < 0 || mark_count < 0 || first_mark > schedules.size || mark_count > schedules.size - first_mark
        corrupt!("Dynamic selected schedules are outside the validated mark domain")
      end
      count = mark_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64
      Array(DynamicMarkSchedule).new(mark_count) do |offset|
        schedule = schedules[first_mark + offset]
        unless schedule.mark_index == first_mark + offset
          corrupt!("Dynamic schedule mark coordinates are not contiguous")
        end
        schedule
      end
    end

    private def self.slice_rows(
      rows : Array(Array(BinaryValue)),
      first_mark : Int32,
      mark_count : Int32,
      budget : BinaryCodecBudget,
    ) : Array(Array(BinaryValue))
      if first_mark < 0 || mark_count < 0 || first_mark > rows.size || mark_count > rows.size - first_mark
        corrupt!("Dynamic arm rows are outside the validated mark domain")
      end
      count = mark_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64
      Array(Array(BinaryValue)).new(mark_count) do |offset|
        rows[first_mark + offset]
      end
    end

    # Build BinaryBulkDecoder's full physical mark vector from schedules. A
    # selected-only schedule has nonzero counts only at its absolute selected
    # marks; full JSON-arm schedules cover every real mark.
    private def self.arm_rows_per_mark(
      schedules : Array(DynamicMarkSchedule),
      arm_index : Int32,
      real_marks : Int32,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      if arm_index < 0 || real_marks < 0
        corrupt!("Dynamic arm schedule dimensions are outside the supported domain")
      end
      count = real_marks.to_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64
      rows = Array(UInt64).new(real_marks, 0_u64)
      previous_mark = -1
      schedules.each do |schedule|
        mark_index = schedule.mark_index
        if mark_index <= previous_mark || mark_index < 0 || mark_index >= real_marks
          corrupt!("Dynamic arm schedules do not identify unique real marks")
        end
        if arm_index >= schedule.variant_count
          corrupt!("Dynamic arm schedule width is smaller than the canonical roster")
        end
        row_count = schedule.arm_count_at(arm_index)
        if row_count > schedule.row_count.to_u64
          corrupt!("Dynamic arm count exceeds its discriminator mark")
        end
        rows[mark_index] = row_count
        previous_mark = mark_index
      end
      rows
    end

    # Physical P is inherited from the enclosing storage site when present;
    # without a parent grid, each discriminator mark's row count is P. It is
    # intentionally distinct from the per-arm Dynamic Q vector.
    private def self.physical_rows_per_mark(
      occurrence_grid : StorageOccurrenceGrid?,
      discriminators : DynamicDiscriminatorStream,
      real_marks : Int32,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      unless real_marks >= 0 && discriminators.mark_count == real_marks + 1
        corrupt!("Dynamic physical row grid does not match the discriminator marks")
      end
      count = real_marks.to_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64
      if grid = occurrence_grid
        unless grid.mark_count == real_marks
          corrupt!("Dynamic parent physical row grid does not match the discriminator marks")
        end
        Array(UInt64).new(real_marks) do |mark_index|
          grid.physical_rows_at(mark_index)
        end
      else
        Array(UInt64).new(real_marks) do |mark_index|
          discriminators.mark_at(mark_index).rows
        end
      end
    end

    private def self.encode_arm(
      granules : Array(Array(BinaryValue)),
      tags : Array(Array(UInt8)),
      arm_index : Int32,
      type : BinaryDataType?,
      name : String,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      child_shared_profile : BinaryBulkProfile,
      occurrence_grid : StorageOccurrenceGrid?,
      inferred_actual_root_depth : Int32,
      json_roster : DynamicJsonObjectBindingRoster?,
      json_object_leaf_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
    ) : BinaryBulkStreams
      arm_type = type || BinaryDataType.primitive("String")
      mark_count = granules.size
      arm_rows = 0_u64
      shared = name == DynamicStructure::SHARED_VARIANT_NAME
      json_arm = !shared && arm_type.contains_json?
      arm_rows_per_mark = if json_arm
                            Array(UInt64).new(mark_count, 0_u64)
                          else
                            [] of UInt64
                          end
      granules.each_with_index do |granule, mark_index|
        granule.each_with_index do |_value, row_index|
          if tags[mark_index][row_index] == arm_index.to_u8
            arm_rows += 1_u64
            arm_rows_per_mark[mark_index] += 1_u64 if json_arm
          end
        end
      end
      budget.ensure_future_nodes(mark_count.to_u64 + arm_rows)
      budget.ensure_future_elements(mark_count.to_u64 + arm_rows)

      lane_granules = Array(Array(BinaryValue)).new(mark_count) do
        [] of BinaryValue
      end
      pending_frame_bytes = 0_u64
      granules.each_with_index do |granule, mark_index|
        granule.each_with_index do |value, row_index|
          next unless tags[mark_index][row_index] == arm_index.to_u8
          if shared
            if value.type.tag == BinaryDataType::TAG_NOTHING
              # Dynamic Nothing NULL is tag 255 and never has a child lane.
              corrupt!("Dynamic NULL tag was incorrectly assigned to SharedVariant")
            end
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              raise UnsupportedFormatError.new("top-level Nullable cannot be emitted as SharedVariant")
            end
            if value.type.contains_json?
              raise UnsupportedFormatError.new("JSON values cannot be emitted through the SharedVariant arm")
            end
            minimum_frame_overhead = profile.with_size_stream? ? 8_u64 : 1_u64
            if pending_frame_bytes > UInt64::MAX - minimum_frame_overhead
              raise UnsupportedFormatError.new("Dynamic SharedVariant reservation overflows UInt64")
            end
            reserved_wire_bytes = pending_frame_bytes + minimum_frame_overhead
            envelope = BinaryValueCodec.encode_borrowed(
              value,
              budget,
              reserved_wire_bytes: reserved_wire_bytes,
            )
            frame_size = if profile.with_size_stream?
                           8_u64 + envelope.size.to_u64
                         else
                           var_uint_size(envelope.size.to_u64) + envelope.size.to_u64
                         end
            if pending_frame_bytes > UInt64::MAX - frame_size
              raise UnsupportedFormatError.new("Dynamic SharedVariant framed byte count overflows UInt64")
            end
            pending_frame_bytes += frame_size
            budget.ensure_wire_bytes(pending_frame_bytes)
            lane_granules[mark_index] << BinaryValue.string(String.new(envelope))
          else
            lane_granules[mark_index] << value
          end
        end
      end

      if json_arm
        roster = json_roster || raise(UnsupportedFormatError.new("bound Dynamic JSON actual has no Object child roster"))
        root_key = BinaryDynamicJsonLeafKey.new("root", arm_index, [] of Int32)
        arm_grid = arm_occurrence_grid(granules, arm_rows_per_mark, occurrence_grid, budget)
        writer = BinaryDynamicBulkJsonObjectWriter.for_root(
          roster,
          budget,
          lane_granules,
          arm_type,
          arm_index,
          arm_grid,
          inferred_actual_root_depth,
        )
        encoded = BinaryBulkCodec.encode_with_budget(
          arm_type,
          lane_granules,
          budget,
          profile: profile,
          json_object_writer: writer,
          json_leaf_key: root_key,
          shared_value_depth_origin: inferred_actual_root_depth,
        )
        writer.finish_leaf_streams(profile, child_shared_profile).each do |key, child_streams|
          if json_object_leaf_streams.has_key?(key)
            raise UnsupportedFormatError.new("Dynamic JSON Object child key was emitted by more than one arm")
          end
          json_object_leaf_streams[key] = child_streams
        end
        encoded
      else
        if shared
          BinaryBulkCodec.encode_with_budget(arm_type, lane_granules, budget, profile: profile)
        else
          BinaryBulkCodec.encode_with_budget(
            arm_type,
            lane_granules,
            budget,
            profile: profile,
            shared_value_depth_origin: inferred_actual_root_depth,
          )
        end
      end
    end

    private def self.arm_occurrence_grid(
      granules : Array(Array(BinaryValue)),
      arm_rows_per_mark : Array(UInt64),
      occurrence_grid : StorageOccurrenceGrid?,
      budget : BinaryCodecBudget,
    ) : StorageOccurrenceGrid
      unless granules.size == arm_rows_per_mark.size
        raise UnsupportedFormatError.new("Dynamic arm occurrence grid has an invalid mark count")
      end
      physical_rows = Array(UInt64).new(granules.size)
      if parent_grid = occurrence_grid
        unless parent_grid.mark_count == granules.size
          raise UnsupportedFormatError.new("Dynamic parent occurrence grid has an invalid mark count")
        end
        granules.size.times do |mark_index|
          physical_rows << parent_grid.physical_rows_at(mark_index)
        end
      else
        granules.each do |rows|
          physical_rows << rows.size.to_u64
        end
      end
      StorageOccurrenceGrid.new(physical_rows, arm_rows_per_mark, budget)
    end

    private def self.type_for_name(structure : DynamicStructure, name : String) : BinaryDataType?
      structure.type_count.times do |index|
        type = structure.type_at(index)
        return type if type.name == name
      end
      nil
    end

    private def self.has_json_actual?(structure : DynamicStructure) : Bool
      structure.type_count.times do |index|
        return true if structure.type_at(index).contains_json?
      end
      false
    end

    # Shared route decision used by encoding and fresh Object/Dynamic
    # statistics. The caller renders the name under its own accounting policy.
    def self.route_index(
      type : BinaryDataType,
      name : String,
      routes : Hash(String, Tuple(BinaryDataType, UInt8)),
      shared_index : UInt8,
    ) : UInt8
      if route = routes[name]?
        route[0] == type ? route[1] : shared_index
      else
        shared_index
      end
    end

    private def self.validate_descriptor_trees(
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32,
      allow_json : Bool = false,
    ) : Nil
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      structure.type_count.times do |index|
        type = structure.type_at(index)
        context.validate_type_tree(type, inferred_actual_root_depth)
        if type.contains_json? && !allow_json
          raise UnsupportedFormatError.new("JSON is not admitted as an unbound Dynamic actual type")
        end
        if type.contains_dynamic?
          raise UnsupportedFormatError.new("recursive Dynamic alternatives are not admitted in Dynamic V3")
        end
        if type.contains_variant?
          raise UnsupportedFormatError.new("Variant-containing alternatives are not admitted in Dynamic V3")
        end
        if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
          raise UnsupportedFormatError.new("Dynamic ordinary LowCardinality alternatives are not admitted")
        end
      end
      nil
    end

    private def self.validate_value_descriptor_trees(
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32,
    ) : Nil
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      granules.each do |granule|
        granule.each do |value|
          context.validate_type_tree(value.type, inferred_actual_root_depth)
          if value.type.contains_dynamic?
            raise UnsupportedFormatError.new("Dynamic values are outside the admitted Dynamic value profile")
          end
          if value.type.contains_variant?
            raise UnsupportedFormatError.new("Variant-containing values are outside the admitted Dynamic value profile")
          end
        end
      end
      nil
    end

    private def self.preflight_discriminator_work(
      budget : BinaryCodecBudget,
      mark_records : UInt64,
      real_marks : UInt64,
      rows : UInt64,
      variants : UInt64,
    ) : Nil
      if mark_records > UInt64::MAX - rows - 1_u64
        raise UnsupportedFormatError.new("Dynamic discriminator node count overflows UInt64")
      end
      budget.ensure_future_nodes(1_u64 + mark_records + rows)

      if real_marks > (UInt64::MAX - 1_u64) // 2_u64
        raise UnsupportedFormatError.new("Dynamic discriminator mark metadata overflows UInt64")
      end
      metadata_marks = (2_u64 * real_marks) + 1_u64
      if variants > 0_u64 && metadata_marks > (UInt64::MAX - mark_records) // variants
        raise UnsupportedFormatError.new("Dynamic discriminator roster edge count overflows UInt64")
      end
      if rows > (UInt64::MAX - mark_records - metadata_marks * variants) // 2_u64
        raise UnsupportedFormatError.new("Dynamic discriminator row edge count overflows UInt64")
      end
      budget.ensure_future_elements(mark_records + (2_u64 * rows) + (metadata_marks * variants))
    end

    private def self.checked_mark_count(count : Int, budget : BinaryCodecBudget) : UInt64
      if count < 0 || count >= Int32::MAX
        raise UnsupportedFormatError.new("Dynamic mark count exceeds the supported domain")
      end
      budget.ensure_future_nodes(count.to_u64 + 2_u64)
      count.to_u64
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    private def self.corrupt_type!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    private def self.corrupt_rank!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
