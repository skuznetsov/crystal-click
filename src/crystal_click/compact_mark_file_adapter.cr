module CrystalClick
  # Selects exactly one physical Compact mark sidecar and adapts compressed
  # sidecars to their canonical MRK bytes. It deliberately knows no schema.
  class CompactMarkFileAdapter
    getter mode : CompactMarkFormat
    getter marks_name : String
    getter compressed : Bool

    @entry : PartChecksums::Entry

    # A dispatch hint only. The adapter constructor remains responsible for
    # validating declared and physical inventories and admitting the layout.
    # Also inspect the directory so a physical-only Compact sidecar cannot
    # silently fall through to a Wide reader.
    def self.routing_candidate?(part_path : String, checksums : PartChecksums) : Bool
      checksums.entries.each_key do |name|
        return true if routing_candidate_name?(name)
      end
      Dir.each_child(part_path) do |name|
        return true if routing_candidate_name?(name)
      end
      false
    end

    def initialize(part_path : String, checksums : PartChecksums, source : PartStreamSource)
      declared_mask = 0
      selected_name = nil.as(String?)
      checksums.entries.each_key do |name|
        next unless mark_sidecar_name?(name)
        unless recognized_name?(name)
          raise UnsupportedFormatError.new("unsupported Compact mark layout")
        end
        if selected_name
          raise CorruptPartError.new("part declares multiple Compact mark sidecars")
        end
        selected_name = name
        declared_mask |= name_bit(name)
      end

      physical_mask = 0
      Dir.each_child(part_path) do |name|
        next unless mark_sidecar_name?(name)
        unless recognized_name?(name)
          raise CorruptPartError.new("part contains an undeclared or unsupported Compact mark sidecar")
        end
        physical_mask |= name_bit(name)
      end

      unless declared_mask == physical_mask
        raise CorruptPartError.new("Compact mark sidecar inventory differs from checksums.txt")
      end
      name = selected_name || raise(CorruptPartError.new("part does not declare a Compact mark sidecar"))
      entry = source.checksum_entry(name) || raise(CorruptPartError.new("Compact mark checksum entry disappeared"))

      @marks_name = String.new(name.to_slice)
      @mode = if name == "data.mrk3" || name == "data.cmrk3"
                CompactMarkFormat::Mrk3
              else
                CompactMarkFormat::Mrk4
              end
      @compressed = name.starts_with?("data.cmrk")
      @entry = entry

      if @compressed
        unless entry.compressed && !entry.uncompressed_size.nil? && !entry.uncompressed_hash.nil?
          raise CorruptPartError.new("compressed Compact marks lack compressed checksum metadata")
        end
      elsif entry.compressed || !entry.uncompressed_size.nil? || !entry.uncompressed_hash.nil?
        raise CorruptPartError.new("plain Compact marks declare compressed checksum metadata")
      end
    end

    # Return owned canonical bytes only for compressed marks. Plain marks stay
    # on CompactMarkIndex's existing mmap path and preserve its W259 guard.
    def read_canonical_marks(input : PartPhysicalInput, budget : CompressedStreamBudget) : Bytes?
      return nil unless @compressed
      unless input.marks_name == @marks_name && input.marks_size.to_u64 == @entry.physical_size
        raise CorruptPartError.new("Compact mark physical input differs from its checksum entry")
      end

      limits = budget.limits
      if @entry.physical_size > limits.max_mark_bytes.to_u64 || @entry.physical_size > Int32::MAX.to_u64
        raise CorruptPartError.new("compressed Compact mark file exceeds its configured limit")
      end
      raw_size = @entry.uncompressed_size || raise(CorruptPartError.new("compressed Compact marks lack a raw size"))
      raw_hash = @entry.uncompressed_hash || raise(CorruptPartError.new("compressed Compact marks lack a raw hash"))
      if raw_size > limits.max_mark_bytes.to_u64 || raw_size > Int32::MAX.to_u64
        raise CorruptPartError.new("canonical Compact marks exceed their configured limit")
      end

      canonical = CompressedMarkReader.read_all(
        input.marks_path,
        input.marks_size,
        budget,
        raw_size.to_i64,
        @entry.file_hash,
      )
      unless canonical.size.to_u64 == raw_size
        raise CorruptPartError.new("decompressed Compact mark size does not match checksums.txt")
      end
      unless CityHashV1.file_hash(canonical) == raw_hash
        raise CorruptPartError.new("decompressed Compact mark hash does not match checksums.txt")
      end
      canonical
    end

    private def mark_sidecar_name?(name : String) : Bool
      name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
    end

    private def self.routing_candidate_name?(name : String) : Bool
      # These exact legacy/adaptive Wide names are not Compact routing hints.
      return false if name == "data.mrk" || name == "data.mrk2" ||
                      name == "data.cmrk" || name == "data.cmrk2"

      name.starts_with?("data.mrk") || name.starts_with?("data.cmrk")
    end

    private def recognized_name?(name : String) : Bool
      name == "data.mrk3" || name == "data.mrk4" ||
        name == "data.cmrk3" || name == "data.cmrk4"
    end

    private def name_bit(name : String) : Int32
      case name
      when "data.mrk3"  then 1
      when "data.mrk4"  then 2
      when "data.cmrk3" then 4
      when "data.cmrk4" then 8
      else
        raise UnsupportedFormatError.new("unsupported Compact mark layout")
      end
    end
  end
end
