module CrystalClick
  # Low-level recursive input view consumed by CompactStaticWriter. Public
  # callers enter through CompactPartColumn.binary_bulk; this carrier only
  # binds the admitted single-stream profile and BASIC Map interpretation.
  class CompactStaticColumnInput
    getter name : String
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter granules : Array(Array(BinaryValue))

    def initialize(name : String, @type : BinaryDataType, @granules : Array(Array(BinaryValue)))
      @name = String.new(name.to_slice)
      @profile = BinaryBulkProfile.single_stream
    end

    def map_basic? : Bool
      true
    end
  end
end
