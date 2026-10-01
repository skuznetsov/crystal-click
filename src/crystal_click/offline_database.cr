module CrystalClick
  # Read-only view of one database in an offline Atomic metadata tree.
  # The catalog reference preserves the lookup context after its original
  # caller drops the catalog variable; the UUID guards against metadata drift.
  class OfflineDatabase
    @catalog : OfflineCatalog
    @name : String
    @uuid : String?
    @virtual_system : Bool

    def initialize(@catalog : OfflineCatalog, name : String, uuid : String?, @virtual_system : Bool = false)
      @name = name.dup
      @uuid = uuid.try(&.dup)
    end

    def name : String
      @name.dup
    end

    def uuid : String
      raise UnsupportedFormatError.new("synthetic system database has no UUID") if @virtual_system
      value = @uuid || raise(UnsupportedFormatError.new("synthetic system database has no UUID"))
      value.dup
    end

    def virtual_system? : Bool
      @virtual_system
    end

    def owned_by?(catalog : OfflineCatalog) : Bool
      @catalog.same?(catalog)
    end

    def table_names : Array(String)
      @catalog.table_names(self)
    end

    def table(name : String) : OfflineTable
      @catalog.table(self, name)
    end

    def [](name : String) : OfflineTable
      table(name)
    end

    def tables : Array(OfflineTable)
      @catalog.tables(self)
    end
  end
end
