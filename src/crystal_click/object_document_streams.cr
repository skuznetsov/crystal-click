module CrystalClick
  # Detached complete physical lanes for paired logical Object document
  # composition. Malformed lane sets and grids are retained for the decoder to
  # classify; construction does not certify a stream profile.
  class ObjectDocumentStreams
    @structures : ObjectDynamicStructureStreams
    @rows_per_mark : Array(UInt64)
    @typed_paths : Hash(String, BinaryBulkStreams)
    @typed_names : Array(String)
    @typed_dynamic_paths : Hash(String, BinaryDynamicBulkStreams)
    @typed_dynamic_names : Array(String)
    @typed_dynamic_statistics_offsets : Hash(String, Int32)
    @typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32))
    @dynamic_paths : Hash(String, DynamicValueStreams)
    @dynamic_names : Array(String)
    @shared : BinaryBulkStreams

    def initialize(
      structures : ObjectDynamicStructureStreams,
      rows_per_mark : Array(UInt64),
      typed_paths : Hash(String, BinaryBulkStreams),
      dynamic_paths : Hash(String, DynamicValueStreams),
      shared : BinaryBulkStreams,
      typed_dynamic_paths : Hash(String, BinaryDynamicBulkStreams) = Hash(String, BinaryDynamicBulkStreams).new,
      typed_dynamic_statistics_offsets : Hash(String, Int32) = Hash(String, Int32).new,
      typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32)) = Hash(String, Hash(String, Int32)).new,
    )
      @structures = structures
      @rows_per_mark = rows_per_mark.dup
      @typed_paths = Hash(String, BinaryBulkStreams).new
      @typed_names = Array(String).new(typed_paths.size)
      typed_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @typed_paths.has_key?(detached_path)
          raise ArgumentError.new("typed Object lane keys must be unique by raw bytes")
        end
        @typed_paths[detached_path] = streams
        @typed_names << detached_path
      end
      @typed_names.sort! { |left, right| compare_paths(left, right) }

      @typed_dynamic_paths = Hash(String, BinaryDynamicBulkStreams).new
      @typed_dynamic_names = Array(String).new(typed_dynamic_paths.size)
      typed_dynamic_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @typed_dynamic_paths.has_key?(detached_path)
          raise ArgumentError.new("typed Dynamic Object lane keys must be unique by raw bytes")
        end
        @typed_dynamic_paths[detached_path] = streams
        @typed_dynamic_names << detached_path
      end
      @typed_dynamic_names.sort! { |left, right| compare_paths(left, right) }
      @typed_dynamic_statistics_offsets = Hash(String, Int32).new
      @typed_dynamic_site_statistics_offsets = Hash(String, Hash(String, Int32)).new
      typed_dynamic_statistics_offsets.each do |path, offset|
        detached_path = String.new(path.to_slice)
        streams = @typed_dynamic_paths[detached_path]? || raise(ArgumentError.new("typed Dynamic statistics offset has no matching lane: #{path.inspect}"))
        unless streams.structures.has_site?("root")
          raise ArgumentError.new("typed Dynamic root statistics offset has no matching root site: #{path.inspect}")
        end
        validate_statistics_offset!(offset)
        @typed_dynamic_statistics_offsets[detached_path] = offset
        site_offsets = Hash(String, Int32).new
        site_offsets["root"] = offset
        @typed_dynamic_site_statistics_offsets[detached_path] = site_offsets
      end
      typed_dynamic_site_statistics_offsets.each do |path, offsets|
        detached_path = String.new(path.to_slice)
        streams = @typed_dynamic_paths[detached_path]? || raise(ArgumentError.new("typed Dynamic site statistics offsets have no matching lane: #{path.inspect}"))
        site_offsets = @typed_dynamic_site_statistics_offsets[detached_path]?
        unless site_offsets
          site_offsets = Hash(String, Int32).new
          @typed_dynamic_site_statistics_offsets[detached_path] = site_offsets
        end
        offsets.each do |site_path, offset|
          unless streams.structures.has_site?(site_path)
            raise ArgumentError.new("typed Dynamic statistics offset has no matching site: #{path.inspect}:#{site_path.inspect}")
          end
          validate_statistics_offset!(offset)
          detached_site_path = String.new(site_path.to_slice)
          if previous = site_offsets[detached_site_path]?
            unless previous == offset
              raise ArgumentError.new("typed Dynamic root statistics offsets conflict for #{path.inspect}")
            end
          else
            site_offsets[detached_site_path] = offset
          end
        end
      end

      @dynamic_paths = Hash(String, DynamicValueStreams).new
      @dynamic_names = Array(String).new(dynamic_paths.size)
      dynamic_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @dynamic_paths.has_key?(detached_path)
          raise ArgumentError.new("Dynamic Object lane keys must be unique by raw bytes")
        end
        @dynamic_paths[detached_path] = streams
        @dynamic_names << detached_path
      end
      @dynamic_names.sort! { |left, right| compare_paths(left, right) }
      @shared = shared
    end

    def structures : ObjectDynamicStructureStreams
      @structures
    end

    def mark_count : Int32
      @rows_per_mark.size
    end

    def row_count_at(mark_index : Int) : UInt64
      @rows_per_mark[mark_index]
    end

    def rows_per_mark : Array(UInt64)
      @rows_per_mark.dup
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_names[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_names[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_names[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_paths.has_key?(path)
    end

    def typed_paths : Array(String)
      @typed_names.map { |path| String.new(path.to_slice) }
    end

    def typed_for(path : String) : BinaryBulkStreams
      @typed_paths[path]? || raise(KeyError.new("typed Object lanes not found: #{path.inspect}"))
    end

    def typed_dynamic_path_count : Int32
      @typed_dynamic_paths.size
    end

    def typed_dynamic_path_at(index : Int) : String
      String.new(@typed_dynamic_names[index].to_slice)
    end

    def has_typed_dynamic_path?(path : String) : Bool
      @typed_dynamic_paths.has_key?(path)
    end

    def typed_dynamic_paths : Array(String)
      @typed_dynamic_names.map { |path| String.new(path.to_slice) }
    end

    def typed_dynamic_for(path : String) : BinaryDynamicBulkStreams
      @typed_dynamic_paths[path]? || raise(KeyError.new("typed Object Dynamic lanes not found: #{path.inspect}"))
    end

    # Relative byte offset of the root Dynamic statistics flag within the
    # exact structure blob produced or parsed for this typed child.
    def typed_dynamic_statistics_offset(path : String) : Int32?
      if offset = @typed_dynamic_statistics_offsets[path]?
        return offset
      end
      streams = @typed_dynamic_paths[path]?
      return nil unless streams && streams.structures.site_count == 1 && streams.structures.has_site?("root")
      site_offsets = @typed_dynamic_site_statistics_offsets[path]?
      return nil unless site_offsets
      site_offsets["root"]?
    end

    # Relative byte offset of a site's statistics flag. Missing offsets are
    # tolerated for decoded/caller-constructed streams; the writer lane binder
    # requires a complete per-site map before emitting physical lanes.
    def typed_dynamic_site_statistics_offset(path : String, site_path : String) : Int32?
      site_offsets = @typed_dynamic_site_statistics_offsets[path]?
      return nil unless site_offsets
      site_offsets[site_path]?
    end

    def dynamic_path_count : Int32
      @dynamic_paths.size
    end

    def dynamic_path_at(index : Int) : String
      String.new(@dynamic_names[index].to_slice)
    end

    def dynamic_path_byte_size_at(index : Int) : Int32
      @dynamic_names[index].bytesize
    end

    def dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @dynamic_names[index].to_slice[byte_index]
    end

    def has_dynamic_path?(path : String) : Bool
      @dynamic_paths.has_key?(path)
    end

    def dynamic_paths : Array(String)
      @dynamic_names.map { |path| String.new(path.to_slice) }
    end

    def dynamic_for(path : String) : DynamicValueStreams
      @dynamic_paths[path]? || raise(KeyError.new("Dynamic Object lanes not found: #{path.inspect}"))
    end

    def shared : BinaryBulkStreams
      @shared
    end

    private def compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def validate_statistics_offset!(offset : Int32) : Nil
      if offset < 0
        raise ArgumentError.new("typed Dynamic statistics offset must be non-negative")
      end
    end
  end
end
