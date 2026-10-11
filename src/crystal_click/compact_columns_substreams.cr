module CrystalClick
  # Detached physical roster for one Compact part. Mrk3 has one indivisible
  # callback slot per columns.txt entry; Mrk4 uses the exact flattened
  # columns_substreams.txt order.
  class CompactColumnsSubstreams
    getter mode : CompactMarkFormat

    @columns : Array({String, String})
    @slots : Array(CompactPhysicalSlot)
    @slots_by_column : Hash(String, Array(CompactPhysicalSlot))

    def initialize(
      @mode : CompactMarkFormat,
      columns : Array({String, String}),
      substreams : Array({String, Array(String)})? = nil,
    )
      validate_structure(columns, substreams)
      @columns = columns.map { |name, type| {String.new(name.to_slice), String.new(type.to_slice)} }
      @slots = [] of CompactPhysicalSlot
      @slots_by_column = Hash(String, Array(CompactPhysicalSlot)).new
      @columns.each do |name, _type|
        @slots_by_column[name] = [] of CompactPhysicalSlot
      end

      case @mode
      when CompactMarkFormat::Mrk3
        raise ArgumentError.new("mrk3 physical roster cannot contain substreams") if substreams
        @columns.each do |name, _type|
          append_slot(name, nil)
        end
      when CompactMarkFormat::Mrk4
        blocks = substreams || raise(CorruptPartError.new("columns_substreams.txt is required for mrk4"))
        unless blocks.size == @columns.size
          raise CorruptPartError.new("columns_substreams.txt column count differs from columns.txt")
        end
        blocks.each_with_index do |block, index|
          expected = @columns[index][0]
          unless block[0] == expected
            raise CorruptPartError.new("columns_substreams.txt order differs from columns.txt")
          end
          block[1].each { |stream_name| append_slot(block[0], stream_name) }
        end
      end
      raise CorruptPartError.new("Compact physical roster is empty") if @slots.empty?
    end

    def columns : Array({String, String})
      @columns.map { |name, type| {String.new(name.to_slice), String.new(type.to_slice)} }
    end

    def roster : Array(CompactPhysicalSlot)
      @slots.map(&.detached_copy)
    end

    def slots_for(column_name : String) : Array(CompactPhysicalSlot)
      slots = @slots_by_column[column_name]? || raise(ArgumentError.new("unknown Compact column"))
      slots.map(&.detached_copy)
    end

    def slot_count : Int32
      @slots.size.to_i32
    end

    # Internal physical binding check that avoids exposing mutable retained
    # String owners or allocating a full detached roster snapshot.
    def slot_matches?(index : Int, stream_name : String?) : Bool
      return false if index < 0
      if slot = @slots[index]?
        slot.stream_name == stream_name
      else
        false
      end
    end

    def slot_count_for(column_name : String) : Int32
      slots = @slots_by_column[column_name]? || raise(ArgumentError.new("unknown Compact column"))
      slots.size.to_i32
    end

    # Logical retained-owner census from the stored metadata, without creating
    # detached public snapshots. Capacities and allocator/RSS overhead are not
    # included.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactColumnsSubstreams).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array({String, String})).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@columns.size.to_u64, sizeof(Tuple(String, String)).to_u64),
      )
      @columns.each do |name, type|
        bytes = checked_add(bytes, string_owner_bytes(name))
        bytes = checked_add(bytes, string_owner_bytes(type))
      end

      bytes = checked_add(bytes, instance_sizeof(Array(CompactPhysicalSlot)).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@slots.size.to_u64, sizeof(Pointer(CompactPhysicalSlot)).to_u64),
      )
      @slots.each do |slot|
        bytes = checked_add(bytes, instance_sizeof(CompactPhysicalSlot).to_u64)
        bytes = checked_add(bytes, string_owner_bytes(slot.column_name))
        if stream_name = slot.stream_name
          bytes = checked_add(bytes, string_owner_bytes(stream_name))
        end
      end

      checked_add(bytes, retained_lookup_index_workspace_bytes)
    end

    # Separate subtotal for the retained column -> callback-slot lookup. Each
    # Hash entry is modeled as its two references plus a fixed control/hash
    # word; each per-column Array is charged by logical size, not capacity.
    def retained_lookup_index_workspace_bytes : UInt64
      bytes = instance_sizeof(Hash(String, Array(CompactPhysicalSlot))).to_u64
      hash_entry_bytes = checked_add(
        checked_add(sizeof(Pointer(String)).to_u64, sizeof(Pointer(Array(CompactPhysicalSlot))).to_u64),
        8_u64,
      )
      bytes = checked_add(bytes, checked_multiply(@columns.size.to_u64, hash_entry_bytes))
      @columns.each do |name, _type|
        slots = @slots_by_column[name]? || raise(CorruptPartError.new("Compact lookup index lost a column"))
        bytes = checked_add(bytes, instance_sizeof(Array(CompactPhysicalSlot)).to_u64)
        bytes = checked_add(
          bytes,
          checked_multiply(slots.size.to_u64, sizeof(Pointer(CompactPhysicalSlot)).to_u64),
        )
      end
      bytes
    end

    private def validate_structure(
      columns : Array({String, String}),
      substreams : Array({String, Array(String)})?,
    ) : Nil
      if columns.empty? || columns.size > WidePart::MAX_METADATA_COLUMNS
        raise CorruptPartError.new("Compact column roster is empty or exceeds its limit")
      end
      seen_columns = Set(String).new
      columns.each do |name, _type|
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES || seen_columns.includes?(name)
          raise CorruptPartError.new("Compact column roster contains an invalid or duplicate column")
        end
        seen_columns << name
      end

      case @mode
      when CompactMarkFormat::Mrk3
        raise ArgumentError.new("mrk3 physical roster cannot contain substreams") if substreams
      when CompactMarkFormat::Mrk4
        blocks = substreams || raise(CorruptPartError.new("columns_substreams.txt is required for mrk4"))
        unless blocks.size == columns.size
          raise CorruptPartError.new("columns_substreams.txt column count differs from columns.txt")
        end
        total_streams = 0
        blocks.each_with_index do |(column, streams), index|
          unless column == columns[index][0] && !streams.empty?
            raise CorruptPartError.new("columns_substreams.txt has an invalid or empty column block")
          end
          if streams.size > WidePart::MAX_METADATA_SUBSTREAMS - total_streams
            raise CorruptPartError.new("columns_substreams.txt exceeds substream limit")
          end
          total_streams += streams.size
          seen_streams = Set(String).new
          streams.each do |stream|
            if stream.empty? || stream.bytesize > WidePart::MAX_METADATA_LINE_BYTES || seen_streams.includes?(stream)
              raise CorruptPartError.new("columns_substreams.txt has an invalid or duplicate stream")
            end
            seen_streams << stream
          end
        end
        if total_streams == 0
          raise CorruptPartError.new("Compact physical roster is empty")
        end
      end
      nil
    end

    private def append_slot(column_name : String, stream_name : String?) : Nil
      if @slots.size >= Int32::MAX
        raise CorruptPartError.new("Compact physical roster exceeds supported in-memory domain")
      end
      slot = CompactPhysicalSlot.new(@slots.size.to_i32, column_name, stream_name)
      @slots << slot
      @slots_by_column[column_name] << slot
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact roster workspace estimate overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact roster workspace estimate overflows UInt64")
      end
      left * right
    end
  end
end
