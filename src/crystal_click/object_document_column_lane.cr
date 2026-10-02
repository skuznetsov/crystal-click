module CrystalClick
  # Internal generated lane view for ObjectDocumentColumnWriter. Data bytes
  # are borrowed only from in-memory W123/W120 owners and are copied into the
  # returned compressed pair before this temporary object is discarded.
  class ObjectDocumentColumnLane
    getter name : String
    getter byte_size : Int32

    @bytes : Bytes
    @statistics_offset : Int32?
    @bulk_source : BinaryBulkStream?
    @discriminator_source : DynamicDiscriminatorStream?
    @prefix_size : Int32

    def initialize(
      @name : String,
      @bytes : Bytes,
      @statistics_offset : Int32? = nil,
      @bulk_source : BinaryBulkStream? = nil,
      @discriminator_source : DynamicDiscriminatorStream? = nil,
      @prefix_size : Int32 = 0,
    )
      @byte_size = @bytes.size
    end

    def encode(
      rows_per_mark : Array(UInt64),
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : CompressedMarkFiles
      if statistics_offset = @statistics_offset
        return CompressedMarkWriter.encode_metadata(
          @bytes,
          statistics_offset,
          rows_per_mark,
          frame_bytes: frame_bytes,
          budget: budget
        )
      end

      mark_count = rows_per_mark.size + 1
      offsets = if source = @bulk_source
                  unless source.offset_count == mark_count
                    raise UnsupportedFormatError.new("Object bulk lane does not have the complete outer mark grid")
                  end
                  Array(UInt64).new(source.offset_count) { |index| source.offset_at(index) }
                elsif source = @discriminator_source
                  unless source.mark_count == mark_count
                    raise UnsupportedFormatError.new("Dynamic discriminator does not have the complete outer mark grid")
                  end
                  Array(UInt64).new(source.mark_count) do |index|
                    mark = source.mark_at(index)
                    if index < rows_per_mark.size && mark.rows != rows_per_mark[index]
                      raise UnsupportedFormatError.new("Dynamic discriminator rows do not match the outer document grid")
                    end
                    if index == rows_per_mark.size && mark.rows != 0_u64
                      raise UnsupportedFormatError.new("Dynamic discriminator terminal mark must have zero rows")
                    end
                    mark.offset
                  end
                else
                  raise UnsupportedFormatError.new("Object column lane has no mark-coordinate source")
                end

      CompressedMarkWriter.encode(
        @bytes,
        offsets,
        rows_per_mark,
        prefix_size: @prefix_size,
        frame_bytes: frame_bytes,
        budget: budget
      )
    end
  end
end
