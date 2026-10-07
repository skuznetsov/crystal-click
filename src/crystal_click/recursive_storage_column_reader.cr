module CrystalClick
  # Reads recursive Tuple/Array layouts. Each JSON leaf remains an Object site
  # with its own discovered structure plan; JSON-free leaves remain BinaryBulk
  # sites. Array occurrences are owned by their structural size schedules,
  # while all lanes share the top-level physical mark grid and operation budgets.
  class RecursiveStorageColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter logical_read_bytes : UInt64
    getter ordinary_profile : BinaryBulkProfile

    private struct BulkGridSet
      getter grids : Hash(String, CompressedMarkGrid)

      def initialize(@grids : Hash(String, CompressedMarkGrid))
      end
    end

    @part_path : String
    @column_name : String
    @schema : StorageColumnSchema
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @source : PartStreamSource
    @plan : RecursiveStorageColumnPlan
    @object_descriptors : Hash(String, ObjectDocumentFileDescriptor)
    @bulk_grids : Hash(String, BulkGridSet)
    @dynamic_readers : Hash(String, DynamicBulkSiteReader)
    @array_frames : Hash(String, StorageArrayOccurrenceFrame)
    @array_size_names : Hash(String, String)
    @object_domain_grids : Hash(String, StorageOccurrenceGrid)
    @site_domain_rows : Hash(String, Array(UInt64))
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)

    def self.open(
      part_path : String,
      column_name : String,
      expected_schema : StorageColumnSchema,
    ) : RecursiveStorageColumnReader
      new(part_path, column_name, expected_schema)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      expected_schema : StorageColumnSchema,
    )
      @array_frames = Hash(String, StorageArrayOccurrenceFrame).new
      @array_size_names = Hash(String, String).new
      @object_domain_grids = Hash(String, StorageOccurrenceGrid).new
      @site_domain_rows = Hash(String, Array(UInt64)).new
      @schema = expected_schema
      @limits = limits_for_schema(expected_schema)
      # Reparse public factory descriptors before they can select metadata,
      # physical prefixes, or codec sites.
      begin
        expected_schema.validate_source_tree!(@limits)
      rescue ex : ArgumentError
        raise ArgumentError.new(ex.message || "recursive schema differs from its source declaration")
      end
      unless (expected_schema.tuple? || expected_schema.array?) && expected_schema.has_json?
        raise UnsupportedFormatError.new("recursive storage requires a root Tuple or Array with a JSON leaf")
      end
      validate_json_site_limits!(expected_schema, @limits)

      raise ArgumentError.new("recursive storage column name must not be empty") if column_name.empty?
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      @transport_limits = CompressedStreamLimits.new

      selected_declaration = WidePart.selected_recursive_json_declaration(@part_path, @column_name) ||
                             raise(UnsupportedFormatError.new("selected column is not an admitted recursive Tuple/Array JSON declaration"))

      metadata = ObjectColumnPartMetadata.open(
        @part_path,
        @column_name,
        ->(declaration : String) {
          unless declaration == selected_declaration
            raise CorruptPartError.new("selected recursive Tuple/Array declaration changed during metadata inspection")
          end
          source_schema = StorageColumnSchema.parse(declaration, @limits)
          unless (source_schema.tuple? || source_schema.array?) && source_schema.has_json? &&
                 source_schema.declaration == expected_schema.declaration
            raise CorruptPartError.new("part recursive Tuple/Array declaration differs from the expected schema")
          end
          nil
        },
      )
      @source_declaration = metadata.source_declaration
      @schema_declaration = String.new(expected_schema.declaration.to_slice)
      @ordinary_profile = metadata.ordinary_profile

      @source = PartStreamSource.new(@part_path)
      codec_budget = BinaryCodecBudget.new(@limits)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      name_context = PhysicalStreamPlanContext.new(@limits)
      descriptors = Hash(String, ObjectDocumentFileDescriptor).new
      object_plans = Hash(String, ObjectDocumentPlan).new
      dynamic_readers = Hash(String, DynamicBulkSiteReader).new
      root_prefix = PhysicalStreamName.escape(@column_name, name_context)
      preinspected = Hash(String, ObjectDocumentFileDescriptor).new

      # The first Array size lane or the first Object site provides the root
      # physical P mark schedule. Nested site Q/C schedules are derived only
      # after P is fixed, never substituted for the part's physical grid.
      rows = if expected_schema.has_array?
               location = first_array_location(expected_schema, root_prefix, "root", 0_u64, name_context) ||
                          raise(CorruptPartError.new("recursive Array schema has no Array site"))
               discover_root_rows_from_array(location[1], location[2], transport_budget)
             else
               location = first_object_location(expected_schema, root_prefix, "root", name_context) ||
                          raise(CorruptPartError.new("recursive Tuple schema has no Object site"))
               descriptor = ObjectDocumentFileReader.inspect_at_site(
                 @source,
                 location[1],
                 location[2].typed_paths,
                 codec_budget,
                 name_context,
                 transport_budget,
                 @ordinary_profile,
                 BinaryBulkProfile.single_stream,
                 true,
                 0_u64,
                 nil,
               )
               begin
                 location[2].validate_plan(descriptor.plan)
               rescue ex : ArgumentError
                 raise CorruptPartError.new(ex.message || "recursive Object site differs from its schema")
               end
               preinspected[location[0]] = descriptor
               descriptor.mark_row_counts
             end

      validate_parent_schedule!(rows, metadata.row_count)
      root_grid = StorageOccurrenceGrid.new(rows, rows, codec_budget)
      array_frames = Hash(String, StorageArrayOccurrenceFrame).new
      array_size_names = Hash(String, String).new
      object_domain_grids = Hash(String, StorageOccurrenceGrid).new
      site_domain_rows = Hash(String, Array(UInt64)).new
      inspect_recursive_sites(
        expected_schema,
        root_prefix,
        "root",
        0_u64,
        1_i32,
        root_grid,
        rows,
        rows,
        descriptors,
        object_plans,
        preinspected,
        array_frames,
        array_size_names,
        object_domain_grids,
        site_domain_rows,
        dynamic_readers,
        codec_budget,
        name_context,
        transport_budget,
      )

      @plan = RecursiveStorageColumnPlan.for_column_with_dynamic_readers(
        @column_name,
        expected_schema,
        object_plans,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        # This is a read-side physical roster plan, not a prediction of the
        # encoded Dynamic body mode. The Object child reader validates the
        # persisted mode header and decodes BASIC or COMPACT accordingly.
        ObjectDocumentCodec::DEFAULT_MODE,
        4096,
        @limits,
        @transport_limits,
        dynamic_readers,
        name_context,
      )

      bulk_grids = Hash(String, BulkGridSet).new
      @plan.bulk_site_count.times do |site_index|
        site = @plan.bulk_site_at(site_index)
        names = site.physical.stream_names
        grids = Hash(String, CompressedMarkGrid).new(initial_capacity: names.size)
        names.each do |role, _logical_name|
          data_name = site.physical.data_file_for(role, true)
          marks_name = site.physical.marks_file_for(role, true)
          grid = @source.inspect_grid(
            data_name,
            marks_name,
            site.physical.prefix_size_for(role),
            transport_budget,
          )
          validate_same_physical_rows!(grid, rows, "BinaryBulk site #{site.key}")
          grids[String.new(role.to_slice)] = grid

          if BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, site.physical.prefix_size_for(role))
            BinaryBulkPhysicalPrefixAdapter.preflight_read(
              [{role, site.physical.prefix_size_for(role), 1}],
              codec_budget,
            )
            window = @source.read_window(data_name, marks_name, 0, 0, site.physical.prefix_size_for(role), transport_budget)
            BinaryBulkPhysicalPrefixAdapter.read_lane(role, window.bytes, window.offsets, site.physical.prefix_size_for(role))
          end
        end
        unless grids.size == names.size
          raise CorruptPartError.new("recursive BinaryBulk grid roster differs from its role plan")
        end
        bulk_grids[String.new(site.key.to_slice)] = BulkGridSet.new(grids)
      end

      expected_streams = @plan.physical_stream_names
      actual_streams = metadata.selected_stream_names
      expected_streams.sort!
      actual_streams.sort!
      unless actual_streams == expected_streams
        raise CorruptPartError.new("selected columns_substreams roster differs from the recursive physical plan")
      end

      validate_object_descriptors!(descriptors)
      @object_descriptors = descriptors
      @bulk_grids = bulk_grids
      @dynamic_readers = dynamic_readers
      @array_frames = array_frames
      @array_size_names = array_size_names
      @object_domain_grids = object_domain_grids
      @site_domain_rows = site_domain_rows
      @mark_row_counts = rows.dup
      @row_count = metadata.row_count
      @mark_count = rows.size.to_i32
      @physical_stream_names = @plan.physical_stream_names
      @selected_checksum_names = @plan.file_names
      @logical_read_bytes = logical_bytes(descriptors, bulk_grids, dynamic_readers, array_frames)
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    # Exact literal declaration retained from columns.txt. The canonical
    # declaration exposed separately is the expected schema's normalized form.
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

    # Returns selected physical parent marks -> rows -> recursive Tuple/Array
    # values. Each leaf consumes its own occurrence domain; physical marks
    # remain rooted at the top-level P grid. LC-bearing sites replay their
    # complete state before this window is assembled.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(StorageColumnValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = BinaryCodecBudget.new(@limits)
      validate_complete_schedules!(codec_budget)
      charge_selected_value_shape!(first_mark, mark_count, codec_budget)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      name_context = PhysicalStreamPlanContext.new(@limits)

      object_rows = Hash(String, Array(Array(ObjectDocument))).new
      @plan.object_site_count.times do |site_index|
        site = @plan.object_site_at(site_index)
        grid = @object_domain_grids[site.key]? || raise(CorruptPartError.new("recursive Object site has no occurrence grid"))
        selected = if site.array_level == 0_u64
                     ObjectDocumentFileReader.read_at_site(
                       @source,
                       site.prefix,
                       site.schema.typed_paths,
                       codec_budget,
                       name_context,
                       transport_budget,
                       first_mark,
                       mark_count,
                       @ordinary_profile,
                       BinaryBulkProfile.single_stream,
                       true,
                       0_u64,
                       @mark_row_counts,
                     )
                   else
                     ObjectDocumentFileReader.read_child_at_site(
                       @source,
                       site.prefix,
                       site.schema.typed_paths,
                       grid,
                       codec_budget,
                       name_context,
                       transport_budget,
                       first_mark,
                       mark_count,
                       @ordinary_profile,
                       BinaryBulkProfile.single_stream,
                       true,
                       site.array_level,
                     )
                   end
        unless selected.size == mark_count
          raise CorruptPartError.new("bounded recursive Object read returned the wrong mark count")
        end
        site_rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive Object site has no logical row schedule"))
        selected.each_with_index do |mark_rows, index|
          unless mark_rows.size.to_u64 == site_rows[first_mark + index]
            raise CorruptPartError.new("bounded recursive Object read returned the wrong occurrence row count")
          end
        end
        object_rows[String.new(site.key.to_slice)] = selected
      end

      bulk_rows = Hash(String, Array(Array(BinaryValue))).new
      @plan.bulk_site_count.times do |site_index|
        site = @plan.bulk_site_at(site_index)
        grid_set = @bulk_grids[site.key]? || raise(CorruptPartError.new("recursive BinaryBulk site has no inspected grid"))
        replay_complete = site.type.contains_low_cardinality?
        read_first = replay_complete ? 0 : first_mark
        read_count = replay_complete ? @mark_count : mark_count
        site_rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive BinaryBulk site has no logical row schedule"))
        rows_for_decode = replay_complete ? site_rows : selected_site_rows(site.key, first_mark, mark_count)
        role_names = site.physical.stream_names
        streams_by_role = Hash(String, BinaryBulkStream).new(initial_capacity: role_names.size)

        prefix_reads = [] of Tuple(String, Int32, Int32)
        role_names.each do |role, _logical_name|
          prefix = site.physical.prefix_size_for(role)
          next unless BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(role, prefix)
          if read_count == Int32::MAX
            raise CorruptPartError.new("recursive Variant read coordinate count exceeds the supported domain")
          end
          prefix_reads << {role, prefix, read_count + 1}
        end
        BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

        role_names.each do |role, _logical_name|
          grid = grid_set.grids[role]? || raise(CorruptPartError.new("recursive BinaryBulk role has no inspected mark grid"))
          window = @source.read_window(
            site.physical.data_file_for(role, true),
            site.physical.marks_file_for(role, true),
            read_first,
            read_count,
            site.physical.prefix_size_for(role),
            transport_budget,
          )
          expected_window_rows = selected_mark_rows(read_first, read_count)
          unless window.rows_per_mark == expected_window_rows
            raise CorruptPartError.new("recursive BinaryBulk physical rows differ from the root mark grid")
          end
          logical = BinaryBulkPhysicalPrefixAdapter.read_lane(
            role,
            window.bytes,
            window.offsets,
            site.physical.prefix_size_for(role),
          )
          streams_by_role[role] = BinaryBulkStream.new(logical[0], logical[1])
          unless grid.mark_count == @mark_count
            raise CorruptPartError.new("recursive BinaryBulk grid changed after inspection")
          end
        end

        stream_set = BinaryBulkStreams.new(read_count, streams_by_role)
        decoded = BinaryBulkDecoder.decode(
          site.type,
          stream_set,
          rows_for_decode,
          codec_budget,
          replay_complete ? first_mark : 0,
          mark_count,
          @ordinary_profile,
        )
        unless decoded.size == mark_count
          raise CorruptPartError.new("bounded recursive BinaryBulk read returned the wrong mark count")
        end
        decoded.each_with_index do |mark_values, index|
          unless mark_values.size.to_u64 == site_rows[first_mark + index]
            raise CorruptPartError.new("bounded recursive BinaryBulk read returned the wrong occurrence row count")
          end
        end
        bulk_rows[String.new(site.key.to_slice)] = decoded
      end

      @plan.dynamic_site_count.times do |site_index|
        site = @plan.dynamic_site_at(site_index)
        reader = @dynamic_readers[site.key]? || raise(CorruptPartError.new("recursive Dynamic site has no discovered physical reader"))
        selected = reader.read_marks(first_mark, mark_count, codec_budget, transport_budget)
        unless selected.size == mark_count
          raise CorruptPartError.new("bounded recursive Dynamic read returned the wrong mark count")
        end
        site_rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive Dynamic site has no logical row schedule"))
        selected.each_with_index do |mark_values, index|
          unless mark_values.size.to_u64 == site_rows[first_mark + index]
            raise CorruptPartError.new("bounded recursive Dynamic read returned the wrong occurrence row count")
          end
        end
        bulk_rows[String.new(site.key.to_slice)] = selected
      end

      result = Array(Array(StorageColumnValue)).new(mark_count)
      mark_count.times do |selected_index|
        parent_mark = first_mark + selected_index
        parent_count = @mark_row_counts[parent_mark]
        if parent_count > Int32::MAX.to_u64
          raise CorruptPartError.new("recursive Tuple parent mark exceeds the supported row domain")
        end
        mark_object_rows = Hash(String, Array(ObjectDocument)).new
        object_rows.each { |key, marks| mark_object_rows[key] = marks[selected_index] }
        mark_bulk_rows = Hash(String, Array(BinaryValue)).new
        bulk_rows.each { |key, marks| mark_bulk_rows[key] = marks[selected_index] }
        row_values = Array(StorageColumnValue).new(parent_count.to_i)
        array_parent_cursors = Hash(String, Int32).new(0)
        array_child_cursors = Hash(String, Int32).new(0)
        parent_count.to_i.times do |row_index|
          value = assemble_value(
            @schema,
            "root",
            row_index,
            parent_mark,
            mark_object_rows,
            mark_bulk_rows,
            array_parent_cursors,
            array_child_cursors,
          )
          StorageColumnDepthGuard.validate(value, @limits, false)
          row_values << value
        end
        validate_assembled_array_cursors!(parent_mark, array_parent_cursors, array_child_cursors)
        result << row_values
      end
      result
    end

    # Reserve the logical Tuple/Array/leaf owners before any site decoder
    # allocates values. Shape is derived from complete per-site Q/C frames,
    # not from a static per-row schema product. LC replay still decodes its
    # complete logical site, but only selected parent rows produce wrappers.
    private def charge_selected_value_shape!(
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : Nil
      total = StorageValueShape.new(0_u64, 0_u64, 0_u64, 0_u64)
      mark_count.times do |index|
        shape = storage_value_shape_for_mark(first_mark + index)
        total = add_storage_shapes(
          total,
          shape,
        )
      end

      # Preflight both dimensions before mutating the shared budget, then
      # reserve elements and nodes. charge_node is intentionally repeated
      # only after ensure_future_nodes bounds the count by max_nodes.
      budget.ensure_future_nodes(total.nodes)
      budget.ensure_future_elements(total.elements)
      budget.charge_elements(total.elements) if total.elements > 0_u64
      remaining_nodes = total.nodes
      while remaining_nodes > 0_u64
        budget.charge_node
        remaining_nodes -= 1_u64
      end
      nil
    end

    # The exact returned wrapper footprint for one selected physical mark.
    # This is a logical owner estimate for aggregate table accounting, not an
    # estimate of transient RSS while leaf codecs replay state.
    def storage_value_shape_for_mark(mark : Int) : StorageValueShape
      unless mark >= 0 && mark < @mark_count
        raise ArgumentError.new("recursive storage shape mark is outside the physical grid")
      end
      shape_for_domain(@schema, "root", mark, @mark_row_counts[mark])
    end

    private def shape_for_domain(
      schema : StorageColumnSchema,
      key : String,
      mark : Int,
      rows : UInt64,
    ) : StorageValueShape
      node_bytes = checked_add_shape_count(
        instance_sizeof(StorageColumnValue).to_u64,
        instance_sizeof(Array(StorageColumnValue)).to_u64,
        "StorageColumnValue owner bytes",
      )
      shape = StorageValueShape.new(
        rows,
        0_u64,
        0_u64,
        checked_multiply_shape_count(rows, node_bytes, "StorageColumnValue owner bytes"),
      )

      if schema.tuple?
        child_slots = checked_multiply_shape_count(rows, schema.child_count.to_u64, "Tuple child slots")
        shape = StorageValueShape.new(
          shape.nodes,
          child_slots,
          child_slots,
          checked_add_shape_count(
            shape.bytes,
            checked_multiply_shape_count(child_slots, sizeof(Pointer(StorageColumnValue)).to_u64, "Tuple child bytes"),
            "StorageColumnValue owner bytes",
          ),
        )
        schema.child_count.times do |index|
          child_key = tuple_child_key(key, index)
          shape = add_storage_shapes(
            shape,
            shape_for_domain(schema.child_at(index), child_key, mark, rows),
          )
        end
      elsif schema.array?
        frame = @array_frames[key]? || raise(CorruptPartError.new("recursive Array site has no occurrence frame"))
        unless frame.parent_count_at(mark) == rows
          raise CorruptPartError.new("recursive Array parent grid differs from its inherited occurrence domain")
        end
        children = frame.child_count_at(mark)
        shape = StorageValueShape.new(
          shape.nodes,
          shape.tuple_cells,
          checked_add_shape_count(shape.elements, children, "Array element count"),
          checked_add_shape_count(
            shape.bytes,
            checked_multiply_shape_count(children, sizeof(Pointer(StorageColumnValue)).to_u64, "Array child bytes"),
            "StorageColumnValue owner bytes",
          ),
        )
        child_key = array_child_key(key)
        shape = add_storage_shapes(shape, shape_for_domain(schema.child_at(0), child_key, mark, children))
      end
      shape
    end

    private def checked_add_shape_count(left : UInt64, right : UInt64, label : String) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("recursive Tuple #{label} overflows UInt64")
      end
      left + right
    end

    private def checked_multiply_shape_count(left : UInt64, right : UInt64, label : String) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("recursive Tuple #{label} overflows UInt64")
      end
      left * right
    end

    private def first_object_location(
      schema : StorageColumnSchema,
      prefix : String,
      key : String,
      name_context : PhysicalStreamPlanContext,
    ) : Tuple(String, String, ObjectDocumentSchema)?
      if object_schema = schema.object_schema_or_nil
        return {String.new(key.to_slice), String.new(prefix.to_slice), object_schema}
      end
      return nil unless schema.tuple?

      schema.child_count.times do |index|
        raw_field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
        child_prefix = PhysicalStreamName.append_escaped_field(prefix, raw_field, name_context)
        child_key = tuple_child_key(key, index)
        if found = first_object_location(schema.child_at(index), child_prefix, child_key, name_context)
          return found
        end
      end
      nil
    end

    private def first_array_location(
      schema : StorageColumnSchema,
      prefix : String,
      key : String,
      array_level : UInt64,
      name_context : PhysicalStreamPlanContext,
    ) : Tuple(String, String, UInt64)?
      if schema.array?
        return {String.new(key.to_slice), String.new(prefix.to_slice), array_level}
      end
      return nil unless schema.tuple?

      schema.child_count.times do |index|
        raw_field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
        child_prefix = PhysicalStreamName.append_escaped_field(prefix, raw_field, name_context)
        child_key = tuple_child_key(key, index)
        if found = first_array_location(schema.child_at(index), child_prefix, child_key, array_level, name_context)
          return found
        end
      end
      nil
    end

    private def discover_root_rows_from_array(
      prefix : String,
      array_level : UInt64,
      transport_budget : CompressedStreamBudget,
    ) : Array(UInt64)
      logical_name = array_size_name(prefix, array_level)
      data_name = checksum_data_name(logical_name)
      marks_name = checksum_marks_name(logical_name)
      grid = @source.inspect_grid(data_name, marks_name, 0, transport_budget)
      unless grid.prefix_size == 0 && grid.mark_count > 0
        raise CorruptPartError.new("root recursive Array size lane has no complete physical mark grid")
      end
      grid.rows_per_mark
    end

    private def inspect_recursive_sites(
      schema : StorageColumnSchema,
      prefix : String,
      key : String,
      array_level : UInt64,
      descriptor_depth : Int32,
      domain_grid : StorageOccurrenceGrid,
      root_physical_rows : Array(UInt64),
      domain_rows : Array(UInt64),
      descriptors : Hash(String, ObjectDocumentFileDescriptor),
      plans : Hash(String, ObjectDocumentPlan),
      preinspected : Hash(String, ObjectDocumentFileDescriptor),
      array_frames : Hash(String, StorageArrayOccurrenceFrame),
      array_size_names : Hash(String, String),
      object_domain_grids : Hash(String, StorageOccurrenceGrid),
      site_domain_rows : Hash(String, Array(UInt64)),
      dynamic_readers : Hash(String, DynamicBulkSiteReader),
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      if object_schema = schema.object_schema_or_nil
        descriptor = if existing = preinspected[key]?
                       existing
                     elsif array_level == 0_u64
                       ObjectDocumentFileReader.inspect_at_site(
                         @source,
                         prefix,
                         object_schema.typed_paths,
                         codec_budget,
                         name_context,
                         transport_budget,
                         @ordinary_profile,
                         BinaryBulkProfile.single_stream,
                         true,
                         0_u64,
                         root_physical_rows,
                       )
                     else
                       ObjectDocumentFileReader.inspect_child_at_site(
                         @source,
                         prefix,
                         object_schema.typed_paths,
                         domain_grid,
                         codec_budget,
                         name_context,
                         transport_budget,
                         @ordinary_profile,
                         BinaryBulkProfile.single_stream,
                         true,
                         array_level,
                       )
                     end
        unless descriptor.mark_row_counts == root_physical_rows
          raise CorruptPartError.new("recursive Object site does not share the root physical mark grid")
        end
        if !preinspected.has_key?(key)
          # A root-domain Object descriptor owns the physical P mark schedule
          # directly; it has no child-occurrence schedule to query. Only a
          # descriptor below Array inherits a separate Q grid from its parent.
          inherited_rows = if array_level == 0_u64
                             root_physical_rows
                           else
                             descriptor.child_occurrence_row_counts(0, root_physical_rows.size)
                           end
          unless inherited_rows == domain_rows
            raise CorruptPartError.new("recursive Object site differs from its inherited occurrence grid")
          end
        end
        begin
          object_schema.validate_plan(descriptor.plan)
        rescue ex : ArgumentError
          raise CorruptPartError.new(ex.message || "recursive Object site differs from its schema")
        end
        descriptors[String.new(key.to_slice)] = descriptor
        plans[String.new(key.to_slice)] = descriptor.plan
        object_domain_grids[String.new(key.to_slice)] = domain_grid
        site_domain_rows[String.new(key.to_slice)] = domain_rows.dup
        return nil
      end

      if bulk_type = schema.bulk_type_or_nil
        if bulk_type.contains_dynamic?
          reader = DynamicBulkSiteReader.open(
            @source,
            bulk_type,
            prefix,
            array_level,
            @ordinary_profile,
            @limits,
            @transport_limits,
            codec_budget,
            transport_budget,
            root_physical_rows,
            domain_grid,
            root_physical_rows.sum(0_u64),
            name_context,
            descriptor_depth,
            key,
          )
          unless reader.mark_count == root_physical_rows.size && reader.mark_row_counts == root_physical_rows
            raise CorruptPartError.new("recursive Dynamic site does not share the root physical mark grid")
          end
          unless reader.mark_count == domain_rows.size
            raise CorruptPartError.new("recursive Dynamic site logical schedule differs from its inherited mark grid")
          end
          reader.mark_count.times do |mark|
            unless reader.logical_occurrences_at(mark) == domain_rows[mark]
              raise CorruptPartError.new("recursive Dynamic site differs from its inherited occurrence schedule")
            end
          end
          dynamic_readers[String.new(key.to_slice)] = reader
        end
        site_domain_rows[String.new(key.to_slice)] = domain_rows.dup
        return nil
      end

      if schema.array?
        logical_name = array_size_name(prefix, array_level)
        frame = read_array_occurrence_frame(
          logical_name,
          array_level,
          root_physical_rows,
          domain_rows,
          codec_budget,
          transport_budget,
        )
        array_frames[String.new(key.to_slice)] = frame
        array_size_names[String.new(key.to_slice)] = String.new(logical_name.to_slice)
        site_domain_rows[String.new(key.to_slice)] = domain_rows.dup
        child_rows = Array(UInt64).new(frame.mark_count) { |mark| frame.child_count_at(mark) }
        inspect_recursive_sites(
          schema.child_at(0),
          prefix,
          array_child_key(key),
          array_level + 1_u64,
          descriptor_depth + 1,
          frame.child_grid,
          root_physical_rows,
          child_rows,
          descriptors,
          plans,
          preinspected,
          array_frames,
          array_size_names,
          object_domain_grids,
          site_domain_rows,
          dynamic_readers,
          codec_budget,
          name_context,
          transport_budget,
        )
        return nil
      end

      unless schema.tuple?
        raise CorruptPartError.new("recursive Tuple schema contains an unknown structural node")
      end
      schema.child_count.times do |index|
        raw_field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
        child_prefix = PhysicalStreamName.append_escaped_field(prefix, raw_field, name_context)
        child_key = tuple_child_key(key, index)
        inspect_recursive_sites(
          schema.child_at(index),
          child_prefix,
          child_key,
          array_level,
          descriptor_depth + 1,
          domain_grid,
          root_physical_rows,
          domain_rows,
          descriptors,
          plans,
          preinspected,
          array_frames,
          array_size_names,
          object_domain_grids,
          site_domain_rows,
          dynamic_readers,
          codec_budget,
          name_context,
          transport_budget,
        )
      end
      nil
    end

    private def read_array_occurrence_frame(
      logical_name : String,
      array_level : UInt64,
      physical_rows : Array(UInt64),
      parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : StorageArrayOccurrenceFrame
      unless physical_rows.size == parent_rows.size && !physical_rows.empty?
        raise CorruptPartError.new("recursive Array parent schedule differs from the complete root mark grid")
      end
      total_parents = 0_u64
      parent_rows.each do |count|
        if count > Int32::MAX.to_u64 || total_parents > UInt64::MAX - count
          raise CorruptPartError.new("recursive Array parent schedule exceeds the supported domain")
        end
        total_parents += count
      end
      expected_bytes = checked_multiply_shape_count(total_parents, 8_u64, "Array size lane bytes")
      if expected_bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("recursive Array size lane exceeds the supported byte domain")
      end
      # Reject a size lane outside the shared codec budget before loading its
      # complete payload into memory. The frame constructor charges these
      # bytes after decoding, but that is too late to bound the read itself.
      codec_budget.ensure_wire_bytes(expected_bytes)
      frame_preflight = checked_add_shape_count(
        total_parents,
        checked_add_shape_count(
          checked_multiply_shape_count(physical_rows.size.to_u64, 5_u64, "Array frame grid records"),
          1_u64,
          "Array frame terminal records",
        ),
        "Array frame records",
      )
      codec_budget.ensure_future_nodes(frame_preflight)
      codec_budget.ensure_future_elements(frame_preflight)

      data_name = checksum_data_name(logical_name)
      marks_name = checksum_marks_name(logical_name)
      grid = @source.inspect_grid(data_name, marks_name, 0, transport_budget)
      unless grid.prefix_size == 0 && grid.mark_count == physical_rows.size &&
             grid.rows_per_mark == physical_rows && grid.logical_size.to_u64 == expected_bytes
        raise CorruptPartError.new("recursive Array size lane disagrees with its physical or parent occurrence grid")
      end

      codec_budget.ensure_future_nodes(total_parents)
      codec_budget.ensure_future_elements(total_parents)
      window = @source.read_window(data_name, marks_name, 0, grid.mark_count, 0, transport_budget)
      offsets = window.offsets
      bytes = window.bytes
      unless window.first_mark == 0 && window.rows_per_mark == physical_rows &&
             offsets.size == physical_rows.size + 1 && offsets.first? == 0_u64 &&
             offsets.last? == expected_bytes && bytes.size.to_u64 == expected_bytes
        raise CorruptPartError.new("recursive Array size window differs from its complete checked lane")
      end

      sizes_by_mark = Array(Array(UInt64)).new(parent_rows.size)
      parent_rows.each_with_index do |count, mark|
        start = offsets[mark]
        finish = offsets[mark + 1]
        expected_mark_bytes = checked_multiply_shape_count(count, 8_u64, "Array size mark bytes")
        unless finish >= start && finish - start == expected_mark_bytes
          raise CorruptPartError.new("recursive Array size window offsets disagree with the inherited parent rows")
        end
        sizes = Array(UInt64).new(count.to_i)
        count.to_i.times do |parent_index|
          offset = start + parent_index.to_u64 * 8_u64
          value = 0_u64
          8.times do |index|
            value |= bytes[(offset + index.to_u64).to_i].to_u64 << (index * 8)
          end
          sizes << value
        end
        sizes_by_mark << sizes
      end
      StorageArrayOccurrenceFrame.for_read(array_level, physical_rows, parent_rows, sizes_by_mark, codec_budget)
    end

    private def validate_complete_schedules!(budget : BinaryCodecBudget) : Nil
      expected_array_keys = [] of String
      @plan.array_site_count.times do |index|
        site = @plan.array_site_at(index)
        expected_array_keys << site.key
        frame = @array_frames[site.key]? || raise(CorruptPartError.new("recursive Array site is missing its complete occurrence frame"))
        unless (@array_size_names[site.key]? == site.size_name) && frame.array_level == site.array_level &&
               frame.mark_count == @mark_count
          raise CorruptPartError.new("recursive Array occurrence frame differs from its physical plan")
        end
        frame.parent_grid.validate_for!(@mark_count, budget)
        frame.child_grid.validate_for!(@mark_count, budget)
        parent_rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive Array site has no inherited occurrence schedule"))
        unless parent_rows.size == @mark_count
          raise CorruptPartError.new("recursive Array inherited schedule differs from the complete mark grid")
        end
        @mark_count.times do |mark|
          unless frame.physical_rows_at(mark) == @mark_row_counts[mark] &&
                 frame.parent_count_at(mark) == parent_rows[mark]
            raise CorruptPartError.new("recursive Array occurrence frame differs from its complete parent grid")
          end
        end
      end
      unless @array_frames.keys.sort! == expected_array_keys.sort!
        raise CorruptPartError.new("recursive Array frame roster differs from its schema sites")
      end
      unless @array_size_names.keys.sort! == expected_array_keys.sort!
        raise CorruptPartError.new("recursive Array size-lane roster differs from its schema sites")
      end

      expected_object_keys = [] of String
      @plan.object_site_count.times do |index|
        site = @plan.object_site_at(index)
        expected_object_keys << site.key
        grid = @object_domain_grids[site.key]? || raise(CorruptPartError.new("recursive Object site has no occurrence grid"))
        grid.validate_for!(@mark_count, budget)
        rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive Object site has no logical row schedule"))
        unless rows.size == @mark_count
          raise CorruptPartError.new("recursive Object site schedule differs from the complete mark grid")
        end
        @mark_count.times do |mark|
          unless grid.physical_rows_at(mark) == @mark_row_counts[mark] &&
                 grid.logical_occurrences_at(mark) == rows[mark]
            raise CorruptPartError.new("recursive Object site grid differs from its complete inherited schedule")
          end
        end
      end
      unless @object_domain_grids.keys.sort! == expected_object_keys.sort!
        raise CorruptPartError.new("recursive Object occurrence-grid roster differs from its schema sites")
      end

      expected_bulk_keys = [] of String
      @plan.bulk_site_count.times do |index|
        site = @plan.bulk_site_at(index)
        expected_bulk_keys << site.key
        grid_set = @bulk_grids[site.key]? || raise(CorruptPartError.new("recursive BinaryBulk site has no inspected grid"))
        rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive BinaryBulk site has no logical row schedule"))
        unless rows.size == @mark_count && grid_set.grids.size == site.physical.stream_names.size
          raise CorruptPartError.new("recursive BinaryBulk site roster differs from its complete schema")
        end
        grid_set.grids.each do |_role, grid|
          unless grid.mark_count == @mark_count && grid.rows_per_mark == @mark_row_counts
            raise CorruptPartError.new("recursive BinaryBulk physical grid differs from the root mark schedule")
          end
        end
      end
      unless @bulk_grids.keys.sort! == expected_bulk_keys.sort!
        raise CorruptPartError.new("recursive BinaryBulk grid roster differs from its schema sites")
      end

      expected_dynamic_keys = [] of String
      @plan.dynamic_site_count.times do |index|
        site = @plan.dynamic_site_at(index)
        expected_dynamic_keys << site.key
        reader = @dynamic_readers[site.key]? || raise(CorruptPartError.new("recursive Dynamic site has no discovered physical reader"))
        reader.validate_complete_schedule!(budget)
        unless reader.mark_count == @mark_count && reader.mark_row_counts == @mark_row_counts
          raise CorruptPartError.new("recursive Dynamic P grid differs from the complete root mark schedule")
        end
        rows = @site_domain_rows[site.key]? || raise(CorruptPartError.new("recursive Dynamic site has no logical row schedule"))
        unless rows.size == @mark_count
          raise CorruptPartError.new("recursive Dynamic Q schedule differs from the complete mark grid")
        end
        @mark_count.times do |mark|
          unless reader.logical_occurrences_at(mark) == rows[mark]
            raise CorruptPartError.new("recursive Dynamic Q grid differs from its inherited occurrence schedule")
          end
        end
      end
      unless @dynamic_readers.keys.sort! == expected_dynamic_keys.sort!
        raise CorruptPartError.new("recursive Dynamic reader roster differs from its schema sites")
      end
      nil
    end

    private def selected_site_rows(key : String, first_mark : Int, mark_count : Int) : Array(UInt64)
      rows = @site_domain_rows[key]? || raise(CorruptPartError.new("recursive site has no logical occurrence schedule"))
      Array(UInt64).new(mark_count) { |index| rows[first_mark + index] }
    end

    private def validate_same_physical_rows!(grid : CompressedMarkGrid, rows : Array(UInt64), owner : String) : Nil
      unless grid.mark_count == rows.size && grid.rows_per_mark == rows
        raise CorruptPartError.new("#{owner} does not share the complete recursive root physical mark grid")
      end
      nil
    end

    private def validate_assembled_array_cursors!(
      mark : Int,
      parent_cursors : Hash(String, Int32),
      child_cursors : Hash(String, Int32),
    ) : Nil
      @array_frames.each do |key, frame|
        expected_parents = frame.parent_count_at(mark)
        expected_children = frame.child_count_at(mark)
        actual_parents = parent_cursors[key]?.try(&.to_u64) || 0_u64
        actual_children = child_cursors[key]?.try(&.to_u64) || 0_u64
        unless actual_parents == expected_parents && actual_children == expected_children
          raise CorruptPartError.new("recursive Array reconstruction differs from its complete occurrence frame")
        end
      end
      nil
    end

    private def add_storage_shapes(left : StorageValueShape, right : StorageValueShape) : StorageValueShape
      StorageValueShape.new(
        checked_add_shape_count(left.nodes, right.nodes, "recursive value nodes"),
        checked_add_shape_count(left.tuple_cells, right.tuple_cells, "Tuple cell count"),
        checked_add_shape_count(left.elements, right.elements, "recursive element count"),
        checked_add_shape_count(left.bytes, right.bytes, "recursive value owner bytes"),
      )
    end

    private def validate_object_descriptors!(descriptors : Hash(String, ObjectDocumentFileDescriptor)) : Nil
      expected_keys = [] of String
      @plan.object_site_count.times do |index|
        site = @plan.object_site_at(index)
        expected_keys << site.key
        descriptor = descriptors[site.key]? || raise(CorruptPartError.new("recursive Object site is missing its metadata descriptor"))
        expected_names = site.physical.stream_names.sort!
        actual_names = descriptor.physical_stream_names.sort!
        unless actual_names == expected_names
          raise CorruptPartError.new("recursive Object site stream roster differs from its physical plan")
        end
        expected_files = checksum_names_for(expected_names)
        actual_files = descriptor.selected_checksum_names.sort!
        unless actual_files == expected_files
          raise CorruptPartError.new("recursive Object site checksum roster differs from its physical plan")
        end
      end
      unless descriptors.keys.sort! == expected_keys.sort!
        raise CorruptPartError.new("recursive Object descriptor roster differs from its schema sites")
      end
      nil
    end

    private def assemble_value(
      schema : StorageColumnSchema,
      key : String,
      row_index : Int32,
      parent_mark : Int,
      object_rows : Hash(String, Array(ObjectDocument)),
      bulk_rows : Hash(String, Array(BinaryValue)),
      array_parent_cursors : Hash(String, Int32),
      array_child_cursors : Hash(String, Int32),
    ) : StorageColumnValue
      if schema.object?
        docs = object_rows[key]? || raise(CorruptPartError.new("recursive Object row has no structural site"))
        document = docs[row_index]? || raise(CorruptPartError.new("recursive Object site is missing a parent row"))
        return StorageColumnValue.object_document(document)
      end
      if schema.bulk?
        values = bulk_rows[key]? || raise(CorruptPartError.new("recursive BinaryBulk row has no structural site"))
        value = values[row_index]? || raise(CorruptPartError.new("recursive BinaryBulk site is missing a parent row"))
        return StorageColumnValue.bulk(value)
      end
      if schema.array?
        frame = @array_frames[key]? || raise(CorruptPartError.new("recursive Array row has no occurrence frame"))
        expected_parent_index = array_parent_cursors[key]?.try(&.to_i64) || 0_i64
        unless expected_parent_index == row_index.to_i64
          raise CorruptPartError.new("recursive Array parent occurrences are not assembled in source order")
        end
        size = frame.size_at(parent_mark, row_index)
        if size > Int32::MAX.to_u64
          raise CorruptPartError.new("recursive Array child count exceeds the supported row domain")
        end
        child_start = array_child_cursors[key]?.try(&.to_i64) || 0_i64
        child_end = child_start + size.to_i64
        if child_end > Int32::MAX
          raise CorruptPartError.new("recursive Array child cursor exceeds the supported row domain")
        end
        array_parent_cursors[key] = (expected_parent_index + 1_i64).to_i32
        array_child_cursors[key] = child_end.to_i32
        child_key = array_child_key(key)
        children = Array(StorageColumnValue).new(size.to_i)
        size.to_i.times do |child_index|
          children << assemble_value(
            schema.child_at(0),
            child_key,
            (child_start + child_index).to_i32,
            parent_mark,
            object_rows,
            bulk_rows,
            array_parent_cursors,
            array_child_cursors,
          )
        end
        return StorageColumnValue.array(children)
      end
      unless schema.tuple?
        raise CorruptPartError.new("recursive Tuple schema contains an unknown structural node")
      end
      children = Array(StorageColumnValue).new(schema.child_count)
      schema.child_count.times do |index|
        child_key = tuple_child_key(key, index)
        children << assemble_value(
          schema.child_at(index),
          child_key,
          row_index,
          parent_mark,
          object_rows,
          bulk_rows,
          array_parent_cursors,
          array_child_cursors,
        )
      end
      StorageColumnValue.tuple(children)
    end

    private def validate_parent_schedule!(rows : Array(UInt64), expected_total : UInt64) : Nil
      total = 0_u64
      rows.each do |count|
        if count > Int32::MAX.to_u64 || total > UInt64::MAX - count
          raise CorruptPartError.new("recursive Tuple parent mark schedule exceeds its supported domain")
        end
        total += count
      end
      unless total == expected_total
        raise CorruptPartError.new("count.txt disagrees with the recursive Tuple parent mark grid")
      end
      nil
    end

    private def tuple_child_key(key : String, index : Int) : String
      String.build { |io| io << key << "/tuple[" << index << ']' }
    end

    private def array_child_key(key : String) : String
      String.build { |io| io << key << "/array[0]" }
    end

    private def array_size_name(prefix : String, array_level : UInt64) : String
      suffix = String.build { |io| io << ".size" << array_level }
      PhysicalStreamName.append_literal(prefix, suffix)
    end

    private def checksum_data_name(logical_name : String) : String
      PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".bin")
    end

    private def checksum_marks_name(logical_name : String) : String
      PhysicalStreamName.append_literal(StreamName.hash(logical_name), ".mrk2")
    end

    private def logical_bytes(
      descriptors : Hash(String, ObjectDocumentFileDescriptor),
      grids : Hash(String, BulkGridSet),
      dynamic_readers : Hash(String, DynamicBulkSiteReader),
      array_frames : Hash(String, StorageArrayOccurrenceFrame),
    ) : UInt64
      total = 0_u64
      descriptors.each_value do |descriptor|
        total = checked_add_u64(total, descriptor.logical_read_bytes)
      end
      grids.each_value do |grid_set|
        grid_set.grids.each_value do |grid|
          total = checked_add_u64(total, grid.logical_size.to_u64)
        end
      end
      dynamic_readers.each_value do |reader|
        total = checked_add_u64(total, reader.logical_read_bytes)
      end
      array_frames.each_value do |frame|
        total = checked_add_u64(total, frame.size_stream.byte_size.to_u64)
      end
      total
    end

    private def selected_mark_rows(first_mark : Int, mark_count : Int) : Array(UInt64)
      Array(UInt64).new(mark_count) { |index| @mark_row_counts[first_mark + index] }
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      marks = @mark_count.to_i128
      if first < 0 || count < 0 || first > marks || count > marks - first
        raise ArgumentError.new("recursive Tuple mark selection is outside the complete parent grid")
      end
      nil
    end

    private def checksum_names_for(logical_names : Array(String)) : Array(String)
      files = [] of String
      logical_names.each do |name|
        base = StreamName.hash(name)
        files << PhysicalStreamName.append_literal(base, ".bin")
        files << PhysicalStreamName.append_literal(base, ".mrk2")
      end
      files.sort!
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end

    private def limits_for_schema(schema : StorageColumnSchema) : BinaryCodecLimits
      limits = nil.as(BinaryCodecLimits?)
      schema.each_json_site do |_key, object_schema|
        current = object_schema.limits
        if selected = limits
          unless same_limits?(selected, current)
            raise ArgumentError.new("recursive Object site limits must match")
          end
        else
          limits = current
        end
      end
      limits || BinaryBulkCodec::DEFAULT_LIMITS
    end

    private def validate_json_site_limits!(schema : StorageColumnSchema, limits : BinaryCodecLimits) : Nil
      schema.each_json_site do |_key, object_schema|
        unless same_limits?(object_schema.limits, limits)
          raise ArgumentError.new("recursive Object site limits must match the operation limits")
        end
      end
      nil
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def checked_add_u64(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("recursive Tuple logical byte count overflows UInt64")
      end
      left + right
    end
  end
end
