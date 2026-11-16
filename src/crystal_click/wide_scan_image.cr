module CrystalClick
  # Owns read-only mappings for the selected ordinary Wide numeric streams in
  # one part during one scan. The caller controls the lifetime; this object is
  # never retained by a WidePart reader.
  class WideScanImage
    getter mapping_count : UInt64
    getter mapped_bytes : UInt64

    @files : Hash(String, MMapDataSource::MappedFile)
    @closed : Bool

    def self.open(paths : Array(String), max_size : Int64 = WidePart::MAX_DATA_FILE_BYTES) : WideScanImage
      new(paths, max_size)
    end

    private def initialize(paths : Array(String), max_size : Int64)
      @files = Hash(String, MMapDataSource::MappedFile).new
      @closed = false
      @mapping_count = 0_u64
      @mapped_bytes = 0_u64
      begin
        paths.each { |path| map_file(path, max_size) }
      rescue ex
        begin
          close
        rescue cleanup_error : Error
          raise MMapCleanupError.new(ex, cleanup_error)
        end
        raise ex
      end
    end

    # Returns the exact-size read-only data bytes for a stream preopened by
    # `open`. Concurrent consumers only read the sealed hash and the mmap.
    def bytes_for(path : String) : Bytes
      raise CorruptPartError.new("Wide scan image is closed") if @closed
      @files[path]?.try(&.bytes) || raise(CorruptPartError.new("Wide scan image does not contain the selected stream"))
    end

    def close : Nil
      return nil if @closed
      @closed = true
      first_error = nil.as(Error?)
      @files.each_value do |file|
        begin
          file.close
        rescue ex : Error
          first_error ||= ex
        end
      end
      @files.clear
      raise first_error.not_nil! if first_error
      nil
    end

    private def map_file(path : String, max_size : Int64) : Nil
      raise CorruptPartError.new("Wide scan image is closed") if @closed
      return nil if @files.has_key?(path)

      size = File.size(path)
      raise CorruptPartError.new("data file exceeds limit") if size <= 0 || size > max_size
      file = MMapDataSource.open_mapped_file(path, size, max_size)
      @files[path] = file
      @mapping_count += 1_u64
      @mapped_bytes += file.bytes.size.to_u64
      nil
    end
  end
end
