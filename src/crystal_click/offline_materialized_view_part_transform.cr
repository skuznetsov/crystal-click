module CrystalClick
  # Coordinates one callback, one complete typed source scan, target-schema
  # revalidation, and the existing staged Wide publisher. It does not execute
  # persisted SQL or claim callback provenance.
  class OfflineMaterializedViewPartTransform
    @input : OfflinePartTransformInput
    @destination : String
    @binding : WidePartSchemaBinding
    @key_name : String
    @rows_per_mark : Int32
    @profile : BinaryBulkProfile
    @shared_profile : BinaryBulkProfile
    @mode : UInt64
    @frame_bytes : Int32
    @metadata_version : Int64
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @shared_json_policy : ObjectSharedAdvancedJsonWritePolicy?
    @shared_target_chunk_rows : Int32

    def initialize(
      @input : OfflinePartTransformInput,
      destination : String,
      binding : WidePartSchemaBinding,
      key_name : String,
      @rows_per_mark : Int32,
      @profile : BinaryBulkProfile,
      @shared_profile : BinaryBulkProfile,
      @mode : UInt64,
      frame_bytes : Int,
      @metadata_version : Int64,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
      @shared_json_policy : ObjectSharedAdvancedJsonWritePolicy?,
      @shared_target_chunk_rows : Int32,
    )
      @destination = String.new(destination.to_slice)
      @binding = binding
      @key_name = String.new(key_name.to_slice)
      unless frame_bytes > 0 && frame_bytes <= Int32::MAX &&
             frame_bytes <= @transport_limits.max_frame_decompressed_bytes
        raise ArgumentError.new("frame size is outside the compressed transport limit")
      end
      @frame_bytes = frame_bytes.to_i32
    end

    def execute(revalidate : Proc(Nil), &callback : OfflinePartTransformInput -> WidePartTransformOutput) : String
      begin
        output = yield @input
        unless @input.complete_for_output?
          raise UnsupportedFormatError.new("materialized-view transform did not complete one full source scan")
        end

        # The handle belongs to the outer callback only. Invalidate it before
        # metadata refresh or writer owner preparation begins; ensure below
        # covers callback exceptions and nonlocal exits as well.
        @input.invalidate!

        keys = output.keys
        raise InvalidPartError.new("materialized-view transform output must not be empty") if keys.empty?
        columns = output.columns

        revalidate.call

        WidePartWriter.write_uint64_columns(
          @destination,
          @key_name,
          keys.to_unsafe.to_slice(keys.size),
          columns,
          @rows_per_mark,
          @profile,
          @shared_profile,
          @mode,
          @frame_bytes,
          @metadata_version,
          @limits,
          @transport_limits,
          @shared_json_policy,
          @shared_target_chunk_rows,
          [] of WidePartProjection,
          @binding
        )
      ensure
        @input.invalidate!
      end
    end
  end
end
