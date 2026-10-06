module CrystalClick
  class WidePartNumericMapSlice(K, T) < WidePartNumericMapSliceBase
    getter values : Slice(Array(Tuple(K, T)))
    getter owner : Array(Array(Tuple(K, T)))

    def initialize(@values : Slice(Array(Tuple(K, T))), @owner : Array(Array(Tuple(K, T))))
    end
  end
end
