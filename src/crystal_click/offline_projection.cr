module CrystalClick
  # Opaque declaration for a named MergeTree projection. This records DDL
  # metadata only; it does not claim that projection data exists in any part.
  struct OfflineProjection
    @name : String
    @definition : String

    def initialize(name : String, definition : String)
      @name = name.dup
      @definition = definition.dup
    end

    def name : String
      @name.dup
    end

    def definition : String
      @definition.dup
    end

    def copy : OfflineProjection
      OfflineProjection.new(@name, @definition)
    end
  end
end
