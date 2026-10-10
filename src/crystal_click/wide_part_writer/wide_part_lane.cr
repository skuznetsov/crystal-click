module CrystalClick
  module WidePartWriter
    private struct WidePartLane
      getter binding : WidePartLaneBinding
      getter data : Bytes
      getter marks : Bytes
      getter frames : Array(CompressedFrameDescriptor)
      getter logical_size : Int64

      def initialize(
        @binding : WidePartLaneBinding,
        @data : Bytes,
        @marks : Bytes,
        @frames : Array(CompressedFrameDescriptor),
        @logical_size : Int64,
      )
      end
    end
  end
end
