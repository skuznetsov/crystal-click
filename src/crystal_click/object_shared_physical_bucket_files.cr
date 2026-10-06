module CrystalClick
  # Detached compressed data/mark pairs for all six lanes of one bucket.
  class ObjectSharedPhysicalBucketFiles
    @lanes : Hash(String, CompressedMarkFiles)

    def initialize(lanes : Hash(String, CompressedMarkFiles))
      unless lanes.size == ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.size &&
             ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.all? { |name| lanes.has_key?(name) }
        raise ArgumentError.new("Object shared bucket output must contain exactly the six physical lanes")
      end
      @lanes = Hash(String, CompressedMarkFiles).new
      ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |name|
        @lanes[String.new(name.to_slice)] = lanes[name]
      end
    end

    def lane(name : String) : CompressedMarkFiles
      @lanes[name]? || raise(ArgumentError.new("unknown Object shared physical lane"))
    end

    def lane_names : Array(String)
      ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.map { |name| String.new(name.to_slice) }
    end
  end
end
