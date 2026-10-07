module CrystalClick
  module WidePartWriter
    private struct TwoColumnBulkPartLane
      getter binding : TwoColumnBulkPartRoleBinding
      getter data : Bytes
      getter marks : Bytes
      getter frames : Array(CompressedFrameDescriptor)
      getter logical_size : Int64

      def initialize(
        @binding : TwoColumnBulkPartRoleBinding,
        @data : Bytes,
        @marks : Bytes,
        @frames : Array(CompressedFrameDescriptor),
        @logical_size : Int64,
      )
      end
    end
  end
end
