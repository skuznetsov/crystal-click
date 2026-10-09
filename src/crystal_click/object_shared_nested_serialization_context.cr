module CrystalClick
  # Inherited settings for the nested Object serializer used by a JSON child.
  # The chunk target is a write-time scheduling directive; readers consume the
  # persisted chunk schedule instead and therefore retain no synthetic target.
  class ObjectSharedNestedSerializationContext
    getter shared_data_version : UInt64
    getter profile : BinaryBulkProfile

    @target_chunk_rows : Int32?

    private def initialize(
      @shared_data_version : UInt64,
      @target_chunk_rows : Int32?,
      @profile : BinaryBulkProfile,
    )
      unless @shared_data_version <= 3_u64
        raise ArgumentError.new("nested Object shared-data version must be between zero and three")
      end
      if target = @target_chunk_rows
        unless target > 0
          raise ArgumentError.new("nested Object target chunk rows must be positive")
        end
      end
    end

    def self.for_write(
      shared_data_version : UInt64,
      target_chunk_rows : Int32,
      profile : BinaryBulkProfile,
    ) : ObjectSharedNestedSerializationContext
      new(shared_data_version, target_chunk_rows, profile)
    end

    def self.for_read(
      shared_data_version : UInt64,
      profile : BinaryBulkProfile,
    ) : ObjectSharedNestedSerializationContext
      new(shared_data_version, nil, profile)
    end

    def writing? : Bool
      !@target_chunk_rows.nil?
    end

    def target_chunk_rows : Int32
      @target_chunk_rows || raise(ArgumentError.new("nested Object read context has no write chunk target"))
    end
  end
end
