require "./clickhouse_timezone_catalog_26_7"
require "./timezone_name"

module CrystalClick
  # Immutable parameters for the temporal scalar tags in the admitted binary
  # descriptor grammar. Timezone admission is delegated to the pinned
  # TimezoneName profile; an empty descriptor timezone is normalized to nil.
  class BinaryTemporalType
    enum Family
      DateTime
      DateTime64
      Time64
    end

    getter family : Family
    getter scale : Int32?

    @time_zone : TimezoneName?

    private def initialize(@family : Family, @scale : Int32?, @time_zone : TimezoneName?)
      case @family
      when Family::DateTime
        raise ArgumentError.new("DateTime cannot carry a scale") unless @scale.nil?
      when Family::DateTime64, Family::Time64
        value = @scale || raise ArgumentError.new("scaled temporal type requires a scale")
        raise ArgumentError.new("temporal scale must be between 0 and 9") unless value >= 0 && value <= 9
        raise ArgumentError.new("Time64 cannot carry a timezone") if @family == Family::Time64 && @time_zone
      end
    end

    def self.datetime(time_zone : String? = nil) : BinaryTemporalType
      new(Family::DateTime, nil, parse_time_zone(time_zone))
    end

    def self.datetime64(scale : Int, time_zone : String? = nil) : BinaryTemporalType
      unless scale >= 0 && scale <= 9
        raise ArgumentError.new("DateTime64 scale must be between 0 and 9")
      end
      new(Family::DateTime64, scale.to_i32, parse_time_zone(time_zone))
    end

    def self.time64(scale : Int) : BinaryTemporalType
      unless scale >= 0 && scale <= 9
        raise ArgumentError.new("Time64 scale must be between 0 and 9")
      end
      new(Family::Time64, scale.to_i32, nil)
    end

    def time_zone? : TimezoneName?
      @time_zone
    end

    def explicit_time_zone? : Bool
      !@time_zone.nil?
    end

    def fixed_width : Int32
      case @family
      when Family::DateTime                   then 4
      when Family::DateTime64, Family::Time64 then 8
      else
        raise ArgumentError.new("unsupported binary temporal family")
      end
    end

    def type_name : String
      zone = @time_zone.try(&.name)
      case @family
      when Family::DateTime
        zone ? "DateTime('#{zone}')" : "DateTime"
      when Family::DateTime64
        zone ? "DateTime64(#{@scale}, '#{zone}')" : "DateTime64(#{@scale})"
      when Family::Time64
        "Time64(#{@scale})"
      else
        raise ArgumentError.new("unsupported binary temporal family")
      end
    end

    def ==(other : self) : Bool
      @family == other.@family && @scale == other.@scale && @time_zone == other.@time_zone
    end

    def hash(hasher)
      hasher = @family.hash(hasher)
      hasher = @scale.hash(hasher)
      @time_zone.hash(hasher)
    end

    private def self.parse_time_zone(name : String?) : TimezoneName?
      return nil unless name && !name.empty?
      TimezoneName.parse(name) || raise ArgumentError.new("timezone name is not admitted by the pinned ClickHouse catalog")
    end
  end
end
