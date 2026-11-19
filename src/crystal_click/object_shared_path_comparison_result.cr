module CrystalClick
  alias ObjectSharedPathComparisonValue = BinaryValue | Bytes

  # Temporary verifier result whose String values borrow the retained
  # normalized path lanes. It owns one row array and those lanes until the
  # Copy comparison completes; the borrowed spans are never exposed publicly.
  struct ObjectSharedPathComparisonResult
    @rows : Array(ObjectSharedPathComparisonValue)
    @owner : BinaryBulkStreams

    def initialize(@rows : Array(ObjectSharedPathComparisonValue), @owner : BinaryBulkStreams)
    end

    def row_count : Int32
      @rows.size
    end

    def row_at(index : Int) : ObjectSharedPathComparisonValue
      @rows[index]
    end
  end
end
