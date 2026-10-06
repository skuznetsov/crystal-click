module CrystalClick
  # Shared MAP layout laws for the finite Object V3 profiles admitted by the
  # normalized document codec. The bucket ordinal is deliberately separate
  # from Array nesting levels and from physical stream-name hashing.
  module ObjectSharedBucketLayout
    MAX_BUCKET_COUNT = 256_u64

    def self.supported?(object : ObjectStructure) : Bool
      return false unless object.version == 4_u64
      case object.shared_data_version
      when 0_u64
        object.bucket_count == 1_u64
      when 1_u64
        1_u64 <= object.bucket_count <= MAX_BUCKET_COUNT
      else
        false
      end
    end

    def self.validate!(object : ObjectStructure) : Nil
      unless supported?(object)
        raise UnsupportedFormatError.new(
          "Object composition supports only Object V3 MAP or MAP_WITH_BUCKETS with 1..256 buckets"
        )
      end
      nil
    end

    def self.bucket_count(object : ObjectStructure) : Int32
      validate!(object)
      object.bucket_count.to_i32
    end

    def self.bucket_for(path : String, bucket_count : UInt64) : Int32
      unless 1_u64 <= bucket_count <= MAX_BUCKET_COUNT
        raise ArgumentError.new("Object shared bucket count must be between 1 and 256")
      end
      (ClickHouseSipHash.hash64(path.to_slice) % bucket_count).to_i32
    end

    def self.bucket_for(path : String, bucket_count : Int) : Int32
      unless 1 <= bucket_count <= MAX_BUCKET_COUNT.to_i
        raise ArgumentError.new("Object shared bucket count must be between 1 and 256")
      end
      bucket_for(path, bucket_count.to_u64)
    end
  end
end
