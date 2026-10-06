module CrystalClick
  # Complete per-real-mark coordinates for one recursive child site. Physical
  # parent rows and logical child occurrences are intentionally independent;
  # the terminal record is implicit and is not stored here.
  class StorageOccurrenceGrid
    MAX_MARK_COUNT = Int32::MAX - 1

    @physical_rows : Array(UInt64)
    @logical_occurrences : Array(UInt64)

    def initialize(
      physical_rows : Array(UInt64),
      logical_occurrences : Array(UInt64),
      budget : BinaryCodecBudget,
    )
      mark_count = physical_rows.size
      unless logical_occurrences.size == mark_count
        raise ArgumentError.new("physical and logical occurrence grids must have the same mark count")
      end
      if mark_count > MAX_MARK_COUNT
        raise UnsupportedFormatError.new("storage occurrence mark grid exceeds the supported domain")
      end

      # Prove the complete retained grid fits before validating a late count or
      # allocating either detached array. The caller's aggregate budget owns
      # this work; the grid never creates a replacement budget.
      records = mark_count.to_u64 * 2_u64
      budget.ensure_future_nodes(records)
      budget.ensure_future_elements(records)

      mark_count.times do |index|
        physical = physical_rows[index]
        logical = logical_occurrences[index]
        unless physical > 0_u64 && physical <= Int32::MAX.to_u64
          raise ArgumentError.new("physical mark rows must be positive Int32 values")
        end
        if logical > Int32::MAX.to_u64
          raise ArgumentError.new("logical child occurrences exceed the Int32 domain")
        end
        budget.charge_node
        budget.charge_node
        budget.charge_elements(2_u64)
      end

      @physical_rows = Array(UInt64).new(mark_count)
      @logical_occurrences = Array(UInt64).new(mark_count)
      mark_count.times do |index|
        @physical_rows << physical_rows[index]
        @logical_occurrences << logical_occurrences[index]
      end
    end

    def mark_count : Int32
      @physical_rows.size
    end

    def physical_rows_at(mark_index : Int) : UInt64
      @physical_rows[mark_index]
    end

    def logical_occurrences_at(mark_index : Int) : UInt64
      @logical_occurrences[mark_index]
    end

    # Revalidates and charges a complete grid for each borrowed codec
    # operation, including operations whose selected window is empty.
    def validate_for!(expected_mark_count : Int, budget : BinaryCodecBudget) : Nil
      unless expected_mark_count == @physical_rows.size
        message = "storage occurrence grid does not match the child mark count"
        if budget.writing?
          raise UnsupportedFormatError.new(message)
        else
          raise CorruptPartError.new(message)
        end
      end

      records = @physical_rows.size.to_u64 * 2_u64
      budget.ensure_future_nodes(records)
      budget.ensure_future_elements(records)
      @physical_rows.size.times do |index|
        physical = @physical_rows[index]
        logical = @logical_occurrences[index]
        unless physical > 0_u64 && physical <= Int32::MAX.to_u64
          message = "physical mark rows are outside the supported domain"
          if budget.writing?
            raise UnsupportedFormatError.new(message)
          else
            raise CorruptPartError.new(message)
          end
        end
        if logical > Int32::MAX.to_u64
          message = "logical child occurrences are outside the supported domain"
          if budget.writing?
            raise UnsupportedFormatError.new(message)
          else
            raise CorruptPartError.new(message)
          end
        end
        budget.charge_node
        budget.charge_node
        budget.charge_elements(2_u64)
      end
      nil
    end
  end
end
