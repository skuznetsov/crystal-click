module CrystalClick
  # Immutable sparse discriminator counts for one selected absolute mark window.
  # Physical table rows remain distinct from each arm's window-local ranks.
  class WideGeometryMarkSchedule
    @first_mark : Int32
    @outer_rows : Array(UInt64)
    @tags_by_mark : Array(Array(UInt8))
    @arm_counts_by_mark : Array(StaticArray(UInt64, 7))

    def self.logical_charge_for_shape(rows_by_mark : Array(UInt64)) : UInt64?
      return nil if rows_by_mark.size > Int32::MAX

      total_rows = 0_u64
      rows_by_mark.each do |rows|
        return nil if rows > GeometryColumnType::MAX_LOGICAL_ELEMENTS
        return nil if rows > GeometryColumnType::MAX_LOGICAL_ELEMENTS - total_rows
        total_rows += rows
      end

      marks = rows_by_mark.size.to_u64
      charge = instance_sizeof(WideGeometryMarkSchedule).to_u64
      charge = checked_add(charge, instance_sizeof(Array(UInt64)).to_u64) || return nil
      charge = checked_product_add(charge, marks, sizeof(UInt64).to_u64) || return nil
      charge = checked_add(charge, instance_sizeof(Array(Array(UInt8))).to_u64) || return nil
      charge = checked_product_add(charge, marks, sizeof(Pointer(Array(UInt8))).to_u64) || return nil
      charge = checked_product_add(charge, marks, instance_sizeof(Array(UInt8)).to_u64) || return nil
      charge = checked_add(charge, total_rows) || return nil
      charge = checked_add(charge, instance_sizeof(Array(StaticArray(UInt64, 7))).to_u64) || return nil
      checked_product_add(charge, marks, sizeof(StaticArray(UInt64, 7)).to_u64)
    end

    def initialize(first_mark : Int32, rows_by_mark : Array(UInt64), tags_by_mark : Array(Array(UInt8)))
      raise ArgumentError.new("Geometry mark schedule origin is negative") if first_mark < 0
      raise ArgumentError.new("Geometry mark schedule rows and tags differ") unless rows_by_mark.size == tags_by_mark.size
      if rows_by_mark.size > Int32::MAX - first_mark
        raise ArgumentError.new("Geometry mark schedule absolute range exceeds native mark limits")
      end

      charge = self.class.logical_charge_for_shape(rows_by_mark) ||
               raise ArgumentError.new("Geometry mark schedule shape exceeds native limits")
      if charge > GeometryColumnType::MAX_MATERIALIZED_BYTES
        raise ArgumentError.new("Geometry mark schedule exceeds the 64 MiB limit")
      end

      counts = Array(StaticArray(UInt64, 7)).new(rows_by_mark.size) do |mark_offset|
        expected_rows = rows_by_mark[mark_offset]
        tags = tags_by_mark[mark_offset]
        unless tags.size.to_u64 == expected_rows
          raise ArgumentError.new("Geometry mark schedule tags differ from physical outer rows")
        end

        arm_counts = StaticArray(UInt64, 7).new(0_u64)
        tags.each do |tag|
          next if tag == 255_u8
          arm = WideGeometryArm.for_tag(tag) ||
                raise ArgumentError.new("Geometry mark schedule contains an invalid global arm tag")
          arm_counts[arm_index(arm)] += 1_u64
        end
        arm_counts
      end

      @first_mark = first_mark
      @outer_rows = rows_by_mark.dup
      @tags_by_mark = tags_by_mark.map(&.dup)
      @arm_counts_by_mark = counts
    end

    def first_mark : Int32
      @first_mark
    end

    def mark_count : Int32
      @outer_rows.size.to_i32
    end

    def outer_rows_at(mark_offset : Int) : UInt64
      @outer_rows[checked_mark_offset(mark_offset)]
    end

    def arm_count_at(mark_offset : Int, arm_index : Int) : UInt64
      @arm_counts_by_mark[checked_mark_offset(mark_offset)][checked_arm_index(arm_index)]
    end

    def arm_range_count(first_abs : Int, count : Int, arm_index : Int) : UInt64
      index = checked_arm_index(arm_index)
      first_offset = checked_absolute_range(first_abs, count)
      total = 0_u64
      count.times do |offset|
        amount = @arm_counts_by_mark[first_offset + offset][index]
        if amount > UInt64::MAX - total
          raise ArgumentError.new("Geometry mark schedule range count overflows")
        end
        total += amount
      end
      total
    end

    def tag_at(mark_offset : Int, row_offset : Int) : UInt8
      tags = @tags_by_mark[checked_mark_offset(mark_offset)]
      if row_offset < 0 || row_offset >= tags.size
        raise BoundsError.new("Geometry mark schedule row offset is out of bounds")
      end
      tags[row_offset]
    end

    def tags_for_mark(mark_offset : Int) : Array(UInt8)
      @tags_by_mark[checked_mark_offset(mark_offset)].dup
    end

    def flattened_tags : Array(UInt8)
      result = Array(UInt8).new(@outer_rows.sum(&.to_i))
      @tags_by_mark.each { |tags| result.concat(tags) }
      result
    end

    def logical_charge : UInt64
      self.class.logical_charge_for_shape(@outer_rows) ||
        raise ArgumentError.new("Geometry mark schedule charge overflows")
    end

    private def checked_mark_offset(mark_offset : Int) : Int32
      if mark_offset < 0 || mark_offset >= mark_count
        raise BoundsError.new("Geometry mark schedule offset is out of bounds")
      end
      mark_offset.to_i32
    end

    private def checked_absolute_range(first_abs : Int, count : Int) : Int32
      if count < 0 || first_abs < @first_mark
        raise BoundsError.new("Geometry absolute mark range is out of bounds")
      end
      offset = first_abs - @first_mark
      if offset > mark_count || count > mark_count - offset
        raise BoundsError.new("Geometry absolute mark range is out of bounds")
      end
      offset.to_i32
    end

    private def checked_arm_index(arm_index : Int) : Int32
      if arm_index < 0 || arm_index >= 7
        raise BoundsError.new("Geometry mark schedule arm index is out of bounds")
      end
      arm_index.to_i32
    end

    private def arm_index(arm : WideGeometryArm) : Int32
      case arm
      when WideGeometryArm::LineString      then 0
      when WideGeometryArm::MultiLineString then 1
      when WideGeometryArm::MultiPolygon    then 2
      when WideGeometryArm::Point           then 3
      when WideGeometryArm::Polygon         then 4
      when WideGeometryArm::Ring            then 5
      when WideGeometryArm::MultiPoint      then 6
      else
        raise ArgumentError.new("Geometry mark schedule arm is invalid")
      end
    end

    private def self.checked_add(total : UInt64, amount : UInt64) : UInt64?
      return nil if amount > UInt64::MAX - total
      total + amount
    end

    private def self.checked_product_add(total : UInt64, count : UInt64, width : UInt64) : UInt64?
      return nil if width != 0_u64 && count > UInt64::MAX // width
      checked_add(total, count * width)
    end
  end
end
