module CrystalClick
  # One sparse Compact JSON output cell. Top-level Strings from the trusted
  # Object Copy lane retain an inline, read-only byte span; other values keep
  # their existing owned BinaryValue representation.
  struct CompactJsonColumnarCell
    STRING_TYPE = BinaryDataType.primitive("String")

    @value : BinaryValue | Bytes

    private def initialize(@value : BinaryValue | Bytes)
    end

    def self.owned(value : BinaryValue) : CompactJsonColumnarCell
      new(value)
    end

    def self.borrowed_string(bytes : Bytes) : CompactJsonColumnarCell
      readonly = Bytes.new(bytes.to_unsafe, bytes.size, read_only: true)
      new(readonly)
    end

    def type : BinaryDataType
      case value = @value
      when BinaryValue
        value.type
      when Bytes
        STRING_TYPE
      else
        raise "invalid Compact JSON column cell representation"
      end
    end

    def is_null? : Bool
      case value = @value
      when BinaryValue
        value.is_null?
      when Bytes
        false
      else
        raise "invalid Compact JSON column cell representation"
      end
    end

    # Materialize an owned value for the established public row/value API.
    # Borrowed Copy bytes are copied only when a caller explicitly requests
    # this BinaryValue view or when a detached snapshot is made.
    def materialize : BinaryValue
      case value = @value
      when BinaryValue
        value
      when Bytes
        BinaryValue.string(STRING_TYPE, value)
      else
        raise "invalid Compact JSON column cell representation"
      end
    end

    # This read-only span borrows the Copy values lane. Consume it inside a
    # `with_cell_at` callback before resetting the batch or releasing its
    # prepared input owner.
    def borrowed_string_bytes? : Bytes?
      case value = @value
      when BinaryValue
        nil
      when Bytes
        value
      else
        nil
      end
    end

    # :nodoc:
    def owned_value? : BinaryValue?
      @value.as?(BinaryValue)
    end
  end
end
