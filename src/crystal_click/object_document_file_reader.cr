module CrystalClick
  # Reads one normalized Wide/SUFFIX Object V3 part into selected logical
  # document granules. Metadata and every physical mark grid are discovered
  # from the supplied part; no fixture roster or filename fallback is used.
  class ObjectDocumentFileReader
    private struct BulkBinding
      getter kind : Symbol
      getter path : String
      getter arm : String
      getter role : String
      getter data_name : String
      getter marks_name : String
      getter prefix_size : Int32

      def initialize(
        @kind : Symbol,
        @path : String,
        @arm : String,
        @role : String,
        @data_name : String,
        @marks_name : String,
        @prefix_size : Int32,
      )
      end
    end

    private struct DiscriminatorBinding
      getter path : String
      getter data_name : String
      getter marks_name : String

      def initialize(@path : String, @data_name : String, @marks_name : String)
      end
    end

    private struct PreparedRead
      getter source : PartStreamSource
      getter schema_snapshot : Hash(String, BinaryDataType)
      getter object_bytes : Bytes
      getter dynamic_bytes : Hash(String, Bytes)
      getter outer_rows : Array(UInt64)
      getter first_mark : Int32
      getter selected_count : Int32
      getter profile : BinaryBulkProfile
      getter shared_profile : BinaryBulkProfile
      getter bulk_bindings : Array(BulkBinding)
      getter discriminator_bindings : Array(DiscriminatorBinding)
      getter codec_budget : BinaryCodecBudget
      getter transport_budget : CompressedStreamBudget
      getter descriptor : ObjectDocumentFileDescriptor?
      getter replay_complete : Bool

      def initialize(
        @source : PartStreamSource,
        @schema_snapshot : Hash(String, BinaryDataType),
        @object_bytes : Bytes,
        @dynamic_bytes : Hash(String, Bytes),
        @outer_rows : Array(UInt64),
        @first_mark : Int32,
        @selected_count : Int32,
        @profile : BinaryBulkProfile,
        @shared_profile : BinaryBulkProfile,
        @bulk_bindings : Array(BulkBinding),
        @discriminator_bindings : Array(DiscriminatorBinding),
        @codec_budget : BinaryCodecBudget,
        @transport_budget : CompressedStreamBudget,
        @descriptor : ObjectDocumentFileDescriptor?,
        @replay_complete : Bool,
      )
      end
    end

    # Inspect all Object metadata and all physical grids without reading any
    # selected value windows. The typed schema and profiles remain explicit in
    # this low-level API; ObjectColumnReader binds them from part metadata.
    def self.inspect(
      part_path : String,
      column_name : String,
      typed_schema : Hash(String, BinaryDataType),
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : ObjectDocumentFileDescriptor
      prepared = prepare_read(
        part_path,
        column_name,
        typed_schema,
        0,
        0,
        profile,
        shared_profile,
        hashed,
        limits,
        transport_limits,
        true,
      )
      prepared.descriptor.not_nil!
    end

    def self.read(
      part_path : String,
      column_name : String,
      typed_schema : Hash(String, BinaryDataType),
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : Array(Array(ObjectDocument))
      prepared = prepare_read(
        part_path,
        column_name,
        typed_schema,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        hashed,
        limits,
        transport_limits,
        false,
      )
      read_prepared(prepared)
    end

    private def self.prepare_read(
      part_path : String,
      column_name : String,
      typed_schema : Hash(String, BinaryDataType),
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      hashed : Bool,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      build_descriptor : Bool,
    ) : PreparedRead
      validate_selection_arguments!(first_mark, mark_count)
      codec_budget = BinaryCodecBudget.new(limits)
      transport_budget = CompressedStreamBudget.new(transport_limits)
      column_prefix = preflight_column_name!(column_name, hashed, limits)
      schema_snapshot = preflight_and_copy_schema!(typed_schema, column_prefix, hashed, limits, codec_budget)
      replay_complete = schema_snapshot.each_value.any? do |type|
        BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
      end
      source = PartStreamSource.new(part_path)

      object_name = PhysicalStreamName.append_literal(column_prefix, ".object_structure")
      object_data_name, object_marks_name = file_pair(object_name, hashed)
      validate_physical_name!(object_data_name)
      validate_physical_name!(object_marks_name)
      object_grid = source.inspect_grid(object_data_name, object_marks_name, nil, transport_budget)
      charge_metadata_read!(object_grid, codec_budget)
      object_bytes = source.read_all(object_data_name, transport_budget)
      ensure_logical_size!(object_bytes, object_grid)
      object, object_statistics_offset = parse_object_metadata(object_bytes, limits, codec_budget)
      validate_layout!(object)
      validate_metadata_grid!(object_grid, object_statistics_offset, object_bytes.size)
      charge_source_roster!(object_grid, codec_budget)
      outer_rows = copy_outer_rows(object_grid)
      selected_count = validate_selection!(first_mark, mark_count, outer_rows.size)

      preflight_dynamic_metadata_names!(object, column_prefix, hashed, limits, codec_budget)
      dynamic_bytes = Hash(String, Bytes).new(initial_capacity: object.dynamic_path_count)
      dynamic_structures = Hash(String, DynamicStructure).new(initial_capacity: object.dynamic_path_count)
      object.dynamic_path_count.times do |index|
        raw_path = object.dynamic_path_at(index)
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path)
        logical_name = PhysicalStreamName.append_literal(path_prefix, ".dynamic_structure")
        data_name, marks_name = file_pair(logical_name, hashed)
        validate_physical_name!(data_name)
        validate_physical_name!(marks_name)
        grid = source.inspect_grid(data_name, marks_name, nil, transport_budget)
        validate_same_rows!(grid, outer_rows)
        charge_metadata_read!(grid, codec_budget)
        bytes = source.read_all(data_name, transport_budget)
        ensure_logical_size!(bytes, grid)
        dynamic, statistics_offset = parse_dynamic_metadata(bytes, limits, codec_budget)
        validate_metadata_grid!(grid, statistics_offset, bytes.size)
        dynamic_bytes[String.new(raw_path.to_slice)] = bytes
        dynamic_structures[String.new(raw_path.to_slice)] = dynamic
      end

      structure_set = ObjectDynamicStructureSet.new(object, dynamic_structures)
      document_plan = ObjectDocumentPlan.new(structure_set, schema_snapshot)
      physical_plan = ObjectDocumentPhysicalPlan.new(
        column_name,
        document_plan,
        profile,
        shared_profile,
        limits
      )

      bulk_bindings = collect_bulk_bindings(document_plan, physical_plan, hashed)
      discriminator_bindings = collect_discriminator_bindings(object, physical_plan, hashed)
      selected_wire_bytes = 0_u64
      logical_lane_bytes = 0_u64
      validate_all_value_grids!(
        source,
        bulk_bindings,
        discriminator_bindings,
        outer_rows,
        transport_budget
      ) do |grid, prefix|
        logical_lane_bytes = checked_add_u64(logical_lane_bytes, grid.logical_size.to_u64)
        unless build_descriptor
          first = replay_complete ? 0 : first_mark
          count = replay_complete ? outer_rows.size : selected_count
          selected_wire_bytes = checked_add_u64(
            selected_wire_bytes,
            selected_extent(grid, first, count, prefix)
          )
        end
      end

      metadata_size = metadata_total_size(object_bytes, dynamic_bytes)
      codec_budget.ensure_wire_bytes(checked_add_u64(metadata_size, selected_wire_bytes))

      logical_read_bytes = checked_add_u64(metadata_size, logical_lane_bytes)
      descriptor = nil.as(ObjectDocumentFileDescriptor?)
      if build_descriptor
        logical_names, checksum_names = descriptor_stream_names!(
          physical_plan,
          hashed,
          limits,
          codec_budget,
        )
        descriptor = ObjectDocumentFileDescriptor.new(
          document_plan,
          outer_rows,
          logical_names,
          checksum_names,
          logical_read_bytes,
        )
      end

      # Selection validation bounded both indices to outer_rows.size before narrowing.
      PreparedRead.new(
        source,
        schema_snapshot,
        object_bytes,
        dynamic_bytes,
        outer_rows,
        first_mark.to_i32,
        selected_count.to_i32,
        profile,
        shared_profile,
        bulk_bindings,
        discriminator_bindings,
        codec_budget,
        transport_budget,
        descriptor,
        replay_complete,
      )
    end

    private def self.read_prepared(prepared : PreparedRead) : Array(Array(ObjectDocument))
      source = prepared.source
      schema_snapshot = prepared.schema_snapshot
      object_bytes = prepared.object_bytes
      dynamic_bytes = prepared.dynamic_bytes
      outer_rows = prepared.outer_rows
      first_mark = prepared.first_mark
      selected_count = prepared.selected_count
      profile = prepared.profile
      shared_profile = prepared.shared_profile
      bulk_bindings = prepared.bulk_bindings
      discriminator_bindings = prepared.discriminator_bindings
      codec_budget = prepared.codec_budget
      transport_budget = prepared.transport_budget
      replay_complete = prepared.replay_complete
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? outer_rows.size : selected_count
      prefix_reads = [] of Tuple(String, Int32, Int32)
      bulk_bindings.each do |binding|
        next unless binding.kind == :typed &&
                    BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(binding.role, binding.prefix_size)
        if read_count == Int32::MAX
          raise CorruptPartError.new("Object Variant read coordinate count exceeds the supported domain")
        end
        prefix_reads << {binding.role, binding.prefix_size, read_count + 1}
      end
      BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

      typed_roles = Hash(String, Hash(String, BinaryBulkStream)).new
      dynamic_roles = Hash(String, Hash(String, Hash(String, BinaryBulkStream))).new
      shared_roles = Hash(String, BinaryBulkStream).new
      bulk_bindings.each do |binding|
        window = source.read_window(
          binding.data_name,
          binding.marks_name,
          read_first,
          read_count,
          binding.prefix_size,
          transport_budget
        )
        lane_bytes = window.bytes
        lane_offsets = window.offsets
        if binding.kind == :typed &&
           BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(binding.role, binding.prefix_size)
          logical = BinaryBulkPhysicalPrefixAdapter.read_lane(
            binding.role,
            lane_bytes,
            lane_offsets,
            binding.prefix_size
          )
          lane_bytes = logical[0]
          lane_offsets = logical[1]
        end
        stream = BinaryBulkStream.new(lane_bytes, lane_offsets)
        case binding.kind
        when :typed
          if roles = typed_roles[binding.path]?
            roles[binding.role] = stream
          else
            roles = Hash(String, BinaryBulkStream).new
            roles[binding.role] = stream
            typed_roles[binding.path] = roles
          end
        when :dynamic
          if arms = dynamic_roles[binding.path]?
            if role_streams = arms[binding.arm]?
              role_streams[binding.role] = stream
            else
              role_streams = Hash(String, BinaryBulkStream).new
              role_streams[binding.role] = stream
              arms[binding.arm] = role_streams
            end
          else
            role_streams = Hash(String, BinaryBulkStream).new
            role_streams[binding.role] = stream
            arms = Hash(String, Hash(String, BinaryBulkStream)).new
            arms[binding.arm] = role_streams
            dynamic_roles[binding.path] = arms
          end
        when :shared
          shared_roles[binding.role] = stream
        else
          raise CorruptPartError.new("unknown Object physical lane class")
        end
      end

      typed_streams = Hash(String, BinaryBulkStreams).new
      typed_roles.each { |path, roles| typed_streams[path] = BinaryBulkStreams.new(read_count, roles) }

      dynamic_streams = Hash(String, DynamicValueStreams).new
      discriminator_bindings.each do |binding|
        window = source.read_window(
          binding.data_name,
          binding.marks_name,
          read_first,
          read_count,
          DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
          transport_budget
        )
        discriminator = discriminator_stream(window)
        arms = Hash(String, BinaryBulkStreams).new
        if arm_roles = dynamic_roles[binding.path]?
          arm_roles.each do |arm, roles|
            arms[arm] = BinaryBulkStreams.new(read_count, roles)
          end
        end
        dynamic_streams[binding.path] = DynamicValueStreams.new(discriminator, arms)
      end

      shared_streams = BinaryBulkStreams.new(read_count, shared_roles)
      selected_rows = Array(UInt64).new(selected_count)
      selected_count.times do |index|
        selected_rows << outer_rows[first_mark + index]
      end
      stream_rows = replay_complete ? outer_rows : selected_rows
      streams = ObjectDocumentStreams.new(
        ObjectDynamicStructureStreams.new(object_bytes, dynamic_bytes),
        stream_rows,
        typed_streams,
        dynamic_streams,
        shared_streams
      )

      ObjectDocumentCodec.decode_with_budget(
        schema_snapshot,
        streams,
        codec_budget,
        first_mark: replay_complete ? first_mark : 0,
        mark_count: selected_count,
        profile: profile,
        shared_profile: shared_profile
      )
    end

    private def self.validate_selection_arguments!(first_mark : Int, mark_count : Int?) : Nil
      raise ArgumentError.new("first mark must be nonnegative") if first_mark < 0
      if count = mark_count
        raise ArgumentError.new("mark count must be nonnegative") if count < 0
      end
      nil
    end

    private def self.validate_selection!(first_mark : Int, mark_count : Int?, total_marks : Int) : Int
      raise ArgumentError.new("first mark is outside the Object grid") if first_mark > total_marks
      selected = mark_count || (total_marks - first_mark)
      if selected > total_marks - first_mark
        raise ArgumentError.new("mark selection is outside the Object grid")
      end
      selected
    end

    private def self.preflight_column_name!(column_name : String, hashed : Bool, limits : BinaryCodecLimits) : String
      escaped_size = PhysicalStreamName.escaped_size(column_name)
      ensure_name_size!(escaped_size, limits)
      object_marks_size = checked_add_u64(escaped_size, ".object_structure.mrk2".bytesize.to_u64)
      ensure_name_size!(object_marks_size, limits)
      ensure_unhashed_name_size!(object_marks_size, hashed)
      PhysicalStreamName.escape(column_name)
    end

    private def self.preflight_and_copy_schema!(
      schema : Hash(String, BinaryDataType),
      column_prefix : String,
      hashed : Bool,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryDataType)
      count = schema.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      context = BinaryCodecContext.new(limits, nil, false, budget, false, false)
      expanded_total = 0_u64
      schema.each do |path, type|
        escaped_size = PhysicalStreamName.escaped_size(path)
        logical_size = checked_add_u64(column_prefix.bytesize.to_u64, checked_add_u64(1_u64, escaped_size))
        ensure_name_size!(logical_size, limits)
        marks_size = checked_add_u64(logical_size, ".mrk2".bytesize.to_u64)
        ensure_name_size!(marks_size, limits)
        ensure_unhashed_name_size!(marks_size, hashed)
        expanded_total = checked_add_u64(expanded_total, logical_size)
        ensure_name_size!(expanded_total, limits)
        context.validate_type_tree(type)
        if type.contains_variant? && ObjectRecursiveDeclaration.measure_descriptor(type, limits, 2).nil?
          raise UnsupportedFormatError.new("Object typed Variant descriptor is outside the admitted declaration grammar")
        end
      end
      copied = Hash(String, BinaryDataType).new(initial_capacity: schema.size)
      schema.each { |path, type| copied[String.new(path.to_slice)] = type }
      copied
    end

    private def self.preflight_dynamic_metadata_names!(
      object : ObjectStructure,
      column_prefix : String,
      hashed : Bool,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Nil
      count = object.dynamic_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      total = 0_u64
      object.dynamic_path_count.times do |index|
        raw_size = object.dynamic_path_byte_size(index)
        escaped_size = PhysicalStreamName.escaped_size(raw_size) do |byte_index|
          object.dynamic_path_byte_at(index, byte_index)
        end
        logical_size = checked_add_u64(column_prefix.bytesize.to_u64, checked_add_u64(1_u64, escaped_size))
        full_size = checked_add_u64(logical_size, ".dynamic_structure.mrk2".bytesize.to_u64)
        ensure_name_size!(full_size, limits)
        ensure_unhashed_name_size!(full_size, hashed)
        total = checked_add_u64(total, full_size)
        ensure_name_size!(total, limits)
      end
      nil
    end

    private def self.parse_object_metadata(
      bytes : Bytes,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Tuple(ObjectStructure, Int32)
      context = BinaryCodecContext.new(limits, bytes, false, budget, false, false)
      structure, statistics_offset = ObjectStructureCodec.read_with_statistics_offset(context)
      context.ensure_consumed
      {structure, statistics_offset}
    end

    private def self.parse_dynamic_metadata(
      bytes : Bytes,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Tuple(DynamicStructure, Int32)
      context = BinaryCodecContext.new(limits, bytes, false, budget, false, false)
      structure, statistics_offset = DynamicStructureCodec.read_with_statistics_offset(context)
      context.ensure_consumed
      {structure, statistics_offset}
    end

    private def self.validate_layout!(object : ObjectStructure) : Nil
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("file reader admits only Object V3 wire 4 with MAP 0 and one bucket")
      end
      nil
    end

    private def self.validate_metadata_grid!(grid : CompressedMarkGrid, statistics_offset : Int32, byte_size : Int) : Nil
      unless grid.logical_size == byte_size.to_i64 && grid.prefix_size == statistics_offset
        raise CorruptPartError.new("metadata mark prefix or logical EOF disagrees with its suffix boundary")
      end
      grid.mark_count.times do |index|
        unless grid.position_at(index) == statistics_offset.to_i64
          raise CorruptPartError.new("metadata real marks disagree with the before-statistics boundary")
        end
      end
      unless grid.position_at(grid.mark_count) == grid.logical_size
        raise CorruptPartError.new("metadata terminal mark does not name complete logical EOF")
      end
      nil
    end

    private def self.copy_outer_rows(grid : CompressedMarkGrid) : Array(UInt64)
      rows = Array(UInt64).new(grid.mark_count)
      grid.mark_count.times { |index| rows << grid.row_count_at(index) }
      rows
    end

    # The source K is a logical outer roster even when the caller selects a
    # smaller local window (or no marks). Admit and charge it before copying
    # any K-sized reader collection; W123 separately charges its selected-K
    # reparse/composition work later.
    private def self.charge_source_roster!(grid : CompressedMarkGrid, budget : BinaryCodecBudget) : Nil
      count = grid.mark_count.to_u64
      return nil if count == 0_u64

      budget.preflight_children(count)
      grid.mark_count.times { budget.charge_node }
      nil
    end

    private def self.validate_same_rows!(grid : CompressedMarkGrid, outer_rows : Array(UInt64)) : Nil
      unless grid.mark_count == outer_rows.size
        raise CorruptPartError.new("physical lane mark count does not match the Object outer grid")
      end
      outer_rows.size.times do |index|
        unless grid.row_count_at(index) == outer_rows[index]
          raise CorruptPartError.new("physical lane row grid does not match the Object outer grid")
        end
      end
      nil
    end

    private def self.ensure_logical_size!(bytes : Bytes, grid : CompressedMarkGrid) : Nil
      unless bytes.size.to_i64 == grid.logical_size
        raise CorruptPartError.new("decoded metadata size disagrees with its inspected logical EOF")
      end
      nil
    end

    private def self.charge_metadata_read!(grid : CompressedMarkGrid, budget : BinaryCodecBudget) : Nil
      if grid.logical_size < 0
        raise CorruptPartError.new("metadata logical size is negative")
      end
      budget.charge_wire_bytes(grid.logical_size.to_u64)
      nil
    end

    private def self.collect_bulk_bindings(
      plan : ObjectDocumentPlan,
      physical : ObjectDocumentPhysicalPlan,
      hashed : Bool,
    ) : Array(BulkBinding)
      bindings = [] of BulkBinding
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        append_bulk_bindings!(bindings, :typed, path, "", physical.typed(path), hashed)
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        dynamic = plan.structures.dynamic_for(path)
        dynamic.canonical_variant_names.each do |arm|
          append_bulk_bindings!(bindings, :dynamic, path, arm, physical.dynamic_arm(path, arm), hashed)
        end
      end
      append_bulk_bindings!(bindings, :shared, "", "", physical.shared, hashed)
      bindings
    end

    private def self.append_bulk_bindings!(
      bindings : Array(BulkBinding),
      kind : Symbol,
      path : String,
      arm : String,
      physical : BinaryBulkPhysicalPlan,
      hashed : Bool,
    ) : Nil
      physical.stream_names.each_key do |role|
        prefix_size = physical.prefix_size_for(role)
        data_name = physical.data_file_for(role, hashed)
        marks_name = physical.marks_file_for(role, hashed)
        validate_physical_name!(data_name)
        validate_physical_name!(marks_name)
        bindings << BulkBinding.new(
          kind,
          String.new(path.to_slice),
          String.new(arm.to_slice),
          String.new(role.to_slice),
          data_name,
          marks_name,
          prefix_size
        )
      end
      nil
    end

    private def self.collect_discriminator_bindings(
      object : ObjectStructure,
      physical : ObjectDocumentPhysicalPlan,
      hashed : Bool,
    ) : Array(DiscriminatorBinding)
      bindings = [] of DiscriminatorBinding
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        logical = physical.discriminator_stream(path)
        data_name, marks_name = file_pair(logical, hashed)
        validate_physical_name!(data_name)
        validate_physical_name!(marks_name)
        bindings << DiscriminatorBinding.new(String.new(path.to_slice), data_name, marks_name)
      end
      bindings
    end

    private def self.validate_all_value_grids!(
      source : PartStreamSource,
      bulk_bindings : Array(BulkBinding),
      discriminator_bindings : Array(DiscriminatorBinding),
      outer_rows : Array(UInt64),
      budget : CompressedStreamBudget,
      &block : CompressedMarkGrid, Int32 ->
    ) : Nil
      bulk_bindings.each do |binding|
        grid = source.inspect_grid(binding.data_name, binding.marks_name, binding.prefix_size, budget)
        validate_same_rows!(grid, outer_rows)
        yield grid, binding.prefix_size
      end
      discriminator_bindings.each do |binding|
        grid = source.inspect_grid(
          binding.data_name,
          binding.marks_name,
          DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
          budget
        )
        validate_same_rows!(grid, outer_rows)
        yield grid, DynamicDiscriminatorCodec::HEADER_BYTES.to_i
      end
      nil
    end

    private def self.selected_extent(grid : CompressedMarkGrid, first_mark : Int, count : Int, prefix : Int) : UInt64
      start = grid.position_at(first_mark)
      finish = grid.position_at(first_mark + count)
      if finish < start
        raise CorruptPartError.new("selected physical lane positions are not monotone")
      end
      checked_add_u64((finish - start).to_u64, prefix.to_u64)
    end

    private def self.discriminator_stream(window : CompressedMarkWindow) : DynamicDiscriminatorStream
      bytes = window.bytes
      offsets = window.offsets
      rows = window.rows_per_mark
      unless window.prefix_size == DynamicDiscriminatorCodec::HEADER_BYTES &&
             offsets.size == rows.size + 1 && offsets.first? == DynamicDiscriminatorCodec::HEADER_BYTES &&
             offsets.last? == bytes.size.to_u64
        raise CorruptPartError.new("selected discriminator window has inconsistent coordinates")
      end
      previous = DynamicDiscriminatorCodec::HEADER_BYTES
      offsets.each do |offset|
        if offset < previous || offset > bytes.size.to_u64
          raise CorruptPartError.new("selected discriminator offsets are not monotone within its bytes")
        end
        previous = offset
      end
      marks = Array(DynamicDiscriminatorMark).new(rows.size + 1)
      rows.size.times do |index|
        marks << DynamicDiscriminatorMark.new(offsets[index], rows[index])
      end
      marks << DynamicDiscriminatorMark.new(offsets.last, 0_u64)
      DynamicDiscriminatorStream.new(bytes, marks)
    end

    private def self.metadata_total_size(object_bytes : Bytes, dynamics : Hash(String, Bytes)) : UInt64
      total = object_bytes.size.to_u64
      dynamics.each_value { |bytes| total = checked_add_u64(total, bytes.size.to_u64) }
      total
    end

    private def self.descriptor_stream_names!(
      physical : ObjectDocumentPhysicalPlan,
      hashed : Bool,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Tuple(Array(String), Array(String))
      count = physical.stream_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      logical_names = physical.stream_names
      unless logical_names.size.to_u64 == count
        raise CorruptPartError.new("Object descriptor stream roster changed after physical planning")
      end

      checksum_names = Array(String).new(logical_names.size * 2)
      seen_files = Hash(String, Bool).new(initial_capacity: logical_names.size * 2)
      output_bytes = 0_u64
      logical_names.each do |logical_name|
        budget.charge_node
        ensure_name_size!(logical_name.bytesize.to_u64, limits)
        output_bytes = checked_add_u64(output_bytes, logical_name.bytesize.to_u64)
        data_name, marks_name = file_pair(logical_name, hashed)
        {data_name, marks_name}.each do |name|
          validate_physical_name!(name)
          ensure_name_size!(name.bytesize.to_u64, limits)
          if seen_files.has_key?(name)
            raise CorruptPartError.new("Object descriptor physical filenames collide")
          end
          seen_files[name] = true
          checksum_names << name
          output_bytes = checked_add_u64(output_bytes, name.bytesize.to_u64)
        end
      end
      checksum_names.sort!
      budget.ensure_wire_bytes(output_bytes)
      budget.charge_wire_bytes(output_bytes)
      {logical_names, checksum_names}
    end

    private def self.file_pair(logical_name : String, hashed : Bool) : Tuple(String, String)
      basename = hashed ? StreamName.hash(logical_name) : logical_name
      {
        PhysicalStreamName.append_literal(basename, ".bin"),
        PhysicalStreamName.append_literal(basename, ".mrk2"),
      }
    end

    private def self.validate_physical_name!(name : String) : Nil
      if name.bytesize > PartChecksums::MAX_NAME_BYTES
        raise UnsupportedFormatError.new("physical part stream basename exceeds checksums.txt name limit")
      end
      nil
    end

    private def self.ensure_name_size!(size : UInt64, limits : BinaryCodecLimits) : Nil
      if size > limits.max_bytes.to_u64 || size > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("physical part stream name exceeds configured bound")
      end
      nil
    end

    private def self.ensure_unhashed_name_size!(size : UInt64, hashed : Bool) : Nil
      if !hashed && size > PartChecksums::MAX_NAME_BYTES.to_u64
        raise UnsupportedFormatError.new("unhashed physical part stream basename exceeds checksums.txt name limit")
      end
      nil
    end

    private def self.checked_add_u64(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Object file reader size accounting overflows UInt64")
      end
      left + right
    end
  end
end
