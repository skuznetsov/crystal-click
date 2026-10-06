module CrystalClick
  # One normalized Object shared-data chunk paired across its independent
  # Copy lanes and bucket-ordered per-path Data chunks.
  class ObjectSharedAdvancedChunk
    getter row_count : UInt64
    getter copy_streams : ObjectSharedCopyStreams

    @buckets : Array(ObjectSharedPhysicalChunk)

    def initialize(
      @row_count : UInt64,
      @copy_streams : ObjectSharedCopyStreams,
      buckets : Array(ObjectSharedPhysicalChunk),
    )
      unless 1 <= buckets.size <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT
        raise ArgumentError.new("Object shared advanced chunks require 1..256 bucket ordinals")
      end
      buckets.each do |bucket|
        unless bucket.row_count == @row_count
          raise ArgumentError.new("Object shared advanced bucket row counts disagree")
        end
      end
      @buckets = buckets.dup
    end

    def bucket_count : Int32
      @buckets.size
    end

    def buckets : Array(ObjectSharedPhysicalChunk)
      @buckets.dup
    end

    def bucket_at(index : Int) : ObjectSharedPhysicalChunk
      @buckets[index]
    end
  end
end
