module CrystalClick
  # The column name and declared type parsed from ClickHouse table DDL.
  struct OfflineColumn
    getter name : String
    getter type : String
    getter alias_column : Bool
    getter key_candidate_column : Bool

    def initialize(
      @name : String,
      @type : String,
      @alias_column : Bool = false,
      @key_candidate_column : Bool = true,
    )
    end
  end
end
