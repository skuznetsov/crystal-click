module CrystalClick
  # Encodes one complete static BinaryBulk physical column. Logical roles
  # remain owned by BinaryBulkCodec; this owner adapts the admitted physical
  # prefix and compresses each lane.
  class BinaryBulkColumnWriter
    def self.encode(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      physical : BinaryBulkPhysicalPlan,
      granules : Array(Array(BinaryValue)),
      rows_per_mark : Array(UInt64),
      frame_bytes : Int,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
    ) : Hash(String, CompressedMarkFiles)
      # Keep the generic column adapter static-only. Dynamic/JSON require
      # caller-specific binding plans and must not inherit this route.
      BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
      codec_budget = BinaryCodecBudget.new(limits, true)
      streams = BinaryBulkCodec.encode_with_budget(
        type, granules, codec_budget, profile: profile
      )
      physical_names = physical.stream_names
      roles = streams.roles
      unless physical_names.keys.sort == roles && streams.mark_count == granules.size &&
             rows_per_mark.size == granules.size
        raise UnsupportedFormatError.new("Binary bulk roles or mark grid differs from the physical plan")
      end

      codec_budget.charge_elements(roles.size.to_u64) if roles.size > 0
      lanes = Array(ObjectDocumentColumnLane).new(roles.size)
      prefix_lanes = Array(Tuple(String, BinaryBulkStream, Int32)).new(roles.size)
      roles.each do |role|
        stream = streams.stream(role)
        prefix = physical.prefix_size_for(role)
        prefix_lanes << {role, stream, prefix}
        variant_prefix = BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
        lanes << ObjectDocumentColumnLane.new(
          physical_names[role],
          stream.borrowed_slice(0, stream.byte_size),
          nil,
          stream,
          nil,
          prefix,
          variant_prefix ? role : nil,
        )
      end

      # Validate all LC/Variant physical headers and reserve transformed
      # coordinate work before any physical output or lane copy is produced.
      BinaryBulkPhysicalPrefixAdapter.preflight_write(prefix_lanes, codec_budget)
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      transport_budget = CompressedStreamBudget.new(transport_limits, true)
      CompressedMarkWriter.preflight_batch(raw_sizes, granules.size + 1, frame_bytes, transport_budget)

      pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: lanes.size)
      lanes.each do |lane|
        if pairs.has_key?(lane.name)
          raise UnsupportedFormatError.new("Binary bulk physical filenames collide")
        end
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, transport_budget)
      end
      unless pairs.keys.sort == physical_names.values.sort
        raise UnsupportedFormatError.new("Binary bulk encoded lane roster differs from the physical plan")
      end
      pairs
    end
  end
end
