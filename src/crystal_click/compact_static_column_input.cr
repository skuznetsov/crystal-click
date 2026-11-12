module CrystalClick
  # Low-level recursive input view consumed by CompactStaticWriter. Public
  # callers enter through CompactPartColumn.binary_bulk; this carrier binds
  # the selected String profile and BASIC Map interpretation.
  class CompactStaticColumnInput
    getter name : String
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter granules : Array(Array(BinaryValue))

    def initialize(
      name : String,
      @type : BinaryDataType,
      @granules : Array(Array(BinaryValue)),
      @profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    )
      @name = String.new(name.to_slice)
    end

    def map_basic? : Bool
      true
    end
  end
end
