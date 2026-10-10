module CrystalClick
  module WidePartWriter
    # Common detached view keeps legacy one-value adapters on the same
    # publisher without changing their historical metadata bytes.
    private struct WidePartMetadataEnvelope
      getter columns : String
      getter substreams : String
      getter count : String
      getter serialization : String
      getter metadata_version : String
      getter codec : String

      def initialize(metadata : WidePartMetadata)
        @columns = metadata.columns
        @substreams = metadata.substreams
        @count = metadata.count
        @serialization = metadata.serialization
        @metadata_version = metadata.metadata_version
        @codec = metadata.codec
      end

      def initialize(metadata : RecursiveStoragePartMetadata)
        @columns = metadata.columns
        @substreams = metadata.substreams
        @count = metadata.count
        @serialization = metadata.serialization
        @metadata_version = metadata.metadata_version
        @codec = metadata.codec
      end
    end
  end
end
