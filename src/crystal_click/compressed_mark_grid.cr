module CrystalClick
  # Detached description of a complete adaptive mark grid. The terminal point
  # is included in `positions`; `rows_per_mark` contains the K real outer rows.
  class CompressedMarkGrid
    getter mark_count : Int32
    getter prefix_size : Int32
    getter logical_size : Int64

    @positions : Array(Int64)
    @rows_per_mark : Array(UInt64)

    def initialize(
      positions : Array(Int64),
      rows_per_mark : Array(UInt64),
      prefix_size : Int,
      logical_size : Int64,
    )
      if prefix_size < 0 || prefix_size > Int32::MAX
        raise ArgumentError.new("prefix size exceeds supported in-memory domain")
      end
      if logical_size < 0
        raise ArgumentError.new("logical size must be nonnegative")
      end
      if rows_per_mark.size >= Int32::MAX || positions.size != rows_per_mark.size + 1
        raise ArgumentError.new("mark grid dimensions exceed supported in-memory domain")
      end
      unless positions.first? == prefix_size.to_i64 && positions.last? == logical_size
        raise ArgumentError.new("mark grid prefix or EOF does not match its logical positions")
      end

      previous = -1_i64
      positions.each do |position|
        if position < 0 || position < previous
          raise ArgumentError.new("mark grid positions must be nonnegative and monotone")
        end
        previous = position
      end
      rows_per_mark.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise ArgumentError.new("outer mark rows exceed the adaptive domain")
        end
      end

      @positions = positions.dup
      @rows_per_mark = rows_per_mark.dup
      @mark_count = rows_per_mark.size.to_i32
      @prefix_size = prefix_size.to_i32
      @logical_size = logical_size
    end

    def positions : Array(Int64)
      @positions.dup
    end

    def rows_per_mark : Array(UInt64)
      @rows_per_mark.dup
    end

    def position_at(index : Int) : Int64
      if index < 0 || index >= @positions.size
        raise ArgumentError.new("mark position index is outside the grid")
      end
      @positions[index]
    end

    def row_count_at(index : Int) : UInt64
      if index < 0 || index >= @rows_per_mark.size
        raise ArgumentError.new("mark row index is outside the grid")
      end
      @rows_per_mark[index]
    end
  end
end
