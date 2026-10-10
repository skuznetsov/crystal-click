module CrystalClick
  module WidePartWriter
    # Recomputes ClickHouse's parent checksum record for one finalized child
    # part. Projection directories are validated independently of ordinary
    # selected-file checks, whose established contract remains size-only.
    private class WidePartProjectionSummary
      SIDECARS = [
        "checksums.txt",
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
      ]

      def self.record(entry_name : String, part_path : String) : ChecksumRecord
        size, hash = summarize(part_path)
        ChecksumRecord.new(entry_name, size, hash, false)
      end

      def self.validate_entry!(
        parent_path : String,
        entry_name : String,
        entry : PartChecksums::Entry,
      ) : Nil
        unless entry_name.ends_with?(".proj") && !entry.compressed && entry.uncompressed_size.nil?
          raise CorruptPartError.new("projection checksum entry has an invalid shape")
        end

        child_path = File.join(parent_path, entry_name)
        size, hash = summarize(child_path)
        unless entry.physical_size == size && entry.file_hash == hash
          raise CorruptPartError.new("projection checksum summary differs from its child part")
        end
        nil
      end

      private def self.summarize(part_path : String) : Tuple(UInt64, {UInt64, UInt64})
        if File.symlink?(part_path) || !Dir.exists?(part_path)
          raise CorruptPartError.new("projection child must be a plain part directory")
        end

        checksums = PartChecksums.open(part_path)
        expected_names = checksums.entries.keys + SIDECARS
        expected_names.sort!
        actual_names = Dir.children(part_path).sort!
        unless actual_names == expected_names
          raise CorruptPartError.new("projection child file roster differs from its checksums")
        end

        checksums.entries.each do |name, entry|
          validate_plain_file!(part_path, name, entry.physical_size)
        end
        SIDECARS.each { |name| validate_plain_file!(part_path, name) }

        total_size = 0_u64
        hasher = ClickHouseSipHash.new
        checksums.entries.keys.sort.each do |name|
          entry = checksums.entries[name]
          if entry.physical_size > UInt64::MAX - total_size
            raise CorruptPartError.new("projection child checksum sizes overflow")
          end
          total_size += entry.physical_size

          name_bytes = name.to_slice
          update_uint64_le(hasher, name_bytes.size.to_u64)
          hasher.update(name_bytes)
          update_uint64_le(hasher, entry.file_hash[0])
          update_uint64_le(hasher, entry.file_hash[1])
        end
        {total_size, hasher.finish128}
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

      private def self.update_uint64_le(hasher : ClickHouseSipHash, value : UInt64) : Nil
        bytes = Bytes.new(8)
        8.times do |index|
          bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8
        end
        hasher.update(bytes)
      end
    end
  end
end
