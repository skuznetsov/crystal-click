module CrystalClick
  # Shared bounded cursor/builder and logical traversal budget for one codec
  # operation. Input slices are borrowed; output grows only after byte checks.
  class BinaryCodecContext
    getter limits : BinaryCodecLimits
    getter input_offset : Int32

    @input : Bytes?
    @output : Array(UInt8)
    @writing : Bool
    @budget : BinaryCodecBudget
    @account_output_bytes : Bool
    @output_byte_limit : UInt64

    # The borrowed/prepaid switches are internal-only plumbing. A caller may
    # disable input charging only after an enclosing owner charged the complete
    # physical input lanes, and may disable output charging only for a
    # temporary envelope whose final framed bytes will be charged by that
    # owner. Public codec entry points deliberately expose neither switch.
    def initialize(
      @limits : BinaryCodecLimits,
      input : Bytes? = nil,
      @writing : Bool = false,
      budget : BinaryCodecBudget? = nil,
      account_input_bytes : Bool = true,
      account_output_bytes : Bool = true,
      output_byte_limit : UInt64? = nil,
    )
      @input = input
      @output = [] of UInt8
      @input_offset = 0_i32
      @budget = budget || BinaryCodecBudget.new(@limits, @writing)
      @account_output_bytes = account_output_bytes
      @output_byte_limit = output_byte_limit || @limits.max_bytes.to_u64
      if @output_byte_limit > @limits.max_bytes.to_u64
        raise ArgumentError.new("binary codec context output bound exceeds its limits")
      end
      unless @budget.limits.max_depth == @limits.max_depth &&
             @budget.limits.max_nodes == @limits.max_nodes &&
             @budget.limits.max_elements == @limits.max_elements &&
             @budget.limits.max_bytes == @limits.max_bytes
        raise ArgumentError.new("binary codec context and shared budget limits differ")
      end
      unless @budget.writing? == @writing
        raise ArgumentError.new("binary codec context and shared budget direction differs")
      end
      if source = @input
        if source.size.to_i64 > @limits.max_bytes
          raise CorruptPartError.new("binary codec input exceeds byte limit")
        end
        @budget.charge_wire_bytes(source.size.to_u64) if account_input_bytes
      end
    end

    def node_count : Int64
      @budget.node_count
    end

    def element_count : Int64
      @budget.element_count
    end

    # Internal shared budget access for bounded Variant roster-name work.
    # This is intentionally the same operation budget used for wire bytes and
    # recursive descriptor/value traversal.
    def budget : BinaryCodecBudget
      @budget
    end

    def visit_node(depth : Int) : Nil
      @budget.visit_node(depth)
    end

    def ensure_depth(depth : Int) : Nil
      @budget.ensure_depth(depth)
    end

    # Verify a lower bound before allocating a declared child array. This does
    # not charge visits; normal recursive traversal charges each node once.
    def ensure_future_nodes(count : UInt64) : Nil
      @budget.ensure_future_nodes(count)
    end

    def charge_elements(count : UInt64) : Nil
      @budget.charge_elements(count)
    end

    # Preflight count-derived metadata collections before allocation. Metadata
    # entries consume aggregate node and edge budgets, but they are owned by a
    # scalar descriptor and therefore do not increase recursive depth.
    def preflight_metadata(
      count : UInt64,
      minimum_wire_bytes_per_entry : UInt64 = 0_u64,
      maximum_count : UInt64 = Int32::MAX.to_u64,
      label : String = "metadata count",
    ) : Int32
      if count > maximum_count
        corrupt!("#{label} exceeds its supported domain")
      end
      checked = checked_count(count, label)
      preflight_children(count) unless count == 0_u64
      if !@writing && minimum_wire_bytes_per_entry > 0_u64 && count > 0_u64
        if count > UInt64::MAX // minimum_wire_bytes_per_entry
          corrupt!("#{label} minimum wire size overflows UInt64")
        end
        ensure_remaining_input_bytes(count * minimum_wire_bytes_per_entry)
      end
      checked
    end

    def visit_metadata_nodes(count : UInt64, depth : Int) : Nil
      count.times { visit_node(depth) }
      nil
    end

    def remaining_input_bytes : UInt64
      source = @input || raise CorruptPartError.new("binary codec has no input")
      (source.size - @input_offset).to_u64
    end

    def ensure_remaining_input_bytes(count : UInt64) : Nil
      if count > remaining_input_bytes
        corrupt!("binary codec input is too short for declared metadata count")
      end
    end

    def validate_type_tree(type : BinaryDataType, depth : Int = 1) : Nil
      visit_node(depth)
      if type.tag == BinaryDataType::TAG_AGGREGATE_COUNT
        # Count's argument belongs to its descriptor grammar and budget, but
        # is not a generic child that value/bulk walkers may recurse through.
        if argument = type.aggregate_count_argument_type
          preflight_children(1_u64)
          validate_type_tree(argument, depth + 1)
        end
        return nil
      end
      count = type.child_count.to_u64
      preflight_children(count) unless count == 0
      count.to_i.times do |index|
        validate_type_tree(type.child_at(index), depth + 1)
      end
      metadata_count = type.metadata_entry_count.to_u64
      if metadata_count > 0_u64
        preflight_children(metadata_count)
        visit_metadata_nodes(metadata_count, depth)
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
      @budget.charge_wire_bytes(1_u64) if @account_output_bytes
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
      @budget.charge_wire_bytes(bytes.size.to_u64) if @account_output_bytes
      bytes.each { |byte| @output << byte }
    end

    def ensure_output_bytes(additional : UInt64) : Nil
      check_output_growth(additional)
    end

    def finish_bytes : Bytes
      Bytes.new(@output.size) { |index| @output[index] }
    end

    # Scalar output position for paired metadata encoders. This avoids a
    # finish_bytes copy/reparse just to capture the statistics-suffix offset.
    def output_size : Int32
      @output.size
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
      current = @output.size.to_u64
      if current > @output_byte_limit || additional > (@output_byte_limit - current)
        fail_local_output_limit
      end
      @budget.ensure_wire_bytes(additional) if @account_output_bytes
    end

    private def fail_local_output_limit : NoReturn
      message = "binary codec byte limit exceeded"
      if @writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
