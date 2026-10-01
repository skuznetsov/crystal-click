module CrystalClick
  # Owned immutable size and prefix-offset vectors for one flattened Geo Array
  # value. Each level's offsets map parent records to records in the next
  # level; the last level maps records to raw Points.
  class WideGeoArrayTopology
    @plan : GeoArrayColumnType
    @sizes : Array(Array(UInt64))
    @offsets : Array(Array(UInt64))
    @row_count : Int32
    @point_count : Int32

    def self.validate!(
      plan : GeoArrayColumnType,
      level_sizes : Array(Array(UInt64)),
      expected_point_count : Int? = nil,
    ) : Nil
      raise ArgumentError.new("Geo Array topology depth does not match its exact type") unless level_sizes.size == plan.depth
      raise ArgumentError.new("Geo Array topology has no size levels") if level_sizes.empty?

      rows = level_sizes[0].size
      if rows >= Int32::MAX || rows.to_u64 > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
        raise ArgumentError.new("Geo Array row count exceeds the supported range")
      end

      expected_count = rows.to_u64
      level_sizes.each_with_index do |sizes, level|
        if sizes.size.to_u64 != expected_count
          raise ArgumentError.new("Geo Array level #{level} cardinality does not match its parent")
        end
        raise ArgumentError.new("Geo Array level #{level} exceeds the supported native range") if sizes.size >= Int32::MAX
        total = checked_sum(sizes, level)
        if total > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
          raise ArgumentError.new("Geo Array level #{level} exceeds the materialization element limit")
        end
        expected_count = total
      end

      if expected_point_count && expected_point_count != expected_count
        raise ArgumentError.new("Geo Array topology does not match the flattened Point count")
      end
      nil
    end

    def initialize(@plan : GeoArrayColumnType, level_sizes : Array(Array(UInt64)))
      self.class.validate!(@plan, level_sizes)
      @row_count = level_sizes[0].size.to_i32
      @point_count = self.class.checked_sum(level_sizes.last, @plan.depth - 1).to_i32
      @sizes = level_sizes.map(&.dup)
      @offsets = Array(Array(UInt64)).new(@plan.depth)
      @sizes.each_with_index do |sizes, level|
        offsets = Array(UInt64).new(sizes.size + 1, 0_u64)
        total = 0_u64
        sizes.each_with_index do |size, index|
          if size > UInt64::MAX - total
            raise ArgumentError.new("Geo Array offset total overflows")
          end
          total += size
          offsets[index + 1] = total
        end
        expected = level + 1 < @plan.depth ? @sizes[level + 1].size.to_u64 : @point_count.to_u64
        unless total == expected
          raise ArgumentError.new("Geo Array size level does not match its child cardinality")
        end
        @offsets << offsets
      end
    end

    def plan : GeoArrayColumnType
      @plan
    end

    def row_count : Int32
      @row_count
    end

    def point_count : Int32
      @point_count
    end

    def level_count : Int32
      @plan.depth
    end

    def record_count(level : Int) : Int32
      @sizes[checked_level(level)].size.to_i32
    end

    def level_counts : Array(UInt64)
      @sizes.map(&.size.to_u64)
    end

    def sizes(level : Int) : Array(UInt64)
      @sizes[checked_level(level)].dup
    end

    def offsets(level : Int) : Array(UInt64)
      @offsets[checked_level(level)].dup
    end

    def size_at(level : Int, index : Int) : UInt64
      values = @sizes[checked_level(level)]
      raise BoundsError.new("Geo Array size index is out of bounds") if index < 0 || index >= values.size
      values[index]? || raise(BoundsError.new("Geo Array size index is out of bounds"))
    end

    def offset_at(level : Int, index : Int) : UInt64
      values = @offsets[checked_level(level)]
      raise BoundsError.new("Geo Array offset index is out of bounds") if index < 0 || index >= values.size
      values[index]? || raise(BoundsError.new("Geo Array offset index is out of bounds"))
    end

    # The final boundary is useful to callers that concatenate mark-local
    # topology. It remains a scalar access, so no retained vector can escape.
    def terminal_offset(level : Int) : UInt64
      @offsets[checked_level(level)].last
    end

    def retained_logical_charge(point_count : UInt64 = @point_count.to_u64) : UInt64
      charge = @plan.materialization_charge(level_counts, point_count) ||
               raise(ArgumentError.new("Geo Array topology charge exceeds the 64 MiB limit"))
      charge
    end

    private def checked_level(level : Int) : Int32
      raise BoundsError.new("Geo Array topology level is out of bounds") if level < 0 || level >= @plan.depth
      level.to_i32
    end

    def self.checked_sum(sizes : Array(UInt64), level : Int) : UInt64
      total = 0_u64
      sizes.each do |size|
        if size > UInt64::MAX - total
          raise ArgumentError.new("Geo Array level #{level} total overflows UInt64")
        end
        total += size
      end
      total
    end
  end
end
