module CrystalClick
  # Exact identity of one JSON descriptor leaf owned by an ordinary actual
  # arm at a Dynamic site. The empty descriptor path denotes a direct JSON
  # actual and preserves the W208-W210 binding shape without ambiguity.
  class BinaryDynamicJsonLeafKey
    getter canonical_arm_index : Int32

    @dynamic_site : String
    @descriptor_child_path : Array(Int32)

    def initialize(
      dynamic_site : String,
      canonical_arm_index : Int,
      descriptor_child_path : Array(Int32),
    )
      raise ArgumentError.new("Dynamic JSON leaf canonical arm must be nonnegative") if canonical_arm_index < 0
      descriptor_child_path.each do |index|
        raise ArgumentError.new("Dynamic JSON leaf child indices must be nonnegative") if index < 0
      end
      if canonical_arm_index > Int32::MAX
        raise ArgumentError.new("Dynamic JSON leaf canonical arm exceeds Int32")
      end
      # `String#to_slice` is read-only, but callers can still mutate the
      # backing storage through `to_unsafe`; detach it because this value is
      # retained as a Hash key.
      @dynamic_site = String.new(dynamic_site.to_slice.dup)
      @canonical_arm_index = canonical_arm_index.to_i32
      @descriptor_child_path = descriptor_child_path.dup
    end

    # Return detached bytes so callers cannot mutate Hash identity through
    # unsafe access to the String backing storage.
    def dynamic_site : String
      String.new(@dynamic_site.to_slice.dup)
    end

    # Budget-oriented accessors avoid allocating a detached String just to
    # measure or inspect the retained key.
    def dynamic_site_bytesize : Int32
      @dynamic_site.bytesize
    end

    def dynamic_site_byte_at(index : Int) : UInt8
      @dynamic_site.byte_at(index)
    end

    # Compare the retained site names bytewise without allocating detached
    # Strings. This is the same lexicographic order used by the String-based
    # leaf-key comparators.
    def compare_dynamic_site(other : BinaryDynamicJsonLeafKey) : Int32
      left_size = dynamic_site_bytesize
      right_size = other.dynamic_site_bytesize
      common_size = Math.min(left_size, right_size)
      common_size.times do |index|
        byte_order = dynamic_site_byte_at(index) <=> other.dynamic_site_byte_at(index)
        return byte_order unless byte_order == 0
      end
      left_size <=> right_size
    end

    # Return a detached path so a key remains stable while used in a Hash.
    def descriptor_child_path : Array(Int32)
      @descriptor_child_path.dup
    end

    def descriptor_path_size : Int32
      @descriptor_child_path.size
    end

    def descriptor_child_at(index : Int) : Int32
      @descriptor_child_path[index]
    end

    def with_child(index : Int) : BinaryDynamicJsonLeafKey
      unless index >= 0 && index <= Int32::MAX
        raise ArgumentError.new("Dynamic JSON leaf child index is outside Int32")
      end
      path = @descriptor_child_path.dup
      path << index.to_i32
      BinaryDynamicJsonLeafKey.new(@dynamic_site, @canonical_arm_index, path)
    end

    # Resolve this binding path against the selected canonical arm descriptor.
    # The returned descriptor must be an exact JSON leaf; a prefix, an invalid
    # edge, or a path that crosses a Dynamic site is not a binding.
    def resolve_json_type(root : BinaryDataType) : BinaryDataType
      selected = root
      @descriptor_child_path.each do |child_index|
        if selected.tag == BinaryDataType::TAG_DYNAMIC
          raise ArgumentError.new("Dynamic JSON leaf path cannot cross a nested Dynamic site")
        end
        unless 0 <= child_index < selected.child_count
          raise ArgumentError.new("Dynamic JSON leaf path is outside its actual descriptor")
        end
        selected = selected.child_at(child_index)
      end
      unless selected.tag == BinaryDataType::TAG_JSON
        raise ArgumentError.new("Dynamic JSON leaf path does not identify a JSON descriptor")
      end
      selected
    end

    def ==(other : BinaryDynamicJsonLeafKey) : Bool
      @dynamic_site == other.@dynamic_site &&
        @canonical_arm_index == other.@canonical_arm_index &&
        @descriptor_child_path == other.@descriptor_child_path
    end

    def hash(hasher)
      hasher = @dynamic_site.hash(hasher)
      hasher = @canonical_arm_index.hash(hasher)
      @descriptor_child_path.hash(hasher)
    end
  end
end
