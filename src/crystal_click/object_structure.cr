require "set"

module CrystalClick
  # Immutable complete Object structure metadata. It records roster identity
  # and version parameters only; no value lanes or placement mode are implied.
  class ObjectStructure
    getter version : UInt64
    getter shared_data_version : UInt64
    getter bucket_count : UInt64

    @dynamic_paths : Array(String)
    @dynamic_path_set : Set(String)
    @legacy_max_dynamic_paths : UInt64?
    @statistics : StructureStatistics?

    def initialize(
      dynamic_paths : Array(String),
      @version : UInt64 = 4_u64,
      @shared_data_version : UInt64 = 0_u64,
      @bucket_count : UInt64 = 1_u64,
      legacy_max_dynamic_paths : UInt64? = nil,
      statistics : StructureStatistics? = nil,
    )
      unless {0_u64, 2_u64, 4_u64}.includes?(@version)
        raise ArgumentError.new("Object structure version must be 0, 2, or 4")
      end

      case @version
      when 0_u64, 2_u64
        unless @shared_data_version == 0_u64 && @bucket_count == 1_u64
          raise ArgumentError.new("legacy Object structures require MAP with one bucket")
        end
        if @version == 0_u64
          unless legacy_max_dynamic_paths
            raise ArgumentError.new("Object V1 requires its legacy maximum-path field")
          end
        elsif legacy_max_dynamic_paths
          raise ArgumentError.new("Object V2 has no legacy maximum-path field")
        end
        unless statistics
          raise ArgumentError.new("Object V1/V2 requires complete legacy statistics")
        end
      when 4_u64
        if legacy_max_dynamic_paths
          raise ArgumentError.new("Object V3 has no legacy maximum-path field")
        end
        unless @shared_data_version <= 3_u64
          raise ArgumentError.new("Object V3 shared-data version must be 0 through 3")
        end
        if @shared_data_version == 0_u64
          unless @bucket_count == 1_u64
            raise ArgumentError.new("Object MAP has exactly one bucket")
          end
        elsif @bucket_count < 1_u64 || @bucket_count > 256_u64
          raise ArgumentError.new("bucket count must be between 1 and 256")
        end
      end

      @dynamic_paths = dynamic_paths.map { |path| String.new(path.to_slice) }
      seen = Set(String).new
      @dynamic_paths.each do |path|
        if seen.includes?(path)
          raise ArgumentError.new("Object dynamic paths must be unique")
        end
        seen.add(path)
      end
      @dynamic_path_set = seen

      if value = statistics
        unless value.count_count == @dynamic_paths.size
          raise ArgumentError.new("Object positional statistics count does not match its path roster")
        end
      end
      @legacy_max_dynamic_paths = legacy_max_dynamic_paths
      @statistics = statistics
    end

    def dynamic_paths : Array(String)
      @dynamic_paths.map { |path| String.new(path.to_slice) }
    end

    def dynamic_path_count : Int32
      @dynamic_paths.size
    end

    def dynamic_path_at(index : Int) : String
      String.new(@dynamic_paths[index].to_slice)
    end

    def dynamic_path_byte_size(index : Int) : Int32
      @dynamic_paths[index].bytesize
    end

    def dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @dynamic_paths[index].to_slice[byte_index]
    end

    def has_dynamic_path?(path : String) : Bool
      @dynamic_path_set.includes?(path)
    end

    def legacy_max_dynamic_paths : UInt64?
      @legacy_max_dynamic_paths
    end

    def statistics : StructureStatistics?
      @statistics
    end

    def ==(other : ObjectStructure) : Bool
      @version == other.@version &&
        @shared_data_version == other.@shared_data_version &&
        @bucket_count == other.@bucket_count &&
        @legacy_max_dynamic_paths == other.@legacy_max_dynamic_paths &&
        @dynamic_paths == other.@dynamic_paths &&
        @statistics == other.@statistics
    end

    def_hash @version, @shared_data_version, @bucket_count,
      @legacy_max_dynamic_paths, @dynamic_paths, @statistics
  end
end
