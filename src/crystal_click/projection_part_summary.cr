module CrystalClick
  # :nodoc:
  # Exact child-directory guard shared by Wide and Compact projection writers.
  # Every checksummed file is bound to its declaration and physical size; only
  # the layout's fixed unchecksummed sidecar roster varies.
  class ProjectionPartSummary
    MRK3_SIDECARS = [
      "checksums.txt",
      "columns.txt",
      "default_compression_codec.txt",
      "metadata_version.txt",
    ]

    # Wide and Compact MRK4 children share this exact sidecar roster.
    MRK4_SIDECARS = MRK3_SIDECARS + ["columns_substreams.txt"]

    def self.record(
      entry_name : String,
      part_path : String,
      sidecars : Array(String),
    ) : PartWriterInfrastructure::ChecksumRecord
      size, hash = summarize(part_path, sidecars)
      PartWriterInfrastructure::ChecksumRecord.new(entry_name, size, hash, false)
    end

    def self.validate_entry!(
      parent_path : String,
      entry_name : String,
      entry : PartChecksums::Entry,
      sidecars : Array(String),
    ) : Nil
      unless entry_name.ends_with?(".proj") && !entry.compressed && entry.uncompressed_size.nil?
        raise CorruptPartError.new("projection checksum entry has an invalid shape")
      end

      child_path = File.join(parent_path, entry_name)
      size, hash = summarize(child_path, sidecars)
      unless entry.physical_size == size && entry.file_hash == hash
        raise CorruptPartError.new("projection checksum summary differs from its child part")
      end
      nil
    end

    private def self.summarize(
      part_path : String,
      sidecars : Array(String),
    ) : Tuple(UInt64, {UInt64, UInt64})
      if File.symlink?(part_path) || !Dir.exists?(part_path)
        raise CorruptPartError.new("projection child must be a plain part directory")
      end

      checksums = PartChecksums.open(part_path)
      expected_names = checksums.entries.keys + sidecars
      expected_names.sort!
      actual_names = Dir.children(part_path).sort!
      unless actual_names == expected_names
        raise CorruptPartError.new("projection child file roster differs from its checksums")
      end

      checksums.entries.each do |name, entry|
        validate_plain_file!(part_path, name, entry.physical_size)
      end
      sidecars.each { |name| validate_plain_file!(part_path, name) }

      summary = ProjectionChecksumSummary.new(checksums)
      {summary.total_size_on_disk, summary.total_checksum}
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect projection child part")
    end

    private def self.validate_plain_file!(part_path : String, name : String, size : UInt64? = nil) : Nil
      path = File.join(part_path, name)
      if File.symlink?(path) || !File.file?(path)
        raise CorruptPartError.new("projection child entries must be plain files")
      end
      if expected_size = size
        unless File.size(path).to_u64 == expected_size
          raise CorruptPartError.new("projection child checksum file size differs")
        end
      end
      nil
    end
  end
end
