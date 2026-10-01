module CrystalClick
  # Exact scalar or BASIC Nullable QBit storage shape. The stream list is
  # derived from the descriptor and bounded against metadata/checksum limits.
  struct QBitColumnType
    MAX_PLANE_STREAM_WIDTH = 65_536
    MAX_MATERIALIZED_BYTES = 64_u64 * 1024_u64 * 1024_u64
    CHECKSUM_FIXED_ENTRIES = 3_u64 # primary.idx, count.txt, serialization.json

    getter value_type : QBitType
    getter nullable : Bool

    def initialize(@value_type : QBitType, @nullable : Bool = false)
      raise ArgumentError.new("QBit plane width exceeds FixedString reader limit") if @value_type.plane_width > MAX_PLANE_STREAM_WIDTH
      ensure_checksum_stream_bound!
    end

    def type_name : String
      @nullable ? "Nullable(#{@value_type.type_name})" : @value_type.type_name
    end

    def physical_streams(column : String) : Array(Tuple(String, Int32))
      streams = [] of Tuple(String, Int32)
      streams << {"#{column}.null", 1} if @nullable
      1.upto(@value_type.plane_count) do |index|
        streams << {"#{column}%2E#{index}", @value_type.plane_width}
      end
      streams
    end

    def stream_width(column : String, name : String) : Int32?
      return 1 if @nullable && name == "#{column}.null"
      plane_prefix = "#{column}%2E"
      return nil unless name.starts_with?(plane_prefix)
      suffix = name[plane_prefix.bytesize..-1]
      return nil unless suffix.matches?(/\A[1-9][0-9]*\z/)
      index = suffix.to_i32?
      return nil unless index && index >= 1 && index <= @value_type.plane_count
      name == "#{column}%2E#{index}" ? @value_type.plane_width : nil
    end

    # Logical selected-range charge includes result slots, exact raw row bytes,
    # all plane payload buffers, and the nullable map where applicable. It is
    # conservative for NULL output rows and is checked before decode/allocation.
    def materialization_charge(rows : UInt64) : UInt64
      streams = @value_type.plane_count.to_u64 + (@nullable ? 1_u64 : 0_u64)
      stream_count = streams + 1_u64 # the paired UInt64 key
      records = stream_count * 2_u64 + CHECKSUM_FIXED_ENTRIES
      raise ArgumentError.new("QBit checksum entry count exceeds reader limit") if records > PartChecksums::MAX_ENTRIES.to_u64

      descriptor_bytes = @value_type.type_name.bytesize.to_u64 + 64_u64 + streams * 32_u64
      slot_bytes = if @nullable
                     sizeof(QBitValue?).to_u64
                   else
                     sizeof(QBitValue).to_u64
                   end
      per_row = slot_bytes
      per_row = checked_add(per_row, @value_type.raw_row_bytes.to_u64)
      per_row = checked_add(per_row, @value_type.plane_count.to_u64 * @value_type.plane_width.to_u64)
      per_row = checked_add(per_row, @nullable ? 1_u64 : 0_u64)
      charge = checked_add(descriptor_bytes, checked_multiply(rows, per_row))
      raise ArgumentError.new("QBit materialization exceeds 64 MiB per-range limit") if charge > MAX_MATERIALIZED_BYTES
      charge
    end

    def self.for_type(type_name : String) : QBitColumnType?
      return nil if type_name.bytesize > 160
      nullable = type_name.starts_with?("Nullable(")
      inner = if nullable
                return nil unless type_name.ends_with?(")")
                type_name["Nullable(".bytesize, type_name.bytesize - "Nullable(".bytesize - 1]
              else
                type_name
              end
      value_type = QBitType.for_type(inner) || return nil
      column = new(value_type, nullable)
      return nil unless column.type_name == type_name
      column
    rescue ArgumentError
      nil
    end

    private def ensure_checksum_stream_bound! : Nil
      physical_count = @value_type.plane_count.to_u64 + (@nullable ? 1_u64 : 0_u64)
      checksum_count = (physical_count + 1_u64) * 2_u64 + CHECKSUM_FIXED_ENTRIES
      raise ArgumentError.new("QBit physical streams exceed checksums entry limit") if checksum_count > PartChecksums::MAX_ENTRIES.to_u64
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise ArgumentError.new("QBit materialization charge overflows UInt64") if left > UInt64::MAX - right
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      return 0_u64 if left == 0_u64 || right == 0_u64
      raise ArgumentError.new("QBit materialization charge overflows UInt64") if left > UInt64::MAX // right
      left * right
    end

    def ==(other : self) : Bool
      @value_type == other.value_type && @nullable == other.nullable
    end

    def hash(hasher)
      hasher = @value_type.hash(hasher)
      @nullable.hash(hasher)
    end
  end
end
