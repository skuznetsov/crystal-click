module CrystalClick
  # Detached arm-set owner for one decompressed Dynamic V3 logical-value
  # stream family. Arm payloads are immutable BinaryBulkStreams owners; keys
  # are copied so later caller mutation cannot rename a retained arm.
  class DynamicValueStreams
    @discriminators : DynamicDiscriminatorStream
    @arms : Hash(String, BinaryBulkStreams)

    def initialize(discriminators : DynamicDiscriminatorStream, arms : Hash(String, BinaryBulkStreams))
      @discriminators = discriminators
      @arms = Hash(String, BinaryBulkStreams).new
      arms.each do |name, streams|
        detached_name = String.new(name.to_slice)
        if @arms.has_key?(detached_name)
          raise ArgumentError.new("Dynamic arm names must be unique by raw bytes")
        end
        @arms[detached_name] = streams
      end
    end

    def discriminators : DynamicDiscriminatorStream
      @discriminators
    end

    def arm(name : String) : BinaryBulkStreams
      @arms[name]
    end

    def arm_names : Array(String)
      names = @arms.keys.map { |name| String.new(name.to_slice) }
      names.sort!
      names
    end

    # Scalar membership/count queries let a bounded codec validate its
    # expected arm set before asking for any detached roster snapshot.
    def arm_count : Int32
      @arms.size
    end

    def has_arm?(name : String) : Bool
      @arms.has_key?(name)
    end
  end
end
