module CrystalClick
  # Detached immutable first-prefix authority for one Dynamic-bearing value
  # column. Every supplied site describes the frozen first block and therefore
  # must carry the full statistics that ClickHouse writes on that block.
  class CompactDynamicWriteContext
    @site_structures : Hash(String, DynamicStructure)

    def initialize(site_structures : Hash(String, DynamicStructure))
      if site_structures.empty?
        raise ArgumentError.new("Compact Dynamic write context requires at least one structure site")
      end

      @site_structures = Hash(String, DynamicStructure).new(initial_capacity: site_structures.size)
      site_structures.each do |path, structure|
        if path.empty?
          raise ArgumentError.new("Compact Dynamic write context site paths must be nonempty")
        end
        unless structure.statistics
          raise ArgumentError.new("Compact Dynamic first-prefix structure requires full statistics at every site")
        end

        detached_path = String.new(path.to_slice)
        if @site_structures.has_key?(detached_path)
          raise ArgumentError.new("Compact Dynamic write context site paths must be unique")
        end
        @site_structures[detached_path] = structure
      end
    end

    # Returns an independently owned path map. DynamicStructure and its
    # statistics are immutable owners, so their references may be shared.
    def site_structures : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new(initial_capacity: @site_structures.size)
      @site_structures.each do |path, structure|
        detached[String.new(path.to_slice)] = structure
      end
      detached
    end

    # Read-only traversal for execution-time validators that do not retain a
    # second path map. DynamicStructure owners are immutable and may be shared.
    def each_site_structure(&block : String, DynamicStructure -> Nil) : Nil
      @site_structures.each { |path, structure| yield path, structure }
      nil
    end

    def structure_at?(path : String) : DynamicStructure?
      @site_structures[path]?
    end

    def site_count : Int32
      @site_structures.size
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactDynamicWriteContext).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, DynamicStructure)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@site_structures.size.to_u64, sizeof({String, DynamicStructure}).to_u64))
      @site_structures.each_key do |path|
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, path.bytesize.to_u64 + 1_u64)
      end
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact Dynamic context workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact Dynamic context workspace overflows UInt64")
      end
      left * right
    end
  end
end
