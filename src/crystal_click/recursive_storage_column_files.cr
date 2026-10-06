module CrystalClick
  # Detached unpublished compressed lanes for one recursive Tuple column.
  # Object and BinaryBulk payloads remain owned by their existing codecs; this
  # value only joins their already collision-checked physical file roster.
  class RecursiveStorageColumnFiles
    @plan : RecursiveStorageColumnPlan
    @pairs : Hash(String, CompressedMarkFiles)
    @stream_names : Array(String)
    @file_names : Array(String)
    @file_lookup : Hash(String, Tuple(CompressedMarkFiles, Bool))

    def initialize(
      @plan : RecursiveStorageColumnPlan,
      pairs : Hash(String, CompressedMarkFiles),
    )
      @pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: pairs.size)
      pairs.each do |name, pair|
        detached = String.new(name.to_slice)
        raise ArgumentError.new("recursive stream names must be unique") if @pairs.has_key?(detached)
        @pairs[detached] = pair
      end

      @stream_names = @plan.physical_stream_names
      unless @pairs.keys.sort == @stream_names
        raise ArgumentError.new("recursive column pairs differ from the admitted physical roster")
      end
      roster = @plan.file_roster
      unless roster.size == @stream_names.size
        raise ArgumentError.new("recursive file roster differs from its stream roster")
      end
      @file_names = [] of String
      @file_lookup = Hash(String, Tuple(CompressedMarkFiles, Bool)).new
      roster.each do |logical_name, file_pair|
        pair = @pairs[logical_name]? || raise(ArgumentError.new("recursive file roster names a missing stream"))
        {file_pair[0], file_pair[1]}.each_with_index do |file_name, index|
          detached = String.new(file_name.to_slice)
          if @file_lookup.has_key?(detached)
            raise ArgumentError.new("recursive output filenames must be unique")
          end
          @file_names << detached
          @file_lookup[detached] = {pair, index == 1}
        end
      end
      unless @file_lookup.size == @stream_names.size * 2
        raise ArgumentError.new("recursive file roster does not cover every lane pair")
      end
      @file_names.sort!
    end

    def plan : RecursiveStorageColumnPlan
      @plan
    end

    def stream_names : Array(String)
      @stream_names.map { |name| String.new(name.to_slice) }
    end

    def physical_stream_names : Array(String)
      stream_names
    end

    def file_names : Array(String)
      @file_names.map { |name| String.new(name.to_slice) }
    end

    def pair_for(logical_name : String) : CompressedMarkFiles
      @pairs[logical_name]? || raise(KeyError.new("recursive stream not found: #{logical_name.inspect}"))
    end

    def file_bytes(file_name : String) : Bytes
      pair, marks = @file_lookup[file_name]? || raise(KeyError.new("recursive output file not found: #{file_name.inspect}"))
      marks ? pair.marks : pair.data
    end
  end
end
