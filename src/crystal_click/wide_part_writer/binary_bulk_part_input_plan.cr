module CrystalClick
  module WidePartWriter
    # Fully preflighted input shared by every nominal static BinaryBulk part
    # adapter.
    private struct BinaryBulkPartInputPlan
      getter part : TwoColumnBulkPartInput
      getter physical : BinaryBulkPhysicalPlan
      getter metadata : RecursiveStoragePartMetadata
      getter canonical_declaration : String

      def initialize(
        @part : TwoColumnBulkPartInput,
        @physical : BinaryBulkPhysicalPlan,
        @metadata : RecursiveStoragePartMetadata,
        @canonical_declaration : String,
      )
      end
    end
  end
end
