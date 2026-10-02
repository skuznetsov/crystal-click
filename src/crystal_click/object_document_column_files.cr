module CrystalClick
  # Owned unpublished file-pair roster for one normalized Object column.
  # Returned byte slices are detached; no filesystem or part publication is
  # performed by this value.
  class ObjectDocumentColumnFiles
    @plan : ObjectDocumentPlan
    @physical : ObjectDocumentPhysicalPlan
    @pairs : Hash(String, CompressedMarkFiles)
    @stream_names : Array(String)
    @file_names : Array(String)
    @file_lookup : Hash(String, Tuple(CompressedMarkFiles, Bool))

    def initialize(
      @plan : ObjectDocumentPlan,
      @physical : ObjectDocumentPhysicalPlan,
      pairs : Hash(String, CompressedMarkFiles),
      file_roster : Hash(String, Tuple(String, String)),
    )
      @pairs = Hash(String, CompressedMarkFiles).new
      pairs.each do |name, pair|
        detached_name = String.new(name.to_slice)
        if @pairs.has_key?(detached_name)
          raise ArgumentError.new("Object column stream names must be unique")
        end
        @pairs[detached_name] = pair
      end

      @stream_names = @physical.stream_names
      unless @pairs.keys.sort == @stream_names
        raise ArgumentError.new("Object column pairs must exactly match the physical stream roster")
      end
      @file_names = [] of String
      @file_lookup = Hash(String, Tuple(CompressedMarkFiles, Bool)).new
      file_roster.each do |logical_name, file_names|
        pair = @pairs[logical_name]? || raise(ArgumentError.new("file roster names a missing Object stream"))
        {file_names[0], file_names[1]}.each_with_index do |file_name, index|
          detached_file_name = String.new(file_name.to_slice)
          if @file_lookup.has_key?(detached_file_name)
            raise ArgumentError.new("Object column output filenames must be unique")
          end
          @file_names << detached_file_name
          @file_lookup[detached_file_name] = {pair, index == 1}
        end
      end
      unless @pairs.size == file_roster.size && @stream_names.size == @pairs.size
        raise ArgumentError.new("Object column file roster does not cover every physical stream")
      end
      @file_names.sort!
    end

    # The fresh statistics-bearing plan used to encode every returned lane.
    def plan : ObjectDocumentPlan
      @plan
    end

    def physical : ObjectDocumentPhysicalPlan
      @physical
    end

    # Detached logical stream basenames (before optional checksum hashing and
    # `.bin`/`.mrk2` suffixes).
    def stream_names : Array(String)
      @stream_names.map { |name| String.new(name.to_slice) }
    end

    # Complete detached physical filename roster.
    def file_names : Array(String)
      @file_names.map { |name| String.new(name.to_slice) }
    end

    def pair_for(logical_name : String) : CompressedMarkFiles
      @pairs[logical_name]? || raise(KeyError.new("Object column stream not found: #{logical_name.inspect}"))
    end

    # Returns a detached byte copy for one exact filename in the roster.
    def file_bytes(file_name : String) : Bytes
      pair, marks = @file_lookup[file_name]? || raise(KeyError.new("Object column file not found: #{file_name.inspect}"))
      marks ? pair.marks : pair.data
    end
  end
end
