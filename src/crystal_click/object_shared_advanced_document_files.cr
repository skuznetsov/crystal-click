module CrystalClick
  # Complete detached output roster for one Object ADVANCED/CHUNKED document.
  # Copy is whole-part and the six physical lanes remain independently owned
  # by each bucket codec.
  class ObjectSharedAdvancedDocumentFiles
    COPY_LANE_NAMES = ["sizes", "indexes", "values"] of String

    @copy_lanes : Hash(String, CompressedMarkFiles)
    @buckets : Array(ObjectSharedPhysicalBucketFiles)

    def initialize(copy_lanes : Hash(String, CompressedMarkFiles), buckets : Array(ObjectSharedPhysicalBucketFiles))
      unless copy_lanes.size == COPY_LANE_NAMES.size && COPY_LANE_NAMES.all? { |name| copy_lanes.has_key?(name) }
        raise ArgumentError.new("Object shared advanced Copy output must contain exactly sizes, indexes, and values")
      end
      unless 1 <= buckets.size <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT
        raise ArgumentError.new("Object shared advanced output requires 1..256 bucket ordinals")
      end

      @copy_lanes = Hash(String, CompressedMarkFiles).new
      COPY_LANE_NAMES.each { |name| @copy_lanes[String.new(name.to_slice)] = copy_lanes[name] }
      @buckets = buckets.dup
    end

    def copy_lane(name : String) : CompressedMarkFiles
      @copy_lanes[name]? || raise(ArgumentError.new("unknown Object shared advanced Copy lane"))
    end

    def bucket_count : Int32
      @buckets.size
    end

    def bucket_at(index : Int) : ObjectSharedPhysicalBucketFiles
      @buckets[index]
    end
  end
end
