module CrystalClick
  # :nodoc:
  # Reusable decoder and typed value storage for one exclusive ordinary Wide
  # UInt64 scan. Each selected column has a private value lane; decoding is
  # serial so one frame workspace is sufficient for the whole scan worker.
  class WideUInt64ScanWorkspace
    getter column_count : Int32

    @scratch : Array(Array(UInt64))
    @decode_workspace : CompressedBlock::DecodeWorkspace

    def initialize(column_count : Int)
      raise BoundsError.new("Wide UInt64 scan column count is out of range") if column_count <= 0 || column_count > WidePartTable::MAX_COLUMNS
      @column_count = column_count.to_i32
      @scratch = Array(Array(UInt64)).new(column_count) { [] of UInt64 }
      # Public typed Wide readers use the existing unchecked frame policy.
      @decode_workspace = CompressedBlock::DecodeWorkspace.new
    end

    def prepare(max_mark_rows : UInt64) : Nil
      raise CorruptPartError.new("mark row count exceeds limit") if max_mark_rows > WidePartTable::MAX_MARK_ROWS
      capacity = max_mark_rows.to_i + 1
      @scratch.each_with_index do |values, index|
        @scratch[index] = Array(UInt64).new(capacity, 0_u64) if values.size < capacity
      end
      nil
    end

    def scratch_slice(index : Int) : Slice(UInt64)
      values = @scratch[index]
      values.to_unsafe.to_slice(values.size)
    end

    def decode_workspace : CompressedBlock::DecodeWorkspace
      @decode_workspace
    end

    # Payload bytes held across the selected-column lanes and frame buffer.
    # Object headers and allocator rounding are intentionally excluded.
    def retained_payload_bytes : UInt64
      bytes = @decode_workspace.buffer_capacity.to_u64
      @scratch.each do |values|
        bytes += values.size.to_u64 * sizeof(UInt64).to_u64
      end
      bytes
    end
  end
end
