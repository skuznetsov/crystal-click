module CrystalClick
  # Bounded writer for one normalized BinaryBulk role across a Compact
  # window, including its detached per-mark coordinate grid.
  class CompactBinaryBulkLaneBuilder
    getter role : String

    @bytes : Array(UInt8)
    @offsets : Array(UInt64)

    def initialize(@role : String, initial_offset : UInt64 = 0_u64)
      @bytes = [] of UInt8
      @offsets = [initial_offset]
    end

    def append(bytes : Bytes, budget : BinaryCodecBudget) : Nil
      budget.ensure_wire_bytes(bytes.size.to_u64)
      budget.charge_wire_bytes(bytes.size.to_u64)
      bytes.each { |byte| @bytes << byte }
      nil
    end

    def append_byte(byte : UInt8, budget : BinaryCodecBudget) : Nil
      budget.ensure_wire_bytes(1_u64)
      budget.charge_wire_bytes(1_u64)
      @bytes << byte
      nil
    end

    def append_u64(value : UInt64, budget : BinaryCodecBudget) : Nil
      budget.ensure_wire_bytes(8_u64)
      budget.charge_wire_bytes(8_u64)
      8.times { |index| @bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
      nil
    end

    def finish_mark : Nil
      @offsets << @bytes.size.to_u64
      nil
    end

    def mark_count : Int32
      @offsets.size - 1
    end

    # Logical payload already appended to this lane. Workspace admission uses
    # this before appending the next slice and before detached stream copies.
    def data_size : UInt64
      @bytes.size.to_u64
    end

    def build : BinaryBulkStream
      bytes = Bytes.new(@bytes.size) { |index| @bytes[index] }
      BinaryBulkStream.new(bytes, @offsets)
    end
  end
end
