module CrystalClick
  # Operation-local compressed-index admission bound to one Compact child and
  # one consumptive read budget. Success can be reused only after this class
  # authenticated the physical index and every Compact key endpoint itself.
  private class CompactProjectionAggregateReaderAdmissionSession
    alias IndexIdentity = Tuple(UInt64, Tuple(UInt64, UInt64), UInt64, Tuple(UInt64, UInt64))

    @part_path : String
    @budget : CompressedStreamBudget
    @validated : Bool
    @key_names : Array(String)?
    @index_identity : IndexIdentity?

    def initialize(part_path : String, @budget : CompressedStreamBudget)
      @part_path = File.expand_path(part_path)
      @budget.ensure_direction(false)
      @validated = false
      @key_names = nil
      @index_identity = nil
    end

    # The only admission transition: authenticate compressed bytes and all
    # mark-start/terminal tuples before remembering success. Reuse still checks
    # the regular-file and physical-size binding on every open.
    def validate_compressed_index!(
      part_path : String,
      context : CompactPartPhysicalContext,
      key_names : Array(String),
      expected_size : Int64,
      checksums : PartChecksums,
      budget : CompressedStreamBudget,
    ) : Nil
      path = File.expand_path(part_path)
      validate_scope!(path, context, budget)
      budget.ensure_direction(false)

      entry = checksums.entry("primary.cidx") ||
              raise(CorruptPartError.new("compressed primary index is absent from checksums.txt"))
      identity = index_identity(entry)
      if expected_size <= 0
        raise CorruptPartError.new("compressed primary index expected size is outside its bound")
      end
      unless entry.compressed && entry.uncompressed_size == expected_size.to_u64 && entry.uncompressed_hash
        raise CorruptPartError.new("compressed primary index metadata differs from its exact key roster mark grid")
      end

      # This is intentionally size-only for a reused session. The first call
      # below performs both authenticated hashes and the endpoint comparison.
      checksums.validate_selected_entries(path, "primary.cidx")
      if @validated
        unless @key_names == key_names && @index_identity == identity
          raise CorruptPartError.new("Compact compressed primary-index admission session differs from its validated child roster")
        end
        return nil
      end

      index_bytes = ProjectionPrimaryIndex.read_compressed(path, expected_size, checksums, budget)
      context.validate_projection_uint64_index_endpoints!(key_names, index_bytes)

      @key_names = key_names.map { |name| String.new(name.to_slice) }
      @index_identity = identity
      @validated = true
      nil
    end

    private def validate_scope!(
      part_path : String,
      context : CompactPartPhysicalContext,
      budget : CompressedStreamBudget,
    ) : Nil
      unless part_path == @part_path && budget.same?(@budget) &&
             context.matches_projection_child_scope?(part_path, budget)
        raise ArgumentError.new("Compact projection admission session cannot cross its child path, context, or read budget")
      end
      nil
    end

    private def index_identity(entry : PartChecksums::Entry) : IndexIdentity
      raw_size = entry.uncompressed_size || raise(CorruptPartError.new("compressed primary index has no declared raw size"))
      raw_hash = entry.uncompressed_hash || raise(CorruptPartError.new("compressed primary index has no declared raw hash"))
      {entry.physical_size, entry.file_hash, raw_size, raw_hash}
    end
  end
end
