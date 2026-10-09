module CrystalClick
  # Detached, uncompressed Compact callback roles for one advanced bucket.
  # Structure headers and 48-byte suffixes are separated for the native
  # seven-callback schedule; all unresolved coordinates remain explicit.
  class ObjectSharedPhysicalBucketRawLayout
    LANE_NAMES = [
      "structure_prefix", "data", "paths_marks", "substreams",
      "substreams_marks", "paths_substreams_metadata", "structure_suffix",
    ] of String

    @lanes : Hash(String, Bytes)
    @relocations : Array(ObjectSharedInlineLaneRelocation)

    def initialize(
      lanes : Hash(String, Bytes),
      relocations : Array(ObjectSharedInlineLaneRelocation),
      budget : BinaryCodecBudget,
    )
      unless lanes.size == LANE_NAMES.size && LANE_NAMES.all? { |name| lanes.has_key?(name) }
        raise ArgumentError.new("advanced inline bucket raw layout must contain exactly seven callback roles")
      end

      retained_bytes = 0_u64
      LANE_NAMES.each do |name|
        retained_bytes = checked_add(retained_bytes, name.bytesize.to_u64)
        retained_bytes = checked_add(retained_bytes, lanes[name].size.to_u64)
      end
      relocations.each do |relocation|
        retained_bytes = checked_add(retained_bytes, relocation.source_lane_byte_size.to_u64)
        retained_bytes = checked_add(retained_bytes, relocation.target_lane_byte_size.to_u64)
      end
      retained_nodes = LANE_NAMES.size.to_u64 + relocations.size.to_u64
      relocation_work = relocation_validation_work(relocations.size.to_u64)
      retained_elements = LANE_NAMES.size.to_u64 * 2_u64 + relocations.size.to_u64 * 2_u64 + relocation_work
      budget.ensure_future_nodes(retained_nodes)
      budget.ensure_future_elements(retained_elements)
      budget.ensure_wire_bytes(retained_bytes)
      retained_nodes.times { budget.charge_node }
      budget.charge_elements(retained_elements) if retained_elements > 0_u64
      budget.charge_wire_bytes(retained_bytes) if retained_bytes > 0_u64

      @lanes = Hash(String, Bytes).new(initial_capacity: LANE_NAMES.size)
      LANE_NAMES.each do |name|
        @lanes[String.new(name.to_slice)] = copy_bytes(lanes[name])
      end
      @relocations = relocations.dup
      validate_relocations!
    end

    def lane_names : Array(String)
      LANE_NAMES.map { |name| String.new(name.to_slice) }
    end

    def lane(name : String) : Bytes
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline bucket role"))
      copy_bytes(source)
    end

    def lane_size(name : String) : Int32
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline bucket role"))
      source.size
    end

    def lane_byte_at(name : String, index : Int) : UInt8
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline bucket role"))
      source[index]
    end

    def relocation_count : Int32
      @relocations.size
    end

    def relocation_at(index : Int) : ObjectSharedInlineLaneRelocation
      @relocations[index]
    end

    def relocations : Array(ObjectSharedInlineLaneRelocation)
      @relocations.dup
    end

    private def validate_relocations! : Nil
      source_fields = Array(Tuple(String, UInt64, UInt64)).new(@relocations.size)
      @relocations.each do |relocation|
        source_name = relocation.source_lane
        target_name = relocation.target_lane
        source = @lanes[source_name]? ||
                 raise(UnsupportedFormatError.new("advanced inline relocation source role is absent"))
        target = @lanes[target_name]? ||
                 raise(UnsupportedFormatError.new("advanced inline relocation target role is absent"))
        if relocation.source_offset > source.size.to_u64 ||
           ObjectSharedInlineLaneRelocation::COORDINATE_BYTES > source.size.to_u64 - relocation.source_offset
          raise UnsupportedFormatError.new("advanced inline relocation field exceeds its source role")
        end
        if relocation.target_offset > target.size.to_u64
          raise UnsupportedFormatError.new("advanced inline relocation target exceeds its role")
        end
        source_end = relocation.source_offset + ObjectSharedInlineLaneRelocation::COORDINATE_BYTES
        source_fields << {source_name, relocation.source_offset, source_end}
      end
      source_fields.sort! do |left, right|
        name_order = left[0] <=> right[0]
        name_order == 0 ? left[1] <=> right[1] : name_order
      end
      source_fields.each_cons(2) do |pair|
        if pair[0][0] == pair[1][0] && pair[1][1] < pair[0][2]
          raise UnsupportedFormatError.new("advanced inline bucket relocation source fields overlap")
        end
      end
      nil
    end

    private def relocation_validation_work(count : UInt64) : UInt64
      return 0_u64 if count == 0_u64
      if count > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("advanced inline bucket validation work overflows UInt64")
      end
      levels = 0_u64
      remaining = count - 1_u64
      while remaining > 0_u64
        levels += 1_u64
        remaining >>= 1
      end
      if levels > 0_u64 && count > UInt64::MAX // levels
        raise UnsupportedFormatError.new("advanced inline bucket validation work overflows UInt64")
      end
      sort_work = count * levels
      base = count * 3_u64
      if sort_work > UInt64::MAX - base
        raise UnsupportedFormatError.new("advanced inline bucket validation work overflows UInt64")
      end
      base + sort_work
    end

    private def copy_bytes(bytes : Bytes) : Bytes
      Bytes.new(bytes.size) { |index| bytes[index] }
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("advanced inline bucket raw layout size overflows")
      end
      left + right
    end
  end
end
