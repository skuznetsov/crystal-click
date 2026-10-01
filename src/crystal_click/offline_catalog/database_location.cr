module CrystalClick
  class OfflineCatalog
    private struct DatabaseLocation
      getter uuid : String
      getter metadata_path : String

      def initialize(@uuid : String, @metadata_path : String)
      end
    end
  end
end
