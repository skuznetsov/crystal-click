module CrystalClick
  # Consumptive operation budget shared across every lane in one transport.
  # Counts remain charged after a failed operation so retries cannot reset work.
  class CompressedStreamBudget
    getter limits : CompressedStreamLimits
    getter file_byte_count : Int64
    getter record_count : Int64
    getter decoded_byte_count : Int64
    getter result_byte_count : Int64

    @writing : Bool

    def initialize(@limits : CompressedStreamLimits = CompressedStreamLimits.new, @writing : Bool = false)
      @file_byte_count = 0_i64
      @record_count = 0_i64
      @decoded_byte_count = 0_i64
      @result_byte_count = 0_i64
    end

    def writing? : Bool
      @writing
    end

    def self.read_default : CompressedStreamBudget
      new(CompressedStreamLimits.new)
    end

    def self.write_default : CompressedStreamBudget
      new(CompressedStreamLimits.new, true)
    end

    def ensure_direction(writing : Bool) : Nil
      raise ArgumentError.new("compressed stream budget direction mismatch") unless @writing == writing
    end

    def reserve_file_bytes(count : Int64) : Nil
      ensure_nonnegative(count)
      ensure_capacity(count, @limits.max_file_bytes - @file_byte_count, "file-byte")
      @file_byte_count += count
    end

    def reserve_records(count : Int64) : Nil
      ensure_nonnegative(count)
      ensure_capacity(count, @limits.max_records - @record_count, "header-record")
      @record_count += count
    end

    def reserve_decoded_bytes(count : Int64) : Nil
      ensure_nonnegative(count)
      ensure_capacity(count, @limits.max_decoded_bytes - @decoded_byte_count, "decoded-byte")
      @decoded_byte_count += count
    end

    def reserve_result_bytes(count : Int64) : Nil
      ensure_nonnegative(count)
      ensure_capacity(count, @limits.max_result_bytes - @result_byte_count, "result-byte")
      @result_byte_count += count
    end

    private def ensure_nonnegative(count : Int64) : Nil
      raise ArgumentError.new("negative compressed stream budget charge") if count < 0
    end

    private def ensure_capacity(count : Int64, remaining : Int64, kind : String) : Nil
      if remaining < 0 || count > remaining
        message = "compressed stream #{kind} limit exceeded"
        if @writing
          raise UnsupportedFormatError.new(message)
        else
          raise CorruptPartError.new(message)
        end
      end
    end
  end
end
