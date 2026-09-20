module CrystalClick
  # An owning, slab-backed sequence of UInt64 values.
  class UInt64SlabVector
    MIN_SHIFT                      =    4
    MAX_SHIFT                      =   20
    DEFAULT_SLAB_SHIFT             =   12
    DEFAULT_DIRECTORY_CAPACITY     = 1024
    MAX_INITIAL_DIRECTORY_CAPACITY = 1 << 20
    MAX_INT32                      = Int32::MAX.to_i64

    # A directory entry is immutable after the corresponding slab is full.
    private struct SlabRef
      getter pointer : Pointer(UInt64)
      getter finalized_used : Int32

      def initialize(@pointer : Pointer(UInt64), @finalized_used : Int32)
      end
    end

    @directory : Array(SlabRef)
    @slab_shift : Int32
    @slab_size : Int32
    @slab_mask : Int32
    @size : Int32
    @capacity : Int32
    @slab_count : Int32
    @directory_capacity : Int32
    @tail_pointer : Pointer(UInt64)
    @tail_used : Int32
    @tail_slab_index : Int32

    # The public counters are widened from their checked Int32 storage.
    def size : Int
      @size.to_i
    end

    def capacity : Int
      @capacity.to_i
    end

    def slab_count : Int
      @slab_count.to_i
    end

    def directory_capacity : Int
      @directory_capacity.to_i
    end

    def slab_shift : Int
      @slab_shift.to_i
    end

    def slab_size : Int
      @slab_size.to_i
    end

    def slab_mask : Int
      @slab_mask.to_i
    end

    def initialize(
      slab_shift : Int = DEFAULT_SLAB_SHIFT,
      initial_directory_capacity : Int = DEFAULT_DIRECTORY_CAPACITY,
    )
      unless slab_shift >= MIN_SHIFT && slab_shift <= MAX_SHIFT
        raise ArgumentError.new("slab_shift must be between #{MIN_SHIFT} and #{MAX_SHIFT}")
      end
      if initial_directory_capacity <= 0
        raise ArgumentError.new("initial_directory_capacity must be positive")
      end
      if initial_directory_capacity > MAX_INITIAL_DIRECTORY_CAPACITY
        raise ArgumentError.new("initial_directory_capacity is too large")
      end

      @slab_shift = slab_shift.to_i32
      @slab_size = (1_i32 << @slab_shift)
      @slab_mask = @slab_size - 1
      @directory_capacity = initial_directory_capacity.to_i32
      @directory = Array(SlabRef).new(initial_directory_capacity)
      @size = 0_i32
      @capacity = 0_i32
      @slab_count = 0_i32
      @tail_pointer = Pointer(UInt64).null
      @tail_used = 0_i32
      @tail_slab_index = -1_i32
    end

    # Appends one value and returns this vector.
    def push(value : UInt64) : self
      checked_size_after_append(1_i32)
      allocate_slab if @slab_count == 0 || @tail_used == @slab_size
      @tail_pointer[@tail_used] = value
      @tail_used = (@tail_used.to_i64 + 1).to_i32
      @size = (@size.to_i64 + 1).to_i32
      self
    end

    # Appends one value and returns this vector.
    def <<(value : UInt64) : self
      push(value)
    end

    # Appends all values from a borrowed slice using slab-sized bulk copies.
    def concat(values : Slice(UInt64)) : self
      count = values.size
      raise ArgumentError.new("slice size cannot be negative") if count < 0
      return self if count == 0

      new_size = checked_size_after_append(count)
      required_slab_count = slab_count_for_size(new_size)
      ensure_directory_capacity(required_slab_count)

      source_offset = 0_i32
      remaining = count
      while remaining > 0
        allocate_slab if @slab_count == 0 || @tail_used == @slab_size

        available = @slab_size - @tail_used
        copied = remaining < available ? remaining : available
        (@tail_pointer + @tail_used).move_from(values.to_unsafe + source_offset, copied)
        @tail_used = (@tail_used.to_i64 + copied).to_i32
        @size = (@size.to_i64 + copied).to_i32
        source_offset = (source_offset.to_i64 + copied).to_i32
        remaining -= copied
      end
      self
    end

    # Appends little-endian UInt64 values from a borrowed byte slice.
    #
    # The source is copied synchronously and is never retained. On a
    # little-endian system this copies raw bytes directly into the slab
    # storage, which also keeps source alignment irrelevant. A big-endian
    # system decodes each value explicitly instead.
    def concat_le_bytes(bytes : Bytes) : self
      byte_size = bytes.size
      raise ArgumentError.new("byte size cannot be negative") if byte_size < 0
      raise ArgumentError.new("byte size must be a multiple of 8") unless byte_size % 8 == 0
      return self if byte_size == 0

      count = byte_size // 8
      raise ArgumentError.new("append count exceeds Int32::MAX") if count > MAX_INT32
      new_size = checked_size_after_append(count.to_i32)
      required_slab_count = slab_count_for_size(new_size)
      ensure_directory_capacity(required_slab_count)

      source_offset = 0
      remaining = count
      while remaining > 0
        allocate_slab if @slab_count == 0 || @tail_used == @slab_size

        available = @slab_size - @tail_used
        copied = remaining < available ? remaining : available
        copied_bytes = copied * 8

        {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
          destination = (@tail_pointer + @tail_used).unsafe_as(Pointer(UInt8))
          destination.move_from(bytes.to_unsafe + source_offset, copied_bytes)
        {% else %}
          copied.times do |index|
            value = 0_u64
            8.times do |byte_index|
              value |= bytes[source_offset + index * 8 + byte_index].to_u64 << (byte_index * 8)
            end
            @tail_pointer[@tail_used + index] = value
          end
        {% end %}

        @tail_used = (@tail_used.to_i64 + copied).to_i32
        @size = (@size.to_i64 + copied).to_i32
        source_offset += copied_bytes
        remaining -= copied
      end
      self
    end

    # Returns a checked value at a zero-based logical index.
    def [](index : Int) : UInt64
      raise BoundsError.new("index out of bounds") if index < 0 || index >= @size

      slab_index = (index >> @slab_shift).to_i32
      offset = (index & @slab_mask).to_i32
      if slab_index == @tail_slab_index
        @tail_pointer[offset]
      else
        @directory[slab_index].pointer[offset]
      end
    end

    # Visits values in logical order, one slab-local pointer at a time.
    def each(& : UInt64 ->) : Nil
      completed_count = @slab_count - (@slab_count > 0 ? 1 : 0)
      slab_index = 0_i32
      while slab_index < completed_count
        descriptor = @directory[slab_index]
        offset = 0_i32
        while offset < descriptor.finalized_used
          yield descriptor.pointer[offset]
          offset += 1
        end
        slab_index += 1
      end

      if @slab_count > 0
        offset = 0_i32
        while offset < @tail_used
          yield @tail_pointer[offset]
          offset += 1
        end
      end
    end

    # Yields non-empty, read-only slab views valid only during each callback.
    # Callers must not retain or mutate a yielded slice, or mutate this vector
    # reentrantly while borrowing it.
    def each_chunk(& : Slice(UInt64) ->) : Nil
      completed_count = @slab_count - (@slab_count > 0 ? 1 : 0)
      slab_index = 0_i32
      while slab_index < completed_count
        descriptor = @directory[slab_index]
        if descriptor.finalized_used > 0
          yield Slice(UInt64).new(descriptor.pointer, descriptor.finalized_used, read_only: true)
        end
        slab_index += 1
      end

      if @tail_used > 0
        yield Slice(UInt64).new(@tail_pointer, @tail_used, read_only: true)
      end
    end

    # Returns an explicit owning copy of the values in this vector.
    def to_a : Array(UInt64)
      Array(UInt64).build(@size) do |buffer|
        offset = 0_i32
        each_chunk do |chunk|
          (buffer + offset).copy_from(chunk.to_unsafe, chunk.size)
          offset = (offset.to_i64 + chunk.size).to_i32
        end
        offset
      end
    end

    private def checked_size_after_append(count : Int32) : Int32
      raise ArgumentError.new("append count cannot be negative") if count < 0
      new_size = @size.to_i64 + count.to_i64
      raise ArgumentError.new("vector size exceeds Int32::MAX") if new_size > MAX_INT32
      new_size.to_i32
    end

    private def slab_count_for_size(size : Int32) : Int32
      raise ArgumentError.new("vector size cannot be negative") if size < 0
      count = (size.to_i64 + @slab_size.to_i64 - 1) // @slab_size.to_i64
      raise ArgumentError.new("slab count exceeds Int32::MAX") if count > MAX_INT32
      capacity = count * @slab_size.to_i64
      raise ArgumentError.new("vector capacity exceeds Int32::MAX") if capacity > MAX_INT32
      count.to_i32
    end

    private def ensure_directory_capacity(required : Int32)
      return if required <= @directory_capacity

      next_capacity = @directory_capacity.to_i64
      required_capacity = required.to_i64
      while next_capacity < required_capacity
        doubled = next_capacity * 2
        if doubled > MAX_INT32
          next_capacity = required_capacity
          break
        end
        next_capacity = doubled
      end

      rebuilt = Array(SlabRef).new(next_capacity.to_i)
      @directory.each { |descriptor| rebuilt << descriptor }
      @directory = rebuilt
      @directory_capacity = next_capacity.to_i32
    end

    private def allocate_slab
      next_slab_count = @slab_count.to_i64 + 1
      raise ArgumentError.new("slab count exceeds Int32::MAX") if next_slab_count > MAX_INT32
      next_capacity = next_slab_count * @slab_size.to_i64
      raise ArgumentError.new("vector capacity exceeds Int32::MAX") if next_capacity > MAX_INT32

      ensure_directory_capacity(next_slab_count.to_i32)

      if @slab_count > 0
        @directory[@tail_slab_index] = SlabRef.new(@tail_pointer, @tail_used)
      end

      pointer = Pointer(UInt64).malloc(@slab_size)
      @directory << SlabRef.new(pointer, 0_i32)
      @tail_pointer = pointer
      @tail_used = 0_i32
      @tail_slab_index = @slab_count
      @slab_count = next_slab_count.to_i32
      @capacity = next_capacity.to_i32
    end
  end
end
