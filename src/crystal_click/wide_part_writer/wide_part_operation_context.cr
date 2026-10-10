module CrystalClick
  module WidePartWriter
    # One operation's global profiles and mutable write-side counters. Reader
    # counters are created separately after the complete roster is encoded.
    # This value crosses the public WidePartColumn closure boundary, but is
    # constructed and consumed only by the writer operation.
    class WidePartOperationContext
      getter rows_per_mark : Int32
      getter profile : BinaryBulkProfile
      getter shared_profile : BinaryBulkProfile
      getter mode : UInt64
      getter frame_bytes : Int32
      getter metadata_version : Int64
      getter limits : BinaryCodecLimits
      getter transport_limits : CompressedStreamLimits
      getter codec_budget : BinaryCodecBudget
      getter transport_budget : CompressedStreamBudget
      getter read_codec_budget : BinaryCodecBudget
      getter read_transport_budget : CompressedStreamBudget
      getter name_context : PhysicalStreamPlanContext
      getter shared_json_policy : ObjectSharedAdvancedJsonWritePolicy?
      getter shared_target_chunk_rows : Int32

      def initialize(
        rows_per_mark : Int32,
        @profile : BinaryBulkProfile,
        @shared_profile : BinaryBulkProfile,
        mode : UInt64,
        frame_bytes : Int,
        @metadata_version : Int64,
        @limits : BinaryCodecLimits,
        @transport_limits : CompressedStreamLimits,
        @shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
        shared_target_chunk_rows : Int32 = 1,
        shared_budgets_from : WidePartOperationContext? = nil,
      )
        unless rows_per_mark > 0 && rows_per_mark <= WidePartWriter::MAX_ROWS_PER_MARK
          raise ArgumentError.new("rows_per_mark is outside the admitted range")
        end
        unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
          raise ArgumentError.new("unsupported Dynamic discriminator write mode")
        end
        unless frame_bytes > 0 && frame_bytes <= Int32::MAX &&
               frame_bytes <= @transport_limits.max_frame_decompressed_bytes
          raise ArgumentError.new("frame size is outside the compressed transport limit")
        end
        raise ArgumentError.new("metadata version must be nonnegative") if @metadata_version < 0
        unless shared_target_chunk_rows > 0
          raise ArgumentError.new("Object shared advanced target chunk rows must be positive")
        end

        @rows_per_mark = rows_per_mark
        @mode = mode
        @frame_bytes = frame_bytes.to_i32
        @shared_target_chunk_rows = shared_target_chunk_rows

        if shared = shared_budgets_from
          unless shared.profile == @profile && shared.shared_profile == @shared_profile &&
                 shared.mode == @mode && shared.frame_bytes == @frame_bytes &&
                 shared.metadata_version == @metadata_version &&
                 shared.shared_json_policy == @shared_json_policy &&
                 shared.shared_target_chunk_rows == @shared_target_chunk_rows &&
                 same_limits?(shared.limits, @limits) &&
                 same_transport_limits?(shared.transport_limits, @transport_limits)
            raise ArgumentError.new("shared Wide operation budgets require an otherwise identical context")
          end
          @codec_budget = shared.codec_budget
          @transport_budget = shared.transport_budget
          @read_codec_budget = shared.read_codec_budget
          @read_transport_budget = shared.read_transport_budget
          @name_context = shared.name_context
        else
          @codec_budget = BinaryCodecBudget.new(@limits, true)
          @transport_budget = CompressedStreamBudget.new(@transport_limits, true)
          @read_codec_budget = BinaryCodecBudget.new(@limits, false)
          @read_transport_budget = CompressedStreamBudget.new(@transport_limits, false)
          @name_context = PhysicalStreamPlanContext.new(@limits)
        end
      end

      # Child parts have independent mark schedules but consume this exact
      # operation's mutable planning, codec, transport and readback counters.
      def with_rows_per_mark(rows_per_mark : Int32) : WidePartOperationContext
        WidePartOperationContext.new(
          rows_per_mark, @profile, @shared_profile, @mode, @frame_bytes,
          @metadata_version, @limits, @transport_limits, @shared_json_policy,
          @shared_target_chunk_rows, self
        )
      end

      private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
        left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
          left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
      end

      private def same_transport_limits?(left : CompressedStreamLimits, right : CompressedStreamLimits) : Bool
        left.max_file_bytes == right.max_file_bytes && left.max_mark_bytes == right.max_mark_bytes &&
          left.max_frame_compressed_bytes == right.max_frame_compressed_bytes &&
          left.max_frame_decompressed_bytes == right.max_frame_decompressed_bytes &&
          left.max_records == right.max_records && left.max_decoded_bytes == right.max_decoded_bytes &&
          left.max_result_bytes == right.max_result_bytes
      end
    end
  end
end
