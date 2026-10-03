module CrystalClick
  # W84 keeps one UInt64/String Array leaf per Array(Map) entry. The additional
  # count is distinct from Map entries because each entry owns its own nested
  # value Array, including when that Array is empty.
  abstract class WidePartArrayMapArrayLeafRowsBase < WidePartArrayMapNumericRowsBase
    abstract def value_count : UInt64
  end
end
