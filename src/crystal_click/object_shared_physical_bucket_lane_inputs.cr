module CrystalClick
  # Exact six-file input roster for one already-authenticated physical bucket.
  class ObjectSharedPhysicalBucketLaneInputs
    LANE_NAMES = [
      "structure", "data", "paths_marks", "substreams", "substreams_marks", "paths_substreams_metadata",
    ] of String

    @lanes : Hash(String, ObjectSharedPhysicalLaneInput)

    def initialize(lanes : Hash(String, ObjectSharedPhysicalLaneInput))
      unless lanes.size == LANE_NAMES.size && LANE_NAMES.all? { |name| lanes.has_key?(name) }
        raise ArgumentError.new("Object shared bucket input must contain exactly the six physical lanes")
      end
      @lanes = Hash(String, ObjectSharedPhysicalLaneInput).new
      LANE_NAMES.each { |name| @lanes[String.new(name.to_slice)] = lanes[name] }
    end

    def lane(name : String) : ObjectSharedPhysicalLaneInput
      @lanes[name]? || raise(ArgumentError.new("unknown Object shared physical lane"))
    end

    def lane_names : Array(String)
      LANE_NAMES.map { |name| String.new(name.to_slice) }
    end
  end
end
