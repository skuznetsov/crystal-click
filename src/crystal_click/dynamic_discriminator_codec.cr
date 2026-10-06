module CrystalClick
  # Paired complete-stream encoder/decoder for the bounded Dynamic V3
  # discriminator profile. This owns decompressed bytes and normalized marks;
  # physical compressed frames and child lanes remain outside this codec.
  class DynamicDiscriminatorCodec
    DEFAULT_MODE   = 1_u64
    DEFAULT_LIMITS = BinaryCodecLimits.new(
      max_depth: 1,
      max_nodes: 1_000_000,
      max_elements: 3_000_000,
      max_bytes: 64 * 1024 * 1024
    )

    BASIC_MODE    =  0_u64
    COMPACT_MODE  =  1_u64
    NULL_TAG      = 255_u8
    HEADER_BYTES  =  8_u64
    MAX_MARK_ROWS = Int32::MAX.to_u64

    def self.encode(
      structure : DynamicStructure,
      tags : Array(Array(UInt8)),
      mode : UInt64 = DEFAULT_MODE,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    ) : DynamicDiscriminatorStream
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(structure, tags, budget, mode: mode)
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. It never resets or replaces the supplied budget.
    def self.encode_with_budget(
      structure : DynamicStructure,
      tags : Array(Array(UInt8)),
      budget : BinaryCodecBudget,
      mode : UInt64 = DEFAULT_MODE,
    ) : DynamicDiscriminatorStream
      encode_core_with_budget(structure, tags, budget, mode, nil)
    end

    # Child-site entry point. Empty groups are meaningful only with the
    # explicit physical/logical grid that owns their mark coordinates.
    def self.encode_child_site_with_budget(
      structure : DynamicStructure,
      tags : Array(Array(UInt8)),
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      mode : UInt64 = BASIC_MODE,
    ) : DynamicDiscriminatorStream
      encode_core_with_budget(structure, tags, budget, mode, grid)
    end

    private def self.encode_core_with_budget(
      structure : DynamicStructure,
      tags : Array(Array(UInt8)),
      budget : BinaryCodecBudget,
      mode : UInt64,
      occurrence_grid : StorageOccurrenceGrid?,
    ) : DynamicDiscriminatorStream
      unless budget.writing?
        raise ArgumentError.new("Dynamic discriminator encode requires a writing budget")
      end
      unless mode == BASIC_MODE || mode == COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end
      if grid = occurrence_grid
        grid.validate_for!(tags.size, budget)
      end

      budget.ensure_depth(1)
      real_marks = tags.size.to_u64
      mark_records = real_marks + 1_u64
      variant_count = structure.canonical_variant_count.to_u64

      minimum_nodes = 1_u64 + mark_records
      minimum_elements = mark_records + ((2_u64 * real_marks + 1_u64) * variant_count)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_elements)

      total_rows = 0_u64
      tags.each_with_index do |granule, mark_index|
        if granule.empty? && occurrence_grid.nil?
          raise ArgumentError.new("Dynamic discriminator real granules must contain rows")
        end
        if grid = occurrence_grid
          unless granule.size.to_u64 == grid.logical_occurrences_at(mark_index)
            raise UnsupportedFormatError.new("Dynamic discriminator child rows disagree with the occurrence grid")
          end
        end
        total_rows += granule.size.to_u64
      end

      total_nodes = 1_u64 + mark_records + total_rows
      total_elements = mark_records + (2_u64 * total_rows) + ((2_u64 * real_marks + 1_u64) * variant_count)
      budget.ensure_future_nodes(total_nodes)
      budget.ensure_future_elements(total_elements)

      body_bytes = 0_u64
      tags.each do |granule|
        first_tag = granule.first? || NULL_TAG
        uniform = true
        granule.each do |tag|
          unless valid_tag?(tag, variant_count)
            raise ArgumentError.new("Dynamic discriminator tag is outside the canonical roster")
          end
          uniform = false if tag != first_tag
        end

        bytes_for_granule = if mode == BASIC_MODE
                              granule.size.to_u64
                            elsif granule.empty?
                              0_u64
                            else
                              var_uint_size(granule.size.to_u64) + 1_u64 + (uniform ? 1_u64 : granule.size.to_u64)
                            end
        body_bytes += bytes_for_granule
      end

      output_bytes = HEADER_BYTES + body_bytes
      if output_bytes > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Dynamic discriminator output exceeds supported byte domain")
      end
      budget.ensure_wire_bytes(output_bytes)

      charge_work(budget, mark_records, total_rows, total_elements)
      budget.charge_wire_bytes(output_bytes)

      wire = Bytes.new(output_bytes.to_i32) { 0_u8 }
      wire[0] = mode.to_u8
      cursor = HEADER_BYTES.to_i32
      offset = HEADER_BYTES
      marks = Array(DynamicDiscriminatorMark).new(mark_records.to_i32)

      tags.each do |granule|
        marks << DynamicDiscriminatorMark.new(offset, granule.size.to_u64)
        first_tag = granule.first? || NULL_TAG
        uniform = true
        granule.each { |tag| uniform = false if tag != first_tag }

        if mode == BASIC_MODE
          granule.each do |tag|
            wire[cursor] = tag
            cursor += 1
          end
        elsif !granule.empty?
          cursor = write_var_uint(wire, cursor, granule.size.to_u64)
          if uniform
            wire[cursor] = 1_u8
            wire[cursor + 1] = first_tag
            cursor += 2
          else
            wire[cursor] = 0_u8
            cursor += 1
            granule.each do |tag|
              wire[cursor] = tag
              cursor += 1
            end
          end
        end
        offset = cursor.to_u64
      end
      marks << DynamicDiscriminatorMark.new(offset, 0_u64)

      DynamicDiscriminatorStream.new(wire, marks)
    end

    def self.decode(
      structure : DynamicStructure,
      stream : DynamicDiscriminatorStream,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    ) : Array(DynamicMarkSchedule)
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(structure, stream, budget, first_mark: first_mark, mark_count: mark_count)
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. All selected schedules are validated before return.
    def self.decode_with_budget(
      structure : DynamicStructure,
      stream : DynamicDiscriminatorStream,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
    ) : Array(DynamicMarkSchedule)
      decode_core_with_budget(structure, stream, budget, first_mark, mark_count, nil)
    end

    # Child-site decoder. The complete grid is structurally checked, including
    # marks outside the requested window and a zero-mark selection; tag values
    # remain selected-window scoped.
    def self.decode_child_site_with_budget(
      structure : DynamicStructure,
      stream : DynamicDiscriminatorStream,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
    ) : Array(DynamicMarkSchedule)
      decode_core_with_budget(structure, stream, budget, first_mark, mark_count, grid)
    end

    private def self.decode_core_with_budget(
      structure : DynamicStructure,
      stream : DynamicDiscriminatorStream,
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      occurrence_grid : StorageOccurrenceGrid?,
    ) : Array(DynamicMarkSchedule)
      if budget.writing?
        raise ArgumentError.new("Dynamic discriminator decode requires a reading budget")
      end
      budget.ensure_depth(1)

      mark_records = stream.mark_count.to_u64
      if mark_records == 0_u64
        corrupt!("Dynamic discriminator mark grid has no terminal mark")
      end
      real_marks = mark_records - 1_u64
      if grid = occurrence_grid
        grid.validate_for!(real_marks.to_i, budget)
      end
      selected_first = validate_selection(first_mark, mark_count, real_marks)
      selected_marks = if count = mark_count
                         count.to_u64
                       else
                         real_marks - selected_first
                       end
      variant_count = structure.canonical_variant_count.to_u64

      # This lower bound depends only on scalar collection sizes. It must run
      # before a mark traversal or any detached bytes/grid accessor.
      minimum_nodes = 1_u64 + mark_records
      minimum_elements = mark_records + ((2_u64 * selected_marks + 1_u64) * variant_count)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_elements)

      budget.ensure_wire_bytes(HEADER_BYTES)
      mode = DynamicDiscriminatorBodyValidator.read_mode(stream)

      all_compact_prefix_bytes = if grid = occurrence_grid
                                   mode == COMPACT_MODE ? compact_prefix_bytes_for(grid, 0_u64, grid.mark_count.to_u64) : 0_u64
                                 else
                                   0_u64
                                 end
      if all_compact_prefix_bytes > UInt64::MAX - HEADER_BYTES
        corrupt!("Dynamic COMPACT structural byte count overflows UInt64")
      end
      # Child COMPACT framing is structurally inspected across the whole grid,
      # including an empty selection. Reserve those small framing prefixes
      # before traversing bodies; payload bytes remain selected-window scoped.
      budget.ensure_wire_bytes(HEADER_BYTES + all_compact_prefix_bytes)

      selected_rows, first_row = if grid = occurrence_grid
                                   validate_occurrence_grid(stream, grid, selected_first, selected_marks, mode)
                                 else
                                   validate_grid(stream, real_marks, selected_first, selected_marks)
                                 end
      total_nodes = 1_u64 + mark_records + selected_rows
      total_elements = mark_records + (2_u64 * selected_rows) + ((2_u64 * selected_marks + 1_u64) * variant_count)
      budget.ensure_future_nodes(total_nodes)
      budget.ensure_future_elements(total_elements)

      selected_extent = if selected_marks == 0_u64
                          0_u64
                        else
                          first_offset = stream.mark_at(selected_first.to_i32).offset
                          after_offset = stream.mark_at((selected_first + selected_marks).to_i32).offset
                          after_offset - first_offset
                        end
      selected_wire_bytes = HEADER_BYTES + selected_extent
      if grid = occurrence_grid
        if mode == COMPACT_MODE
          selected_prefix_bytes = compact_prefix_bytes_for(grid, selected_first, selected_marks)
          unselected_prefix_bytes = all_compact_prefix_bytes - selected_prefix_bytes
          if selected_wire_bytes > UInt64::MAX - unselected_prefix_bytes
            corrupt!("Dynamic COMPACT selected byte count overflows UInt64")
          end
          selected_wire_bytes += unselected_prefix_bytes
        end
      end
      budget.ensure_wire_bytes(selected_wire_bytes)

      charge_work(budget, mark_records, selected_rows, total_elements)
      budget.charge_wire_bytes(selected_wire_bytes)

      schedules = Array(DynamicMarkSchedule).new(selected_marks.to_i32)
      running_offsets = Array(UInt64).new(variant_count.to_i32, 0_u64)
      selected_end = selected_first + selected_marks
      mark_index = selected_first
      selected_row_offset = 0_u64
      while mark_index < selected_end
        mark = stream.mark_at(mark_index.to_i32)
        following = stream.mark_at((mark_index + 1_u64).to_i32)
        body_offset = mark.offset.to_i32
        body_size = (following.offset - mark.offset).to_i32
        body = stream.borrowed_slice(body_offset, body_size)
        tags = decode_body(mode, body, mark.rows, variant_count)

        ranks = Array(Int32?).new(tags.size, nil)
        arm_counts = Array(UInt64).new(variant_count.to_i32, 0_u64)
        tags.each_with_index do |tag, row_index|
          next if tag == NULL_TAG
          arm_index = tag.to_i32
          ranks[row_index] = arm_counts[arm_index].to_i32
          arm_counts[arm_index] += 1_u64
        end

        schedules << DynamicMarkSchedule.new(
          mark_index.to_i32,
          first_row + selected_row_offset,
          tags,
          ranks,
          arm_counts,
          running_offsets
        )
        arm_counts.each_with_index do |count, arm_index|
          running_offsets[arm_index] += count
        end
        selected_row_offset += mark.rows
        mark_index += 1_u64
      end

      schedules
    end

    private def self.validate_selection(first_mark : Int, mark_count : Int?, real_marks : UInt64) : UInt64
      if first_mark < 0 || first_mark > real_marks.to_i64
        raise ArgumentError.new("Dynamic discriminator first mark is outside the real grid")
      end
      first = first_mark.to_u64
      if count = mark_count
        remaining_marks = (real_marks - first).to_i64
        if count < 0 || count > remaining_marks
          raise ArgumentError.new("Dynamic discriminator mark count is outside the real grid")
        end
      end
      first
    end

    private def self.compact_prefix_bytes_for(
      grid : StorageOccurrenceGrid,
      first_mark : UInt64,
      mark_count : UInt64,
    ) : UInt64
      selected_end = first_mark + mark_count
      total = 0_u64
      grid.mark_count.times do |mark_index|
        index = mark_index.to_u64
        next if index < first_mark || index >= selected_end
        rows = grid.logical_occurrences_at(mark_index).to_u64
        next if rows == 0_u64

        prefix = var_uint_size(rows) + 1_u64
        if total > UInt64::MAX - prefix
          corrupt!("Dynamic COMPACT structural byte count overflows UInt64")
        end
        total += prefix
      end
      total
    end

    private def self.validate_grid(
      stream : DynamicDiscriminatorStream,
      real_marks : UInt64,
      selected_first : UInt64,
      selected_marks : UInt64,
    ) : Tuple(UInt64, UInt64)
      byte_size = stream.byte_size.to_u64
      selected_end = selected_first + selected_marks
      total_rows = 0_u64
      selected_rows = 0_u64
      first_row = 0_u64
      previous_offset = HEADER_BYTES
      mark_index = 0_u64

      while mark_index <= real_marks
        mark = stream.mark_at(mark_index.to_i32)
        if mark_index == real_marks
          unless mark.rows == 0_u64 && mark.offset == byte_size
            corrupt!("Dynamic discriminator terminal mark does not match stream end")
          end
          if real_marks == 0_u64 && mark.offset != HEADER_BYTES
            corrupt!("empty Dynamic discriminator stream contains bytes after its header")
          end
          if real_marks > 0_u64 && mark.offset <= previous_offset
            corrupt!("Dynamic discriminator terminal mark has no positive byte extent")
          end
          if selected_first == real_marks
            first_row = total_rows
          end
          break
        end

        if mark.rows == 0_u64 || mark.rows > MAX_MARK_ROWS
          corrupt!("Dynamic discriminator real mark row count is outside its supported domain")
        end
        if mark_index == 0_u64
          unless mark.offset == HEADER_BYTES
            corrupt!("Dynamic discriminator first mark does not begin after its header")
          end
        elsif mark.offset <= previous_offset
          corrupt!("Dynamic discriminator marks are not strictly increasing")
        end

        if mark_index == selected_first
          first_row = total_rows
        end
        if mark_index >= selected_first && mark_index < selected_end
          selected_rows += mark.rows
        end
        total_rows += mark.rows
        previous_offset = mark.offset
        mark_index += 1_u64
      end

      {selected_rows, first_row}
    end

    private def self.validate_occurrence_grid(
      stream : DynamicDiscriminatorStream,
      grid : StorageOccurrenceGrid,
      selected_first : UInt64,
      selected_marks : UInt64,
      mode : UInt64,
    ) : Tuple(UInt64, UInt64)
      real_marks = grid.mark_count.to_u64
      unless stream.mark_count == grid.mark_count + 1
        corrupt!("child Dynamic discriminator grid does not have exactly one terminal mark")
      end

      byte_size = stream.byte_size.to_u64
      total_rows = 0_u64
      selected_rows = 0_u64
      first_row = 0_u64
      selected_end = selected_first + selected_marks
      previous_offset = HEADER_BYTES

      real_marks.to_i.times do |mark_index|
        mark = stream.mark_at(mark_index)
        following = stream.mark_at(mark_index + 1)
        expected_rows = grid.logical_occurrences_at(mark_index).to_u64

        if mark_index == 0
          unless mark.offset == HEADER_BYTES
            corrupt!("child Dynamic discriminator first mark does not begin after its header")
          end
        elsif mark.offset != previous_offset
          corrupt!("child Dynamic discriminator marks are not contiguous")
        end
        if mark.offset > byte_size || following.offset > byte_size || following.offset < mark.offset
          corrupt!("child Dynamic discriminator offsets are outside the byte domain")
        end
        unless mark.rows == expected_rows
          corrupt!("child Dynamic discriminator rows disagree with the occurrence grid")
        end
        body = stream.borrowed_slice(mark.offset.to_i32, (following.offset - mark.offset).to_i32)
        DynamicDiscriminatorBodyValidator.inspect_body(mode, body, expected_rows)

        if mark_index.to_u64 == selected_first
          first_row = total_rows
        end
        if mark_index.to_u64 >= selected_first && mark_index.to_u64 < selected_end
          selected_rows += expected_rows
        end
        total_rows += expected_rows
        previous_offset = following.offset
      end

      terminal = stream.mark_at(real_marks.to_i)
      unless terminal.rows == 0_u64 && terminal.offset == byte_size && terminal.offset == previous_offset
        corrupt!("child Dynamic discriminator terminal mark does not match stream end")
      end
      if real_marks == 0_u64 && terminal.offset != HEADER_BYTES
        corrupt!("empty child Dynamic discriminator stream contains bytes after its header")
      end
      if selected_first == real_marks
        first_row = total_rows
      end

      {selected_rows, first_row}
    end

    private def self.decode_body(mode : UInt64, body : Bytes, expected_rows : UInt64, variant_count : UInt64) : Array(UInt8)
      layout = DynamicDiscriminatorBodyValidator.inspect_body(mode, body, expected_rows)
      format, _offset = layout
      return [] of UInt8 if format == DynamicDiscriminatorBodyValidator::COMPACT_EMPTY

      tags = Array(UInt8).new(expected_rows.to_i32)
      expected_rows.to_i.times do |row_index|
        tag = DynamicDiscriminatorBodyValidator.tag_at(body, layout, row_index)
        unless valid_tag?(tag, variant_count)
          corrupt!("Dynamic discriminator tag is outside the canonical roster")
        end
        tags << tag
      end
      tags
    end

    private def self.write_var_uint(bytes : Bytes, cursor : Int32, original : UInt64) : Int32
      value = original
      loop do
        byte = (value & 0x7f_u64).to_u8
        value >>= 7
        byte |= 0x80_u8 if value > 0_u64
        bytes[cursor] = byte
        cursor += 1
        break if value == 0_u64
      end
      cursor
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      count = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        count += 1_u64
      end
      count
    end

    private def self.valid_tag?(tag : UInt8, variant_count : UInt64) : Bool
      tag == NULL_TAG || tag.to_u64 < variant_count
    end

    private def self.charge_work(
      budget : BinaryCodecBudget,
      mark_records : UInt64,
      rows : UInt64,
      elements : UInt64,
    ) : Nil
      budget.visit_node(1)
      index = 0_u64
      while index < mark_records + rows
        budget.charge_node
        index += 1_u64
      end
      budget.charge_elements(elements)
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
