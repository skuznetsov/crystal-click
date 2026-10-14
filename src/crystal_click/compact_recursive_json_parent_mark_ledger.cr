module CrystalClick
  # One shared whole-mark cursor for every recursive JSON and Array callback
  # in a parent physical mark. Child sites borrow authenticated views from this
  # ledger; they never receive fabricated or rebased physical shards.
  class CompactRecursiveJsonParentMarkLedger
    struct Capture
      getter bytes : Bytes
      getter shard : CompactPartPhysicalShard
      getter shard_offset : Int32

      def initialize(@bytes : Bytes, @shard : CompactPartPhysicalShard, @shard_offset : Int32)
      end
    end

    enum Phase
      Prefixes
      ArraySizes
      Bodies
      Complete
    end

    getter mark_index : Int32
    getter row_count : UInt64
    getter mode : CompactMarkFormat

    @physical : CompactPartPhysicalContext
    @shards : Array(CompactPartPhysicalShard)
    @cursor : CompactBinaryBulkGranuleCursor
    @budget : BinaryCodecBudget
    @phase : Phase
    @site_sources : Array(CompactRecursiveJsonObjectSiteSource)
    @captured_event_names : Array(String)
    @expected_size_lanes : Int32
    @captured_size_lanes : Int32
    @mixed_body_schedule : Bool
    @self_delimited_source : CompactRecursiveJsonObjectSiteSource?
    @self_delimited_name : String?
    @self_delimited_callback_name : String?
    @self_delimited_size : Int32
    @completed : Bool

    def initialize(
      @physical : CompactPartPhysicalContext,
      column_name : String,
      granule : CompactPartPhysicalGranule,
      @budget : BinaryCodecBudget,
    )
      if @budget.writing?
        raise ArgumentError.new("recursive Compact parent ledger requires a read-direction codec budget")
      end
      @mark_index = granule.mark
      @row_count = granule.row_count
      @mode = @physical.mode
      unless @mode.mrk3? || @mode.mrk4?
        raise UnsupportedFormatError.new("recursive Compact parent ledger requires plain mrk3 or mrk4")
      end
      @shards = granule.shards
      @physical.validate_parent_granule!(column_name, granule, @shards)
      if @mode.mrk3?
        @physical.validate_mrk3_site!(
          column_name,
          PhysicalStreamName.escape(column_name),
          granule.mark,
          @shards,
        )
      end
      @cursor = CompactBinaryBulkGranuleCursor.new(@mode, @shards, nil)
      @cursor.charge_complete_wire_input!(@budget)
      @phase = Phase::Prefixes
      @site_sources = [] of CompactRecursiveJsonObjectSiteSource
      @captured_event_names = [] of String
      @expected_size_lanes = -1
      @captured_size_lanes = 0
      @mixed_body_schedule = false
      @self_delimited_source = nil
      @self_delimited_name = nil
      @self_delimited_callback_name = nil
      @self_delimited_size = 0
      @completed = false
    end

    def site_source(site_identity : String) : CompactRecursiveJsonObjectSiteSource
      ensure_phase!(Phase::Prefixes, "recursive Compact JSON prefix")
      source = CompactRecursiveJsonObjectSiteSource.new(
        self,
        site_identity,
        CompactRecursiveObjectSharedInlineCoordinateContext.new(@physical, site_identity, @shards),
        @budget,
      )
      @site_sources << source
      source
    end

    def finish_prefixes! : Nil
      ensure_phase!(Phase::Prefixes, "recursive Compact Array-size traversal")
      @site_sources.each do |source|
        unless source.prefix_complete?
          raise CorruptPartError.new("recursive Compact parent advanced before every JSON site prefix completed")
        end
      end
      @phase = Phase::ArraySizes
      nil
    end

    def begin_array_sizes!(expected_lanes : Int32) : Nil
      ensure_phase!(Phase::ArraySizes, "recursive Compact Array-size schedule")
      if expected_lanes < 0 || @expected_size_lanes >= 0
        raise CorruptPartError.new("recursive Compact Array-size schedule was initialized more than once")
      end
      @expected_size_lanes = expected_lanes
      nil
    end

    def capture_array_size_lane(callback_name : String, byte_count : Int32) : Bytes
      ensure_phase!(Phase::ArraySizes, "recursive Compact Array-size callback")
      if @expected_size_lanes < 0 || @captured_size_lanes >= @expected_size_lanes
        raise CorruptPartError.new("recursive Compact Array-size callback is outside its frozen parent schedule")
      end
      capture_exact(callback_name, byte_count, size_lane: true).bytes
    end

    # Start the serializer-DFS body schedule after every JSON Object prefix is
    # complete. Array sizes are now captured in place immediately before their
    # descendants rather than in a global prepass.
    def begin_mixed_body_schedule!(expected_size_lanes : Int32) : Nil
      ensure_phase!(Phase::ArraySizes, "recursive Compact mixed body schedule")
      if expected_size_lanes < 0 || @expected_size_lanes >= 0 || @mixed_body_schedule
        raise CorruptPartError.new("recursive Compact mixed body schedule was initialized more than once")
      end
      @expected_size_lanes = expected_size_lanes
      @mixed_body_schedule = true
      @phase = Phase::Bodies
      nil
    end

    def capture_mixed_array_size_lane(callback_name : String, byte_count : Int32) : Bytes
      ensure_phase!(Phase::Bodies, "recursive Compact mixed Array-size callback")
      unless @mixed_body_schedule && @expected_size_lanes >= 0 &&
             @captured_size_lanes < @expected_size_lanes
        raise CorruptPartError.new("recursive Compact mixed Array-size callback is outside its frozen parent schedule")
      end
      capture_exact(callback_name, byte_count, size_lane: true).bytes
    end

    def capture_uint8_body(callback_name : String, byte_count : Int32) : Bytes
      ensure_phase!(Phase::Bodies, "recursive Compact UInt8 body callback")
      capture_exact(callback_name, byte_count).bytes
    end

    def capture_bulk_body(callback_name : String, byte_count : Int32) : Bytes
      ensure_phase!(Phase::Bodies, "recursive Compact opaque Bulk body callback")
      capture_exact(callback_name, byte_count).bytes
    end

    # Parse one variable-width static Bulk body callback against a borrowed
    # snapshot. Cursor/event state is advanced only after the grammar has
    # returned a valid extent; mrk4 additionally requires that extent to be
    # the complete named callback.
    def with_bulk_body_grammar_extent(
      callback_name : String,
      &block : Bytes -> Tuple(T, Int32)
    ) : Tuple(T, Capture) forall T
      ensure_phase!(Phase::Bodies, "recursive Compact Bulk body grammar")
      borrowed = if @mode.mrk4?
                   shard = shard_for_event(callback_name)
                   size = shard.logical_end - shard.logical_start
                   if size < 0 || size > Int32::MAX
                     raise CorruptPartError.new("recursive Compact Bulk callback exceeds its supported byte domain")
                   end
                   shard.bytes
                 else
                   @cursor.remaining_slice
                 end

      value, consumed = yield borrowed
      unless consumed >= 0 && consumed <= borrowed.size
        raise CorruptPartError.new("recursive Compact Bulk grammar consumed outside its parent callback")
      end
      if @mode.mrk4? && consumed != borrowed.size
        raise CorruptPartError.new("recursive Compact Bulk grammar did not consume its exact named callback")
      end

      # capture_exact is the first cursor/event mutation in this path. The
      # callback order and exact mrk4 extent remain authenticated by the
      # existing parent-ledger machinery.
      capture = capture_exact(callback_name, consumed)
      {value, capture}
    end

    def finish_array_sizes! : Nil
      ensure_phase!(Phase::ArraySizes, "recursive Compact body traversal")
      unless @expected_size_lanes >= 0 && @captured_size_lanes == @expected_size_lanes
        raise CorruptPartError.new("recursive Compact parent did not consume its exact Array-size lane count")
      end
      @phase = Phase::Bodies
      nil
    end

    def capture_site_exact(
      source : CompactRecursiveJsonObjectSiteSource,
      callback_name : String,
      byte_count : Int32,
    ) : Capture
      validate_site_source!(source)
      ensure_phase!(Phase::Prefixes, "recursive Compact JSON prefix callback") if source.prefix_capturing?
      ensure_phase!(Phase::Bodies, "recursive Compact JSON body callback") unless source.prefix_capturing?
      capture_exact(callback_name, byte_count)
    end

    def capture_site_physical_exact(
      source : CompactRecursiveJsonObjectSiteSource,
      canonical_physical_name : String,
      raw_callback_name : String,
      byte_count : Int32,
    ) : Capture
      validate_site_source!(source)
      ensure_phase!(Phase::Prefixes, "recursive Compact JSON prefix callback") if source.prefix_capturing?
      ensure_phase!(Phase::Bodies, "recursive Compact JSON body callback") unless source.prefix_capturing?
      capture_exact(canonical_physical_name, byte_count, raw_callback_name)
    end

    def capture_site_inline_fragment(
      source : CompactRecursiveJsonObjectSiteSource,
      callback_name : String,
    ) : Capture
      validate_site_source!(source)
      ensure_phase!(Phase::Bodies, "recursive Compact JSON body callback")
      unless @mode.mrk4?
        raise UnsupportedFormatError.new("recursive Compact mrk3 inline fragments require descriptor grammar framing")
      end
      capture_remaining_event(callback_name)
    end

    # Borrow an immutable snapshot without advancing the shared cursor. The
    # callback is committed only after the generic Object parser has returned
    # its exact extent, matching the root framer's MRK4 transaction boundary.
    def borrow_site_self_delimited(
      source : CompactRecursiveJsonObjectSiteSource,
      callback_name : String,
    ) : Bytes
      borrow_site_self_delimited(source, callback_name, callback_name)
    end

    def borrow_site_self_delimited(
      source : CompactRecursiveJsonObjectSiteSource,
      canonical_physical_name : String,
      raw_callback_name : String,
    ) : Bytes
      validate_site_source!(source)
      ensure_phase!(source.prefix_capturing? ? Phase::Prefixes : Phase::Bodies,
        "recursive Compact self-delimited Object callback")
      unless @mode.mrk4?
        raise UnsupportedFormatError.new("an unlabeled Compact mrk3 remainder is not an exact callback interval")
      end
      if @self_delimited_source
        raise CorruptPartError.new("recursive Compact parent already has a borrowed self-delimited callback")
      end
      shard = shard_for_event(canonical_physical_name)
      size = shard.logical_end - shard.logical_start
      if size < 0 || size > Int32::MAX
        raise CorruptPartError.new("recursive Compact callback exceeds its supported byte domain")
      end
      @self_delimited_source = source
      @self_delimited_name = String.new(canonical_physical_name.to_slice)
      @self_delimited_callback_name = String.new(raw_callback_name.to_slice)
      @self_delimited_size = size.to_i32
      shard.bytes
    end

    def commit_site_self_delimited(
      source : CompactRecursiveJsonObjectSiteSource,
      callback_name : String,
      consumed : Int32,
    ) : Capture
      commit_site_self_delimited(source, callback_name, callback_name, consumed)
    end

    def commit_site_self_delimited(
      source : CompactRecursiveJsonObjectSiteSource,
      canonical_physical_name : String,
      raw_callback_name : String,
      consumed : Int32,
    ) : Capture
      unless @self_delimited_source.try(&.same?(source)) &&
             @self_delimited_name == canonical_physical_name &&
             @self_delimited_callback_name == raw_callback_name
        raise CorruptPartError.new("recursive Compact self-delimited callback differs from its parent reservation")
      end
      unless consumed == @self_delimited_size
        raise CorruptPartError.new("recursive Compact self-delimited parser did not consume its exact named callback")
      end
      capture = capture_site_physical_exact(source, canonical_physical_name, raw_callback_name, consumed)
      clear_self_delimited_reservation!
      capture
    end

    def with_site_grammar_extent(source : CompactRecursiveJsonObjectSiteSource, callback_name : String, &block : Bytes -> Tuple(T, Int32)) : Tuple(T, Capture) forall T
      with_site_physical_grammar_extent(source, callback_name, callback_name) do |bytes|
        yield bytes
      end
    end

    def with_site_physical_grammar_extent(
      source : CompactRecursiveJsonObjectSiteSource,
      canonical_physical_name : String,
      raw_callback_name : String,
      &block : Bytes -> Tuple(T, Int32)
    ) : Tuple(T, Capture) forall T
      validate_site_source!(source)
      phase = source.prefix_capturing? ? Phase::Prefixes : Phase::Bodies
      phase_name = source.prefix_capturing? ? "recursive Compact JSON prefix grammar" : "recursive Compact JSON body grammar"
      ensure_phase!(phase, phase_name)

      if @mode.mrk4?
        reservation_acquired = false
        begin
          borrowed = borrow_site_self_delimited(source, canonical_physical_name, raw_callback_name)
          reservation_acquired = true
          value, consumed = yield borrowed
          capture = commit_site_self_delimited(source, canonical_physical_name, raw_callback_name, consumed)
          reservation_acquired = false
          {value, capture}
        ensure
          if reservation_acquired
            clear_self_delimited_reservation_if_owned!(source, canonical_physical_name, raw_callback_name)
          end
        end
      else
        shard = @shards[0]? || raise(CorruptPartError.new("recursive Compact mrk3 parent tape is missing"))
        start = @cursor.position
        borrowed = @cursor.remaining_slice
        value, consumed = yield borrowed
        unless consumed >= 0 && consumed <= borrowed.size
          raise CorruptPartError.new("recursive Compact mrk3 parser consumed outside the parent tape")
        end
        @cursor.advance_borrowed_prefix(consumed)
        @captured_event_names << String.new(raw_callback_name.to_slice)
        {value, Capture.new(@cursor.consumed_slice(start), shard, start)}
      end
    end

    # The expected list is derived from the selected serializer traversal and
    # all site-local frozen schedules. It authenticates the full MRK4 parent
    # roster, including structural Array-size and ordinary UInt8 callbacks.
    def finish_mark!(expected_events : Array(String)) : Nil
      ensure_phase!(Phase::Bodies, "recursive Compact complete parent mark")
      @site_sources.each do |source|
        unless source.finished?
          raise CorruptPartError.new("recursive Compact parent mark has an unfinished JSON site")
        end
      end
      if @mixed_body_schedule &&
         (@expected_size_lanes < 0 || @captured_size_lanes != @expected_size_lanes)
        raise CorruptPartError.new("recursive Compact mixed traversal did not consume its exact Array-size lane count")
      end
      unless @captured_event_names == expected_events
        raise CorruptPartError.new("recursive Compact parent callback sequence differs from its frozen serializer schedule")
      end
      if @mode.mrk4?
        @cursor.validate_expected_events!(expected_events)
      end
      @cursor.finish_granule
      @phase = Phase::Complete
      @completed = true
      nil
    end

    def complete? : Bool
      @completed
    end

    def authenticates_source?(source : CompactRecursiveJsonObjectSiteSource) : Bool
      @completed && @site_sources.any? { |candidate| candidate.same?(source) }
    end

    def same_budget?(budget : BinaryCodecBudget) : Bool
      @budget.same?(budget)
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonParentMarkLedger).to_u64
      bytes = checked_add(bytes, cursor_workspace_bytes)
      bytes = checked_add(bytes, instance_sizeof(Array(CompactPartPhysicalShard)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@shards.size.to_u64, sizeof(Pointer(CompactPartPhysicalShard)).to_u64))
      @shards.each { |shard| bytes = checked_add(bytes, shard.retained_workspace_bytes) }
      bytes = checked_add(bytes, instance_sizeof(Array(CompactRecursiveJsonObjectSiteSource)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@site_sources.size.to_u64, sizeof(Pointer(CompactRecursiveJsonObjectSiteSource)).to_u64))
      @site_sources.each { |source| bytes = checked_add(bytes, source.retained_workspace_bytes) }
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@captured_event_names.size.to_u64, sizeof(Pointer(String)).to_u64))
      @captured_event_names.each do |name|
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, name.bytesize.to_u64 + 1_u64)
      end
      if name = @self_delimited_name
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, name.bytesize.to_u64 + 1_u64)
      end
      if name = @self_delimited_callback_name
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, name.bytesize.to_u64 + 1_u64)
      end
      bytes
    end

    private def capture_exact(
      callback_name : String,
      byte_count : Int32,
      logical_name : String = callback_name,
      size_lane : Bool = false,
    ) : Capture
      if byte_count < 0
        raise CorruptPartError.new("recursive Compact callback requested a negative byte count")
      end
      capture = if @mode.mrk4?
                  shard = shard_for_event(callback_name)
                  unless shard.bytes.size == byte_count
                    raise CorruptPartError.new("recursive Compact named callback has the wrong byte extent")
                  end
                  @cursor.begin_event(callback_name)
                  unless @cursor.remaining == byte_count
                    raise CorruptPartError.new("recursive Compact named callback has the wrong byte extent")
                  end
                  bytes = @cursor.read_exact(byte_count)
                  @cursor.finish_event
                  Capture.new(bytes, shard, 0)
                else
                  shard = @shards[0]? || raise(CorruptPartError.new("recursive Compact mrk3 parent tape is missing"))
                  start = @cursor.position
                  Capture.new(@cursor.read_exact(byte_count), shard, start)
                end
      if size_lane
        @captured_size_lanes += 1
      end
      event_name = @mode.mrk4? ? callback_name : logical_name
      @captured_event_names << String.new(event_name.to_slice)
      capture
    end

    private def clear_self_delimited_reservation_if_owned!(
      source : CompactRecursiveJsonObjectSiteSource,
      canonical_physical_name : String,
      raw_callback_name : String,
    ) : Nil
      if @self_delimited_source.try(&.same?(source)) &&
         @self_delimited_name == canonical_physical_name &&
         @self_delimited_callback_name == raw_callback_name
        clear_self_delimited_reservation!
      end
      nil
    end

    private def clear_self_delimited_reservation! : Nil
      @self_delimited_source = nil
      @self_delimited_name = nil
      @self_delimited_callback_name = nil
      @self_delimited_size = 0
      nil
    end

    private def capture_remaining_event(callback_name : String) : Capture
      shard = shard_for_event(callback_name)
      @cursor.begin_event(callback_name)
      bytes = @cursor.remaining_slice
      @cursor.advance_borrowed_prefix(bytes.size)
      @cursor.finish_event
      @captured_event_names << String.new(callback_name.to_slice)
      Capture.new(bytes, shard, 0)
    end

    private def shard_for_event(callback_name : String) : CompactPartPhysicalShard
      @shards.find { |shard| shard.stream_name == callback_name } ||
        raise(CorruptPartError.new("recursive Compact callback has no authenticated parent shard"))
    end

    private def cursor_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactBinaryBulkGranuleCursor).to_u64
      if @mode.mrk4?
        bytes = checked_add(bytes, instance_sizeof(Array(Tuple(String, Bytes))).to_u64)
        bytes = checked_add(bytes, checked_multiply(@shards.size.to_u64, sizeof(Tuple(String, Bytes)).to_u64))
        @shards.each do |shard|
          bytes = checked_add(bytes, (shard.logical_end - shard.logical_start).to_u64)
          if name = shard.stream_name
            bytes = checked_add(bytes, instance_sizeof(String).to_u64)
            bytes = checked_add(bytes, name.bytesize.to_u64 + 1_u64)
          end
        end
      else
        shard = @shards[0]? || raise(CorruptPartError.new("recursive Compact mrk3 cursor is missing its whole tape"))
        # CompactBinaryBulkGranuleCursor always constructs @events, even for
        # an unlabeled mrk3 tape where it remains empty.
        bytes = checked_add(bytes, instance_sizeof(Array(Tuple(String, Bytes))).to_u64)
        bytes = checked_add(bytes, sizeof(Bytes).to_u64)
        bytes = checked_add(bytes, (shard.logical_end - shard.logical_start).to_u64)
      end
      bytes
    end

    private def validate_site_source!(source : CompactRecursiveJsonObjectSiteSource) : Nil
      unless @site_sources.any? { |candidate| candidate.same?(source) }
        raise CorruptPartError.new("recursive Compact JSON callback source is not owned by this parent mark")
      end
      nil
    end

    private def ensure_phase!(expected : Phase, label : String) : Nil
      unless @phase == expected
        raise CorruptPartError.new("#{label} violates the recursive Compact parent callback phase order")
      end
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("recursive Compact parent workspace estimate overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("recursive Compact parent workspace estimate overflows UInt64")
      end
      left * right
    end
  end
end
