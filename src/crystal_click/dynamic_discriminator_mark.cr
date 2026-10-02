module CrystalClick
  # One normalized decompressed byte position and its outer-row extent.
  # The terminal stream mark has zero rows and sits at the byte-stream end.
  class DynamicDiscriminatorMark
    getter offset : UInt64
    getter rows : UInt64

    def initialize(@offset : UInt64, @rows : UInt64)
    end
  end
end
