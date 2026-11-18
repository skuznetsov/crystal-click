module CrystalClick
  # :nodoc:
  # Authenticated full-grid source snapshot for one Compact preparation.
  # Instances can only be minted by a factory that performs the physical read;
  # caller-provided detached windows or shards cannot acquire this authority.
  class CompactPartPhysicalWindowCapture
    @physical : CompactPartPhysicalContext
    @window : CompactPartPhysicalWindow
    @extra_windows : Hash(String, CompactPartPhysicalWindow)
    @authenticated_frames : Array(CompressedFrameFingerprint)

    private def initialize(
      @physical : CompactPartPhysicalContext,
      @window : CompactPartPhysicalWindow,
      @extra_windows : Hash(String, CompactPartPhysicalWindow) = Hash(String, CompactPartPhysicalWindow).new,
      @authenticated_frames : Array(CompressedFrameFingerprint) = [] of CompressedFrameFingerprint,
    )
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

    # Captures the root JSON column and any selected companions through one
    # data.bin mmap. The returned frame roster is authenticated by the same
    # read that produced all detached shards.
    def self.read_complete_columns(
      physical : CompactPartPhysicalContext,
      root_column_name : String,
      companion_column_names : Array(String),
    ) : CompactPartPhysicalWindowCapture
      columns = [root_column_name] of String
      companion_column_names.each { |name| columns << name }
      windows, fingerprints = physical.read_complete_windows_with_fingerprints(columns)
      root = windows[root_column_name]?
      unless root
        raise CorruptPartError.new("Compact shared source capture omitted its root JSON window")
      end
      extras = Hash(String, CompactPartPhysicalWindow).new(initial_capacity: companion_column_names.size)
      companion_column_names.each do |name|
        window = windows[name]?
        unless window
          raise CorruptPartError.new("Compact shared source capture omitted a companion window")
        end
        extras[String.new(name.to_slice)] = window
      end
      new(physical, root, extras, fingerprints)
    end

    def granules : Array(CompactPartPhysicalGranule)
      @window.granules
    end

    def authenticated_frames : Array(CompressedFrameFingerprint)
      @authenticated_frames.dup
    end

    def companion_uint64_mark_bytes(column_name : String, mark_index : Int) : Bytes
      window = @extra_windows[column_name]?
      unless window && mark_index >= 0 && mark_index < window.mark_count
        raise ArgumentError.new("Compact source capture has no selected companion mark")
      end
      unless window.shard_count_at(mark_index) == 1
        raise CorruptPartError.new("Compact UInt64 source capture has more than one physical slot")
      end
      window.shard_bytes_at(mark_index, 0)
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactPartPhysicalWindowCapture).to_u64
      bytes = checked_add(bytes, @window.retained_workspace_bytes)
      @extra_windows.each_value { |window| bytes = checked_add(bytes, window.retained_workspace_bytes) }
      bytes = checked_add(bytes, instance_sizeof(Hash(String, CompactPartPhysicalWindow)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@extra_windows.size.to_u64,
        sizeof(Pointer(CompactPartPhysicalWindow)).to_u64))
      @extra_windows.each_key { |name| bytes = checked_add(bytes, string_owner_bytes(name)) }
      bytes = checked_add(bytes, instance_sizeof(Array(CompressedFrameFingerprint)).to_u64)
      checked_add(bytes,
        checked_multiply(@authenticated_frames.size.to_u64, sizeof(CompressedFrameFingerprint).to_u64))
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

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact source capture workspace overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact source capture workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
