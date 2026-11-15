module CrystalClick
  # Scan-local storage for Compact ordinary UInt64 marks. The typed allocation
  # is a single aligned high-water slab; its per-column ranges remain live
  # until the current callback batch has been acknowledged.
  class CompactUInt64ScanWorkspace
    getter transport_workspace : CompressedBlock::DecodeWorkspace

    @values : Slice(UInt64)

    def initialize
      @values = Slice(UInt64).new(0)
      @transport_workspace = CompressedBlock::DecodeWorkspace.new
    end

    def retained_header_bytes : UInt64
      instance_sizeof(CompactUInt64ScanWorkspace).to_u64 +
        instance_sizeof(CompressedBlock::DecodeWorkspace).to_u64
    end

    def retained_slab_bytes : UInt64
      @values.size.to_u64 * sizeof(UInt64).to_u64
    end

    # Keep the current high-water allocation when it fits. If the current mark
    # is smaller and the retained capacity would exceed its materialization
    # allowance, the caller may plan an exact-size replacement instead.
    def planned_capacity_values(required_values : UInt64, available_bytes : UInt64) : UInt64?
      if required_values > Int32::MAX.to_u64
        return nil
      end
      required_bytes = required_values * sizeof(UInt64).to_u64
      return nil if required_bytes > available_bytes

      current_values = @values.size.to_u64
      current_bytes = retained_slab_bytes
      if current_bytes <= available_bytes && current_values >= required_values
        current_values
      else
        required_values
      end
    end

    # Capacity is planned and charged by the caller before this allocation.
    def prepare_capacity!(values : UInt64) : Nil
      if values > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact UInt64 scan slab exceeds its in-memory bound")
      end
      size = values.to_i
      if @values.size != size
        # No callback can still borrow the previous mark here. Drop the
        # high-water owner before asking Boehm for a replacement allocation.
        @values = Slice(UInt64).new(0)
        @values = Slice(UInt64).new(size)
      end
      nil
    end

    def release_slab! : Nil
      @values = Slice(UInt64).new(0)
      nil
    end

    def values_for(rows : UInt64, slot_index : Int, slot_count : Int) : Slice(UInt64)
      if rows == 0_u64 || rows > Int32::MAX.to_u64 || slot_count <= 0 ||
         slot_index < 0 || slot_index >= slot_count
        raise CorruptPartError.new("Compact UInt64 scan slab selection is invalid")
      end
      required_values = rows * slot_count.to_u64
      unless required_values <= @values.size.to_u64
        raise CorruptPartError.new("Compact UInt64 scan slab was not prepared for this mark")
      end
      offset = rows.to_i * slot_index
      Slice(UInt64).new(@values.to_unsafe + offset, rows.to_i)
    end
  end
end
