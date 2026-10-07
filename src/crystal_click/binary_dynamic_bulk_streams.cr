module CrystalClick
  # Paired detached occurrence structures and normalized decompressed lanes.
  # Both component owners detach their mutable inputs; this owner keeps their
  # association without adding physical filename or compression semantics.
  class BinaryDynamicBulkStreams
    getter structures : BinaryDynamicStructureStreams
    getter data : BinaryBulkStreams
    @json_objects : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams)

    def initialize(
      @structures : BinaryDynamicStructureStreams,
      @data : BinaryBulkStreams,
      json_objects : Hash(Tuple(String, Int32), ObjectDocumentStreams) = Hash(Tuple(String, Int32), ObjectDocumentStreams).new,
      budget : BinaryCodecBudget? = nil,
      json_object_leaf_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams) = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new,
    )
      if owner = budget
        count = json_objects.size.to_u64 + json_object_leaf_streams.size.to_u64
        owner.preflight_children(count) if count > 0_u64
        owner.charge_wire_bytes(self.class.json_object_key_bytesize_total(json_objects)) if json_objects.size > 0
        owner.charge_wire_bytes(self.class.json_object_leaf_key_bytesize_total(json_object_leaf_streams)) if json_object_leaf_streams.size > 0
        count.times { owner.charge_node }
      end
      @json_objects = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new(
        initial_capacity: json_objects.size + json_object_leaf_streams.size,
      )
      json_objects.each do |legacy_key, streams|
        key = BinaryDynamicJsonLeafKey.new(legacy_key[0], legacy_key[1], [] of Int32)
        if @json_objects.has_key?(key)
          raise ArgumentError.new("Dynamic JSON Object child keys must be unique")
        end
        @json_objects[key] = streams
      end
      json_object_leaf_streams.each do |key, streams|
        if @json_objects.has_key?(key)
          raise ArgumentError.new("Dynamic JSON Object child keys must be unique")
        end
        @json_objects[key] = streams
      end
    end

    # Legacy tuple keys expose only direct JSON actuals. Wrapped callers use
    # #json_object_leaf_keys to retain multiple sibling leaves in one arm.
    def json_object_keys : Array(Tuple(String, Int32))
      json_object_leaf_keys.compact_map do |key|
        next unless key.descriptor_path_size == 0
        {key.dynamic_site, key.canonical_arm_index}
      end.sort_by { |key| {key[0], key[1]} }
    end

    def json_object_leaf_keys : Array(BinaryDynamicJsonLeafKey)
      keys = @json_objects.keys
      keys.sort! do |left, right|
        compare_leaf_keys(left, right)
      end
      keys
    end

    def json_object_keys(budget : BinaryCodecBudget) : Array(Tuple(String, Int32))
      count = 0_u64
      bytes = 0_u64
      @json_objects.each_key do |key|
        next unless key.descriptor_path_size == 0
        count = checked_add(count, 1_u64)
        bytes = checked_add(bytes, key.dynamic_site_bytesize.to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
      count.times { budget.charge_node }
      keys = Array(Tuple(String, Int32)).new(count.to_i)
      @json_objects.each_key do |key|
        next unless key.descriptor_path_size == 0
        keys << {key.dynamic_site, key.canonical_arm_index}
      end
      keys.sort_by! { |key| {key[0], key[1]} }
      keys
    end

    def json_object_leaf_keys(budget : BinaryCodecBudget) : Array(BinaryDynamicJsonLeafKey)
      count = @json_objects.size.to_u64
      path_elements = 0_u64
      @json_objects.each_key do |key|
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

    def json_object_count : Int32
      @json_objects.size
    end

    def json_object_key_bytesize_total : UInt64
      total = 0_u64
      @json_objects.each_key do |key|
        if key.descriptor_path_size != 0
          next
        end
        total = checked_add(total, key.dynamic_site_bytesize.to_u64)
      end
      total
    end

    def json_object_leaf_key_bytesize_total : UInt64
      self.class.json_object_leaf_key_bytesize_total(@json_objects)
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

    def self.json_object_leaf_key_bytesize_total(
      json_objects : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
    ) : UInt64
      total = 0_u64
      json_objects.each_key do |key|
        size = key.dynamic_site_bytesize.to_u64 + key.descriptor_path_size.to_u64 * 4_u64
        if total > UInt64::MAX - size
          raise CorruptPartError.new("Dynamic JSON Object child key bytes overflow UInt64")
        end
        total += size
      end
      total
    end

    def has_json_object?(site : String, canonical_arm_index : Int) : Bool
      has_json_object_leaf?(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32))
    end

    def has_json_object_leaf?(key : BinaryDynamicJsonLeafKey) : Bool
      @json_objects.has_key?(key)
    end

    def json_object_for(site : String, canonical_arm_index : Int) : ObjectDocumentStreams
      json_object_leaf_for(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32))
    end

    def json_object_leaf_for(key : BinaryDynamicJsonLeafKey) : ObjectDocumentStreams
      @json_objects[key]? ||
        raise KeyError.new("Dynamic JSON Object child stream not found for #{key.dynamic_site.inspect}:#{key.canonical_arm_index}")
    end

    private def compare_leaf_keys(
      left : BinaryDynamicJsonLeafKey,
      right : BinaryDynamicJsonLeafKey,
    ) : Int32
      site_order = left.compare_dynamic_site(right)
      return site_order unless site_order == 0
      arm_order = left.canonical_arm_index <=> right.canonical_arm_index
      return arm_order unless arm_order == 0
      common_path = Math.min(left.descriptor_path_size, right.descriptor_path_size)
      common_path.times do |index|
        order = left.descriptor_child_at(index) <=> right.descriptor_child_at(index)
        return order unless order == 0
      end
      left.descriptor_path_size <=> right.descriptor_path_size
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Dynamic JSON Object child key bytes overflow UInt64")
      end
      left + right
    end
  end
end
