module CrystalClick
  # Detached unpublished file pairs for one physical Array(JSON) column.
  # Inner Object lanes remain owned by ObjectDocumentColumnFiles; this owner
  # adds exactly the Array wrapper's .size0 lane.
  class ArrayObjectColumnFiles
    @inner : ObjectDocumentColumnFiles
    @size_stream_name : String
    @size_pair : CompressedMarkFiles
    @stream_names : Array(String)
    @file_names : Array(String)
    @size_data_name : String
    @size_marks_name : String

    def initialize(
      @inner : ObjectDocumentColumnFiles,
      size_stream_name : String,
      @size_pair : CompressedMarkFiles,
      size_file_names : Tuple(String, String),
    )
      @size_stream_name = String.new(size_stream_name.to_slice)
      @size_data_name = String.new(size_file_names[0].to_slice)
      @size_marks_name = String.new(size_file_names[1].to_slice)

      @stream_names = @inner.stream_names
      if @stream_names.includes?(@size_stream_name)
        raise ArgumentError.new("Array size stream collides with an inner Object stream")
      end
      @stream_names << @size_stream_name
      @stream_names.sort!

      @file_names = @inner.file_names
      if @file_names.includes?(@size_data_name) || @file_names.includes?(@size_marks_name) ||
         @size_data_name == @size_marks_name
        raise ArgumentError.new("Array size filenames collide with an inner Object file")
      end
      @file_names << @size_data_name
      @file_names << @size_marks_name
      @file_names.sort!
    end

    def plan : ObjectDocumentPlan
      @inner.plan
    end

    def physical : ObjectDocumentPhysicalPlan
      @inner.physical
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
      return @size_pair if logical_name == @size_stream_name
      @inner.pair_for(logical_name)
    end

    def file_bytes(file_name : String) : Bytes
      return Bytes.new(@size_pair.data.size) { |index| @size_pair.data[index] } if file_name == @size_data_name
      return Bytes.new(@size_pair.marks.size) { |index| @size_pair.marks[index] } if file_name == @size_marks_name
      @inner.file_bytes(file_name)
    end
  end
end
