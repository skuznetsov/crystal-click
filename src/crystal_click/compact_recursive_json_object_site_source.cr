module CrystalClick
  # Non-contiguous callback view for one static JSON site. All reads are
  # delegated to the parent mark's single cursor; this class owns only the
  # site's logical path offsets, observed callbacks, and authenticated
  # whole-data coordinate context.
  class CompactRecursiveJsonObjectSiteSource < ObjectSharedPathCallbackSource
    private struct CapturedCallback
      getter name : String
      getter bytes : Bytes
      getter path_start : UInt64
      getter path_end : UInt64

      def initialize(name : String, @bytes : Bytes, @path_start : UInt64, @path_end : UInt64)
        @name = String.new(name.to_slice)
      end
    end

    enum State
      Prefix
      Body
      Finished
    end

    @ledger : CompactRecursiveJsonParentMarkLedger
    @site_identity : String
    @coordinate_context : CompactRecursiveObjectSharedInlineCoordinateContext
    @budget : BinaryCodecBudget
    @state : State
    @captured : Array(CapturedCallback)
    @logical_event_names : Array(String)
    @grammar_active : Bool

    def initialize(
      @ledger : CompactRecursiveJsonParentMarkLedger,
      site_identity : String,
      @coordinate_context : CompactRecursiveObjectSharedInlineCoordinateContext,
      @budget : BinaryCodecBudget,
    )
      @site_identity = String.new(site_identity.to_slice)
      @state = State::Prefix
      @captured = [] of CapturedCallback
      @logical_event_names = [] of String
      @grammar_active = false
    end

    protected def borrow_self_delimited(expected_name : String) : Bytes
      ensure_capture_state!
      @ledger.borrow_site_self_delimited(self, expected_name)
    end

    protected def commit_self_delimited(expected_name : String, consumed : Int32) : Nil
      capture = @ledger.commit_site_self_delimited(self, expected_name, consumed)
      append_capture(expected_name, capture)
      nil
    end

    def site_identity : String
      String.new(@site_identity.to_slice)
    end

    def prefix_capturing? : Bool
      @state == State::Prefix
    end

    def prefix_complete? : Bool
      @state != State::Prefix
    end

    def finished? : Bool
      @state == State::Finished
    end

    def begin_body_capture! : Nil
      unless @state == State::Prefix && !@grammar_active
        raise CorruptPartError.new("recursive Compact JSON body began before its site prefix completed")
      end
      @state = State::Body
      nil
    end

    def take_exact(expected_name : String, size : Int32) : Bytes
      ensure_capture_state!
      capture = @ledger.capture_site_exact(self, expected_name, size)
      append_capture(expected_name, capture)
    end

    # A Compact grammar parser may consume only its own prefix of the MRK3
    # whole-mark tape. MRK4 remains one exact named callback. The global cursor
    # commits only after the parser reports an in-range extent.
    def with_grammar_extent(expected_name : String, &block : Bytes -> Tuple(T, Int32)) : Tuple(T, Bytes) forall T
      ensure_capture_state!
      if @grammar_active
        raise CorruptPartError.new("recursive Compact JSON source rejects a re-entrant grammar parser")
      end
      @grammar_active = true
      begin
        value, capture = @ledger.with_site_grammar_extent(self, expected_name) do |remaining|
          yield remaining
        end
        bytes = append_capture(expected_name, capture)
        {value, bytes}
      ensure
        @grammar_active = false
      end
    end

    def take_inline_fragment(expected_name : String) : Bytes
      ensure_body_state!
      capture = @ledger.capture_site_inline_fragment(self, expected_name)
      append_capture(expected_name, capture)
    end

    def take_inline_fragment_slice(
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      bytes = take_inline_fragment(callback_name)
      captured = @captured.last? || raise(CorruptPartError.new("recursive Compact inline fragment capture is missing"))
      unless captured.name == callback_name
        raise CorruptPartError.new("recursive Compact inline fragment differs from its captured callback")
      end
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        captured.path_start,
        captured.path_end,
        bytes,
        @coordinate_context,
        @budget,
      )
    end

    # MRK3 slices are created from the exact grammar extent just committed by
    # with_grammar_extent. The path positions are local to this JSON site,
    # unlike the parent cursor position, and remain meaningful across sibling
    # prefix/body interleaving.
    def inline_callback_slice(
      canonical_name : String,
      callback_name : String,
      relative_start : Int32,
      relative_end : Int32,
      bytes : Bytes,
    ) : ObjectSharedInlineCallbackReadSlice
      unless @ledger.mode.mrk3?
        raise ArgumentError.new("recursive Compact positional slices are only defined for mrk3 tapes")
      end
      if relative_start < 0 || relative_end < relative_start ||
         relative_end - relative_start != bytes.size || relative_end.to_u64 != position.to_u64
        raise CorruptPartError.new("recursive Compact MRK3 callback interval differs from its site path extent")
      end
      captured = @captured.last? || raise(CorruptPartError.new("recursive Compact MRK3 callback extent is missing"))
      unless captured.name == callback_name && captured.path_start == relative_start.to_u64 &&
             captured.path_end == relative_end.to_u64 && same_bytes?(captured.bytes, bytes)
        raise CorruptPartError.new("recursive Compact MRK3 callback differs from its authenticated site extent")
      end
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        captured.path_start,
        captured.path_end,
        bytes,
        @coordinate_context,
        @budget,
      )
    end

    def validate_expected_events!(names : Array(String)) : Nil
      unless @logical_event_names == names
        raise CorruptPartError.new("recursive Compact JSON site callbacks differ from its frozen serializer schedule")
      end
      nil
    end

    # Finish is site-local only. The parent ledger remains open until every
    # sibling body/suffix and ordinary child callback has been consumed.
    def finish! : Nil
      ensure_body_state!
      @state = State::Finished
      nil
    end

    def validate_prepared_source!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair),
      budget : BinaryCodecBudget,
    ) : Nil
      validate_prepared_source_gate!(budget)
      prefix.validate_physical_owner!(physical_plan)
      unless ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan) == prefix.physical_prefix
        raise CorruptPartError.new("recursive Compact prefix differs from its site physical plan")
      end
      unless prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
        raise UnsupportedFormatError.new("recursive Compact JSON source requires complete Object statistics")
      end

      schedule = CompactJsonObjectRoleSchedule.build(
        prefix,
        physical_plan,
        prefix.nested_context.profile,
        budget,
      )
      unless schedule.body_bindings == role_bindings && schedule.body_pairs == callback_pairs
        raise CorruptPartError.new("recursive Compact site body roles differ from the prepared Object schedule")
      end
      unless schedule.event_names == @logical_event_names &&
             @captured.size == schedule.event_names.size
        raise CorruptPartError.new("recursive Compact site did not consume its exact callback schedule")
      end

      event_index = 0
      schedule.prefix_pairs.each_with_index do |pair, index|
        parsed_name, parsed_bytes = prefix.prefix_callback_at(index, budget)
        captured = @captured[event_index]? ||
                   raise(CorruptPartError.new("recursive Compact JSON prefix capture is incomplete"))
        unless pair[1] == parsed_name && captured.name == parsed_name && same_bytes?(captured.bytes, parsed_bytes)
          raise CorruptPartError.new("recursive Compact JSON prefix bytes differ from their parent source")
        end
        event_index += 1
      end
      callback_pairs.each_with_index do |pair, index|
        parsed_name, parsed_bytes = prefix.body_callback_at(index, budget)
        slice = prefix.body_callback_slice_at(index)
        captured = @captured[event_index]? ||
                   raise(CorruptPartError.new("recursive Compact JSON body capture is incomplete"))
        unless parsed_name == pair[0] && captured.name == pair[1] &&
               same_bytes?(captured.bytes, parsed_bytes) && same_bytes?(captured.bytes, slice.bytes) &&
               slice.canonical_name == pair[0] && slice.callback_name == pair[1] &&
               slice.context.same?(@coordinate_context) &&
               slice.relative_start == captured.path_start && slice.relative_end == captured.path_end
          raise CorruptPartError.new("recursive Compact JSON body bytes or coordinates differ from their parent source")
        end
        @coordinate_context.validate_path_bytes!(captured.path_start, parsed_bytes, budget)
        event_index += 1
      end
      unless event_index == @captured.size &&
             @captured.last?.try(&.path_end) == @coordinate_context.path_data_size.to_u64
        raise CorruptPartError.new("recursive Compact site extents do not cover its captured path")
      end

      if schedule.advanced
        begin
          unless prefix.body_role_bindings == schedule.body_bindings &&
                 prefix.body_callback_pairs == schedule.body_pairs
            raise CorruptPartError.new("recursive Compact Advanced prefix retained a different body schedule")
          end
        rescue ex : ArgumentError
          prefix.bind_body_schedule!(schedule.body_bindings, schedule.body_pairs)
        end
      end
      nil
    end

    # Narrow lifecycle/budget seam used by the Advanced prepared holder before
    # any Object materializer allocates site metadata. It is also directly
    # falsifiable without manufacturing a callback prefix or schema plan.
    def validate_prepared_source_gate!(budget : BinaryCodecBudget) : Nil
      unless finished? && @ledger.authenticates_source?(self)
        raise UnsupportedFormatError.new("recursive Compact prepared source requires completed parent and site lifecycles")
      end
      unless @ledger.same_budget?(budget) && @budget.same?(budget)
        raise ArgumentError.new("recursive Compact preparation must retain its exact capture budget operation")
      end
      nil
    end

    def position : Int32
      size = @coordinate_context.path_data_size
      unless size >= 0 && size <= Int32::MAX
        raise CorruptPartError.new("recursive Compact site cursor exceeds its supported path domain")
      end
      size.to_i32
    end

    def remaining : Int32
      0
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonObjectSiteSource).to_u64
      bytes = checked_add(bytes, @coordinate_context.retained_workspace_bytes)
      bytes = checked_add(bytes, string_owner_bytes(@site_identity))
      bytes = checked_add(bytes, instance_sizeof(Array(CapturedCallback)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@captured.size.to_u64, sizeof(CapturedCallback).to_u64))
      @captured.each do |capture|
        # CapturedCallback owns its copied name. The bytes are borrowed views
        # into the parent cursor, so the ledger's cursor census owns payload.
        bytes = checked_add(bytes, string_owner_bytes(capture.name))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@logical_event_names.size.to_u64, sizeof(Pointer(String)).to_u64))
      @logical_event_names.each { |name| bytes = checked_add(bytes, string_owner_bytes(name)) }
      bytes
    end

    private def append_capture(name : String, capture : CompactRecursiveJsonParentMarkLedger::Capture) : Bytes
      path_start, path_end = @coordinate_context.append_authenticated_extent!(
        capture.shard,
        capture.shard_offset,
        capture.bytes,
      )
      detached_name = String.new(name.to_slice)
      @captured << CapturedCallback.new(detached_name, capture.bytes, path_start, path_end)
      @logical_event_names << detached_name
      capture.bytes
    end

    private def ensure_capture_state! : Nil
      unless @state == State::Prefix || @state == State::Body
        raise CorruptPartError.new("recursive Compact JSON source is already finished")
      end
      if @grammar_active
        raise CorruptPartError.new("recursive Compact JSON source rejects re-entrant reads while parsing")
      end
      nil
    end

    private def ensure_body_state! : Nil
      unless @state == State::Body && !@grammar_active
        raise CorruptPartError.new("recursive Compact JSON body callback is outside its site lifecycle")
      end
      nil
    end

    private def same_bytes?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.each_with_index do |byte, index|
        return false unless byte == right[index]
      end
      true
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("recursive Compact site workspace estimate overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("recursive Compact site workspace estimate overflows UInt64")
      end
      left * right
    end
  end
end
