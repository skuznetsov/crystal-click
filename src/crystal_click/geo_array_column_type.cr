module CrystalClick
  # Exact physical plan for the stock-qualified Geo Array declarations.
  # The Geo name remains the logical type even when two names share a depth.
  class GeoArrayColumnType
    MAX_MATERIALIZED_BYTES = 64_u64 * 1024_u64 * 1024_u64
    MAX_LOGICAL_ELEMENTS   = 65_536_u64

    @type_name : String
    @depth : Int32
    @coordinate_type : WideTupleLeafType

    private def initialize(type_name : String, @depth : Int32)
      @type_name = String.new(type_name.to_slice)
      @coordinate_type = WideTupleLeafType.parse("Float64") ||
                         raise ArgumentError.new("Geo Array requires the exact Float64 coordinate descriptor")
    end

    def self.for_type(type_name : String) : GeoArrayColumnType?
      depth = case type_name
              when "MultiPoint", "LineString", "Ring" then 1
              when "Polygon", "MultiLineString"       then 2
              when "MultiPolygon"                     then 3
              else
                return nil
              end
      new(type_name, depth)
    rescue ArgumentError
      nil
    end

    def type_name : String
      String.new(@type_name.to_slice)
    end

    def depth : Int32
      @depth
    end

    def coordinate_type : WideTupleLeafType
      @coordinate_type
    end

    def size_stream(column : String, level : Int) : String
      if level < 0 || level >= @depth
        raise BoundsError.new("Geo Array size level is out of bounds")
      end
      "#{column}.size#{level}"
    end

    def outer_size_stream(column : String) : String
      size_stream(column, 0)
    end

    def size_streams(column : String) : Array(String)
      Array(String).new(@depth) do |level|
        size_stream(column, level)
      end
    end

    def coordinate_streams(column : String) : Tuple(String, String)
      {"#{column}%2E1", "#{column}%2E2"}
    end

    def physical_streams(column : String) : Array(Tuple(String, Int32))
      streams = Array(Tuple(String, Int32)).new(@depth + 2)
      size_streams(column).each { |stream| streams << {stream, 8} }
      x_stream, y_stream = coordinate_streams(column)
      streams << {x_stream, 8}
      streams << {y_stream, 8}
      streams
    end

    def stream_width(column : String, stream : String) : Int32?
      return 8 if size_streams(column).includes?(stream)
      x_stream, y_stream = coordinate_streams(column)
      return 8 if stream == x_stream || stream == y_stream
      nil
    end

    # Logical accounting for one retained Geo result plus explicitly supplied
    # reader schedule and scratch storage. This is a deterministic bound, not
    # an estimate of allocator overhead or process RSS.
    def materialization_charge(
      level_counts : Array(UInt64),
      point_count : UInt64,
      schedule_charge : UInt64 = 0_u64,
      scratch_bytes : UInt64 = 0_u64,
    ) : UInt64?
      return nil unless level_counts.size == @depth
      return nil if point_count > MAX_LOGICAL_ELEMENTS

      rows = level_counts[0]
      return nil if rows > MAX_LOGICAL_ELEMENTS
      total = instance_sizeof(GeoArrayColumnType).to_u64
      total = checked_add(total, instance_sizeof(WideGeoArrayTopology).to_u64) || return nil
      total = checked_add(total, instance_sizeof(WideGeoArrayColumnData).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(Array(UInt64))).to_u64 * 2_u64) || return nil
      outer_slots = @depth.to_u64 * sizeof(Pointer(Array(UInt64))).to_u64 * 2_u64
      total = checked_add(total, outer_slots) || return nil
      total = checked_add(total, instance_sizeof(Array(WidePointValue)).to_u64) || return nil
      type_name_bytes = @type_name.bytesize.to_u64 + 1_u64
      total = checked_add(total, instance_sizeof(String).to_u64) || return nil
      total = checked_add(total, type_name_bytes) || return nil
      total = checked_add(total, @coordinate_type.logical_charge) || return nil

      size_slots = 0_u64
      offset_slots = 0_u64
      @depth.times do |level|
        count = level_counts[level]
        return nil if count > MAX_LOGICAL_ELEMENTS
        total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64 * 2_u64) || return nil
        size_slots = checked_add(size_slots, count) || return nil
        offset_slots = checked_add(offset_slots, count) || return nil
        offset_slots = checked_add(offset_slots, 1_u64) || return nil
      end
      total = checked_product(total, size_slots, sizeof(UInt64).to_u64) || return nil
      total = checked_product(total, offset_slots, sizeof(UInt64).to_u64) || return nil
      total = checked_product(total, point_count, sizeof(WidePointValue).to_u64) || return nil
      total = checked_add(total, schedule_charge) || return nil
      total = checked_add(total, scratch_bytes) || return nil
      return nil if total > MAX_MATERIALIZED_BYTES
      total
    end

    # Combined logical budget for the reader. The three-argument form is used
    # for one full result or a one-mark callback. The five-argument form also
    # accounts for all decoded selected size vectors retained during a
    # multi-mark preflight.
    def reader_materialization_charge(
      result_level_counts : Array(UInt64),
      result_point_count : UInt64,
      mark_count : Int,
    ) : UInt64?
      reader_materialization_charge(
        result_level_counts,
        result_point_count,
        mark_count,
        result_level_counts,
        result_point_count
      )
    end

    def reader_materialization_charge(
      result_level_counts : Array(UInt64),
      result_point_count : UInt64,
      mark_count : Int,
      selected_level_counts : Array(UInt64),
      selected_point_count : UInt64,
    ) : UInt64?
      return nil unless selected_level_counts.size == @depth
      return nil if selected_point_count > MAX_LOGICAL_ELEMENTS
      schedule_charge = WideGeoArrayMarkSchedule.logical_charge_for_mark_count(mark_count, @depth) || return nil

      scratch = instance_sizeof(Array(WidePointValue)).to_u64
      scratch = checked_product(scratch, result_point_count, sizeof(WidePointValue).to_u64) || return nil
      coordinate_bytes = checked_product(0_u64, result_point_count, 16_u64) || return nil
      scratch = checked_add(scratch, coordinate_bytes) || return nil
      scratch = checked_add(scratch, instance_sizeof(Array(Array(Array(UInt64)))).to_u64) || return nil
      # levels_by_mark owns one Array(Array(UInt64)) value per physical mark,
      # and each such value owns one Array(UInt64) value per logical depth.
      mark_slots = mark_count.to_u64
      scratch = checked_add(scratch, checked_product(0_u64, mark_slots, instance_sizeof(Array(Array(UInt64))).to_u64) || return nil) || return nil
      scratch = checked_add(scratch, checked_product(0_u64, mark_slots, sizeof(Pointer(Array(Array(UInt64)))).to_u64) || return nil) || return nil
      level_headers = mark_slots * @depth.to_u64
      scratch = checked_add(scratch, checked_product(0_u64, level_headers, instance_sizeof(Array(UInt64)).to_u64) || return nil) || return nil
      scratch = checked_add(scratch, checked_product(0_u64, level_headers, sizeof(Pointer(Array(UInt64))).to_u64) || return nil) || return nil

      # flatten() stages one outer container plus one UInt64 array per depth.
      scratch = checked_add(scratch, instance_sizeof(Array(Array(UInt64))).to_u64) || return nil
      scratch = checked_add(scratch, checked_product(0_u64, @depth.to_u64, sizeof(Pointer(Array(UInt64))).to_u64) || return nil) || return nil
      scratch = checked_add(scratch, checked_product(0_u64, @depth.to_u64, instance_sizeof(Array(UInt64)).to_u64) || return nil) || return nil

      # selected_level_counts, per_mark_counts, the per-depth candidate copy,
      # and schedule.level_counts_at's snapshot can coexist with the result.
      count_arrays = 4_u64
      scratch = checked_product(scratch, count_arrays, instance_sizeof(Array(UInt64)).to_u64) || return nil
      scratch = checked_product(scratch, count_arrays * @depth.to_u64, sizeof(UInt64).to_u64) || return nil
      size_values = 0_u64
      selected_level_counts.each do |count|
        return nil if count > MAX_LOGICAL_ELEMENTS
        size_values = checked_add(size_values, count) || return nil
      end
      # Decoded UInt64 vectors and their raw little-endian frame buffers can
      # overlap while one size mark is decoded. Charging a second complete
      # selected-size footprint is conservative and keeps raw frames covered.
      size_bytes = checked_product(0_u64, size_values, sizeof(UInt64).to_u64) || return nil
      scratch = checked_add(scratch, size_bytes) || return nil
      scratch = checked_add(scratch, size_bytes) || return nil
      # Every selected mark's nested size arrays are still live during
      # preflight. Level buffers are copied into the returned owner later.
      charge = materialization_charge(result_level_counts, result_point_count, schedule_charge, scratch) || return nil
      charge
    end

    private def checked_add(total : UInt64, amount : UInt64) : UInt64?
      return nil if amount > UInt64::MAX - total
      total + amount
    end

    private def checked_product(total : UInt64, count : UInt64, width : UInt64) : UInt64?
      return nil if width != 0_u64 && count > UInt64::MAX // width
      checked_add(total, count * width)
    end
  end
end
