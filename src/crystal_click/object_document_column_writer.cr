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

      codec_budget = BinaryCodecBudget.new(limits, true)
      fresh_plan = ObjectDocumentStatistics.recompute_with_budget(plan, granules, codec_budget)

      # Statistics and value traversal share exactly one logical write budget.
      streams = ObjectDocumentCodec.encode_with_budget(
        fresh_plan,
        granules,
        codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )

      # Variant discriminators acquire an eight-byte physical prefix only at
      # the column boundary. Admit all added headers and coordinate rebasing
      # against the same operation budget before constructing any adapted
      # lane buffer.
      preflight_variant_prefixes!(physical_plan, fresh_plan, streams, codec_budget)
      lanes = bind_lanes(physical_plan, fresh_plan, streams)
      mark_count = streams.mark_count + 1
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      transport_budget = CompressedStreamBudget.new(transport_limits, true)
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_count, frame_bytes, transport_budget)

      # This is the first K-sized row-grid copy in physical composition, and it
      # follows the aggregate frame/mark/byte admission above.
      rows_per_mark = streams.rows_per_mark
      pairs = Hash(String, CompressedMarkFiles).new
      lanes.each do |lane|
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, transport_budget)
      end

      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
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
      ObjectDocumentColumnFiles.new(fresh_plan, physical_plan, pairs, file_roster)
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
    ) : Array(ObjectDocumentColumnLane)
      LaneBinder.bind_lanes(physical_plan, plan, streams)
    end

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    def self.bind_child_site_lanes(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
    ) : Array(ObjectDocumentColumnLane)
      LaneBinder.bind_lanes(physical_plan, plan, streams)
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
