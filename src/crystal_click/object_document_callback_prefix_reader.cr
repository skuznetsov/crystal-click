module CrystalClick
  # Direct static-JSON entry point over the same typed-prefix traversal used
  # by nested inline JSON. Static roots carry no BinaryDynamicJsonLeafKey and
  # explicitly select the complete Object statistics context.
  class ObjectDocumentCallbackPrefixReader
    def self.read_static_json_prefix(
      tape : T,
      descriptor : BinaryDataType,
      json_descriptor_depth : Int32,
      physical_prefix : String,
      callback_prefix : String,
      array_level : UInt64,
      nested_context : ObjectSharedNestedSerializationContext,
      budget : BinaryCodecBudget,
      bare_inferred_root_json : Bool = true,
      statistics_offset_observer : Proc(String, Int32, Nil)? = nil,
    ) : ObjectDocumentCallbackPrefix forall T
      ObjectDocumentInlinePlanReader.read_json_site_prefix(
        tape,
        descriptor,
        nil,
        json_descriptor_depth,
        physical_prefix,
        callback_prefix,
        array_level,
        nested_context,
        budget,
        ObjectDocumentCallbackPrefix::StatisticsContext::Complete,
        bare_inferred_root_json,
        statistics_offset_observer,
      ).as(ObjectDocumentCallbackPrefix)
    end
  end
end
