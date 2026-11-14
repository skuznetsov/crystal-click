module CrystalClick
  # Resolves one Wide adaptive-mark sidecar and authenticates `.cmrk2` marks
  # against both checksum declarations before exposing their canonical bytes.
  # Plain `.mrk2` files remain on the existing mmap reader path.
  class WideMarkFileAdapter
    getter marks_name : String
    getter compressed : Bool

    @entry : PartChecksums::Entry

    # Projection children use one mark suffix throughout the part. Once any
    # compressed mark is declared or present, validate the complete sidecar
    # inventory before a selected-lane reader can fall back to `.mrk2`.
    # Plain-only parts keep their existing per-lane validation path.
    def self.projection_child_compressed_marks?(part_path : String, checksums : PartChecksums) : Bool
      declared = [] of String
      checksums.entries.each do |name, entry|
        if name.ends_with?(".cmrk2") || name.ends_with?(".mrk2")
          declared << name
        end
      end

      physical = [] of String
      Dir.each_child(part_path) do |name|
        if name.ends_with?(".cmrk2") || name.ends_with?(".mrk2")
          physical << name
        end
      end

      compressed_candidate = declared.any?(&.ends_with?(".cmrk2")) || physical.any?(&.ends_with?(".cmrk2"))
      return false unless compressed_candidate

      declared.each do |name|
        entry = checksums.entry(name) || raise(CorruptPartError.new("projection child mark checksum entry disappeared"))
        WideMarkFileAdapter.new(name, entry)
      end

      unless physical.sort == declared.sort
        raise CorruptPartError.new("projection child mark sidecar inventory differs from checksums.txt")
      end
      if declared.any?(&.ends_with?(".mrk2"))
        raise CorruptPartError.new("compressed projection child mixes .mrk2 and .cmrk2 mark sidecars")
      end
      declared.each { |name| checksums.validate_selected_entries(part_path, name) }
      true
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect projection child mark inventory")
    end

    def self.open(
      part_path : String,
      source : PartStreamSource,
      data_name : String,
    ) : {PartPhysicalInput, WideMarkFileAdapter}
      unless data_name.ends_with?(".bin") && data_name.bytesize > ".bin".bytesize
        raise ArgumentError.new("Wide data stream name must end in .bin")
      end
      base = String.new(data_name.to_slice[0, data_name.bytesize - ".bin".bytesize])
      plain_name = "#{base}.mrk2"
      compressed_name = "#{base}.cmrk2"
      candidates = [plain_name, compressed_name]

      physical = [] of String
      Dir.each_child(part_path) do |name|
        if name.starts_with?("#{base}.")
          extension = name.byte_slice(base.bytesize + 1, name.bytesize - base.bytesize - 1)
          if extension.starts_with?("mrk") || extension.starts_with?("cmrk")
            unless candidates.includes?(name)
              raise UnsupportedFormatError.new("unsupported Wide mark extension")
            end
          end
        end
      end

      candidates.each do |name|
        path = File.join(part_path, name)
        if File.symlink?(path)
          raise CorruptPartError.new("Wide mark sidecar must not be a symbolic link")
        end
        physical << name if File.exists?(path) || File.symlink?(path)
      end

      declared = candidates.select { |name| !source.checksum_entry(name).nil? }
      unless physical.sort == declared.sort
        raise CorruptPartError.new("Wide mark sidecar inventory differs from checksums.txt")
      end
      if declared.size > 1
        raise CorruptPartError.new("ambiguous Wide mark sidecars")
      elsif declared.empty?
        raise CorruptPartError.new("Wide data stream has no declared mark sidecar")
      end

      marks_name = declared.first
      input = source.physical_input(data_name, marks_name)
      entry = source.checksum_entry(marks_name) || raise(CorruptPartError.new("Wide mark checksum entry disappeared"))
      {input, new(marks_name, entry)}
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect Wide mark sidecar")
    end

    # Keeps ordinary `.mrk2` callers on their original transport path. Strict
    # projection readers use this predicate only to decide whether a physical
    # or declared `.cmrk2` selects the authenticated compressed path; #open
    # then checks the complete sidecar inventory and rejects ambiguity.
    def self.compressed_candidate?(part_path : String, source : PartStreamSource, data_name : String) : Bool
      unless data_name.ends_with?(".bin") && data_name.bytesize > ".bin".bytesize
        raise ArgumentError.new("Wide data stream name must end in .bin")
      end
      base = data_name.byte_slice(0, data_name.bytesize - ".bin".bytesize)
      compressed_name = "#{base}.cmrk2"
      path = File.join(part_path, compressed_name)
      File.exists?(path) || File.symlink?(path) || !source.checksum_entry(compressed_name).nil?
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect compressed Wide mark sidecar")
    end

    # Writer staged readback may construct the adapter from its exact staged
    # checksum entry. Reader admission normally uses #open to also validate
    # the part's physical/declaration inventory.
    def initialize(marks_name : String, @entry : PartChecksums::Entry)
      @marks_name = String.new(marks_name.to_slice)
      if @marks_name.ends_with?(".cmrk2")
        unless @entry.compressed && !@entry.uncompressed_size.nil? && !@entry.uncompressed_hash.nil?
          raise CorruptPartError.new("compressed Wide marks lack compressed checksum metadata")
        end
        @compressed = true
      elsif @marks_name.ends_with?(".mrk2")
        if @entry.compressed || !@entry.uncompressed_size.nil? || !@entry.uncompressed_hash.nil?
          raise CorruptPartError.new("plain Wide marks declare compressed checksum metadata")
        end
        @compressed = false
      else
        raise UnsupportedFormatError.new("unsupported Wide mark extension")
      end
    end

    # Returns owned canonical bytes only for compressed marks. The exact mark
    # basename, declared physical size/hash, and declared canonical size/hash
    # are all checked before the bytes are available to the grid parser.
    def read_canonical_marks(input : PartPhysicalInput, budget : CompressedStreamBudget) : Bytes?
      unless input.marks_name == @marks_name && input.marks_size.to_u64 == @entry.physical_size
        raise CorruptPartError.new("Wide mark physical input differs from its checksum entry")
      end
      return nil unless @compressed

      limits = budget.limits
      if @entry.physical_size > limits.max_mark_bytes.to_u64 || @entry.physical_size > Int32::MAX.to_u64
        raise CorruptPartError.new("compressed Wide mark file exceeds its configured limit")
      end
      raw_size = @entry.uncompressed_size || raise(CorruptPartError.new("compressed Wide marks lack a raw size"))
      raw_hash = @entry.uncompressed_hash || raise(CorruptPartError.new("compressed Wide marks lack a raw hash"))
      if raw_size > limits.max_mark_bytes.to_u64 || raw_size > Int32::MAX.to_u64
        raise CorruptPartError.new("canonical Wide marks exceed their configured limit")
      end

      canonical = CompressedMarkReader.read_all(
        input.marks_path,
        input.marks_size,
        budget,
        raw_size.to_i64,
        @entry.file_hash,
      )
      unless canonical.size.to_u64 == raw_size
        raise CorruptPartError.new("decompressed Wide mark size does not match checksums.txt")
      end
      unless CityHashV1.file_hash(canonical) == raw_hash
        raise CorruptPartError.new("decompressed Wide mark hash does not match checksums.txt")
      end
      canonical
    end
  end
end
