module CrystalClick
  # Reads the first persisted recursive Tuple profile. Each JSON leaf remains
  # an Object site with its own discovered structure plan; JSON-free leaves
  # remain BinaryBulk sites. All sites share the Tuple parent's physical mark
  # grid, codec budget, name context, and transport operation.
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
      @schema = expected_schema
      @limits = limits_for_schema(expected_schema)
      # Reparse public factory descriptors before they can select metadata,
      # physical prefixes, or codec sites.
      begin
        expected_schema.validate_source_tree!(@limits)
      rescue ex : ArgumentError
        raise ArgumentError.new(ex.message || "recursive schema differs from its source declaration")
      end
      unless expected_schema.tuple? && expected_schema.has_json?
        raise UnsupportedFormatError.new("recursive storage requires a root Tuple with a JSON leaf")
      end
      validate_json_site_limits!(expected_schema, @limits)

      raise ArgumentError.new("recursive storage column name must not be empty") if column_name.empty?
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      @transport_limits = CompressedStreamLimits.new

      selected_declaration = WidePart.selected_recursive_json_declaration(@part_path, @column_name) ||
                             raise(UnsupportedFormatError.new("selected column is not an admitted recursive Tuple JSON declaration"))

      metadata = ObjectColumnPartMetadata.open(
        @part_path,
        @column_name,
        ->(declaration : String) {
          unless declaration == selected_declaration
            raise CorruptPartError.new("selected recursive Tuple declaration changed during metadata inspection")
          end
          source_schema = StorageColumnSchema.parse(declaration, @limits)
          unless source_schema.tuple? && source_schema.has_json? &&
                 source_schema.declaration == expected_schema.declaration
            raise CorruptPartError.new("part recursive Tuple declaration differs from the expected schema")
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
      parent_rows = nil.as(Array(UInt64)?)

      root_prefix = PhysicalStreamName.escape(@column_name, name_context)
      parent_rows = inspect_object_sites(
        expected_schema,
        root_prefix,
        "root",
        parent_rows,
        descriptors,
        object_plans,
        codec_budget,
        name_context,
        transport_budget,
      )

      rows = parent_rows || raise(CorruptPartError.new("recursive Tuple schema has no inspected Object site"))
      validate_parent_schedule!(rows, metadata.row_count)

      @plan = RecursiveStorageColumnPlan.for_column(
        @column_name,
        expected_schema,
        object_plans,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        ObjectDocumentCodec::DEFAULT_MODE,
        4096,
        @limits,
        @transport_limits,
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
          validate_same_parent_rows!(grid, rows, "BinaryBulk site #{site.key}")
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
      @mark_row_counts = rows.dup
      @row_count = metadata.row_count
      @mark_count = rows.size.to_i32
      @physical_stream_names = @plan.physical_stream_names
      @selected_checksum_names = @plan.file_names
      @logical_read_bytes = logical_bytes(descriptors, bulk_grids)
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

    # Returns selected physical parent marks -> rows -> recursive Tuple
    # values. LC-bearing leaves replay their complete state before this window
    # is assembled; the complete parent grid was already checked at open.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(StorageColumnValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = BinaryCodecBudget.new(@limits)
      charge_selected_value_shape!(first_mark, mark_count, codec_budget)
      transport_budget = CompressedStreamBudget.new(@transport_limits)
      name_context = PhysicalStreamPlanContext.new(@limits)

      object_rows = Hash(String, Array(Array(ObjectDocument))).new
      @plan.object_site_count.times do |site_index|
        site = @plan.object_site_at(site_index)
        selected = ObjectDocumentFileReader.read_at_site(
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
        unless selected.size == mark_count
          raise CorruptPartError.new("bounded recursive Object read returned the wrong mark count")
        end
        selected.each_with_index do |mark_rows, index|
          unless mark_rows.size.to_u64 == @mark_row_counts[first_mark + index]
            raise CorruptPartError.new("bounded recursive Object read returned the wrong parent row count")
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
        rows_for_decode = replay_complete ? @mark_row_counts : selected_mark_rows(first_mark, mark_count)
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
          expected_window_rows = replay_complete ? @mark_row_counts : rows_for_decode
          unless window.rows_per_mark == expected_window_rows
            raise CorruptPartError.new("recursive BinaryBulk selected row grid differs from its complete parent schedule")
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
          unless mark_values.size.to_u64 == @mark_row_counts[first_mark + index]
            raise CorruptPartError.new("bounded recursive BinaryBulk read returned the wrong parent row count")
          end
        end
        bulk_rows[String.new(site.key.to_slice)] = decoded
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
        parent_count.to_i.times do |row_index|
          value = assemble_value(@schema, "root", row_index, mark_object_rows, mark_bulk_rows)
          StorageColumnDepthGuard.validate(value, @limits, false)
          row_values << value
        end
        result << row_values
      end
      result
    end

    # Reserve the logical Tuple/leaf owners before any site decoder allocates
    # its values. Object and BinaryBulk codecs account their own decoded trees;
    # these are the additional StorageColumnValue wrappers assembled around
    # those leaves. LC replay still decodes its full dictionary domain, but
    # only selected parent rows produce returned StorageColumnValue wrappers.
    private def charge_selected_value_shape!(
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : Nil
      nodes_per_row, edges_per_row = storage_value_shape(@schema)
      selected_rows = 0_u64
      mark_count.times do |index|
        selected_rows = checked_add_shape_count(
          selected_rows,
          @mark_row_counts[first_mark + index],
          "selected parent row count",
        )
      end
      nodes = checked_multiply_shape_count(selected_rows, nodes_per_row, "StorageColumnValue node count")
      edges = checked_multiply_shape_count(selected_rows, edges_per_row, "StorageColumnValue edge count")

      # Preflight both dimensions before mutating the shared budget, then
      # reserve elements and nodes. charge_node is intentionally repeated
      # only after ensure_future_nodes bounds the count by max_nodes.
      budget.ensure_future_nodes(nodes)
      budget.ensure_future_elements(edges)
      budget.charge_elements(edges) if edges > 0_u64
      remaining_nodes = nodes
      while remaining_nodes > 0_u64
        budget.charge_node
        remaining_nodes -= 1_u64
      end
      nil
    end

    private def storage_value_shape(schema : StorageColumnSchema) : Tuple(UInt64, UInt64)
      nodes = 1_u64
      edges = 0_u64
      return {nodes, edges} unless schema.tuple?

      schema.child_count.times do |index|
        child_nodes, child_edges = storage_value_shape(schema.child_at(index))
        nodes = checked_add_shape_count(nodes, child_nodes, "StorageColumnValue schema node count")
        edges = checked_add_shape_count(edges, child_edges, "StorageColumnValue schema edge count")
        edges = checked_add_shape_count(edges, 1_u64, "StorageColumnValue schema edge count")
      end
      {nodes, edges}
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

    private def inspect_object_sites(
      schema : StorageColumnSchema,
      prefix : String,
      key : String,
      expected_rows : Array(UInt64)?,
      descriptors : Hash(String, ObjectDocumentFileDescriptor),
      plans : Hash(String, ObjectDocumentPlan),
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
    ) : Array(UInt64)?
      if object_schema = schema.object_schema_or_nil
        descriptor = ObjectDocumentFileReader.inspect_at_site(
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
          expected_rows,
        )
        begin
          object_schema.validate_plan(descriptor.plan)
        rescue ex : ArgumentError
          raise CorruptPartError.new(ex.message || "recursive Object site differs from its schema")
        end
        rows = descriptor.mark_row_counts
        if expected = expected_rows
          unless rows == expected
            raise CorruptPartError.new("recursive Object sites do not share one parent mark grid")
          end
        end
        descriptors[String.new(key.to_slice)] = descriptor
        plans[String.new(key.to_slice)] = descriptor.plan
        return rows
      end

      return expected_rows unless schema.tuple?
      site_rows = expected_rows
      schema.child_count.times do |index|
        raw_field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
        child_prefix = PhysicalStreamName.append_escaped_field(prefix, raw_field, name_context)
        child_key = String.build { |io| io << key << "/tuple[" << index << ']' }
        child_rows = inspect_object_sites(
          schema.child_at(index),
          child_prefix,
          child_key,
          site_rows,
          descriptors,
          plans,
          codec_budget,
          name_context,
          transport_budget,
        )
        if rows = child_rows
          if expected = site_rows
            unless rows == expected
              raise CorruptPartError.new("recursive Object sites do not share one parent mark grid")
            end
          else
            site_rows = rows
          end
        end
      end
      site_rows
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
      object_rows : Hash(String, Array(ObjectDocument)),
      bulk_rows : Hash(String, Array(BinaryValue)),
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
      unless schema.tuple?
        raise CorruptPartError.new("recursive Tuple schema contains an unknown structural node")
      end
      children = Array(StorageColumnValue).new(schema.child_count)
      schema.child_count.times do |index|
        child_key = String.build { |io| io << key << "/tuple[" << index << ']' }
        children << assemble_value(schema.child_at(index), child_key, row_index, object_rows, bulk_rows)
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

    private def validate_same_parent_rows!(grid : CompressedMarkGrid, rows : Array(UInt64), owner : String) : Nil
      unless grid.rows_per_mark == rows
        raise CorruptPartError.new("#{owner} does not share the complete recursive Tuple parent mark grid")
      end
      nil
    end

    private def logical_bytes(
      descriptors : Hash(String, ObjectDocumentFileDescriptor),
      grids : Hash(String, BulkGridSet),
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
