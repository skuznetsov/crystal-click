module CrystalClick
  # Paired detached occurrence structures and normalized decompressed lanes.
  # Both component owners detach their mutable inputs; this owner keeps their
  # association without adding physical filename or compression semantics.
  class BinaryDynamicBulkStreams
    getter structures : BinaryDynamicStructureStreams
    getter data : BinaryBulkStreams
    @json_objects : Hash(Tuple(String, Int32), ObjectDocumentStreams)

    def initialize(
      @structures : BinaryDynamicStructureStreams,
      @data : BinaryBulkStreams,
      json_objects : Hash(Tuple(String, Int32), ObjectDocumentStreams) = Hash(Tuple(String, Int32), ObjectDocumentStreams).new,
      budget : BinaryCodecBudget? = nil,
    )
      if owner = budget
        count = json_objects.size.to_u64
        owner.preflight_children(count) if count > 0_u64
        owner.charge_wire_bytes(self.class.json_object_key_bytesize_total(json_objects)) if count > 0_u64
        count.times { owner.charge_node }
      end
      @json_objects = Hash(Tuple(String, Int32), ObjectDocumentStreams).new(initial_capacity: json_objects.size)
      json_objects.each do |key, streams|
        detached_key = {String.new(key[0].to_slice), key[1]}
        if @json_objects.has_key?(detached_key)
          raise ArgumentError.new("Dynamic JSON Object child keys must be unique")
        end
        @json_objects[detached_key] = streams
      end
    end

    def json_object_keys : Array(Tuple(String, Int32))
      @json_objects.keys.map { |key| {String.new(key[0].to_slice), key[1]} }.sort_by { |key| {key[0], key[1]} }
    end

    def json_object_count : Int32
      @json_objects.size
    end

    def json_object_key_bytesize_total : UInt64
      self.class.json_object_key_bytesize_total(@json_objects)
    end

    def self.json_object_key_bytesize_total(
      json_objects : Hash(Tuple(String, Int32), ObjectDocumentStreams),
    ) : UInt64
      total = 0_u64
      json_objects.each_key do |key|
        size = key[0].bytesize.to_u64
        if total > UInt64::MAX - size
          raise CorruptPartError.new("Dynamic JSON Object child key bytes overflow UInt64")
        end
        total += size
      end
      total
    end

    # Copy the owner keys only after their full logical and byte cost is
    # admitted by the shared read budget.
    def json_object_keys(budget : BinaryCodecBudget) : Array(Tuple(String, Int32))
      count = @json_objects.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(json_object_key_bytesize_total) if count > 0_u64
      count.times { budget.charge_node }
      keys = Array(Tuple(String, Int32)).new(count.to_i)
      @json_objects.each_key do |key|
        keys << {String.new(key[0].to_slice), key[1]}
      end
      keys
    end

    def has_json_object?(site : String, canonical_arm_index : Int) : Bool
      @json_objects.has_key?({site, canonical_arm_index.to_i32})
    end

    def json_object_for(site : String, canonical_arm_index : Int) : ObjectDocumentStreams
      @json_objects[{site, canonical_arm_index.to_i32}]? ||
        raise KeyError.new("Dynamic JSON Object child stream not found for #{site.inspect}:#{canonical_arm_index}")
    end
  end
end
