module CrystalClick
  module WidePartWriter
    # Backward-compatible internal adapter. Historical two-column writers
    # preserve their own admission and metadata, then use the schema-wide
    # publication owner for checksums, staging, readback and exclusive rename.
    private class TwoColumnBulkPartWriter
      def self.write(
        input : TwoColumnBulkPartInput,
        keys : Slice(UInt64),
        metadata : RecursiveStoragePartMetadata,
        encoded_files : Hash(String, CompressedMarkFiles),
        rows_per_mark : Int32,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
        &validate_value : String -> Nil
      ) : String
        bindings = Array(WidePartLaneBinding).new(input.role_bindings.size)
        input.role_bindings.each do |_role, binding|
          bindings << WidePartLaneBinding.new(
            input.value_name,
            binding.logical_name,
            binding.data_filename,
            binding.marks_filename
          )
        end
        publication = WidePartPublicationInput.new(
          input.target,
          input.parent,
          input.key_name,
          input.mark_count,
          input.expected_files,
          input.expected_rows,
          input.logical_names,
          bindings
        )
        WidePartPublisher.write(
          publication,
          keys,
          WidePartMetadataEnvelope.new(metadata),
          encoded_files,
          rows_per_mark,
          limits,
          transport_limits
        ) { |stage| validate_value.call(stage) }
      end
    end
  end
end
