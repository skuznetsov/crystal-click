module CrystalClick
  # Keyless static-site entry into the existing Object callback materializer.
  # Value serde, lane normalization and shared MAP decoding stay in the common
  # materializer; this owner only supplies the framer-certified roles and the
  # offsets observed while parsing complete Dynamic prefixes.
  class ObjectDocumentCallbackBodyMaterializer
    def self.materialize(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair),
      statistics_offsets : Hash(String, Int32),
    ) : ObjectDocumentStreams
      prefix.validate_physical_owner!(physical_plan)
      prefix.bind_body_schedule!(role_bindings, callback_pairs)
      ObjectDocumentInlineBodyMaterializer.materialize(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
        statistics_offsets,
      )
    end
  end
end
