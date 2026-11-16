module CrystalClick
  private class WidePartMetadataFiles
    def self.read_metadata_file(path : String, name : String, require_regular : Bool = false) : String
      file = File.join(path, name)
      size = if require_regular
               info = File.info?(file, follow_symlinks: false) || raise(InvalidPartError.new("#{name} is missing or inaccessible"))
               raise CorruptPartError.new("#{name} must not be a symbolic link") if info.type.symlink?
               raise CorruptPartError.new("#{name} is not a regular file") unless info.type.file?
               info.size
             else
               raise CorruptPartError.new("#{name} must not be a symbolic link") if File.symlink?(file)
               File.size(file)
             end
      raise UnsupportedFormatError.new("#{name} exceeds metadata limit") if size > WidePart::MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise UnsupportedFormatError.new("#{name} must end with LF") if text.empty? || text.bytesize != size || text.bytes.last != 10
      text
    end

    def self.read_default_codec(path : String) : String
      file = File.join(path, "default_compression_codec.txt")
      raise CorruptPartError.new("default_compression_codec.txt must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("default codec exceeds metadata limit") if size > WidePart::MAX_CODEC_FILE_BYTES
      codec = File.read(file)
      unless codec.bytesize == size && (codec == "CODEC(LZ4)" || codec == "CODEC(ZSTD(1))")
        raise UnsupportedFormatError.new("only CODEC(LZ4) and CODEC(ZSTD(1)) are supported")
      end
      codec
    end

    def self.parse_count_file(path : String, name : String) : UInt64
      file = File.join(path, name)
      raise CorruptPartError.new("#{name} must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise CorruptPartError.new("invalid row count") if size == 0 || size > 32
      text = File.read(file)
      raise CorruptPartError.new("invalid row count") unless text.bytesize == size
      WidePart.parse_count_metadata(text, UInt64::MAX)
    end
  end
end
