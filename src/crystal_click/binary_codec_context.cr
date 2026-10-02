module CrystalClick
  # Shared bounded cursor/builder and logical traversal budget for one codec
  # operation. Input slices are borrowed; output grows only after byte checks.
  class BinaryCodecContext
    getter limits : BinaryCodecLimits
    getter node_count : Int64
    getter element_count : Int64
    getter input_offset : Int32

    @input : Bytes?
    @output : Array(UInt8)
    @writing : Bool

    def initialize(@limits : BinaryCodecLimits, input : Bytes? = nil, @writing : Bool = false)
      @input = input
      @output = [] of UInt8
      @node_count = 0_i64
      @element_count = 0_i64
      @input_offset = 0_i32
      if source = @input
        if source.size.to_i64 > @limits.max_bytes
          raise CorruptPartError.new("binary codec input exceeds byte limit")
        end
      end
    end

    def visit_node(depth : Int) : Nil
      ensure_depth(depth)
      if @node_count >= @limits.max_nodes
        fail_budget("node")
      end
      @node_count += 1
    end

    def ensure_depth(depth : Int) : Nil
      if depth <= 0 || depth > @limits.max_depth
        fail_budget("depth")
      end
    end

    # Verify a lower bound before allocating a declared child array. This does
    # not charge visits; normal recursive traversal charges each node once.
    def ensure_future_nodes(count : UInt64) : Nil
      remaining = (@limits.max_nodes - @node_count).to_u64
      fail_budget("node") if count > remaining
    end

    def charge_elements(count : UInt64) : Nil
      remaining = (@limits.max_elements - @element_count).to_u64
      fail_budget("element") if count > remaining
      @element_count += count.to_i64
    end

    def validate_type_tree(type : BinaryDataType, depth : Int = 1) : Nil
      visit_node(depth)
      count = type.child_count.to_u64
      preflight_children(count) unless count == 0
      count.to_i.times do |index|
        validate_type_tree(type.child_at(index), depth + 1)
      end
    end

    # Charge child edges and prove each announced child has a node budget before
    # its collection is allocated. Recursive visitors later charge the nodes.
    def preflight_children(count : UInt64) : Nil
      charge_elements(count)
      ensure_future_nodes(count)
    end

    def read_byte : UInt8
      source = @input || raise CorruptPartError.new("binary codec has no input")
      if @input_offset >= source.size
        raise CorruptPartError.new("binary codec input is truncated")
      end
      value = source[@input_offset]
      @input_offset += 1
      value
    end

    # This module deliberately accepts only the minimal canonical VarUInt
    # profile; ClickHouse's general binary decoder is not claimed to require it.
    def read_var_uint : UInt64
      value = 0_u64
      10.times do |index|
        byte = read_byte
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          raise CorruptPartError.new("binary codec VarUInt overflows UInt64")
        end
        value |= payload << (index * 7)
        continuing = (byte & 0x80_u8) != 0_u8
        if !continuing
          if index > 0 && payload == 0_u64
            raise CorruptPartError.new("binary codec VarUInt is nonminimal")
          end
          return value
        end
        if index == 9
          raise CorruptPartError.new("binary codec VarUInt is too long")
        end
      end
      raise CorruptPartError.new("binary codec VarUInt is too long")
    end

    def read_slice(size : UInt64) : Bytes
      source = @input || raise CorruptPartError.new("binary codec has no input")
      remaining = (source.size - @input_offset).to_u64
      if size > remaining || size > Int32::MAX.to_u64
        raise CorruptPartError.new("binary codec byte range is truncated or too large")
      end
      start = @input_offset
      @input_offset += size.to_i32
      source[start, size.to_i32]
    end

    def ensure_consumed : Nil
      source = @input || raise CorruptPartError.new("binary codec has no input")
      unless @input_offset == source.size
        raise CorruptPartError.new("binary codec input has trailing bytes")
      end
    end

    def write_byte(byte : UInt8) : Nil
      check_output_growth(1_u64)
      @output << byte
    end

    def write_var_uint(value : UInt64) : Nil
      remaining = value
      loop do
        payload = (remaining & 0x7f_u64).to_u8
        remaining >>= 7
        write_byte(remaining == 0_u64 ? payload : payload | 0x80_u8)
        break if remaining == 0_u64
      end
    end

    def write_slice(bytes : Bytes) : Nil
      ensure_output_bytes(bytes.size.to_u64)
      bytes.each { |byte| @output << byte }
    end

    def ensure_output_bytes(additional : UInt64) : Nil
      check_output_growth(additional)
    end

    def finish_bytes : Bytes
      Bytes.new(@output.size) { |index| @output[index] }
    end

    def checked_count(value : UInt64, label : String) : Int32
      if value > Int32::MAX.to_u64
        corrupt!("#{label} exceeds supported in-memory count")
      end
      value.to_i32
    end

    def corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    def unsupported!(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end

    private def check_output_growth(additional : UInt64) : Nil
      current = @output.size.to_i64
      if additional > (@limits.max_bytes - current).to_u64
        fail_budget("byte")
      end
    end

    private def fail_budget(kind : String) : NoReturn
      message = "binary codec #{kind} limit exceeded"
      if @writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
