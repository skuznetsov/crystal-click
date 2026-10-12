module CrystalClick
  # Conservative retained-grid bound for the plain Compact readback path.
  # This is a budget preflight, not an allocator/RSS estimate.
  class CompactReadbackGrid
    def self.preflight!(
      budget : CompressedStreamBudget,
      mark_count : Int,
      slot_count : Int,
      data_size : UInt64,
    ) : Nil
      budget.preflight_result_bytes(
        to_i64(retained_workspace_upper_bound(mark_count, slot_count, data_size)),
      )
      nil
    end

    private def self.retained_workspace_upper_bound(
      mark_count : Int,
      slot_count : Int,
      data_size : UInt64,
    ) : UInt64
      if mark_count <= 0 || slot_count <= 0 || data_size == 0_u64
        raise UnsupportedFormatError.new("Compact readback grid dimensions are invalid")
      end

      marks = mark_count.to_u64
      slots = slot_count.to_u64
      coordinate_count = checked_multiply(checked_add(marks, 1_u64), slots)
      frame_count = data_size // CompressedBlock::FRAME_HEADER_SIZE.to_u64

      bytes = instance_sizeof(CompactMarkIndex).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(Int64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(coordinate_count, sizeof(Int64).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(marks, sizeof(UInt64).to_u64))
      bytes = checked_add(bytes, instance_sizeof(CompressedFrameIndex).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(CompressedFrameDescriptor)).to_u64)
      checked_add(bytes, checked_multiply(frame_count, sizeof(CompressedFrameDescriptor).to_u64))
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact readback grid workspace overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact readback grid workspace overflows UInt64")
      end
      left * right
    end

    private def self.to_i64(value : UInt64) : Int64
      if value > Int64::MAX.to_u64
        raise UnsupportedFormatError.new("Compact readback grid exceeds the supported result domain")
      end
      value.to_i64
    end
  end
end
