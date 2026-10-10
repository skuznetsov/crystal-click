module CrystalClick
  # Production-role composition from normalized Object documents to complete
  # unpublished compressed `.bin`/`.mrk2` pairs.
  module ObjectDocumentColumnWriter
    MAX_FILE_NAME_BYTES = PartChecksums::MAX_NAME_BYTES

    def self.encode(
      column_name : String,
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32 = 1,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : ObjectDocumentColumnFiles
      if granules.empty?
        raise ArgumentError.new("a physical Object column requires at least one real mark")
      end
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("frame size must be a positive Int32 value")
      end
      if frame_bytes < DynamicDiscriminatorCodec::HEADER_BYTES.to_i
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      unless shared_target_chunk_rows > 0
        raise ArgumentError.new("Object shared advanced target chunk rows must be positive")
      end

      # The descriptor/value roster is unchanged by fresh statistics, so bind
      # and validate every physical name before W123 creates proportional lane
      # byte streams. Statistics themselves then share W123's write budget.
      physical_plan = ObjectDocumentPhysicalPlan.new(
        column_name,
        plan,
        profile,
        shared_profile,
        limits
      )
      file_roster = preflight_file_roster(physical_plan, hashed)

      write_codec_budget = codec_budget || BinaryCodecBudget.new(limits, true)
      validate_write_codec_budget!(write_codec_budget, limits)
      write_transport_budget = transport_budget || CompressedStreamBudget.new(transport_limits, true)
      validate_write_transport_budget!(write_transport_budget, transport_limits)
      fresh_plan = ObjectDocumentStatistics.recompute_with_budget(plan, granules, write_codec_budget)

      # Statistics and value traversal share exactly one logical write budget.
      streams = ObjectDocumentCodec.encode_with_budget(
        fresh_plan,
        granules,
        write_codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )

      # Variant and typed-Dynamic discriminators acquire physical framing
      # only at the column boundary. Admit added headers, COMPACT bodies, and
      # coordinate rebasing before constructing any adapted lane buffer.
      preflight_variant_prefixes!(physical_plan, fresh_plan, streams, write_codec_budget)
      lanes = bind_lanes(physical_plan, fresh_plan, streams)
      mark_count = streams.mark_count + 1
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_count, frame_bytes, write_transport_budget)

      # This is the first K-sized row-grid copy in physical composition, and it
      # follows the aggregate frame/mark/byte admission above.
      rows_per_mark = streams.rows_per_mark
      pairs = Hash(String, CompressedMarkFiles).new
      lanes.each do |lane|
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, write_transport_budget)
      end
      append_advanced_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        write_codec_budget, write_transport_budget, frame_bytes, profile,
        shared_json_policy, shared_target_chunk_rows
      )
      ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        write_codec_budget, write_transport_budget, frame_bytes, profile
      )
      ObjectDocumentRootDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        write_codec_budget, write_transport_budget, frame_bytes, profile
      )

      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
    end

    private def self.validate_write_codec_budget!(budget : BinaryCodecBudget, limits : BinaryCodecLimits) : Nil
      unless budget.writing? && budget.limits.max_depth == limits.max_depth &&
             budget.limits.max_nodes == limits.max_nodes &&
             budget.limits.max_elements == limits.max_elements &&
             budget.limits.max_bytes == limits.max_bytes
        raise ArgumentError.new("Object writer requires a compatible write codec budget")
      end
      nil
    end

    private def self.validate_write_transport_budget!(budget : CompressedStreamBudget, limits : CompressedStreamLimits) : Nil
      budget.ensure_direction(true)
      unless budget.limits.max_file_bytes == limits.max_file_bytes &&
             budget.limits.max_mark_bytes == limits.max_mark_bytes &&
             budget.limits.max_frame_compressed_bytes == limits.max_frame_compressed_bytes &&
             budget.limits.max_frame_decompressed_bytes == limits.max_frame_decompressed_bytes &&
             budget.limits.max_records == limits.max_records &&
             budget.limits.max_decoded_bytes == limits.max_decoded_bytes &&
             budget.limits.max_result_bytes == limits.max_result_bytes
        raise ArgumentError.new("Object writer requires a compatible write transport budget")
      end
      nil
    end

    # Encodes one Object JSON site under an already escaped structural prefix.
    # Unlike the Array wrapper API, granules here are marks -> parent rows ->
    # documents: each JSON document belongs to exactly one physical parent row.
    # The caller owns shared name/logical/transport budgets across sibling sites.
    def self.encode_at_site(
      escaped_prefix : String,
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      hashed : Bool = false,
      frame_bytes : Int = 4096,
      initial_array_level : UInt64 = 0_u64,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32 = 1,
    ) : ObjectDocumentColumnFiles
      if granules.empty?
        raise ArgumentError.new("a physical Object site requires at least one real mark")
      end
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("frame size must be a positive Int32 value")
      end
      if frame_bytes < DynamicDiscriminatorCodec::HEADER_BYTES.to_i
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      unless codec_budget.writing?
        raise ArgumentError.new("Object site codec budget must be write-direction")
      end
      transport_budget.ensure_direction(true)
      unless same_limits?(codec_budget.limits, name_context.limits)
        raise ArgumentError.new("Object site codec and physical-name limits differ")
      end

      limits = codec_budget.limits
      physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
        escaped_prefix,
        plan,
        profile,
        shared_profile,
        limits,
        initial_array_level,
        name_context
      )
      file_roster = preflight_file_roster(physical_plan, hashed)
      fresh_plan = ObjectDocumentStatistics.recompute_with_budget(plan, granules, codec_budget)
      streams = ObjectDocumentCodec.encode_with_budget(
        fresh_plan,
        granules,
        codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )

      preflight_variant_prefixes!(physical_plan, fresh_plan, streams, codec_budget)
      lanes = bind_lanes(physical_plan, fresh_plan, streams)
      mark_count = streams.mark_count + 1
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_count, frame_bytes, transport_budget)

      rows_per_mark = streams.rows_per_mark
      pairs = Hash(String, CompressedMarkFiles).new
      lanes.each do |lane|
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, transport_budget)
      end
      append_advanced_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentRootDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
    end

    # Recursive storage has already admitted the complete sibling filename
    # roster with one shared PhysicalStreamPlanContext. Consume that exact
    # site plan instead of rebuilding it against (and double-charging) the
    # shared context. A detached reconstruction is used only as a fail-closed
    # binding check for accidental plan/site mismatches.
    def self.encode_at_physical_site(
      escaped_prefix : String,
      plan : ObjectDocumentPlan,
      physical_plan : ObjectDocumentPhysicalPlan,
      granules : Array(Array(ObjectDocument)),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
      hashed : Bool = false,
      frame_bytes : Int = 4096,
      initial_array_level : UInt64 = 0_u64,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32 = 1,
    ) : ObjectDocumentColumnFiles
      if granules.empty?
        raise ArgumentError.new("a physical Object site requires at least one real mark")
      end
      if frame_bytes <= 0 || frame_bytes > Int32::MAX || frame_bytes < DynamicDiscriminatorCodec::HEADER_BYTES
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      unless codec_budget.writing?
        raise ArgumentError.new("Object site codec budget must be write-direction")
      end
      transport_budget.ensure_direction(true)
      unless shared_target_chunk_rows > 0
        raise ArgumentError.new("Object shared advanced target chunk rows must be positive")
      end
      limits = codec_budget.limits
      unless physical_plan.initial_array_level == initial_array_level
        raise ArgumentError.new("Object physical site plan does not match the admitted Array level")
      end

      expected_physical = ObjectDocumentPhysicalPlan.from_escaped_prefix(
        escaped_prefix, plan, profile, shared_profile, limits, initial_array_level
      )
      unless expected_physical.stream_names == physical_plan.stream_names
        raise UnsupportedFormatError.new("Object physical site plan differs from the supplied physical stream roster or Array-level binding")
      end

      file_roster = preflight_file_roster(physical_plan, hashed)
      fresh_plan = ObjectDocumentStatistics.recompute_with_budget(plan, granules, codec_budget)
      streams = ObjectDocumentCodec.encode_with_budget(
        fresh_plan,
        granules,
        codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )
      preflight_variant_prefixes!(physical_plan, fresh_plan, streams, codec_budget)
      lanes = bind_lanes(physical_plan, fresh_plan, streams)
      mark_count = streams.mark_count + 1
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_count, frame_bytes, transport_budget)

      rows_per_mark = streams.rows_per_mark
      pairs = Hash(String, CompressedMarkFiles).new
      lanes.each do |lane|
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, transport_budget)
      end
      append_advanced_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile,
        shared_json_policy, shared_target_chunk_rows
      )
      ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentRootDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, rows_per_mark,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
    end

    # Encodes an Object JSON leaf below one or more caller-owned structural
    # wrappers. `grid` keeps the enclosing part's physical rows separate from
    # this site's logical Object occurrences; no array-size lane is inferred
    # here. The Dynamic discriminator mode remains site-local and leaves the
    # root/Array row-domain guards intact.
    def self.encode_child_at_physical_site(
      escaped_prefix : String,
      plan : ObjectDocumentPlan,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      granules : Array(Array(ObjectDocument)),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
      hashed : Bool = false,
      frame_bytes : Int = 4096,
      initial_array_level : UInt64 = 0_u64,
    ) : ObjectDocumentColumnFiles
      if granules.empty?
        raise ArgumentError.new("a physical Object child site requires at least one real mark")
      end
      if frame_bytes <= 0 || frame_bytes > Int32::MAX || frame_bytes < DynamicDiscriminatorCodec::HEADER_BYTES
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      unless codec_budget.writing?
        raise ArgumentError.new("Object child-site codec budget must be write-direction")
      end
      transport_budget.ensure_direction(true)
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise UnsupportedFormatError.new("unsupported Dynamic discriminator write mode")
      end
      unless physical_plan.initial_array_level == initial_array_level
        raise ArgumentError.new("Object physical child-site plan does not match the admitted Array level")
      end

      limits = codec_budget.limits
      expected_physical = ObjectDocumentPhysicalPlan.from_escaped_prefix(
        escaped_prefix, plan, profile, shared_profile, limits, initial_array_level
      )
      unless expected_physical.stream_names == physical_plan.stream_names
        raise UnsupportedFormatError.new("Object child-site plan differs from the supplied physical stream roster or Array-level binding")
      end

      file_roster = preflight_file_roster(physical_plan, hashed)
      fresh_plan = ObjectDocumentStatistics.recompute_child_site_with_budget(
        plan, granules, grid, codec_budget
      )
      streams = ObjectDocumentCodec.encode_child_site_with_budget(
        fresh_plan,
        granules,
        grid,
        codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )

      preflight_variant_prefixes!(physical_plan, fresh_plan, streams, codec_budget)
      lanes = bind_lanes(physical_plan, fresh_plan, streams)
      mark_records = grid.mark_count + 1
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_records, frame_bytes, transport_budget)

      pairs = Hash(String, CompressedMarkFiles).new
      lanes.each do |lane|
        pairs[lane.name] = lane.encode_child_site(grid, frame_bytes, transport_budget)
      end
      physical_rows = physical_rows_from_grid(grid, codec_budget)
      append_advanced_pairs!(
        pairs, physical_plan, fresh_plan, streams, physical_rows,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, physical_rows,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentRootDynamicJsonPhysical.append_pairs!(
        pairs, physical_plan, fresh_plan, streams, physical_rows,
        codec_budget, transport_budget, frame_bytes, profile
      )
      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
    end

    # Exports the existing child Object lanes as two ordered callback groups
    # for a Compact parent Data tape. Prefix callbacks must be appended by the
    # caller's prefix pass; body callbacks follow only after that pass has
    # completed. The lane binder and framing adapters remain the sole source of
    # the Object lane grammar. Shared-data v2/v3 are deliberately refused
    # until their Compact callback/mark-coordinate relocation owner is wired.
    def self.inline_fragments_at_child_site(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      callback_root_prefix : String? = nil,
    ) : Tuple(Array(Tuple(String, Bytes)), Array(Tuple(String, Bytes)))
      unless budget.writing?
        raise ArgumentError.new("inline child Object fragment export requires a write-direction budget")
      end
      version = plan.structures.object.shared_data_version
      unless version < 2_u64
        raise UnsupportedFormatError.new("inline child Object shared-data v2/v3 requires Compact coordinate relocation")
      end
      inline_fragments_for_child_site_core(
        physical_plan, plan, streams, grid, budget, profile,
        callback_root_prefix || ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan),
        false,
      )
    end

    # Rich counterpart to the legacy callback tuple API. Advanced shared
    # callbacks are appended only after their seven bucket and three Copy
    # roles have been materialized without independent compression, and all
    # unresolved mark coordinates remain explicit in the returned sidecar.
    def self.inline_raw_layout_at_child_site(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      nested_context : ObjectSharedNestedSerializationContext,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      callback_root_prefix : String? = nil,
    ) : ObjectSharedAdvancedInlineRawLayout
      unless budget.writing? && nested_context.writing?
        raise ArgumentError.new("inline child Object raw export requires write-direction contexts")
      end
      version = plan.structures.object.shared_data_version
      unless nested_context.shared_data_version == version && version <= 3_u64
        raise UnsupportedFormatError.new("inline child Object raw export context differs from its prepared layout")
      end
      canonical_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)
      root = callback_root_prefix || canonical_root
      root_owner : ObjectDocumentInlineWriteOwners::Owner = {
        canonical_root,
        root,
        physical_plan,
        plan,
        streams,
        grid,
      }
      owners = ObjectDocumentInlineWriteOwners.new(root_owner, nested_context, budget)
      callback_owners = owners.callback_owners(budget)

      allow_advanced = version >= 2_u64
      prefix_events = ObjectDocumentInlineCallbackOrder.prefix_callback_events(
        physical_plan,
        plan,
        root,
        budget,
        allow_advanced: allow_advanced,
        descendants: callback_owners,
      )
      body_events = ObjectDocumentInlineCallbackOrder.body_callback_events(
        physical_plan,
        plan,
        nested_context.profile,
        root,
        budget,
        allow_advanced: allow_advanced,
        include_advanced_shared: true,
        descendants: callback_owners,
      )
      schedule = ObjectDocumentInlineCallbackEvents.new(
        {canonical_root, root, physical_plan, plan},
        callback_owners,
        budget,
      )
      prefix_fragments = Hash(String, Hash(String, Bytes)).new(initial_capacity: owners.size)
      body_fragments = Hash(String, Hash(String, Bytes)).new(initial_capacity: owners.size)
      relocations = [] of ObjectSharedInlineCallbackRelocation
      owners.each do |owner|
        owner_event_context : ObjectDocumentInlineCallbackOrder::EventScheduleContext = {schedule, owner[0]}
        local_prefixes, local_bodies = inline_fragments_for_child_site_core(
          owner[2], owner[3], owner[4], owner[5], budget, nested_context.profile,
          owner[1], allow_advanced, owner_event_context, true,
        )
        prefix_fragments[owner[0]] = fragment_bytes_by_raw_name!(local_prefixes)
        local_body_map = fragment_bytes_by_raw_name!(local_bodies)

        if allow_advanced
          target_rows = nested_context.target_chunk_rows ||
                        raise(ArgumentError.new("advanced inline child Object writer context has no target chunk size"))
          unless target_rows > 0
            raise(ArgumentError.new("advanced inline child Object target chunk size must be positive"))
          end
          advanced = ObjectSharedAdvancedInlineCodec.encode_body_callbacks(
            owner[2],
            owner[3],
            owner[4],
            physical_rows_from_grid(owner[5], budget),
            version.to_i,
            owner[2].shared_bucket_count,
            target_rows,
            nested_context.profile,
            owner[1],
            budget,
            shared_json_policy,
            owner_event_context,
            true,
          )
          unless advanced.prefix_callback_count == 0
            raise UnsupportedFormatError.new("advanced inline Object body codec emitted an unexpected prefix callback")
          end
          expected_advanced_count = ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
            owner[2], owner[3], nested_context.profile, budget, owner_event_context, true
          ).count { |binding| binding[1] == :advanced_bucket || binding[1] == :advanced_copy }
          unless advanced.body_callback_count == expected_advanced_count
            raise UnsupportedFormatError.new("advanced inline Object callback count differs from its Compact schedule")
          end
          advanced.body_callback_count.times do |index|
            callback = advanced.body_callback_at(index)
            if local_body_map.has_key?(callback[0])
              raise UnsupportedFormatError.new("advanced inline callback duplicates an ordinary body callback")
            end
            local_body_map[callback[0]] = callback[1]
          end
          relocations.concat(advanced.relocations)
        end
        body_fragments[owner[0]] = local_body_map
      end

      prefixes = splice_callback_events!(prefix_events, prefix_fragments, budget, "prefix")
      bodies = splice_callback_events!(body_events, body_fragments, budget, "body")
      ObjectSharedAdvancedInlineRawLayout.new(prefixes, bodies, relocations, budget)
    end

    private def self.fragment_bytes_by_raw_name!(
      fragments : Array(Tuple(String, Bytes)),
    ) : Hash(String, Bytes)
      result = Hash(String, Bytes).new(initial_capacity: fragments.size)
      fragments.each do |fragment|
        if result.has_key?(fragment[0])
          raise UnsupportedFormatError.new("inline callback raw name is duplicated within its owner")
        end
        result[fragment[0]] = fragment[1]
      end
      result
    end

    private def self.splice_callback_events!(
      events : Array(ObjectDocumentInlineCallbackOrder::CallbackEvent),
      fragments : Hash(String, Hash(String, Bytes)),
      budget : BinaryCodecBudget,
      phase : String,
    ) : Array(Tuple(String, Bytes))
      count = events.size.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      output = Array(Tuple(String, Bytes)).new(events.size)
      consumed = Hash(Tuple(String, String), Bool).new(initial_capacity: events.size)
      events.each do |event|
        owner_root = event[0]
        callback_root = event[2]
        owner_fragments = fragments[owner_root]? ||
                          raise(UnsupportedFormatError.new("inline #{phase} event names an unmaterialized Object owner"))
        bytes = owner_fragments[callback_root]? ||
                raise(UnsupportedFormatError.new("inline #{phase} event has no owner-local callback bytes"))
        key = {owner_root, callback_root}
        if consumed.has_key?(key)
          raise(UnsupportedFormatError.new("inline #{phase} event consumes one owner callback more than once"))
        end
        consumed[key] = true
        output << {callback_root, bytes}
        budget.charge_node
      end
      fragment_count = 0_u64
      fragments.each do |owner_root, owner_fragments|
        owner_fragments.each_key do |callback_root|
          fragment_count += 1_u64
          unless consumed.has_key?({owner_root, callback_root})
            raise UnsupportedFormatError.new("inline #{phase} owner has callbacks outside the complete event schedule")
          end
        end
      end
      unless fragment_count == count
        raise UnsupportedFormatError.new("inline #{phase} event count differs from owner-local callback materialization")
      end
      budget.charge_elements(count) if count > 0_u64
      output
    end

    private def self.inline_fragments_for_child_site_core(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      callback_root : String,
      allow_advanced : Bool,
      event_context : ObjectDocumentInlineCallbackOrder::EventScheduleContext? = nil,
      local_only : Bool = false,
    ) : Tuple(Array(Tuple(String, Bytes)), Array(Tuple(String, Bytes)))
      grid.validate_for!(streams.mark_count, budget)

      lanes = bind_lanes(physical_plan, plan, streams, budget)
      if lanes.size > Int32::MAX // 2
        raise UnsupportedFormatError.new("inline child Object callback roster exceeds the supported domain")
      end
      fragment_slots = lanes.size.to_u64 * 2_u64
      prefix_pairs = ObjectDocumentInlineCallbackOrder.prefix_callback_pairs(
        physical_plan, plan, callback_root, budget, allow_advanced, event_context, local_only
      )
      body_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
        physical_plan, plan, profile, callback_root, budget, allow_advanced, false,
        event_context, local_only
      )
      expected_prefixes = Hash(String, Bool).new(initial_capacity: prefix_pairs.size)
      expected_bodies = Hash(String, Bool).new(initial_capacity: body_pairs.size)
      prefix_pairs.each { |pair| expected_prefixes[pair[0]] = true }
      body_pairs.each { |pair| expected_bodies[pair[0]] = true }

      budget.ensure_future_nodes(fragment_slots)
      budget.ensure_future_elements(fragment_slots)
      fragment_slots.times { budget.charge_node }
      budget.charge_elements(fragment_slots)
      prefix_fragments = Hash(String, Bytes).new(initial_capacity: prefix_pairs.size)
      body_fragments = Hash(String, Bytes).new(initial_capacity: body_pairs.size)

      lanes.each do |lane|
        lane.inline_fragments_for_child_site(grid, budget).each do |fragment|
          name = fragment[0]
          target = if expected_prefixes.has_key?(name)
                     prefix_fragments
                   elsif expected_bodies.has_key?(name)
                     body_fragments
                   else
                     raise UnsupportedFormatError.new("inline child Object lane emitted an unplanned callback")
                   end
          if target.has_key?(name)
            raise UnsupportedFormatError.new("inline child Object lane emitted a duplicate callback")
          end
          target[name] = fragment[1]
        end
      end

      unless prefix_fragments.size == prefix_pairs.size && body_fragments.size == body_pairs.size
        raise UnsupportedFormatError.new("inline child Object lane callbacks do not exactly match the Compact schedule")
      end
      total_fragments = prefix_pairs.size.to_u64 + body_pairs.size.to_u64
      budget.ensure_future_nodes(total_fragments)
      budget.ensure_future_elements(total_fragments)
      total_fragments.times { budget.charge_node }
      budget.charge_elements(total_fragments) if total_fragments > 0_u64
      prefixes = Array(Tuple(String, Bytes)).new(prefix_pairs.size)
      prefix_pairs.each do |pair|
        bytes = prefix_fragments[pair[0]]? || raise(UnsupportedFormatError.new("inline prefix fragment is missing"))
        prefixes << {pair[1], bytes}
      end
      bodies = Array(Tuple(String, Bytes)).new(body_pairs.size)
      body_pairs.each do |pair|
        bytes = body_fragments[pair[0]]? || raise(UnsupportedFormatError.new("inline body fragment is missing"))
        bodies << {pair[1], bytes}
      end
      {prefixes, bodies}
    end

    private def self.preflight_file_roster(
      physical_plan : ObjectDocumentPhysicalPlan,
      hashed : Bool,
    ) : Hash(String, Tuple(String, String))
      if physical_plan.stream_count > PartChecksums::MAX_ENTRIES // 2
        raise UnsupportedFormatError.new("Object column file roster exceeds checksums entry limit")
      end
      names = physical_plan.stream_names
      roster = Hash(String, Tuple(String, String)).new
      filenames = Hash(String, Bool).new
      names.each do |name|
        base = hashed ? StreamName.hash(name) : name
        if base.bytesize > MAX_FILE_NAME_BYTES - ".mrk2".bytesize
          raise UnsupportedFormatError.new("Object column filename exceeds checksums name limit")
        end
        data_name = PhysicalStreamName.append_literal(base, ".bin")
        marks_name = PhysicalStreamName.append_literal(base, ".mrk2")
        if data_name.bytesize > MAX_FILE_NAME_BYTES || marks_name.bytesize > MAX_FILE_NAME_BYTES
          raise UnsupportedFormatError.new("Object column filename exceeds checksums name limit")
        end
        if filenames.has_key?(data_name) || filenames.has_key?(marks_name)
          raise UnsupportedFormatError.new("Object column filenames collide after hashing")
        end
        filenames[data_name] = true
        filenames[marks_name] = true
        roster[String.new(name.to_slice)] = {data_name, marks_name}
      end
      roster
    end

    # Internal reusable preflight for a parent Array(JSON) wrapper. The JSON
    # roles remain owned by this writer; the wrapper owner adds its own
    # `.size0` lane and checks the combined roster.
    def self.file_roster_for_child_site(
      physical_plan : ObjectDocumentPhysicalPlan,
      hashed : Bool,
    ) : Hash(String, Tuple(String, String))
      preflight_file_roster(physical_plan, hashed)
    end

    private def self.bind_lanes(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      codec_budget : BinaryCodecBudget? = nil,
    ) : Array(ObjectDocumentColumnLane)
      LaneBinder.bind_lanes(physical_plan, plan, streams, codec_budget)
    end

    private def self.append_advanced_pairs!(
      pairs : Hash(String, CompressedMarkFiles),
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      physical_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int,
      profile : BinaryBulkProfile,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
      shared_target_chunk_rows : Int32 = 1,
    ) : Nil
      version = plan.structures.object.shared_data_version
      return nil if version < 2_u64

      rows = streams.advanced_shared_rows(codec_budget)
      files = ObjectSharedAdvancedDocumentCodec.encode(
        rows,
        physical_rows,
        version.to_i,
        ObjectSharedBucketLayout.bucket_count(plan.structures.object),
        codec_budget,
        transport_budget,
        frame_bytes,
        profile: profile,
        shared_json_policy: shared_json_policy,
        shared_target_chunk_rows: shared_target_chunk_rows,
      )
      {"sizes", "indexes", "values"}.each do |lane|
        pairs[physical_plan.advanced_copy_stream_name(lane)] = files.copy_lane(lane)
      end
      files.bucket_count.times do |bucket_index|
        ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
          pairs[physical_plan.advanced_bucket_stream_name(bucket_index, lane)] =
            files.bucket_at(bucket_index).lane(lane)
        end
      end
      nil
    end

    # Advanced Object copy/bucket lanes are produced after ordinary child
    # lanes at both the root and recursively bound JSON child sites.
    def self.append_child_site_advanced_pairs!(
      pairs : Hash(String, CompressedMarkFiles),
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      physical_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int,
      profile : BinaryBulkProfile,
    ) : Nil
      append_advanced_pairs!(
        pairs, physical_plan, plan, streams, physical_rows,
        codec_budget, transport_budget, frame_bytes, profile
      )
    end

    private def self.physical_rows_from_grid(
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      count = grid.mark_count.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      rows = Array(UInt64).new(grid.mark_count)
      grid.mark_count.times do |index|
        rows << grid.physical_rows_at(index)
        budget.charge_node
      end
      budget.charge_elements(count)
      rows
    end

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    def self.bind_child_site_lanes(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      codec_budget : BinaryCodecBudget? = nil,
    ) : Array(ObjectDocumentColumnLane)
      LaneBinder.bind_lanes(physical_plan, plan, streams, codec_budget)
    end

    private def self.preflight_variant_prefixes!(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
    ) : Nil
      LaneBinder.preflight_variant_prefixes!(physical_plan, plan, streams, budget)
    end

    def self.preflight_child_site_variant_prefixes!(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
    ) : Nil
      LaneBinder.preflight_variant_prefixes!(physical_plan, plan, streams, budget)
    end
  end
end
