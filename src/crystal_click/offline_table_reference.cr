module CrystalClick
  # A syntactic table identity captured from one persisted MV declaration or
  # direct SELECT relation. `database` is always populated; qualification says
  # whether the original spelling named that database explicitly.
  class OfflineTableReference
    @database : String
    @name : String
    @database_qualified : Bool

    def initialize(database : String, name : String, @database_qualified : Bool)
      raise UnsupportedFormatError.new("materialized-view table reference database is empty") if database.empty?
      raise UnsupportedFormatError.new("materialized-view table reference name is empty") if name.empty?
      @database = detached_string(database)
      @name = detached_string(name)
    end

    def database : String
      detached_string(@database)
    end

    def name : String
      detached_string(@name)
    end

    def database_qualified? : Bool
      @database_qualified
    end

    def copy : OfflineTableReference
      OfflineTableReference.new(@database, @name, @database_qualified)
    end

    private def detached_string(value : String) : String
      String.new(value.to_slice)
    end
  end
end
