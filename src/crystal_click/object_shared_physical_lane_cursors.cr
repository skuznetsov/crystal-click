module CrystalClick
  # Mutable positions for one side of a physical-parent lane interval.
  class ObjectSharedPhysicalLaneCursors
    property data : Int64
    property paths_marks : Int64
    property substreams : Int64
    property substreams_marks : Int64
    property metadata : Int64

    def initialize(
      @data : Int64,
      @paths_marks : Int64,
      @substreams : Int64,
      @substreams_marks : Int64,
      @metadata : Int64,
    )
    end
  end
end
