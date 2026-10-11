module CrystalClick
  # Identity of one selected static Compact JSON Object site. It is deliberately
  # distinct from BinaryDynamicJsonLeafKey: a root column is not a Dynamic arm.
  class CompactStaticJsonSiteManifest
    getter column_name : String
    getter physical_prefix : String
    getter callback_prefix : String
    getter descriptor : BinaryDataType

    def initialize(
      column_name : String,
      @descriptor : BinaryDataType,
    )
      unless @descriptor.tag == BinaryDataType::TAG_JSON
        raise ArgumentError.new("Compact static JSON site requires a JSON descriptor")
      end
      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact static JSON column name is empty or exceeds its bound")
      end
      @column_name = String.new(column_name.to_slice)
      @physical_prefix = PhysicalStreamName.escape(column_name)
      @callback_prefix = String.new(column_name.to_slice)
    end
  end
end
