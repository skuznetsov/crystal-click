module CrystalClick
  # Shared exact-match and direction guard for borrowed reader-operation
  # budgets. The owners are consumptive; this helper validates but never
  # creates, copies, resets, or otherwise changes them.
  class StorageReadBudgetValidator
    def self.validate!(
      codec_budget : BinaryCodecBudget?,
      transport_budget : CompressedStreamBudget?,
      codec_limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      codec_error : String,
      transport_error : String,
    ) : Nil
      if codec = codec_budget
        unless !codec.writing? && same_codec_limits?(codec.limits, codec_limits)
          raise ArgumentError.new(codec_error)
        end
      end

      if transport = transport_budget
        transport.ensure_direction(false)
        unless same_transport_limits?(transport.limits, transport_limits)
          raise ArgumentError.new(transport_error)
        end
      end
      nil
    end

    private def self.same_codec_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def self.same_transport_limits?(
      left : CompressedStreamLimits,
      right : CompressedStreamLimits,
    ) : Bool
      left.max_file_bytes == right.max_file_bytes && left.max_mark_bytes == right.max_mark_bytes &&
        left.max_frame_compressed_bytes == right.max_frame_compressed_bytes &&
        left.max_frame_decompressed_bytes == right.max_frame_decompressed_bytes &&
        left.max_records == right.max_records && left.max_decoded_bytes == right.max_decoded_bytes &&
        left.max_result_bytes == right.max_result_bytes
    end
  end
end
