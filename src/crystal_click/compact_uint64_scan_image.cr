module CrystalClick
  # One scan-local view of the currently mapped Compact data.bin. It borrows
  # the frame descriptors validated with the admitted mark grid, then checks
  # that the mapped file still has the same frame geometry before any decode.
  class CompactUInt64ScanImage
    getter data : Bytes
    getter frame_index : CompressedFrameIndex

    @mapping : MMapDataSource::MappedFile
    @context : CompactPartPhysicalContext
    @data_path : String
    @data_size : Int64
    @closed : Bool

    def initialize(context : CompactPartPhysicalContext, budget : CompressedStreamBudget)
      @context = context
      @data_path = context.data_path
      @data_size = context.data_size
      @frame_index = context.frame_index
      @closed = false

      info = begin
        file_info = File.info?(@data_path, follow_symlinks: false) ||
                    raise(CorruptPartError.new("Compact data file is missing or inaccessible"))
        raise CorruptPartError.new("Compact data file must not be a symbolic link") if File.symlink?(@data_path)
        file_info
      rescue ex : IO::Error
        raise CorruptPartError.new(ex.message || "cannot inspect Compact data file")
      end
      raise CorruptPartError.new("Compact data file is not a regular file") unless info.type.file?
      raise CorruptPartError.new("Compact data file size changed") unless info.size == @data_size

      # Charge the mapped-file work before mmap can reserve address space.
      budget.reserve_file_bytes(@data_size)
      mapping = MMapDataSource.open_mapped_file(@data_path, @data_size, budget.limits.max_file_bytes)
      @mapping = mapping
      @data = mapping.bytes
      begin
        @frame_index.validate_data_geometry!(@data, budget.limits, budget)
      rescue ex
        begin
          mapping.close
        rescue cleanup_error : Error
          raise MMapCleanupError.new(ex, cleanup_error)
        end
        raise ex
      end
    end

    # Proves that a worker's physical context refers to this same immutable
    # source/index pair before it borrows the scan image.
    def validate_context!(context : CompactPartPhysicalContext) : Nil
      unless context.same?(@context)
        raise CorruptPartError.new("Compact scan image does not match its admitted part context")
      end
      nil
    end

    def close : Nil
      return nil if @closed
      @closed = true
      @mapping.close
    end

    # Serial scans use a lexical image scope so mmap cleanup preserves both
    # the callback exception and a possible unmap failure.
    def self.with_context(
      context : CompactPartPhysicalContext,
      budget : CompressedStreamBudget,
      & : CompactUInt64ScanImage -> Nil
    ) : Nil
      image = new(context, budget)
      callback_error = nil.as(Exception?)
      begin
        yield image
      rescue ex
        callback_error = ex
        raise ex
      ensure
        begin
          image.close
        rescue cleanup_error : Error
          if original_error = callback_error
            raise MMapCleanupError.new(original_error, cleanup_error)
          end
          raise cleanup_error
        end
      end
      nil
    end
  end
end
