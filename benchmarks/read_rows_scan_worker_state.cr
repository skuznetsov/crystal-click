module CrystalClickReadRowsScan
  # Scratch owned by one direct Wide scan worker. The object and its backing
  # buffers are created once before READY, then touched only by that worker.
  class WorkerState
    struct Identity
      getter worker : UInt64
      getter mark_scratch : UInt64
      getter mark_scratch_capacity : Int64
      getter decode_workspace : UInt64
      getter decode_buffer : UInt64
      getter decode_buffer_capacity : Int64

      def initialize(
        @worker : UInt64,
        @mark_scratch : UInt64,
        @mark_scratch_capacity : Int64,
        @decode_workspace : UInt64,
        @decode_buffer : UInt64,
        @decode_buffer_capacity : Int64,
      )
      end
    end

    getter mark_scratch : Slice(UInt64)
    getter decode_workspace : CrystalClick::CompressedBlock::DecodeWorkspace

    def initialize(mark_rows : Int32)
      @mark_scratch = Slice(UInt64).new(mark_rows)
      # The workspace object is retained before READY; its byte backing store
      # grows lazily on the first decoded frame and is reused after that.
      @decode_workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new(padded_lz4: true)
    end

    def identity : Identity
      {% if flag?(:read_rows_profile) %}
        Identity.new(
          object_id.to_u64,
          @mark_scratch.to_unsafe.address.to_u64,
          @mark_scratch.size.to_i64,
          @decode_workspace.object_id.to_u64,
          @decode_workspace.buffer_identity,
          @decode_workspace.buffer_capacity.to_i64,
        )
      {% else %}
        Identity.new(0_u64, 0_u64, 0_i64, 0_u64, 0_u64, 0_i64)
      {% end %}
    end
  end
end
