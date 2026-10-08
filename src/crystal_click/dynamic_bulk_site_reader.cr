module CrystalClick
  # Reusable owner for one Dynamic-bearing BinaryBulk site inside a larger
  # physical column. It discovers that site's actual structures parent-first,
  # binds its lanes to the caller's P mark grid, and decodes values on the
  # caller's Q occurrence grid. Metadata admission stays with the outer
  # schema-bound column reader.
  class DynamicBulkSiteReader
    getter plan : BinaryDynamicBulkPlan
    getter physical : BinaryDynamicBulkPhysicalPlan
    getter row_count : UInt64
    getter mark_count : Int32
    getter logical_read_bytes : UInt64

    @source : PartStreamSource
    @site_key : String
    @type : BinaryDataType
    @prefix : String
    @initial_array_level : UInt64
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @ordinary_profile : BinaryBulkProfile
    @name_context : PhysicalStreamPlanContext
    @initial_descriptor_depth : Int32
    @site_grid : StorageOccurrenceGrid
    @mark_row_counts : Array(UInt64)
    @grids : Hash(String, CompressedMarkGrid)
    @structure_grids : Hash(String, CompressedMarkGrid)
    @structure_names : Hash(String, String)
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)

    def self.open(
      source : PartStreamSource,
      type : BinaryDataType,
      escaped_prefix : String,
      initial_array_level : UInt64,
      ordinary_profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      expected_parent_rows : Array(UInt64)? = nil,
      site_grid : StorageOccurrenceGrid? = nil,
      expected_total_rows : UInt64? = nil,
      name_context : PhysicalStreamPlanContext? = nil,
      initial_descriptor_depth : Int32 = 1,
      site_key : String = "root",
    ) : DynamicBulkSiteReader
      new(
        source, type, escaped_prefix, initial_array_level, ordinary_profile,
        limits, transport_limits, codec_budget, transport_budget,
        expected_parent_rows, site_grid, expected_total_rows,
        name_context, initial_descriptor_depth, site_key
      )
    end

    private def initialize(
      @source : PartStreamSource,
      @type : BinaryDataType,
      escaped_prefix : String,
      @initial_array_level : UInt64,
      @ordinary_profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      expected_parent_rows : Array(UInt64)?,
      inherited_grid : StorageOccurrenceGrid?,
      expected_total_rows : UInt64?,
      name_context : PhysicalStreamPlanContext?,
      @initial_descriptor_depth : Int32,
      site_key : String,
    )
      if site_key.empty?
        raise ArgumentError.new("Dynamic site reader key must be nonempty")
      end
      @site_key = String.new(site_key.to_slice)
      unless codec_budget.limits.max_depth == @limits.max_depth &&
             codec_budget.limits.max_nodes == @limits.max_nodes &&
             codec_budget.limits.max_elements == @limits.max_elements &&
             codec_budget.limits.max_bytes == @limits.max_bytes
        raise ArgumentError.new("Dynamic site reader codec budget differs from its limits")
      end
      unless !codec_budget.writing? && !transport_budget.writing? &&
             transport_budget.limits.max_file_bytes == @transport_limits.max_file_bytes &&
             transport_budget.limits.max_mark_bytes == @transport_limits.max_mark_bytes &&
             transport_budget.limits.max_frame_compressed_bytes == @transport_limits.max_frame_compressed_bytes &&
             transport_budget.limits.max_frame_decompressed_bytes == @transport_limits.max_frame_decompressed_bytes &&
             transport_budget.limits.max_records == @transport_limits.max_records &&
             transport_budget.limits.max_decoded_bytes == @transport_limits.max_decoded_bytes &&
             transport_budget.limits.max_result_bytes == @transport_limits.max_result_bytes
        raise ArgumentError.new("Dynamic site reader transport budget differs from its limits")
      end
      if codec_budget.writing?
        raise ArgumentError.new("Dynamic site discovery requires a read-direction codec budget")
      end
      if @initial_array_level > UInt64::MAX - @limits.max_depth.to_u64
        raise ArgumentError.new("Dynamic site initial Array level overflows the name coordinate")
      end
      unless @initial_descriptor_depth > 0 && @initial_descriptor_depth <= @limits.max_depth
        raise CorruptPartError.new("Dynamic site inherited descriptor depth exceeds the configured limit")
      end
      @name_context = name_context || PhysicalStreamPlanContext.new(@limits)
      unless @name_context.limits.max_depth == @limits.max_depth &&
             @name_context.limits.max_nodes == @limits.max_nodes &&
             @name_context.limits.max_elements == @limits.max_elements &&
             @name_context.limits.max_bytes == @limits.max_bytes
        raise ArgumentError.new("Dynamic site reader physical context differs from its limits")
      end

      # Resolver construction performs the shared, inherited-depth descriptor
      # preflight before this public entry point uses recursive descriptor
      # predicates or retains its own prefix copy.
      resolver = BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
        @type, escaped_prefix, @initial_array_level, @limits,
        codec_budget, @name_context, @initial_descriptor_depth
      )
      @name_context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      @name_context.charge_name_bytes(escaped_prefix.bytesize.to_u64)
      @prefix = String.new(escaped_prefix.to_slice)
      unless @type.contains_dynamic?
        raise UnsupportedFormatError.new("Dynamic site reader requires a Dynamic-bearing descriptor")
      end
      if @type.contains_json?
        raise UnsupportedFormatError.new("JSON is outside the admitted Dynamic site profile")
      end
      @structure_grids = Hash(String, CompressedMarkGrid).new
      @structure_names = Hash(String, String).new
      @grids = Hash(String, CompressedMarkGrid).new
      structure_logical_bytes = 0_u64
      json_metadata_logical_bytes = 0_u64
      json_coordinates = Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectSiteCoordinates).new

      # A requested Dynamic site may expose another site through its parsed
      # actual roster. Resolve only from ancestor structures already loaded.
      loader = ->(site_path : String, structures : Hash(String, DynamicStructure), budget : BinaryCodecBudget) {
        logical_name = resolver.structure_stream_name(site_path, structures)
        hashed = StreamName.hash(logical_name)
        data_name = PhysicalStreamName.append_literal(hashed, ".bin")
        marks_name = PhysicalStreamName.append_literal(hashed, ".mrk2")
        grid = @source.inspect_grid(data_name, marks_name, nil, transport_budget)
        logical_size = grid.logical_size.to_u64
        budget.ensure_wire_bytes(logical_size)
        if logical_size > UInt64::MAX - structure_logical_bytes
          raise CorruptPartError.new("Dynamic site structure byte count overflows")
        end
        bytes = @source.read_all(data_name, transport_budget)
        unless bytes.size.to_u64 == logical_size
          raise CorruptPartError.new("Dynamic site structure changed after grid inspection")
        end
        structure_logical_bytes += logical_size
        @structure_grids[String.new(site_path.to_slice)] = grid
        @structure_names[String.new(site_path.to_slice)] = String.new(logical_name.to_slice)
        bytes
      }
      json_object_leaf_plan_loader = ->(key : BinaryDynamicJsonLeafKey, json_descriptor_depth : Int32, structure : DynamicStructure, structures : Hash(String, DynamicStructure), budget : BinaryCodecBudget) {
        coordinates = resolver.json_object_leaf_site(key, structures)
        json_descriptor = coordinates.json_type.json_type ||
                          raise(CorruptPartError.new("Dynamic JSON leaf has no persisted descriptor"))
        typed_schema = copy_json_typed_schema(json_descriptor, budget)
        descriptor = ObjectDocumentFileReader.inspect_at_site(
          @source,
          coordinates.escaped_prefix,
          typed_schema,
          budget,
          @name_context,
          transport_budget,
          @ordinary_profile,
          BinaryBulkProfile.single_stream,
          true,
          coordinates.array_level,
          nil,
          json_descriptor_depth + 1,
        )
        if descriptor.logical_read_bytes > UInt64::MAX - json_metadata_logical_bytes
          raise CorruptPartError.new("Dynamic JSON Object metadata byte count overflows")
        end
        json_metadata_logical_bytes += descriptor.logical_read_bytes
        if json_coordinates.has_key?(key)
          raise CorruptPartError.new("Dynamic JSON Object leaf coordinates are duplicated")
        end
        key_bytes = key.dynamic_site_bytesize.to_u64 + key.descriptor_path_size.to_u64 * 4_u64
        budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
        budget.charge_node
        json_coordinates[key] = coordinates
        descriptor.plan
      }
      @plan = BinaryDynamicBulkPlan.decode_structure_streams_with_loader(
        @type, codec_budget, loader, @ordinary_profile, @initial_descriptor_depth,
        resolver.descriptor_preflight, nil, json_object_leaf_plan_loader
      )
      unless @plan.type == @type && @plan.profile == @ordinary_profile
        raise CorruptPartError.new("Dynamic site structures differ from the declared site descriptor")
      end

      @physical = BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(
        @plan,
        @prefix,
        @limits,
        @name_context,
        @initial_array_level,
      )
      physical_json_sites = @physical.json_object_sites
      unless physical_json_sites.size == json_coordinates.size
        raise CorruptPartError.new("Dynamic JSON Object physical sites differ from discovered bindings")
      end
      physical_json_sites.each do |site|
        coordinates = json_coordinates[site.leaf_key]? ||
                      raise(CorruptPartError.new("Dynamic JSON Object physical leaf has no discovered coordinates"))
        unless site.escaped_prefix == coordinates.escaped_prefix &&
               site.array_level == coordinates.array_level &&
               site.binding.leaf_key == site.leaf_key &&
               site.binding.json_type == coordinates.json_type
          raise CorruptPartError.new("Dynamic JSON Object physical coordinates changed after discovery")
        end
      end
      role_names = @physical.stream_names
      unless @physical.structure_stream_names.keys.sort! == @plan.structure_roles.sort!
        raise CorruptPartError.new("Dynamic site structure roles differ from the parsed actual roster")
      end

      rows = expected_parent_rows
      logical_bytes = structure_logical_bytes
      if json_metadata_logical_bytes > UInt64::MAX - logical_bytes
        raise CorruptPartError.new("Dynamic JSON Object metadata byte count overflows")
      end
      logical_bytes += json_metadata_logical_bytes
      data_roles = @physical.data_stream_names
      data_roles.keys.sort!.each do |role|
        prefix_size = @physical.prefix_size_for(role)
        grid = @source.inspect_grid(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true),
          prefix_size,
          transport_budget,
        )
        if current_rows = rows
          unless grid.rows_per_mark == current_rows
            raise CorruptPartError.new("Dynamic site lanes differ from the inherited physical mark grid")
          end
        else
          rows = grid.rows_per_mark
        end
        logical_size = grid.logical_size.to_u64
        if logical_size > UInt64::MAX - logical_bytes
          raise CorruptPartError.new("Dynamic site logical stream byte count overflows")
        end
        logical_bytes += logical_size
        @grids[String.new(role.to_slice)] = grid

        if discriminator_role?(role)
          window = @source.read_window(
            @physical.data_file_for(role, true),
            @physical.marks_file_for(role, true),
            0,
            0,
            prefix_size,
            transport_budget,
          )
          if dynamic_discriminator_role?(role)
            BinaryBulkDiscriminatorFramingAdapter.validate_header(role, window.bytes, prefix_size)
          else
            BinaryBulkPhysicalPrefixAdapter.preflight_read(
              [{role, prefix_size, 1}], codec_budget
            )
            BinaryBulkPhysicalPrefixAdapter.read_lane(
              role, window.bytes, window.offsets, prefix_size
            )
          end
        end
      end

      actual_rows = rows || raise(CorruptPartError.new("Dynamic site plan has no data lanes"))
      validate_row_grid!(actual_rows, expected_total_rows)
      @mark_row_counts = detached_rows(actual_rows, codec_budget)
      @mark_count = @mark_row_counts.size.to_i32
      @row_count = @mark_row_counts.sum(0_u64)
      if inherited = inherited_grid
        inherited.validate_for!(@mark_count, codec_budget)
        @site_grid = inherited
        @mark_count.times do |mark|
          unless inherited.physical_rows_at(mark) == @mark_row_counts[mark]
            raise CorruptPartError.new("Dynamic site P grid differs from its inherited occurrence grid")
          end
        end
      else
        unless expected_parent_rows.nil?
          raise ArgumentError.new("Dynamic site reader requires a grid for an inherited Q schedule")
        end
        @site_grid = StorageOccurrenceGrid.new(@mark_row_counts, @mark_row_counts, codec_budget)
      end
      validate_complete_schedule!(codec_budget)

      @plan.site_paths.each do |site_path|
        role = "#{site_path}.dynamic_structure"
        expected_name = @physical.structure_stream_names[role]?
        unless expected_name && @structure_names[site_path]? == expected_name
          raise CorruptPartError.new("Dynamic site structure name differs from its parsed actual site")
        end
        grid = @structure_grids[site_path]? ||
               raise(CorruptPartError.new("Dynamic site structure has no inspected mark grid"))
        offset = @plan.statistics_offset_for(site_path)
        unless grid.logical_size >= offset && grid.prefix_size == offset &&
               grid.mark_count == @mark_count && grid.rows_per_mark == @mark_row_counts
          raise CorruptPartError.new("Dynamic site structure differs from its statistics or P grid")
        end
        grid.mark_count.times do |index|
          unless grid.position_at(index) == offset.to_i64
            raise CorruptPartError.new("Dynamic site structure marks do not point at the statistics offset")
          end
        end
        unless grid.position_at(grid.mark_count) == grid.logical_size
          raise CorruptPartError.new("Dynamic site structure terminal mark does not point at EOF")
        end
      end

      @physical_stream_names = role_names.values.sort!
      @selected_checksum_names = checksum_names(role_names)
      @logical_read_bytes = logical_bytes
    end

    def mark_row_counts : Array(UInt64)
      @mark_row_counts.dup
    end

    # Exact read-discovery identity check used by the recursive manifest. The
    # physical binding remains owned by this reader and is reused only when its
    # schema site, prepared plan, and inherited coordinates still match.
    def matches_site?(
      type : BinaryDataType,
      prefix : String,
      site_key : String,
      array_level : UInt64,
      descriptor_depth : Int32,
      profile : BinaryBulkProfile,
      plan : BinaryDynamicBulkPlan,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
    ) : Bool
      @type == type && @prefix == prefix && @site_key == site_key && @initial_array_level == array_level &&
        @initial_descriptor_depth == descriptor_depth && @ordinary_profile == profile &&
        same_limits?(@limits, limits) && same_transport_limits?(@transport_limits, transport_limits) &&
        @plan.same?(plan) && @plan.type == type && @plan.profile == profile &&
        @physical.same_prepared_plan?(@plan)
    end

    def logical_occurrences_at(mark : Int) : UInt64
      @site_grid.logical_occurrences_at(mark)
    end

    def physical_stream_names : Array(String)
      copy_strings(@physical_stream_names)
    end

    def selected_checksum_names : Array(String)
      copy_strings(@selected_checksum_names)
    end

    # Logical retained-owner charge for the actual data and structure grids.
    # Each grid's own mark_count determines its positions (K+1) and row (K)
    # slots; do not infer the map cardinalities from another site or part.
    def retained_grid_workspace_bytes : UInt64
      bytes = grid_map_workspace_bytes(@grids)
      checked_grid_workspace_add(bytes, grid_map_workspace_bytes(@structure_grids))
    end

    def contains_bound_dynamic_json? : Bool
      @plan.has_json_object_bindings?
    end

    # Revalidates the complete borrowed P/Q grid on every read operation.
    # In particular, an empty Q mark remains an explicit decoder schedule.
    def validate_complete_schedule!(budget : BinaryCodecBudget) : Nil
      @site_grid.validate_for!(@mark_count, budget)
      total_q = 0_u64
      @mark_count.times do |mark|
        physical = @site_grid.physical_rows_at(mark)
        logical = @site_grid.logical_occurrences_at(mark)
        unless physical == @mark_row_counts[mark]
          raise CorruptPartError.new("Dynamic site complete P grid changed after inspection")
        end
        if logical > Int32::MAX.to_u64 - total_q
          raise CorruptPartError.new("Dynamic site complete Q grid exceeds the flattened value domain")
        end
        total_q += logical
      end
      nil
    end

    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      read_marks(
        first_mark, mark_count, BinaryCodecBudget.new(@limits),
        CompressedStreamBudget.new(@transport_limits)
      )
    end

    def read_marks(
      first_mark : Int,
      mark_count : Int,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      name_context : PhysicalStreamPlanContext? = nil,
    ) : Array(Array(BinaryValue))
      if transport_budget.writing? || !same_transport_limits?(@transport_limits, transport_budget.limits)
        raise ArgumentError.new("Dynamic site reader transport budget differs from its limits")
      end
      validate_selection!(first_mark, mark_count)
      validate_complete_schedule!(codec_budget)
      operation_name_context = name_context || PhysicalStreamPlanContext.new(@limits)
      unless operation_name_context.limits.max_depth == @limits.max_depth &&
             operation_name_context.limits.max_nodes == @limits.max_nodes &&
             operation_name_context.limits.max_elements == @limits.max_elements &&
             operation_name_context.limits.max_bytes == @limits.max_bytes
        raise ArgumentError.new("Dynamic site operation physical context differs from its limits")
      end
      traversal = BinaryCodecContext.new(@limits, nil, false, codec_budget, false, false)
      has_json_objects = @plan.has_json_object_bindings?
      replay_complete = has_json_objects || @plan.contains_low_cardinality?(@type, "root", traversal)
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? @mark_count : mark_count
      rows_for_decode = if replay_complete
                          copy_logical_rows(0, @mark_count, codec_budget)
                        else
                          copy_logical_rows(first_mark, mark_count, codec_budget)
                        end
      role_names = @physical.data_stream_names

      prefix_reads = [] of Tuple(String, Int32, Int32)
      role_names.keys.sort!.each do |role|
        prefix_size = @physical.prefix_size_for(role)
        next unless discriminator_role?(role)
        if read_count == Int32::MAX
          raise CorruptPartError.new("Dynamic site discriminator coordinate count exceeds the supported domain")
        end
        prefix_reads << {role, prefix_size, read_count + 1}
      end
      BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

      streams_by_role = Hash(String, BinaryBulkStream).new(initial_capacity: role_names.size)
      role_names.keys.sort!.each do |role|
        grid = @grids[role]? || raise(CorruptPartError.new("Dynamic site data role has no inspected grid"))
        prefix_size = @physical.prefix_size_for(role)
        window = @source.read_window(
          @physical.data_file_for(role, true),
          @physical.marks_file_for(role, true), read_first, read_count,
          prefix_size, transport_budget
        )
        expected_rows = selected_physical_rows(read_first, read_count, codec_budget)
        unless window.rows_per_mark == expected_rows && grid.mark_count == @mark_count
          raise CorruptPartError.new("Dynamic site selected window differs from the inspected P grid")
        end
        logical = if dynamic_discriminator_role?(role)
                    BinaryBulkDiscriminatorFramingAdapter.read_lane(
                      role, window.bytes, window.offsets, prefix_size, codec_budget
                    )
                  else
                    BinaryBulkPhysicalPrefixAdapter.read_lane(
                      role, window.bytes, window.offsets, prefix_size
                    )
                  end
        streams_by_role[role] = BinaryBulkStream.new(logical[0], logical[1])
      end

      stream_set = BinaryBulkStreams.new(read_count, streams_by_role)
      decoded = if has_json_objects
                  empty_structures = BinaryDynamicStructureStreams.new(Hash(String, Bytes).new)
                  dynamic_streams = BinaryDynamicBulkStreams.new(
                    empty_structures, stream_set, budget: codec_budget
                  )
                  child_loader = ->(key : BinaryDynamicJsonLeafKey, binding : DynamicJsonObjectBinding, grid : StorageOccurrenceGrid, budget : BinaryCodecBudget) {
                    physical_site = @physical.json_object_site(key)
                    expected_binding = @plan.json_object_binding(key)
                    structure = @plan.structure_for(key.dynamic_site)
                    json_depth = @plan.json_object_leaf_depth(key, @initial_descriptor_depth)
                    begin
                      binding.validate_for!(key, structure, budget, json_depth)
                      expected_binding.validate_for!(key, structure, budget, json_depth)
                    rescue ex : ArgumentError
                      raise CorruptPartError.new(ex.message || "Dynamic JSON binding changed before Object decode")
                    end
                    leaf_type = @plan.json_object_leaf_type(key)
                    unless binding.json_type == leaf_type && physical_site.binding.leaf_key == key
                      raise CorruptPartError.new("bound Dynamic JSON leaf changed before Object decode")
                    end
                    descriptor = leaf_type.json_type ||
                                 raise(CorruptPartError.new("bound Dynamic JSON leaf lost its descriptor"))
                    typed_schema = copy_json_typed_schema(descriptor, budget)
                    ObjectDocumentFileReader.read_child_at_site(
                      @source,
                      physical_site.escaped_prefix,
                      typed_schema,
                      grid,
                      budget,
                      operation_name_context,
                      transport_budget,
                      0,
                      @mark_count,
                      @ordinary_profile,
                      BinaryBulkProfile.single_stream,
                      true,
                      physical_site.array_level,
                      binding.plan,
                      binding.schema,
                      json_depth,
                      json_depth + 1,
                    )
                  }
                  json_reader = BinaryDynamicBulkJsonObjectReader.new(
                    @plan,
                    dynamic_streams,
                    rows_for_decode,
                    codec_budget,
                    @ordinary_profile,
                    physical_rows_per_mark: @mark_row_counts,
                    physical_child_loader: child_loader,
                    initial_descriptor_depth: @initial_descriptor_depth,
                  )
                  full = BinaryBulkDecoder.decode(
                    @type, stream_set, rows_for_decode, codec_budget,
                    0, @mark_count, @ordinary_profile, @plan, json_reader
                  )
                  slice_selected_marks(full, first_mark, mark_count, codec_budget)
                else
                  BinaryBulkDecoder.decode(
                    @type, stream_set, rows_for_decode, codec_budget,
                    replay_complete ? first_mark : 0, mark_count, @ordinary_profile, @plan
                  )
                end
      unless decoded.size == mark_count
        raise CorruptPartError.new("Dynamic site decoder returned the wrong selected mark count")
      end
      decoded.each_with_index do |values, index|
        unless values.size.to_u64 == @site_grid.logical_occurrences_at(first_mark + index)
          raise CorruptPartError.new("Dynamic site decoder returned the wrong logical Q row count")
        end
      end
      decoded
    end

    private def validate_row_grid!(rows : Array(UInt64), expected_total : UInt64?) : Nil
      if rows.empty? || rows.size > WidePartWriter::MAX_MARKS
        raise CorruptPartError.new("Dynamic physical mark count is outside the admitted range")
      end
      total = 0_u64
      rows.each do |count|
        if count == 0_u64 || count > WidePartWriter::MAX_ROWS_PER_MARK.to_u64 ||
           count > WidePart::MAX_ROWS.to_u64 - total
          raise CorruptPartError.new("Dynamic physical row count exceeds the part limit")
        end
        total += count
      end
      if expected = expected_total
        unless total == expected
          raise CorruptPartError.new("Dynamic physical mark grid differs from count.txt")
        end
      end
      nil
    end

    private def detached_rows(rows : Array(UInt64), budget : BinaryCodecBudget) : Array(UInt64)
      budget.ensure_future_nodes(rows.size.to_u64 + 1_u64)
      budget.ensure_future_elements(rows.size.to_u64)
      budget.charge_node
      budget.charge_elements(rows.size.to_u64)
      Array(UInt64).new(rows.size) { |index| rows[index] }
    end

    private def copy_json_typed_schema(
      descriptor : BinaryJsonType,
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryDataType)
      count = descriptor.typed_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      total_path_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        size = descriptor.typed_path_byte_size(index).to_u64
        if total_path_bytes > UInt64::MAX - size
          raise CorruptPartError.new("Dynamic JSON typed path byte count overflows")
        end
        total_path_bytes += size
      end
      budget.charge_wire_bytes(total_path_bytes) if total_path_bytes > 0_u64
      count.times { budget.charge_node }
      schema = Hash(String, BinaryDataType).new(initial_capacity: descriptor.typed_path_count)
      descriptor.typed_path_count.times do |index|
        schema[descriptor.typed_path_at(index)] = descriptor.typed_type_at(index)
      end
      schema
    end

    private def slice_selected_marks(
      marks : Array(Array(BinaryValue)),
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : Array(Array(BinaryValue))
      count = mark_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.charge_node
      count.times { budget.charge_node }
      Array(Array(BinaryValue)).new(mark_count) do |index|
        marks[first_mark + index]
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

    private def validate_selection!(first_mark : Int, count : Int) : Nil
      first = first_mark.to_i128
      selected = count.to_i128
      total = @mark_count.to_i128
      if first < 0_i128 || first > total || selected < 0_i128 || selected > total - first
        raise ArgumentError.new("Dynamic selected mark range is outside the physical grid")
      end
      nil
    end

    private def copy_logical_rows(first_mark : Int, count : Int, budget : BinaryCodecBudget) : Array(UInt64)
      budget.ensure_future_nodes(count.to_u64 + 1_u64)
      budget.ensure_future_elements(count.to_u64)
      budget.charge_node
      budget.charge_elements(count.to_u64)
      Array(UInt64).new(count) { |index| @site_grid.logical_occurrences_at(first_mark + index) }
    end

    private def selected_physical_rows(first_mark : Int, count : Int, budget : BinaryCodecBudget) : Array(UInt64)
      budget.ensure_future_nodes(count.to_u64 + 1_u64)
      budget.ensure_future_elements(count.to_u64)
      budget.charge_node
      budget.charge_elements(count.to_u64)
      Array(UInt64).new(count) { |index| @mark_row_counts[first_mark + index] }
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end

    private def grid_map_workspace_bytes(grids : Hash(String, CompressedMarkGrid)) : UInt64
      bytes = instance_sizeof(Hash(String, CompressedMarkGrid)).to_u64
      key_and_value_slots = sizeof(Pointer(String)).to_u64 +
                            sizeof(Pointer(CompressedMarkGrid)).to_u64 +
                            sizeof(UInt64).to_u64
      bytes = checked_grid_workspace_add(
        bytes,
        checked_grid_workspace_multiply(grids.size.to_u64, key_and_value_slots)
      )
      grids.each do |key, grid|
        bytes = checked_grid_workspace_add(bytes, grid_key_workspace_bytes(key))
        bytes = checked_grid_workspace_add(bytes, compressed_grid_workspace_bytes(grid))
      end
      bytes
    end

    private def compressed_grid_workspace_bytes(grid : CompressedMarkGrid) : UInt64
      marks = grid.mark_count.to_u64
      positions = checked_grid_workspace_add(marks, 1_u64)
      bytes = instance_sizeof(CompressedMarkGrid).to_u64
      bytes = checked_grid_workspace_add(bytes, instance_sizeof(Array(Int64)).to_u64)
      bytes = checked_grid_workspace_add(
        bytes,
        checked_grid_workspace_multiply(positions, sizeof(Int64).to_u64)
      )
      bytes = checked_grid_workspace_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_grid_workspace_add(bytes, checked_grid_workspace_multiply(marks, sizeof(UInt64).to_u64))
    end

    private def grid_key_workspace_bytes(key : String) : UInt64
      checked_grid_workspace_add(
        instance_sizeof(String).to_u64,
        checked_grid_workspace_add(key.bytesize.to_u64, 1_u64)
      )
    end

    private def checked_grid_workspace_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Dynamic retained grid workspace overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_grid_workspace_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise BoundsError.new("Dynamic retained grid workspace overflows UInt64")
      end
      left * right
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def same_transport_limits?(left : CompressedStreamLimits, right : CompressedStreamLimits) : Bool
      left.max_file_bytes == right.max_file_bytes && left.max_mark_bytes == right.max_mark_bytes &&
        left.max_frame_compressed_bytes == right.max_frame_compressed_bytes &&
        left.max_frame_decompressed_bytes == right.max_frame_decompressed_bytes &&
        left.max_records == right.max_records && left.max_decoded_bytes == right.max_decoded_bytes &&
        left.max_result_bytes == right.max_result_bytes
    end
  end
end
