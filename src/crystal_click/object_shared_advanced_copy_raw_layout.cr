module CrystalClick
  # Detached, uncompressed whole-Object Copy callbacks. Parent offsets retain
  # the exact input framing so chunk/mark agreement can be audited without
  # compressing or guessing from lane bytes.
  class ObjectSharedAdvancedCopyRawLayout
    LANE_NAMES = ["sizes", "indexes", "values"] of String

    @lanes : Hash(String, Bytes)
    @parent_offsets : Hash(String, Array(UInt64))

    def initialize(
      lanes : Hash(String, Bytes),
      parent_offsets : Hash(String, Array(UInt64)),
      budget : BinaryCodecBudget,
    )
      unless lanes.size == LANE_NAMES.size && LANE_NAMES.all? { |name| lanes.has_key?(name) }
        raise ArgumentError.new("advanced inline Copy raw layout must contain sizes, indexes, and values")
      end
      unless parent_offsets.size == LANE_NAMES.size && LANE_NAMES.all? { |name| parent_offsets.has_key?(name) }
        raise ArgumentError.new("advanced inline Copy raw layout parent offsets are incomplete")
      end

      retained_bytes = 0_u64
      retained_elements = 0_u64
      LANE_NAMES.each do |name|
        offsets = parent_offsets[name]
        if offsets.empty? || offsets.first != 0_u64 || offsets.last != lanes[name].size.to_u64
          raise UnsupportedFormatError.new("advanced inline Copy parent offsets do not span the raw lane")
        end
        offsets.each_cons(2) do |pair|
          if pair[1] < pair[0]
            raise UnsupportedFormatError.new("advanced inline Copy parent offsets are not monotone")
          end
        end
        retained_bytes = checked_add(retained_bytes, name.bytesize.to_u64)
        retained_bytes = checked_add(retained_bytes, lanes[name].size.to_u64)
        retained_bytes = checked_add(retained_bytes, offsets.size.to_u64 * 8_u64)
        retained_elements = checked_add(retained_elements, offsets.size.to_u64)
      end
      budget.ensure_future_nodes(LANE_NAMES.size.to_u64)
      budget.ensure_future_elements(retained_elements)
      budget.ensure_wire_bytes(retained_bytes)
      LANE_NAMES.size.times { budget.charge_node }
      budget.charge_elements(retained_elements) if retained_elements > 0_u64
      budget.charge_wire_bytes(retained_bytes) if retained_bytes > 0_u64

      @lanes = Hash(String, Bytes).new(initial_capacity: LANE_NAMES.size)
      @parent_offsets = Hash(String, Array(UInt64)).new(initial_capacity: LANE_NAMES.size)
      LANE_NAMES.each do |name|
        @lanes[String.new(name.to_slice)] = copy_bytes(lanes[name])
        @parent_offsets[String.new(name.to_slice)] = parent_offsets[name].dup
      end
    end

    def raw_lane(name : String) : Bytes
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline Copy role"))
      copy_bytes(source)
    end

    def lane_size(name : String) : Int32
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline Copy role"))
      source.size
    end

    def lane_byte_at(name : String, index : Int) : UInt8
      source = @lanes[name]? || raise(ArgumentError.new("unknown advanced inline Copy role"))
      source[index]
    end

    def parent_offset_count(name : String) : Int32
      offsets_for(name).size
    end

    def parent_offset_at(name : String, index : Int) : UInt64
      offsets_for(name)[index]
    end

    def lane_names : Array(String)
      LANE_NAMES.map { |name| String.new(name.to_slice) }
    end

    private def offsets_for(name : String) : Array(UInt64)
      @parent_offsets[name]? || raise(ArgumentError.new("unknown advanced inline Copy role"))
    end

    private def copy_bytes(bytes : Bytes) : Bytes
      Bytes.new(bytes.size) { |index| bytes[index] }
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("advanced inline Copy raw layout size overflows")
      end
      left + right
    end
  end
end
