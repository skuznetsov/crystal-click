module CrystalClick
  # Logical limits for paired compressed-frame and mark transport. These bound
  # transport work and retained results; they are not RSS or allocator limits.
  class CompressedStreamLimits
    DEFAULT_MAX_FILE_BYTES               = 256_i64 * 1024 * 1024
    DEFAULT_MAX_MARK_BYTES               = 64_i64 * 1024 * 1024
    DEFAULT_MAX_FRAME_COMPRESSED_BYTES   = 64_i64 * 1024 * 1024
    DEFAULT_MAX_FRAME_DECOMPRESSED_BYTES = 64_i64 * 1024 * 1024
    DEFAULT_MAX_RECORDS                  = 1_i64 * 1_000_000
    DEFAULT_MAX_DECODED_BYTES            = 64_i64 * 1024 * 1024
    DEFAULT_MAX_RESULT_BYTES             = 64_i64 * 1024 * 1024

    getter max_file_bytes : Int64
    getter max_mark_bytes : Int64
    getter max_frame_compressed_bytes : Int64
    getter max_frame_decompressed_bytes : Int64
    getter max_records : Int64
    getter max_decoded_bytes : Int64
    getter max_result_bytes : Int64

    def initialize(
      max_file_bytes : Int = DEFAULT_MAX_FILE_BYTES,
      max_mark_bytes : Int = DEFAULT_MAX_MARK_BYTES,
      max_frame_compressed_bytes : Int = DEFAULT_MAX_FRAME_COMPRESSED_BYTES,
      max_frame_decompressed_bytes : Int = DEFAULT_MAX_FRAME_DECOMPRESSED_BYTES,
      max_records : Int = DEFAULT_MAX_RECORDS,
      max_decoded_bytes : Int = DEFAULT_MAX_DECODED_BYTES,
      max_result_bytes : Int = DEFAULT_MAX_RESULT_BYTES,
    )
      @max_file_bytes = checked_limit(max_file_bytes)
      @max_mark_bytes = checked_limit(max_mark_bytes)
      @max_frame_compressed_bytes = checked_limit(max_frame_compressed_bytes)
      @max_frame_decompressed_bytes = checked_limit(max_frame_decompressed_bytes)
      @max_records = checked_limit(max_records)
      @max_decoded_bytes = checked_limit(max_decoded_bytes)
      @max_result_bytes = checked_limit(max_result_bytes)
    end

    private def checked_limit(value : Int) : Int64
      case value
      when UInt128
        raise ArgumentError.new("compressed stream limit exceeds Int64") if value > Int64::MAX.to_u128
        value.to_i64
      when UInt64
        raise ArgumentError.new("compressed stream limit exceeds Int64") if value > Int64::MAX.to_u64
        value.to_i64
      else
        converted = value.to_i128
        if converted < 0 || converted > Int64::MAX.to_i128
          raise ArgumentError.new("compressed stream limits must be nonnegative Int64 values")
        end
        converted.to_i64
      end
    end
  end
end
