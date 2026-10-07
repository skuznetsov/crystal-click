module CrystalClick
  module WidePartWriter
    # Preflighted, generic Dynamic-bearing inputs retained by the two-column
    # adapter. The recursive plans are shared by encoding and staged readback.
    private struct DynamicBulkPartInputPlan
      getter part : TwoColumnBulkPartInput
      getter dynamic_plan : BinaryDynamicBulkPlan
      getter physical : BinaryDynamicBulkPhysicalPlan
      getter codec_budget : BinaryCodecBudget
      getter metadata : RecursiveStoragePartMetadata
      getter canonical_declaration : String

      def initialize(
        @part : TwoColumnBulkPartInput,
        @dynamic_plan : BinaryDynamicBulkPlan,
        @physical : BinaryDynamicBulkPhysicalPlan,
        @codec_budget : BinaryCodecBudget,
        @metadata : RecursiveStoragePartMetadata,
        @canonical_declaration : String,
      )
      end
    end
  end
end
