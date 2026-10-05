module CrystalClick
  # Exact scalar temporal leaf identity admitted as a
  # SimpleAggregateFunction storage child. This is intentionally narrower than
  # ordinary temporal column parsing: it has no wrappers or catalog aliases.
  class TemporalStorageType
    enum Family
      Date
      Date32
      DateTime
      DateTime64
      Time
      Time64
    end

    @family : Family
    @type_name : String
    @precision : Int32?
    @time_zone : TimezoneName?
    @storage_width : Int32

    private def initialize(
      @family : Family,
      type_name : String,
      @precision : Int32?,
      @time_zone : TimezoneName?,
      @storage_width : Int32,
    )
      @type_name = String.new(type_name.to_slice)
    end

    # Parse only the six exact canonical scalar names. DateTime spellings and
    # their pinned timezone validation are shared with DateTimeColumnType;
    # Time64's one-digit scale grammar is kept here rather than duplicated in
    # the aggregate parser or carrier plan.
    def self.parse(type_name : String) : TemporalStorageType?
      case type_name
      when "Date"
        return new(Family::Date, type_name, nil, nil, 2)
      when "Date32"
        return new(Family::Date32, type_name, nil, nil, 4)
      when "Time"
        return new(Family::Time, type_name, nil, nil, 4)
      end

      if parsed = DateTimeColumnType.parse_leaf(type_name)
        family = case parsed.family
                 when DateTimeColumnType::Family::DateTime
                   Family::DateTime
                 when DateTimeColumnType::Family::DateTime64
                   Family::DateTime64
                 else
                   return nil
                 end
        return new(
          family,
          parsed.leaf_type_name,
          parsed.precision?.try(&.to_i),
          parsed.time_zone?,
          parsed.raw_width,
        )
      end

      if match = /\ATime64\(([0-9])\)\z/.match(type_name)
        scale = match[1].to_i
        parsed = BinaryTemporalType.time64(scale)
        return new(Family::Time64, parsed.type_name, scale, nil, parsed.fixed_width)
      end

      nil
    end

    def family : Family
      @family
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def precision? : Int32?
      @precision
    end

    def time_zone? : TimezoneName?
      @time_zone
    end

    def storage_width : Int32
      @storage_width
    end

    def ==(other : self) : Bool
      @family == other.@family &&
        @type_name == other.@type_name &&
        @precision == other.@precision &&
        @time_zone == other.@time_zone &&
        @storage_width == other.@storage_width
    end

    def hash(hasher)
      hasher = @family.hash(hasher)
      hasher = @type_name.hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @time_zone.hash(hasher)
      @storage_width.hash(hasher)
    end
  end
end
