module CrystalClick
  # Detached logical projection of a complete Compact mark grid. Coordinates
  # retain global mark-slot order, including equal values for empty callbacks.
  class CompactMarkIndex
    getter mark_count : Int32
    getter slot_count : Int32

    @positions : Array(Int64)
    @rows : Array(UInt64)

    private def initialize(
      @mark_count : Int32,
      @slot_count : Int32,
      @positions : Array(Int64),
      @rows : Array(UInt64),
    )
    end

    def self.read(
      input : PartPhysicalInput,
      roster : CompactColumnsSubstreams,
      expected_row_count : UInt64,
      budget : CompressedStreamBudget,
    ) : CompactMarkIndex
      budget.ensure_direction(false)
      limits = budget.limits
      data_size = input.data_size
      marks_size = input.marks_size
      if data_size <= 0 || data_size > Int32::MAX || data_size > limits.max_file_bytes
        raise UnsupportedFormatError.new("zero-domain or oversized Compact data files are unsupported")
      end
      if marks_size <= 0 || marks_size > Int32::MAX || marks_size > limits.max_mark_bytes
        raise CorruptPartError.new("Compact mark file size is outside its supported bound")
      end
      if data_size > Int64::MAX - marks_size
        raise CorruptPartError.new("Compact paired file sizes overflow")
      end

      slot_count = roster.slot_count
      record_width = slot_count.to_i64 * 16_i64 + 8_i64
      if record_width <= 0 || record_width > Int32::MAX
        raise CorruptPartError.new("Compact mark record width exceeds supported in-memory domain")
      end
      record_count = marks_size % record_width == 0 ? marks_size // record_width : 0_i64
      if record_count > Int32::MAX
        raise CorruptPartError.new("Compact mark grid exceeds supported in-memory domain")
      end
      if record_count > 0
        fields_per_record = slot_count.to_i64 * 2_i64 + 1_i64
        if record_count > Int64::MAX // fields_per_record
          raise CorruptPartError.new("Compact mark coordinate count overflows")
        end
        budget.reserve_records(record_count * fields_per_record)
      end
      budget.reserve_file_bytes(data_size + marks_size)
      preflight_regular_file(input.marks_path, marks_size, "Compact mark file")
      preflight_regular_file(input.data_path, data_size, "Compact data file")

      result = nil.as(CompactMarkIndex?)
      MMapDataSource.with_file(input.marks_path, marks_size, limits.max_mark_bytes) do |mark_bytes|
        CompressedMarkReader.validate_plain_marks!(mark_bytes, record_width.to_i, budget, record_count)
        actual_count = mark_bytes.size.to_i64 // record_width
        if actual_count < 2 || actual_count > Int32::MAX
          raise CorruptPartError.new("Compact mark grid must contain real marks and an explicit terminal record")
        end
        if actual_count != record_count
          raise CorruptPartError.new("Compact mark record count changed")
        end

        coordinate_count = actual_count * slot_count.to_i64
        if coordinate_count > Int32::MAX
          raise CorruptPartError.new("Compact coordinate grid exceeds supported in-memory domain")
        end
        positions = Array(Int64).new(coordinate_count.to_i)
        rows = Array(UInt64).new((actual_count - 1).to_i)
        terminal_mark = actual_count - 1
        row_sum = 0_u64

        MMapDataSource.with_file(input.data_path, data_size, limits.max_file_bytes) do |data|
          frame_index = CompressedFrameIndex.new(data, limits, budget)
          actual_count.to_i.times do |mark_index|
            mark_offset = mark_index.to_i64 * record_width
            slot_count.times do |slot_index|
              coordinate_offset = mark_offset + slot_index.to_i64 * 16_i64
              compressed_offset = read_u64(mark_bytes, coordinate_offset.to_i)
              decompressed_offset = read_u64(mark_bytes, (coordinate_offset + 8_i64).to_i)
              terminal = mark_index.to_i64 == terminal_mark
              if terminal && (compressed_offset != data_size.to_u64 || decompressed_offset != 0_u64)
                raise CorruptPartError.new("Compact terminal coordinates must name physical EOF")
              end
              logical = frame_index.logical_position(compressed_offset, decompressed_offset, terminal)
              positions << logical
            end

            row_count = read_u64(mark_bytes, (mark_offset + slot_count.to_i64 * 16_i64).to_i)
            if mark_index.to_i64 == terminal_mark
              raise CorruptPartError.new("Compact terminal mark rows must be zero") unless row_count == 0_u64
            else
              if row_count == 0_u64 || row_count > Int32::MAX.to_u64
                raise CorruptPartError.new("Compact mark rows are outside the adaptive domain")
              end
              if row_count > UInt64::MAX - row_sum
                raise CorruptPartError.new("Compact mark row total overflows")
              end
              row_sum += row_count
              rows << row_count
            end
          end

          first_position = positions.first? || raise(CorruptPartError.new("Compact mark grid has no first coordinate"))
          raise CorruptPartError.new("first Compact mark slot must name logical offset zero") unless first_position == 0_i64
          previous = -1_i64
          positions.each do |position|
            if position < previous
              raise CorruptPartError.new("Compact mark coordinates are not monotone")
            end
            previous = position
          end
          logical_eof = frame_index.logical_size
          unless positions.last? == logical_eof
            raise CorruptPartError.new("terminal Compact mark does not name logical EOF")
          end
          unless row_sum == expected_row_count
            raise CorruptPartError.new("Compact mark rows do not sum to count.txt")
          end
          result = new((actual_count - 1).to_i32, slot_count, positions, rows)
        end
      end
      result.not_nil!
    end

    def position_at(mark_index : Int, slot_index : Int) : Int64
      validate_mark_index(mark_index, true)
      validate_slot_index(slot_index)
      @positions[mark_index * @slot_count + slot_index]
    end

    def row_count_at(mark_index : Int) : UInt64
      validate_mark_index(mark_index, false)
      @rows[mark_index]
    end

    private def validate_mark_index(mark_index : Int, include_terminal : Bool) : Nil
      upper = include_terminal ? @mark_count : @mark_count - 1
      if mark_index < 0 || mark_index > upper
        raise ArgumentError.new("Compact mark index is outside the grid")
      end
    end

    private def validate_slot_index(slot_index : Int) : Nil
      if slot_index < 0 || slot_index >= @slot_count
        raise ArgumentError.new("Compact slot index is outside the roster")
      end
    end

    private def self.read_u64(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("truncated Compact mark coordinate")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.preflight_regular_file(path : String, expected_size : Int64, label : String) : Nil
      info = File.info?(path, follow_symlinks: false) || raise(CorruptPartError.new("#{label} is missing or inaccessible"))
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
      raise CorruptPartError.new("#{label} is not a regular file") unless info.type.file?
      raise CorruptPartError.new("#{label} size does not match its physical input") unless info.size == expected_size
      nil
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect #{label}")
    end
  end
end
