module CrystalClick
  # Detached arm-set owner for one decompressed Dynamic V3 logical-value
  # stream family. Arm payloads are immutable BinaryBulkStreams owners; keys
  # are copied so later caller mutation cannot rename a retained arm.
  class DynamicValueStreams
    @discriminators : DynamicDiscriminatorStream
    @arms : Hash(String, BinaryBulkStreams)
    @json_object_leaf_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams)

    def initialize(
      discriminators : DynamicDiscriminatorStream,
      arms : Hash(String, BinaryBulkStreams),
      budget : BinaryCodecBudget? = nil,
      json_object_leaf_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams) = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new,
    )
      @discriminators = discriminators
      if owner = budget
        count = json_object_leaf_streams.size.to_u64
        owner.preflight_children(count) if count > 0_u64
        owner.charge_wire_bytes(self.class.json_object_leaf_key_bytesize_total(json_object_leaf_streams)) if count > 0_u64
        count.times { owner.charge_node }
      end
      @arms = Hash(String, BinaryBulkStreams).new
      arms.each do |name, streams|
        detached_name = String.new(name.to_slice)
        if @arms.has_key?(detached_name)
          raise ArgumentError.new("Dynamic arm names must be unique by raw bytes")
        end
        @arms[detached_name] = streams
      end
      @json_object_leaf_streams = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new(
        initial_capacity: json_object_leaf_streams.size,
      )
      json_object_leaf_streams.each do |key, streams|
        if @json_object_leaf_streams.has_key?(key)
          raise ArgumentError.new("Dynamic JSON Object child keys must be unique")
        end
        @json_object_leaf_streams[key] = streams
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

    def json_object_leaf_keys : Array(BinaryDynamicJsonLeafKey)
      keys = @json_object_leaf_streams.keys
      keys.sort! do |left, right|
        site_order = left.compare_dynamic_site(right)
        next site_order unless site_order == 0
        arm_order = left.canonical_arm_index <=> right.canonical_arm_index
        next arm_order unless arm_order == 0
        common_path = Math.min(left.descriptor_path_size, right.descriptor_path_size)
        path_order = 0
        common_path.times do |index|
          path_order = left.descriptor_child_at(index) <=> right.descriptor_child_at(index)
          break unless path_order == 0
        end
        path_order == 0 ? left.descriptor_path_size <=> right.descriptor_path_size : path_order
      end
      keys
    end

    def json_object_leaf_keys(budget : BinaryCodecBudget) : Array(BinaryDynamicJsonLeafKey)
      count = @json_object_leaf_streams.size.to_u64
      path_elements = 0_u64
      @json_object_leaf_streams.each_key do |key|
        size = key.descriptor_path_size.to_u64
        if path_elements > UInt64::MAX - size
          raise CorruptPartError.new("Dynamic JSON Object child path count overflows UInt64")
        end
        path_elements += size
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(json_object_leaf_key_bytesize_total) if count > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      json_object_leaf_keys
    end

    def json_object_leaf_count : Int32
      @json_object_leaf_streams.size
    end

    def has_json_object_leaf?(key : BinaryDynamicJsonLeafKey) : Bool
      @json_object_leaf_streams.has_key?(key)
    end

    def json_object_leaf_for(key : BinaryDynamicJsonLeafKey) : ObjectDocumentStreams
      @json_object_leaf_streams[key]? ||
        raise KeyError.new("Dynamic JSON Object child stream not found for #{key.dynamic_site.inspect}:#{key.canonical_arm_index}")
    end

    # A Dynamic arm reader owns only the JSON Object children beneath its
    # canonical ordinary arm. Build that detached map after charging the
    # bounded key and entry copies against the same decode operation.
    def json_object_leaf_streams_for_arm(
      canonical_arm_index : Int,
      budget : BinaryCodecBudget,
    ) : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams)
      count = 0_u64
      path_elements = 0_u64
      key_bytes = 0_u64
      @json_object_leaf_streams.each_key do |key|
        next unless key.canonical_arm_index == canonical_arm_index
        count += 1_u64
        path_size = key.descriptor_path_size.to_u64
        if path_elements > UInt64::MAX - path_size
          raise CorruptPartError.new("Dynamic JSON Object child path count overflows UInt64")
        end
        path_elements += path_size
        bytes = key.dynamic_site_bytesize.to_u64 + path_size * 4_u64
        if key_bytes > UInt64::MAX - bytes
          raise CorruptPartError.new("Dynamic JSON Object child key bytes overflow UInt64")
        end
        key_bytes += bytes
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(key_bytes) if count > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64

      result = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new(initial_capacity: count.to_i)
      @json_object_leaf_streams.each do |key, streams|
        next unless key.canonical_arm_index == canonical_arm_index
        result[BinaryDynamicJsonLeafKey.new(key.dynamic_site, key.canonical_arm_index, key.descriptor_child_path)] = streams
      end
      result
    end

    def json_object_leaf_key_bytesize_total : UInt64
      self.class.json_object_leaf_key_bytesize_total(@json_object_leaf_streams)
    end

    def self.json_object_leaf_key_bytesize_total(
      streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
    ) : UInt64
      total = 0_u64
      streams.each_key do |key|
        size = key.dynamic_site_bytesize.to_u64 + key.descriptor_path_size.to_u64 * 4_u64
        if total > UInt64::MAX - size
          raise CorruptPartError.new("Dynamic JSON Object child key bytes overflow UInt64")
        end
        total += size
      end
      total
    end
  end
end
