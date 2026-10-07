module CrystalClick
  # Reads one complete Dynamic-bearing BinaryBulk column from a normalized
  # Object part. Structure sites are discovered parent-first from the actual
  # roster, then all data lanes are bound to the same root mark grid.
  class DynamicBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @source : PartStreamSource
    @plan : BinaryDynamicBulkPlan
    @physical : BinaryDynamicBulkPhysicalPlan
    @grids : Hash(String, CompressedMarkGrid)
    @structure_grids : Hash(String, CompressedMarkGrid)
    @structure_names : Hash(String, String)
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : DynamicBulkColumnReader
      new(part_path, column_name, expected_type, limits, transport_limits)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @type : BinaryDataType,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
    )
      # Bound recursive descriptor/name work before summary predicates,
      # metadata callbacks, or the recursive physical planner can traverse it.
      name_budget = BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      canonical_bytes = canonical.bytesize.to_u64
      name_budget.ensure_wire_bytes(canonical_bytes)
      name_budget.charge_wire_bytes(canonical_bytes)
      @schema_declaration = String.new(canonical.to_slice)

      unless @type.contains_dynamic?
        raise UnsupportedFormatError.new("Dynamic bulk reader requires a Dynamic-bearing descriptor")
      end
      if @type.contains_json?
        raise UnsupportedFormatError.new("JSON is outside the admitted Dynamic bulk profile")
      end
      unless column_name.bytesize > 0 && column_name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Dynamic bulk column name is outside the admitted range")
      end
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)

      metadata = ObjectColumnPartMetadata.open(
        @part_path,
        @column_name,
        ->(declaration : String) {
          unless declaration == canonical
            raise CorruptPartError.new("Dynamic source declaration differs from the expected nominal descriptor")
          end
          nil
        },
        subcolumns_validator: ->(subcolumns : Array(JSON::Any), row_count : UInt64) {
          DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
            subcolumns, @type, row_count, @limits
          )
        },
        require_selected_subcolumns: @type.tag == BinaryDataType::TAG_NAMED_TUPLE ||
                                     @type.tag == BinaryDataType::TAG_UNNAMED_TUPLE,
      )
      @source_declaration = metadata.source_declaration
      @ordinary_profile = metadata.ordinary_profile
      if metadata.row_count == 0_u64
        raise CorruptPartError.new("Dynamic bulk part must contain at least one parent row")
      end

      @source = PartStreamSource.new(@part_path)
      codec_budget = BinaryCodecBudget.new(@limits)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      resolver = BinaryDynamicBulkSiteNameResolver.new(@type, @column_name, @limits)
      @structure_grids = Hash(String, CompressedMarkGrid).new
      @structure_names = Hash(String, String).new
      @grids = Hash(String, CompressedMarkGrid).new
      structure_logical_bytes = 0_u64

      # The recursive plan requests precisely the currently admissible site;
      # an actual arm can reveal another Dynamic node, so this callback binds
      # only from parsed ancestor rosters and charges every materialization to
      # the same budgets used for the rest of this column read.
      loader = ->(site_path : String, structures : Hash(String, DynamicStructure), budget : BinaryCodecBudget) {
        logical_name = resolver.structure_stream_name(site_path, structures)
        hashed = StreamName.hash(logical_name)
        data_name = PhysicalStreamName.append_literal(hashed, ".bin")
        marks_name = PhysicalStreamName.append_literal(hashed, ".mrk2")
        grid = @source.inspect_grid(data_name, marks_name, nil, transport_budget)
        unless grid.logical_size >= 0
          raise CorruptPartError.new("Dynamic structure lane has a negative logical size")
        end
        logical_size = grid.logical_size.to_u64
        budget.ensure_wire_bytes(logical_size)
        if logical_size > UInt64::MAX - structure_logical_bytes
          raise CorruptPartError.new("Dynamic structure logical byte count overflows")
        end
        bytes = @source.read_all(data_name, transport_budget)
        unless bytes.size.to_u64 == logical_size
          raise CorruptPartError.new("Dynamic structure lane size changed after grid inspection")
        end
        structure_logical_bytes += logical_size
        @structure_grids[String.new(site_path.to_slice)] = grid
        @structure_names[String.new(site_path.to_slice)] = String.new(logical_name.to_slice)
        bytes
      }
      @plan = BinaryDynamicBulkPlan.decode_structure_streams_with_loader(
        @type, codec_budget, loader, @ordinary_profile
      )

      @physical = BinaryDynamicBulkPhysicalPlan.new(
        @plan, @column_name, @limits, PhysicalStreamPlanContext.new(@limits)
      )
      role_names = @physical.stream_names
      expected_stream_names = role_names.values.sort!
      actual_stream_names = metadata.selected_stream_names.sort!
      unless actual_stream_names == expected_stream_names
        raise CorruptPartError.new("Dynamic selected columns_substreams roster differs from the physical plan")
      end
      unless @physical.structure_stream_names.keys.sort! == @plan.structure_roles.sort!
        raise CorruptPartError.new("Dynamic structure roles differ from the parsed actual site roster")
      end

      root_rows = nil.as(Array(UInt64)?)
      logical_bytes = structure_logical_bytes
      data_roles = @physical.data_stream_names
      data_roles.keys.sort!.each do |role|
        prefix = @physical.prefix_size_for(role)
        grid = @source.inspect_grid(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true),
          prefix,
          transport_budget,
        )
        if current_rows = root_rows
          unless grid.rows_per_mark == current_rows
            raise CorruptPartError.new("Dynamic physical lanes disagree on the parent mark grid")
          end
        else
          root_rows = grid.rows_per_mark
        end
        logical_size = grid.logical_size.to_u64
        if logical_size > UInt64::MAX - logical_bytes
          raise CorruptPartError.new("Dynamic logical stream byte count overflows")
        end
        logical_bytes += logical_size
        @grids[String.new(role.to_slice)] = grid

        if discriminator_role?(role)
          window = @source.read_window(
            @physical.data_file_for(role, true),
            @physical.marks_file_for(role, true),
            0,
            0,
            prefix,
            transport_budget,
          )
          if dynamic_discriminator_role?(role)
            BinaryBulkDiscriminatorFramingAdapter.validate_header(role, window.bytes, prefix)
          else
            BinaryBulkPhysicalPrefixAdapter.preflight_read(
              [{role, prefix, 1}], codec_budget
            )
            BinaryBulkPhysicalPrefixAdapter.read_lane(
              role, window.bytes, window.offsets, prefix
            )
          end
        end
      end

      rows = root_rows || raise(CorruptPartError.new("Dynamic physical plan has no data lanes"))
      validate_row_grid!(rows, metadata.row_count)
      @plan.site_paths.each do |site_path|
        role = "#{site_path}.dynamic_structure"
        expected_name = @physical.structure_stream_names[role]?
        unless expected_name && @structure_names[site_path]? == expected_name
          raise CorruptPartError.new("Dynamic structure lane name differs from its parsed actual site")
        end
        grid = @structure_grids[site_path]? ||
               raise(CorruptPartError.new("Dynamic structure lane has no inspected mark grid"))
        offset = @plan.statistics_offset_for(site_path)
        unless grid.logical_size >= offset &&
               grid.prefix_size == offset && grid.mark_count == rows.size && grid.rows_per_mark == rows
          raise CorruptPartError.new("Dynamic structure lane differs from its statistics or parent grid")
        end
        grid.mark_count.times do |index|
          unless grid.position_at(index) == offset.to_i64
            raise CorruptPartError.new("Dynamic structure real marks do not point at the statistics offset")
          end
        end
        unless grid.position_at(grid.mark_count) == grid.logical_size
          raise CorruptPartError.new("Dynamic structure terminal mark does not point at EOF")
        end
      end

      @mark_row_counts = rows
      @row_count = metadata.row_count
      @mark_count = rows.size.to_i32
      @physical_stream_names = expected_stream_names
      @selected_checksum_names = checksum_names(role_names)
      @logical_read_bytes = logical_bytes
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def mark_row_counts : Array(UInt64)
      @mark_row_counts.dup
    end

    def physical_stream_names : Array(String)
      copy_strings(@physical_stream_names)
    end

    def selected_checksum_names : Array(String)
      copy_strings(@selected_checksum_names)
    end

    # Returns selected parent marks as recursive BinaryValues. If any actual
    # Dynamic arm contains LowCardinality, all lanes replay from mark zero so
    # even an empty end-window request validates off-window dictionary state.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = BinaryCodecBudget.new(@limits)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      traversal = BinaryCodecContext.new(@limits, nil, false, codec_budget, false, false)
      replay_complete = @plan.contains_low_cardinality?(@type, "root", traversal)
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? @mark_count : mark_count
      rows_for_decode = replay_complete ? @mark_row_counts : selected_rows(first_mark, mark_count)
      role_names = @physical.data_stream_names

      prefix_reads = [] of Tuple(String, Int32, Int32)
      role_names.keys.sort!.each do |role|
        prefix = @physical.prefix_size_for(role)
        next unless discriminator_role?(role)
        if read_count == Int32::MAX
          raise CorruptPartError.new("Dynamic discriminator coordinate count exceeds the supported domain")
        end
        prefix_reads << {role, prefix, read_count + 1}
      end
      BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

      streams_by_role = Hash(String, BinaryBulkStream).new(initial_capacity: role_names.size)
      role_names.keys.sort!.each do |role|
        grid = @grids[role]? || raise(CorruptPartError.new("Dynamic data role has no inspected parent grid"))
        prefix = @physical.prefix_size_for(role)
        window = @source.read_window(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true),
          read_first,
          read_count,
          prefix,
          transport_budget,
        )
        expected_rows = selected_rows(read_first, read_count)
        unless window.rows_per_mark == expected_rows && grid.mark_count == @mark_count
          raise CorruptPartError.new("Dynamic selected lane window differs from its inspected parent grid")
        end
        logical = if dynamic_discriminator_role?(role)
                    BinaryBulkDiscriminatorFramingAdapter.read_lane(
                      role, window.bytes, window.offsets, prefix, codec_budget
                    )
                  else
                    BinaryBulkPhysicalPrefixAdapter.read_lane(
                      role, window.bytes, window.offsets, prefix
                    )
                  end
        streams_by_role[role] = BinaryBulkStream.new(logical[0], logical[1])
      end

      stream_set = BinaryBulkStreams.new(read_count, streams_by_role)
      decoded = BinaryBulkDecoder.decode(
        @type,
        stream_set,
        rows_for_decode,
        codec_budget,
        replay_complete ? first_mark : 0,
        mark_count,
        @ordinary_profile,
        @plan,
      )
      unless decoded.size == mark_count
        raise CorruptPartError.new("Dynamic bulk decoder returned the wrong physical mark count")
      end
      decoded.each_with_index do |mark_values, index|
        unless mark_values.size.to_u64 == @mark_row_counts[first_mark + index]
          raise CorruptPartError.new("Dynamic bulk decoder returned the wrong parent row count")
        end
      end
      decoded
    end

    private def validate_row_grid!(rows : Array(UInt64), expected_total : UInt64) : Nil
      if rows.empty? || rows.size > WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("Dynamic physical mark count is outside the admitted range")
      end
      total = 0_u64
      rows.each do |count|
        if count > WidePart::MAX_ROWS.to_u64 - total
          raise CorruptPartError.new("Dynamic physical row count exceeds the part limit")
        end
        total += count
      end
      unless total == expected_total
        raise CorruptPartError.new("Dynamic parent mark grid differs from count.txt")
      end
    end

    private def discriminator_role?(role : String) : Bool
      role.ends_with?(".discriminators")
    end

    private def dynamic_discriminator_role?(role : String) : Bool
      suffix = ".discriminators"
      role.ends_with?(suffix) && @plan.has_site?(role[0, role.bytesize - suffix.bytesize])
    end

    private def checksum_names(role_names : Hash(String, String)) : Array(String)
      names = Array(String).new(role_names.size * 2)
      role_names.each_key do |role|
        names << @physical.data_file_for(role, true)
        names << @physical.marks_file_for(role, true)
      end
      names.sort!
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      total = @mark_count.to_i128
      if first < 0_i128 || first > total || count < 0_i128 || count > total - first
        raise ArgumentError.new("Dynamic selected mark range is outside the physical grid")
      end
      nil
    end

    private def selected_rows(first_mark : Int, count : Int) : Array(UInt64)
      Array(UInt64).new(count) { |index| @mark_row_counts[first_mark + index] }
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end
  end
end
