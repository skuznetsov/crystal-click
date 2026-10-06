module CrystalClick
  # Thin public coordinator for one complete six-lane ADVANCED bucket.
  module ObjectSharedPhysicalBucketCodec
    def self.encode(
      version : Int,
      parents : Array(ObjectSharedPhysicalParentMark),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int = 4096,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : ObjectSharedPhysicalBucketFiles
      # Per-path String profile belongs to the opaque Data payloads. Bucket
      # framing stores those bytes unchanged, but accepts the selector so a
      # caller can propagate one profile across the complete object codec.
      ObjectSharedPhysicalBucketEncoder.encode(version, parents, codec_budget, transport_budget, frame_bytes)
    end

    def self.decode(
      version : Int,
      lane_inputs : ObjectSharedPhysicalBucketLaneInputs,
      expected_parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : Array(ObjectSharedPhysicalParentMark)
      ObjectSharedPhysicalBucketDecoder.decode(version, lane_inputs, expected_parent_rows, codec_budget, transport_budget)
    end
  end
end
