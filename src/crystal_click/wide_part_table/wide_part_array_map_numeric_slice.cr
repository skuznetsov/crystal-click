module CrystalClick
  class WidePartArrayMapNumericSlice(K, T) < WidePartArrayMapNumericSliceBase
    getter values : Slice(Array(Array(Tuple(K, T))))
    getter owner : Array(Array(Array(Tuple(K, T))))

    def initialize(@values : Slice(Array(Array(Tuple(K, T)))), @owner : Array(Array(Array(Tuple(K, T)))))
    end
  end
end
