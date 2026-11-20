module CrystalClick
  # Detached caller-owned buffers for the three exact per-chunk Copy lanes.
  class ObjectSharedCopyStreams
    @sizes : Bytes
    @indexes : Bytes
    @values : Bytes

    def initialize(sizes : Bytes, indexes : Bytes, values : Bytes)
      @sizes = Bytes.new(sizes.size) { |index| sizes[index] }
      @indexes = Bytes.new(indexes.size) { |index| indexes[index] }
      @values = Bytes.new(values.size) { |index| values[index] }
    end

    def sizes : Bytes
      Bytes.new(@sizes.size) { |index| @sizes[index] }
    end

    def indexes : Bytes
      Bytes.new(@indexes.size) { |index| @indexes[index] }
    end

    def values : Bytes
      Bytes.new(@values.size) { |index| @values[index] }
    end

    # Non-allocating extents let enclosing owners preflight detached lane
    # snapshots before requesting the public byte getters. The Copy decoder
    # remains responsible for the single wire-byte charge.
    def sizes_size : Int32
      @sizes.size
    end

    def indexes_size : Int32
      @indexes.size
    end

    def values_size : Int32
      @values.size
    end

    # :nodoc:
    # Keep the owned, defensive lane snapshots inside this trusted reader
    # boundary. Public lane getters remain detached for legacy callers.
    def decode_into_columns_with_budget(
      bucket_structures : Array(ObjectSharedChunkStructure),
      columns_by_index : Array(CompactJsonColumnarColumn),
      output : CompactJsonColumnarBatch,
      row_offset : Int32,
      budget : BinaryCodecBudget,
    ) : UInt64
      ObjectSharedCopyCodec.decode_into_columns_with_budget(
        Bytes.new(@sizes.to_unsafe, @sizes.size, read_only: true),
        Bytes.new(@indexes.to_unsafe, @indexes.size, read_only: true),
        Bytes.new(@values.to_unsafe, @values.size, read_only: true),
        bucket_structures,
        columns_by_index,
        output,
        row_offset,
        budget,
        borrow_string_slices: true,
      )
    end

    # :nodoc:
    # Build bounded payload references without exposing mutable backing lanes.
    def decode_selected_references_with_budget(
      bucket_structures : Array(ObjectSharedChunkStructure),
      output : CompactJsonColumnarBatch,
      row_offset : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      ObjectSharedCopyCodec.decode_selected_references_with_budget(
        Bytes.new(@sizes.to_unsafe, @sizes.size, read_only: true),
        Bytes.new(@indexes.to_unsafe, @indexes.size, read_only: true),
        Bytes.new(@values.to_unsafe, @values.size, read_only: true),
        bucket_structures,
        output,
        row_offset,
        budget,
      )
    end

    # :nodoc:
    # Borrow one immutable values owner for a reusable cursor. The reference
    # ledger guarantees every later window is inside this exact byte lane.
    def selected_values_view : Bytes
      Bytes.new(@values.to_unsafe, @values.size, read_only: true)
    end
  end
end
