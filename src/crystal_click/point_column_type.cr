module CrystalClick
  # Exact physical descriptor for a scalar Point over two Float64 coordinate
  # streams. The shared Float64 leaf descriptor supplies slot accounting and
  # the reader invokes WidePart's existing Float64 decoder.
  class PointColumnType
    MAX_MATERIALIZED_BYTES    = 64_u64 * 1024_u64 * 1024_u64
    FIXED_LOGICAL_BYTES       = 64_u64
    STREAM_SLOT_LOGICAL_BYTES = 32_u64

    getter coordinate_type : WideTupleLeafType

    def initialize
      @coordinate_type = WideTupleLeafType.parse("Float64") ||
                         raise ArgumentError.new("Point requires the exact Float64 coordinate descriptor")
    end

    def self.for_type(type_name : String) : PointColumnType?
      return nil unless type_name == "Point"
      new
    rescue ArgumentError
      nil
    end

    def type_name : String
      "Point"
    end

    def coordinate_streams(column : String) : Tuple(String, String)
      {"#{column}%2E1", "#{column}%2E2"}
    end

    def physical_streams(column : String) : Array(Tuple(String, Int32))
      first, second = coordinate_streams(column)
      [{first, 8}, {second, 8}]
    end

    def stream_width(column : String, stream : String) : Int32?
      first, second = coordinate_streams(column)
      return 8 if stream == first || stream == second
      nil
    end

    def materialization_charge(rows : UInt64, schedule_charge : UInt64 = 0_u64) : UInt64
      descriptor_bytes = FIXED_LOGICAL_BYTES +
                         instance_sizeof(PointColumnType).to_u64 +
                         STREAM_SLOT_LOGICAL_BYTES * 2_u64 +
                         coordinate_type.logical_charge
      return over_limit! if descriptor_bytes > MAX_MATERIALIZED_BYTES ||
                            schedule_charge > MAX_MATERIALIZED_BYTES - descriptor_bytes

      fixed = descriptor_bytes + schedule_charge
      per_row = 16_u64 + sizeof(WidePointValue).to_u64
      return over_limit! if rows > (MAX_MATERIALIZED_BYTES - fixed) // per_row

      fixed + rows * per_row
    end

    private def over_limit! : UInt64
      raise ArgumentError.new("Point materialization exceeds 64 MiB per-range limit")
    end
  end
end
