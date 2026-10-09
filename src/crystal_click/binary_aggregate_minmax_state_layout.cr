module CrystalClick
  # ClickHouse SingleValueData state grammar. The argument descriptor is
  # nominal metadata; only Generic's present payload is an ordinary child
  # value, visited through BinaryValueCodec under the caller's shared budget.
  class BinaryAggregateMinMaxStateLayout
    getter input_type : BinaryDataType
    getter state_kind : BinaryAggregateMinMaxArgumentPolicy::StateKind
    getter? nullable_argument : Bool

    @fixed_width : Int32?

    def initialize(profile : BinaryAggregateMinMaxArgumentPolicy::Profile)
      @input_type = profile.input_type
      @state_kind = profile.state_kind
      @nullable_argument = profile.nullable_argument?
      @fixed_width = @state_kind.fixed? ? (@input_type.fixed_width || raise ArgumentError.new("AggregateFunction min/max fixed argument has no carrier width")) : nil
    end

    def minimum_state_bytes : Int32
      @nullable_argument ? 1 : (@state_kind.string? ? 4 : 1)
    end

    def default_state_bytes : Bytes
      return Bytes[0_u8] if @nullable_argument
      return encode_int32(-1_i32) if @state_kind.string?
      Bytes[0_u8]
    end

    # Validate only the canonical outer/family framing here. A Generic body is
    # recursively visited by its owner with the active operation budget.
    def validate_state_bytes(bytes : Bytes) : Nil
      if @nullable_argument
        if bytes.size == 1 && bytes[0] == 0_u8
          return nil
        end
        unless bytes.size >= 2 && bytes[0] == 1_u8
          raise ArgumentError.new("AggregateFunction nullable min/max state has invalid presence or body")
        end
        validate_inner_state_bytes(bytes[1, bytes.size - 1])
      else
        validate_inner_state_bytes(bytes)
      end
      nil
    end

    # Consume one state from a cursor. Legacy String states accepted by
    # ClickHouse are normalized into the current writer's canonical spelling.
    def read_state(context : BinaryCodecContext, depth : Int) : Bytes
      if @nullable_argument
        case context.read_byte
        when 0_u8
          return Bytes[0_u8]
        when 1_u8
          return prepend_presence(read_inner_state(context, depth))
        else
          context.corrupt!("AggregateFunction nullable min/max state has an invalid presence byte")
        end
      end
      read_inner_state(context, depth)
    end

    # Caller has already checked the canonical frame. This parses a present
    # Generic body using the caller's shared write budget but does not charge
    # input or output bytes; the physical/raw state bytes are charged once by
    # the actual enclosing writer.
    def validate_generic_for_write(bytes : Bytes, context : BinaryCodecContext, depth : Int) : Nil
      return unless @state_kind.generic?
      body = generic_body(bytes) || return
      reader = BinaryCodecContext.new(context.limits, body, true, context.budget, false, false)
      BinaryValueCodec.consume_minmax_argument(@input_type, reader, depth + 1)
      reader.ensure_consumed
      nil
    rescue ex : CorruptPartError
      context.unsupported!("invalid generic AggregateFunction min/max state body: #{ex.message}")
    rescue ex : UnsupportedFormatError
      context.unsupported!("invalid generic AggregateFunction min/max state body: #{ex.message}")
    end

    # Public raw-state construction validates a Generic body under the
    # standalone limits supplied by its owner; the owner separately bounds
    # the complete framed state bytes. This traversal bound is not an RSS or
    # full descriptor-tree bound. Codec reads use the context-taking factory
    # instead, so they do not parse this body twice or reset shared budgets.
    def validate_owned_generic_body(bytes : Bytes, limits : BinaryCodecLimits) : Nil
      return unless @state_kind.generic?
      body = generic_body(bytes) || return
      budget = BinaryCodecBudget.new(limits, true)
      reader = BinaryCodecContext.new(limits, body, true, budget, false, false)
      BinaryValueCodec.consume_minmax_argument(@input_type, reader, 1)
      reader.ensure_consumed
      nil
    rescue ex : CorruptPartError
      raise ArgumentError.new("invalid generic AggregateFunction min/max state body: #{ex.message}")
    rescue ex : UnsupportedFormatError
      raise ArgumentError.new("invalid generic AggregateFunction min/max state body: #{ex.message}")
    end

    private def read_inner_state(context : BinaryCodecContext, depth : Int) : Bytes
      case @state_kind
      when .fixed?
        flag = context.read_byte
        case flag
        when 0_u8
          Bytes[0_u8]
        when 1_u8
          raw = context.read_slice(@fixed_width.not_nil!.to_u64)
          prepend_presence(raw)
        else
          context.corrupt!("AggregateFunction min/max fixed state has an invalid presence byte")
        end
      when .string?
        read_string_state(context)
      when .generic?
        flag = context.read_byte
        case flag
        when 0_u8
          Bytes[0_u8]
        when 1_u8
          body = BinaryValueCodec.consume_minmax_argument(@input_type, context, depth + 1)
          prepend_presence(body)
        else
          context.corrupt!("AggregateFunction min/max generic state has an invalid presence byte")
        end
      else
        context.corrupt!("AggregateFunction min/max has an unsupported state family")
      end
    rescue ex : ArgumentError
      context.corrupt!("invalid generic AggregateFunction min/max state body: #{ex.message}")
    end

    private def read_string_state(context : BinaryCodecContext) : Bytes
      length = read_int32(context)
      return encode_int32(-1_i32) if length < 0
      return canonical_string_state(Bytes.empty) if length == 0

      wire = context.read_slice(length.to_u64)
      payload_size = if wire[length - 1] == 0_u8
                       length - 1
                     else
                       length
                     end
      content = Bytes.new(payload_size) { |index| wire[index] }
      canonical_string_state(content)
    end

    private def validate_inner_state_bytes(bytes : Bytes) : Nil
      case @state_kind
      when .fixed?
        unless bytes.size == 1 && bytes[0] == 0_u8
          unless bytes.size == @fixed_width.not_nil! + 1 && bytes[0] == 1_u8
            raise ArgumentError.new("AggregateFunction min/max fixed state has invalid presence or carrier width")
          end
        end
      when .string?
        unless bytes.size >= 4
          raise ArgumentError.new("AggregateFunction min/max String state is shorter than its signed length")
        end
        length = read_int32(bytes)
        if length == -1_i32
          unless bytes.size == 4
            raise ArgumentError.new("AggregateFunction absent min/max String state has trailing bytes")
          end
        elsif length <= 0
          raise ArgumentError.new("AggregateFunction min/max String state is not canonically present")
        elsif bytes.size.to_i64 != 4_i64 + length.to_i64 || bytes[bytes.size - 1] != 0_u8
          raise ArgumentError.new("AggregateFunction min/max String state has a bad length or terminator")
        end
      when .generic?
        unless bytes.size == 1 && bytes[0] == 0_u8
          # A present Field-backed empty Tuple has no serialized body bytes.
          # The recursive child serde, not this frame check, proves whether a
          # zero-length body is valid for the admitted argument type.
          unless bytes.size >= 1 && bytes[0] == 1_u8
            raise ArgumentError.new("AggregateFunction min/max generic state has invalid presence or body")
          end
        end
      end
      nil
    end

    private def generic_body(bytes : Bytes) : Bytes?
      offset = 0
      if @nullable_argument
        return nil if bytes[0] == 0_u8
        offset = 1
      end
      return nil unless bytes[offset] == 1_u8
      start = offset + 1
      bytes[start, bytes.size - start]
    end

    private def canonical_string_state(content : Bytes) : Bytes
      if content.size >= Int32::MAX
        raise ArgumentError.new("AggregateFunction min/max String state exceeds the signed Int32 length domain")
      end
      length = content.size + 1
      total_size = 4_i64 + length.to_i64
      if total_size > Int32::MAX.to_i64
        raise ArgumentError.new("AggregateFunction min/max String state exceeds its supported byte domain")
      end
      bytes = Bytes.new(total_size.to_i32)
      write_int32(bytes, 0, length.to_i32)
      content.size.times { |index| bytes[4 + index] = content[index] }
      bytes[bytes.size - 1] = 0_u8
      bytes
    end

    private def prepend_presence(raw : Bytes) : Bytes
      bytes = Bytes.new(raw.size + 1)
      bytes[0] = 1_u8
      raw.size.times { |index| bytes[index + 1] = raw[index] }
      bytes
    end

    private def read_int32(context : BinaryCodecContext) : Int32
      read_int32(context.read_slice(4_u64))
    end

    private def read_int32(bytes : Bytes) : Int32
      bits = bytes[0].to_u32 |
             (bytes[1].to_u32 << 8) |
             (bytes[2].to_u32 << 16) |
             (bytes[3].to_u32 << 24)
      bits.unsafe_as(Int32)
    end

    private def encode_int32(value : Int32) : Bytes
      bytes = Bytes.new(4)
      write_int32(bytes, 0, value)
      bytes
    end

    private def write_int32(bytes : Bytes, offset : Int, value : Int32) : Nil
      bits = value.unsafe_as(UInt32)
      bytes[offset] = (bits & 0xff_u32).to_u8
      bytes[offset + 1] = ((bits >> 8) & 0xff_u32).to_u8
      bytes[offset + 2] = ((bits >> 16) & 0xff_u32).to_u8
      bytes[offset + 3] = ((bits >> 24) & 0xff_u32).to_u8
      nil
    end
  end
end
