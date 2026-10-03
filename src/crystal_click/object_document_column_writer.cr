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

    private def self.bind_lanes(
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
    ) : Array(ObjectDocumentColumnLane)
      if streams.mark_count <= 0
        raise UnsupportedFormatError.new("Object document output has no real outer marks")
      end
      expected = Hash(String, Bool).new
      physical_plan.stream_names.each { |name| expected[name] = false }
      lanes = Array(ObjectDocumentColumnLane).new(expected.size)
      structures = streams.structures
      object_bytes = structures.borrowed_object
      object_offset = structures.object_statistics_offset ||
                      raise(UnsupportedFormatError.new("Object metadata encoder omitted its statistics offset"))
      add_lane!(lanes, expected, ObjectDocumentColumnLane.new(physical_plan.object_structure_stream, object_bytes, object_offset))

      object = plan.structures.object
      if structures.dynamic_statistics_offset_count != object.dynamic_path_count
        raise UnsupportedFormatError.new("Dynamic metadata statistics offsets do not match the Object path roster")
      end
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        name = physical_plan.dynamic_structure_stream(path)
        bytes = structures.borrowed_dynamic(path)
        offset = structures.dynamic_statistics_offset(path) ||
                 raise(UnsupportedFormatError.new("Dynamic metadata encoder omitted a statistics offset"))
        add_lane!(lanes, expected, ObjectDocumentColumnLane.new(name, bytes, offset))
      end

      if streams.dynamic_path_count != object.dynamic_path_count
        raise UnsupportedFormatError.new("Dynamic value lane paths do not match the Object metadata roster")
      end
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        dynamic_structure = plan.structures.dynamic_for(path)
        canonical_names = dynamic_structure.canonical_variant_names
        dynamic_streams = streams.dynamic_for(path)
        if dynamic_streams.arm_count != dynamic_structure.canonical_variant_count
          raise UnsupportedFormatError.new("Dynamic value arm roster does not match its descriptor metadata")
        end
        canonical_names.each do |arm_name|
          unless dynamic_streams.has_arm?(arm_name)
            raise UnsupportedFormatError.new("Dynamic value arm is missing from its descriptor roster")
          end
        end
        unless dynamic_streams.arm_names == canonical_names
          raise UnsupportedFormatError.new("Dynamic value arm names are not in the canonical descriptor order")
        end

        discriminator = dynamic_streams.discriminators
        if discriminator.mark_count != streams.mark_count + 1
          raise UnsupportedFormatError.new("Dynamic discriminator mark count does not match the outer grid")
        end
        add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
          physical_plan.discriminator_stream(path),
          discriminator.borrowed_slice(0, discriminator.byte_size),
          nil,
          nil,
          discriminator,
          DynamicDiscriminatorCodec::HEADER_BYTES.to_i32
        ))

        canonical_names.each do |arm_name|
          add_bulk_lanes!(
            lanes,
            expected,
            physical_plan.dynamic_arm(path, arm_name),
            dynamic_streams.arm(arm_name),
            streams.mark_count
          )
        end
      end

      if streams.typed_path_count != plan.typed_path_count
        raise UnsupportedFormatError.new("typed lane path count does not match the explicit schema")
      end
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        add_bulk_lanes!(lanes, expected, physical_plan.typed(path), streams.typed_for(path), streams.mark_count)
      end
      add_bulk_lanes!(lanes, expected, physical_plan.shared, streams.shared, streams.mark_count)

      unless lanes.size == expected.size && expected.each_value.all? { |seen| seen }
        raise UnsupportedFormatError.new("Object column lanes do not exactly cover the physical filename roster")
      end
      lanes
    end

    private def self.add_bulk_lanes!(
      lanes : Array(ObjectDocumentColumnLane),
      expected : Hash(String, Bool),
      physical : BinaryBulkPhysicalPlan,
      streams : BinaryBulkStreams,
      real_mark_count : Int32,
    ) : Nil
      physical_names = physical.stream_names
      if physical_names.size != streams.role_count
        raise UnsupportedFormatError.new("binary bulk roles do not match their physical binding")
      end
      unless physical_names.keys.sort == streams.roles
        raise UnsupportedFormatError.new("binary bulk role set does not match its physical binding")
      end
      streams.roles.each do |role|
        source = streams.stream(role)
        unless source.offset_count == real_mark_count + 1
          raise UnsupportedFormatError.new("binary bulk lane does not have the complete outer mark grid")
        end
        name = physical.stream_name_for(role)
        bytes = source.borrowed_slice(0, source.byte_size)
        add_lane!(lanes, expected, ObjectDocumentColumnLane.new(
          name,
          bytes,
          nil,
          source,
          nil,
          physical.prefix_size_for(role)
        ))
      end
      nil
    end

    private def self.add_lane!(lanes : Array(ObjectDocumentColumnLane), expected : Hash(String, Bool), lane : ObjectDocumentColumnLane) : Nil
      unless expected.has_key?(lane.name)
        raise UnsupportedFormatError.new("encoded Object lane has no physical filename binding")
      end
      if expected[lane.name]
        raise UnsupportedFormatError.new("multiple encoded Object lanes share one physical filename")
      end
      expected[lane.name] = true
      lanes << lane
      nil
    end
  end
end
