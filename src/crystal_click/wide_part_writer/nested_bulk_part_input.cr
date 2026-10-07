module CrystalClick
  module WidePartWriter
    # Preflighted, Nested-specific inputs retained by the nominal adapter.
    private struct NestedBulkPartInputPlan
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
