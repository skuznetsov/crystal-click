module CrystalClick
  # Selects the dictionary ownership used by the bounded LowCardinality
  # storage writer. Ordinary bulk streams retain the part-global profile;
  # Object shared paths may inline the staged keys in each index occurrence.
  enum BinaryLowCardinalityStoragePolicy
    PartGlobalDictionary
    AdditionalKeysOnly
  end
end
