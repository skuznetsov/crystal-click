module CrystalClick
  # One exact source callback interval captured from a path tape. Payload bytes
  # remain borrowed from the tape's detached Data owner; coordinate resolution
  # additionally requires the authenticated containing-Data context.
  class ObjectSharedInlineCallbackReadSlice
    @canonical_name : String
    @callback_name : String
    @relative_start : UInt64
    @relative_end : UInt64
    @bytes : Bytes
    @context : ObjectSharedInlineCoordinateContext?

    def initialize(
      canonical_name : String,
      callback_name : String,
      @relative_start : UInt64,
      @relative_end : UInt64,
      @bytes : Bytes,
      @context : ObjectSharedInlineCoordinateContext?,
      provenance_budget : BinaryCodecBudget? = nil,
    )
      if canonical_name.empty? || callback_name.empty?
        raise CorruptPartError.new("inline callback slice has an empty callback name")
      end
      if @relative_end < @relative_start || @relative_end - @relative_start != @bytes.size.to_u64
        raise CorruptPartError.new("inline callback slice interval disagrees with its captured bytes")
      end
      if context = @context
        if @relative_end > context.path_data_size.to_u64
          raise CorruptPartError.new("inline callback slice is outside its authenticated path interval")
        end
        budget = provenance_budget || raise(ArgumentError.new("authenticated inline callback slices require their operation budget"))
        context.validate_path_bytes!(@relative_start, @bytes, budget)
      end
      @canonical_name = String.new(canonical_name.to_slice)
      @callback_name = String.new(callback_name.to_slice)
    end

    def canonical_name : String
      String.new(@canonical_name.to_slice)
    end

    def callback_name : String
      String.new(@callback_name.to_slice)
    end

    def relative_start : UInt64
      @relative_start
    end

    def relative_end : UInt64
      @relative_end
    end

    def byte_size : Int32
      @bytes.size
    end

    # The returned bytes are a borrowed view whose lifetime is bounded by the
    # ObjectSharedPathStreams/tape that produced this slice.
    def bytes : Bytes
      @bytes
    end

    def authenticated_context? : Bool
      !@context.nil?
    end

    def context : ObjectSharedInlineCoordinateContext
      @context || raise(CorruptPartError.new("inline callback slice has no authenticated coordinate context"))
    end

    def resolve_pair(pair : Tuple(UInt64, UInt64)) : Int64
      context = @context || raise(CorruptPartError.new("inline callback slice has no authenticated coordinate context"))
      context.callback_position(pair, @relative_start, @relative_end, true) ||
        raise(CorruptPartError.new("inline coordinate is outside the named callback slice"))
    end

    def resolve_absolute_position(pair : Tuple(UInt64, UInt64)) : Int64
      context = @context || raise(CorruptPartError.new("inline callback slice has no authenticated coordinate context"))
      unless context.is_a?(ObjectSharedInlineDataCoordinateContext)
        raise UnsupportedFormatError.new("absolute inline positions are only defined for Wide Data coordinates")
      end
      wide_context = context.as(ObjectSharedInlineDataCoordinateContext)
      absolute = wide_context.resolve_path_position(pair)
      slice_start = wide_context.absolute_path_offset(@relative_start)
      slice_end = wide_context.absolute_path_offset(@relative_end)
      unless absolute >= slice_start && absolute <= slice_end
        raise CorruptPartError.new("inline coordinate is outside the named callback slice")
      end
      absolute
    end

    def local_position_for_absolute(absolute : Int64, allow_terminal : Bool) : Int64?
      context = @context || raise(CorruptPartError.new("inline callback slice has no authenticated coordinate context"))
      unless context.is_a?(ObjectSharedInlineDataCoordinateContext)
        raise UnsupportedFormatError.new("absolute inline positions are only defined for Wide Data coordinates")
      end
      wide_context = context.as(ObjectSharedInlineDataCoordinateContext)
      slice_start = wide_context.absolute_path_offset(@relative_start)
      slice_end = wide_context.absolute_path_offset(@relative_end)
      if absolute < slice_start || (allow_terminal ? absolute > slice_end : absolute >= slice_end)
        return nil
      end
      absolute - slice_start
    end

    def local_position_for_pair(pair : Tuple(UInt64, UInt64), allow_terminal : Bool) : Int64?
      context = @context || raise(CorruptPartError.new("inline callback slice has no authenticated coordinate context"))
      context.callback_position(pair, @relative_start, @relative_end, allow_terminal)
    end

    def shares_context?(context : ObjectSharedInlineCoordinateContext) : Bool
      if current = @context
        current.same_path?(context)
      else
        false
      end
    end

    def context_matches?(other : ObjectSharedInlineCallbackReadSlice) : Bool
      return false unless left = @context
      return false unless right = other.@context
      left.same_path?(right)
    end

    def context_matches_context?(context : ObjectSharedInlineCoordinateContext) : Bool
      if current = @context
        current.same_path?(context)
      else
        false
      end
    end
  end
end
