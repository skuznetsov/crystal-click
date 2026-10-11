module CrystalClick
  # Bounded reader for regular, non-stream metadata files inside one part.
  # Optional checksum sizes prove declared length only, not file content.
  class PartMetadataFileReader
    MAX_METADATA_FILE_BYTES = 4_i64 * 1024 * 1024

    @part_path : String
    @budget : CompressedStreamBudget
    @source : PartStreamSource?

    def initialize(
      part_path : String,
      @budget : CompressedStreamBudget,
      @source : PartStreamSource? = nil,
    )
      raise CorruptPartError.new("part directory must not be a symbolic link") if File.symlink?(part_path)
      raise CorruptPartError.new("part path is not a directory") unless Dir.exists?(part_path)
      @budget.ensure_direction(false)
      @part_path = String.new(part_path.to_slice)
    end

    def read(name : String, maximum_bytes : Int64 = MAX_METADATA_FILE_BYTES) : String
      validate_basename(name)
      if maximum_bytes < 0 || maximum_bytes > Int32::MAX
        raise ArgumentError.new("metadata file bound is outside the supported domain")
      end

      path = File.join(@part_path, name)
      raise CorruptPartError.new("metadata file must not be a symbolic link") if File.symlink?(path)
      info = File.info?(path, follow_symlinks: false) || raise CorruptPartError.new("metadata file is missing or inaccessible")
      raise CorruptPartError.new("metadata file is not a regular file") unless info.type.file?
      size = info.size
      raise CorruptPartError.new("metadata file size is invalid") if size < 0 || size > maximum_bytes || size > Int32::MAX

      if source = @source
        if declared_size = source.checksum_size_declaration(name)
          unless size.to_u64 == declared_size
            raise CorruptPartError.new("metadata file size does not match checksums.txt")
          end
        end
      end

      # Charge before allocating the file snapshot. Failed reads retain this
      # operation's consumed budget just like compressed-file transport.
      @budget.reserve_file_bytes(size)
      bytes = Bytes.new(size.to_i)
      File.open(path, "rb") do |file|
        opened = file.info
        raise CorruptPartError.new("metadata file is not a regular file") unless opened.file?
        raise CorruptPartError.new("metadata file size changed") unless opened.size == size
        file.read_fully(bytes) unless bytes.empty?
        raise CorruptPartError.new("metadata file size changed") unless file.read_byte.nil?
        finished = file.info
        raise CorruptPartError.new("metadata file size changed") unless finished.file? && finished.size == size
      end
      String.new(bytes)
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot read metadata file")
    end

    private def validate_basename(name : String) : Nil
      if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
        raise CorruptPartError.new("metadata file basename is empty or exceeds its bound")
      end
      name.each_byte do |byte|
        if byte == '/'.ord.to_u8 || byte == '\\'.ord.to_u8 || byte < 0x20 || byte == 0x7f || byte == 0
          raise CorruptPartError.new("metadata file basename contains unsafe bytes")
        end
      end
      if name == "." || name == ".."
        raise CorruptPartError.new("metadata file basename is not a file name")
      end
      nil
    end
  end
end
