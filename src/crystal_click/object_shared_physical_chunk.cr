module CrystalClick
  # One logical-row chunk in a physical parent interval. Zero-row chunks are
  # valid and may be pathless; the enclosing physical parent remains positive.
  class ObjectSharedPhysicalChunk
    getter row_count : UInt64

    @paths : Array(ObjectSharedPhysicalPath)

    def initialize(@row_count : UInt64, paths : Array(ObjectSharedPhysicalPath))
      if @row_count > Int32::MAX.to_u64
        raise ArgumentError.new("Object shared logical chunk rows exceed Int32")
      end
      if @row_count == 0_u64 && !paths.empty?
        raise ArgumentError.new("zero-row Object shared chunks must be pathless")
      end
      paths.each_cons(2) do |pair|
        unless ObjectSharedPhysicalPath.compare_names(pair[0].name, pair[1].name) < 0
          raise ArgumentError.new("Object shared chunk paths must be byte-sorted and unique")
        end
      end
      @paths = paths.dup
    end

    def paths : Array(ObjectSharedPhysicalPath)
      @paths.dup
    end

    def path_count : Int32
      @paths.size
    end

    def path_at(index : Int) : ObjectSharedPhysicalPath
      @paths[index]
    end
  end
end
