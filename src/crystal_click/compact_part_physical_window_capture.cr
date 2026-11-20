module CrystalClick
  # :nodoc:
  # Authenticated source snapshot for Compact preparation. Full captures back
  # the established complete-grid route; selected captures retain only their
  # requested absolute marks for PREWHERE-style Advanced preparation.
  class CompactPartPhysicalWindowCapture
    @physical : CompactPartPhysicalContext
    @window : CompactPartPhysicalWindow?
    @extra_windows : Hash(String, CompactPartPhysicalWindow)
    @sparse_column : String?
    @sparse_granules : Hash(Int32, CompactPartPhysicalGranule)?
    @authenticated_frames : Array(CompressedFrameFingerprint)

    private def initialize(
      @physical : CompactPartPhysicalContext,
      window : CompactPartPhysicalWindow,
      extra_windows : Hash(String, CompactPartPhysicalWindow),
      authenticated_frames : Array(CompressedFrameFingerprint),
    )
      unless window.mode == @physical.mode &&
             window.first_mark == 0 &&
             window.mark_count == @physical.granule_count
        raise CorruptPartError.new("Compact source capture is not a complete physical mark grid")
      end
      @window = window
      @extra_windows = extra_windows
      @sparse_column = nil
      @sparse_granules = nil
      @authenticated_frames = authenticated_frames.dup
    end

    private def initialize(
      @physical : CompactPartPhysicalContext,
      column_name : String,
      sparse_granules : Hash(Int32, CompactPartPhysicalGranule),
      authenticated_frames : Array(CompressedFrameFingerprint),
    )
      unless @physical.mode.mrk4? && !column_name.empty? && !sparse_granules.empty?
        raise CorruptPartError.new("Compact selected source capture is empty or not MRK4")
      end
      @window = nil
      @extra_windows = Hash(String, CompactPartPhysicalWindow).new
      @sparse_column = String.new(column_name.to_slice)
      @sparse_granules = Hash(Int32, CompactPartPhysicalGranule).new(initial_capacity: sparse_granules.size)
      previous_mark = -1_i32
      sparse_granules.keys.sort.each do |mark|
        granule = sparse_granules[mark]
        unless mark > previous_mark && mark < @physical.granule_count && granule.mark == mark
          raise CorruptPartError.new("Compact selected source capture has an invalid absolute mark")
        end
        @sparse_granules.not_nil![mark] = granule.detached_copy
        previous_mark = mark
      end
      @authenticated_frames = authenticated_frames.dup
    end

    # Reads from the authoritative physical context itself. This is the only
    # constructor path, so a detached caller value cannot mint a capture.
    def self.read_complete(
      physical : CompactPartPhysicalContext,
      column_name : String,
    ) : CompactPartPhysicalWindowCapture
      window = physical.read_window(column_name, 0, physical.granule_count)
      new(physical, window, Hash(String, CompactPartPhysicalWindow).new, [] of CompressedFrameFingerprint)
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

    # Captures only selected root JSON mark spans and preserves their absolute
    # physical mark identity. No placeholder granules or unrelated JSON bytes
    # are retained for marks outside the supplied selection.
    def self.read_selected_column(
      physical : CompactPartPhysicalContext,
      root_column_name : String,
      mark_indices : Array(Int32),
    ) : CompactPartPhysicalWindowCapture
      granules, fingerprints = physical.read_selected_window_with_fingerprints(root_column_name, mark_indices)
      new(physical, root_column_name, granules, fingerprints)
    end

    def granules : Array(CompactPartPhysicalGranule)
      window = @window || raise(ArgumentError.new("Compact selected capture has no complete granule array"))
      window.granules
    end

    def sparse? : Bool
      @window.nil?
    end

    def selected_mark_count : Int32
      if window = @window
        return window.mark_count
      end
      (@sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))).size.to_i32
    end

    def selected_mark_indices_match?(mark_indices : Array(Int32)) : Bool
      return false unless sparse?
      granules = @sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))
      return false unless granules.size == mark_indices.size
      previous = -1_i32
      mark_indices.each do |mark|
        return false unless mark > previous && granules.has_key?(mark)
        previous = mark
      end
      true
    end

    def column_name : String
      name = @window.try(&.column) || @sparse_column ||
             raise(CorruptPartError.new("Compact source capture has no column identity"))
      String.new(name.to_slice)
    end

    def validate_physical!(physical : CompactPartPhysicalContext) : Nil
      unless @physical.same?(physical)
        raise CorruptPartError.new("Compact source capture belongs to a different physical context")
      end
      nil
    end

    def root_mark_shard_count_at(mark_index : Int) : Int32
      if window = @window
        return window.shard_count_at(mark_index)
      end
      granule_at(mark_index).shard_count
    end

    def root_mark_shard_bytes_at(mark_index : Int, shard_index : Int) : Bytes
      if window = @window
        return window.shard_bytes_at(mark_index, shard_index)
      end
      granule_at(mark_index).shard_bytes_at(shard_index)
    end

    def root_mark_row_offset(mark_index : Int) : UInt64
      if window = @window
        return window.row_offset_at(mark_index)
      end
      granules = @sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))
      granules[mark_index.to_i32]?.try(&.row_offset) ||
        raise(ArgumentError.new("Compact source capture does not contain the selected mark"))
    end

    def selected_mark_indices : Array(Int32)
      if window = @window
        Array(Int32).new(window.mark_count) { |index| index.to_i32 }
      else
        marks = (@sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))).keys
        marks.sort!
        marks
      end
    end

    def granule_at(mark_index : Int) : CompactPartPhysicalGranule
      if window = @window
        unless mark_index >= 0 && mark_index < window.mark_count
          raise ArgumentError.new("Compact source capture mark is outside its full grid")
        end
        return window.granule_at(mark_index)
      end
      granules = @sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))
      granules[mark_index.to_i32]?.try(&.detached_copy) ||
        raise(ArgumentError.new("Compact source capture does not contain the selected mark"))
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
      if window = @window
        bytes = checked_add(bytes, window.retained_workspace_bytes)
      end
      @extra_windows.each_value { |window| bytes = checked_add(bytes, window.retained_workspace_bytes) }
      bytes = checked_add(bytes, instance_sizeof(Hash(String, CompactPartPhysicalWindow)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@extra_windows.size.to_u64,
        sizeof(Pointer(CompactPartPhysicalWindow)).to_u64))
      @extra_windows.each_key { |name| bytes = checked_add(bytes, string_owner_bytes(name)) }
      if column = @sparse_column
        bytes = checked_add(bytes, string_owner_bytes(column))
        granules = @sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))
        bytes = checked_add(bytes, instance_sizeof(Hash(Int32, CompactPartPhysicalGranule)).to_u64)
        bytes = checked_add(bytes, checked_multiply(granules.size.to_u64,
          sizeof(Pointer(CompactPartPhysicalGranule)).to_u64))
        granules.each_value { |granule| bytes = checked_add(bytes, granule.retained_workspace_bytes) }
      end
      bytes = checked_add(bytes, instance_sizeof(Array(CompressedFrameFingerprint)).to_u64)
      checked_add(bytes,
        checked_multiply(@authenticated_frames.size.to_u64, sizeof(CompressedFrameFingerprint).to_u64))
    end

    # Bind a site and detached shard roster to the bytes authenticated by this
    # exact full or sparse read.
    def validate_site_shards!(
      physical : CompactPartPhysicalContext,
      site_identity : String,
      mark_index : Int,
      shards : Array(CompactPartPhysicalShard),
    ) : Nil
      validate_physical!(physical)
      unless mark_index >= 0 && mark_index < @physical.granule_count
        raise CorruptPartError.new("Compact source capture mark is outside its physical grid")
      end
      column = @window.try(&.column) || @sparse_column ||
               raise(CorruptPartError.new("Compact source capture has no root column"))
      expected_site = "#{PhysicalStreamName.escape(column)}:mark=#{mark_index}"
      unless site_identity == expected_site
        raise CorruptPartError.new("Compact source capture site differs from its selected column mark")
      end
      matches = if window = @window
                  window.matches_shards_at?(mark_index, shards)
                else
                  granules = @sparse_granules || raise(CorruptPartError.new("Compact selected capture has no mark map"))
                  granules[mark_index.to_i32]?.try(&.matches_shards?(shards)) || false
                end
      unless matches
        raise CorruptPartError.new("Compact site shards differ from their authenticated source snapshot")
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
