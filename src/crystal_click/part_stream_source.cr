module CrystalClick
  # Checksum-sized resolver and transport adapter for one quiescent part
  # directory. It snapshots checksum declarations but does not claim to verify
  # their whole-file hashes.
  class PartStreamSource
    private struct ResolvedFile
      getter path : String
      getter size : Int64

      def initialize(@path : String, @size : Int64)
      end
    end

    @part_path : String
    @entries : Hash(String, PartChecksums::Entry)

    def initialize(part_path : String)
      raise CorruptPartError.new("part directory must not be a symbolic link") if File.symlink?(part_path)
      raise CorruptPartError.new("part path is not a directory") unless Dir.exists?(part_path)

      checksums = PartChecksums.open(part_path)
      @part_path = String.new(part_path.to_slice)
      @entries = Hash(String, PartChecksums::Entry).new(initial_capacity: checksums.entries.size)
      checksums.entries.each do |name, entry|
        # Checksum names and entries are detached from the parser-owned table;
        # no caller ever receives this retained snapshot.
        @entries[String.new(name.to_slice)] = PartChecksums::Entry.new(
          entry.physical_size,
          entry.compressed,
          entry.uncompressed_size,
          entry.file_hash
        )
      end
    end

    def inspect_grid(
      data_name : String,
      marks_name : String,
      prefix_size : Int? = nil,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : CompressedMarkGrid
      data, marks = resolve_pair(data_name, marks_name)
      CompressedMarkReader.inspect(
        data.path,
        marks.path,
        data.size,
        marks.size,
        prefix_size,
        budget
      )
    end

    def read_all(
      data_name : String,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : Bytes
      data = resolve(data_name)
      CompressedMarkReader.read_all(data.path, data.size, budget)
    end

    def read_window(
      data_name : String,
      marks_name : String,
      first_mark : Int,
      mark_count : Int,
      prefix_size : Int = 0,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : CompressedMarkWindow
      data, marks = resolve_pair(data_name, marks_name)
      CompressedMarkReader.read(
        data.path,
        marks.path,
        data.size,
        marks.size,
        first_mark,
        mark_count,
        prefix_size,
        budget
      )
    end

    # Resolve one exact checksum-declared pair into the detached input owner
    # consumed by the schema-agnostic Object shared physical decoder.
    def physical_lane_input(data_name : String, marks_name : String) : ObjectSharedPhysicalLaneInput
      data, marks = resolve_pair(data_name, marks_name)
      ObjectSharedPhysicalLaneInput.new(data.path, marks.path, data.size, marks.size)
    end

    private def resolve_pair(data_name : String, marks_name : String) : {ResolvedFile, ResolvedFile}
      {resolve(data_name), resolve(marks_name)}
    end

    private def resolve(name : String) : ResolvedFile
      validate_basename(name)
      entry = @entries[name]? || raise CorruptPartError.new("part stream is absent from checksums.txt")
      path = File.join(@part_path, name)

      raise CorruptPartError.new("part stream must not be a symbolic link") if File.symlink?(path)
      raise CorruptPartError.new("part stream is missing or not a regular file") unless File.file?(path)

      info = File.info(path)
      raise CorruptPartError.new("part stream is not a regular file") unless info.file?
      actual_size = info.size
      if actual_size < 0 || actual_size.to_u64 != entry.physical_size
        raise CorruptPartError.new("part stream size does not match checksums.txt")
      end
      if actual_size > Int32::MAX
        raise CorruptPartError.new("part stream exceeds the supported in-memory file domain")
      end

      ResolvedFile.new(path, actual_size)
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect part stream")
    end

    private def validate_basename(name : String) : Nil
      if name.empty? || name.bytesize > PartChecksums::MAX_NAME_BYTES
        raise CorruptPartError.new("part stream basename is empty or exceeds its bound")
      end

      name.each_byte do |byte|
        if byte == '/'.ord.to_u8 || byte == '\\'.ord.to_u8 || byte < 0x20 || byte == 0x7f || byte == 0
          raise CorruptPartError.new("part stream basename contains unsafe bytes")
        end
      end
      if name == "." || name == ".."
        raise CorruptPartError.new("part stream basename is not a file name")
      end
      nil
    end
  end
end
