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
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : Hash(String, CompressedMarkFiles)
      write_codec_budget = codec_budget || BinaryCodecBudget.new(limits, true)
      unless write_codec_budget.writing? && same_codec_limits?(write_codec_budget.limits, limits)
        raise ArgumentError.new("Binary bulk writer requires a compatible write codec budget")
      end
      write_transport_budget = transport_budget || CompressedStreamBudget.new(transport_limits, true)
      validate_transport_budget!(write_transport_budget, transport_limits)

      # Keep the generic column adapter static-only. Dynamic/JSON require
      # caller-specific binding plans and must not inherit this route.
      BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
      streams = BinaryBulkCodec.encode_with_budget(
        type, granules, write_codec_budget, profile: profile
      )
      physical_names = physical.stream_names
      roles = streams.roles
      unless physical_names.keys.sort == roles && streams.mark_count == granules.size &&
             rows_per_mark.size == granules.size
        raise UnsupportedFormatError.new("Binary bulk roles or mark grid differs from the physical plan")
      end

      write_codec_budget.charge_elements(roles.size.to_u64) if roles.size > 0
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
      BinaryBulkPhysicalPrefixAdapter.preflight_write(prefix_lanes, write_codec_budget)
      raw_sizes = Array(Int32).new(lanes.size) { |index| lanes[index].byte_size }
      CompressedMarkWriter.preflight_batch(raw_sizes, granules.size + 1, frame_bytes, write_transport_budget)

      pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: lanes.size)
      lanes.each do |lane|
        if pairs.has_key?(lane.name)
          raise UnsupportedFormatError.new("Binary bulk physical filenames collide")
        end
        pairs[lane.name] = lane.encode(rows_per_mark, frame_bytes, write_transport_budget)
      end
      unless pairs.keys.sort == physical_names.values.sort
        raise UnsupportedFormatError.new("Binary bulk encoded lane roster differs from the physical plan")
      end
      pairs
    end

    private def self.same_codec_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def self.validate_transport_budget!(budget : CompressedStreamBudget, limits : CompressedStreamLimits) : Nil
      budget.ensure_direction(true)
      unless budget.limits.max_file_bytes == limits.max_file_bytes &&
             budget.limits.max_mark_bytes == limits.max_mark_bytes &&
             budget.limits.max_frame_compressed_bytes == limits.max_frame_compressed_bytes &&
             budget.limits.max_frame_decompressed_bytes == limits.max_frame_decompressed_bytes &&
             budget.limits.max_records == limits.max_records &&
             budget.limits.max_decoded_bytes == limits.max_decoded_bytes &&
             budget.limits.max_result_bytes == limits.max_result_bytes
        raise ArgumentError.new("Binary bulk writer requires a compatible write transport budget")
      end
      nil
    end
  end
end
