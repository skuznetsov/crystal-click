module CrystalClick
  class OfflineCatalog
    private struct DatabaseLocation
      getter name : String
      getter uuid : String
      getter metadata_path : String

      def initialize(name : String, uuid : String, metadata_path : String)
        @name = String.new(name.to_slice)
        @uuid = String.new(uuid.to_slice)
        @metadata_path = String.new(metadata_path.to_slice)
      end
    end
  end
end
