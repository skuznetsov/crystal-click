module CrystalClick
  # :nodoc:
  # Authenticated full-grid source snapshot for one Compact preparation.
  # Instances can only be minted by a factory that performs the physical read;
  # caller-provided detached windows or shards cannot acquire this authority.
  class CompactPartPhysicalWindowCapture
    @physical : CompactPartPhysicalContext
    @window : CompactPartPhysicalWindow

    private def initialize(@physical : CompactPartPhysicalContext, @window : CompactPartPhysicalWindow)
      unless @window.mode == @physical.mode &&
             @window.first_mark == 0 &&
             @window.mark_count == @physical.granule_count
        raise CorruptPartError.new("Compact source capture is not a complete physical mark grid")
      end
    end

    # Reads from the authoritative physical context itself. This is the only
    # constructor path, so a detached caller value cannot mint a capture.
    def self.read_complete(
      physical : CompactPartPhysicalContext,
      column_name : String,
    ) : CompactPartPhysicalWindowCapture
      window = physical.read_window(column_name, 0, physical.granule_count)
      new(physical, window)
    end

    def granules : Array(CompactPartPhysicalGranule)
      @window.granules
    end

    # Bind a site and detached shard roster to the bytes authenticated by this
    # exact full-grid read. Uncaptured public framer callers keep their normal
    # independent provenance read.
    def validate_site_shards!(
      physical : CompactPartPhysicalContext,
      site_identity : String,
      mark_index : Int,
      shards : Array(CompactPartPhysicalShard),
    ) : Nil
      unless @physical.same?(physical)
        raise CorruptPartError.new("Compact source capture belongs to a different physical context")
      end
      unless mark_index >= 0 && mark_index < @window.mark_count
        raise CorruptPartError.new("Compact source capture mark is outside its full physical grid")
      end

      expected_site = "#{PhysicalStreamName.escape(@window.column)}:mark=#{mark_index}"
      unless site_identity == expected_site
        raise CorruptPartError.new("Compact source capture site differs from its selected column mark")
      end
      unless @window.matches_shards_at?(mark_index, shards)
        raise CorruptPartError.new("Compact site shards differ from their authenticated full-grid snapshot")
      end
      nil
    end
  end
end
