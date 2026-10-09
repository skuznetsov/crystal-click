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
      getter bucket_index : Int32?

      def initialize(
        @kind : Symbol,
        @path : String,
        @arm : String,
        @role : String,
        @data_name : String,
        @marks_name : String,
        @prefix_size : Int32,
        @bucket_index : Int32? = nil,
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
      getter physical_plan : ObjectDocumentPhysicalPlan
      getter document_plan : ObjectDocumentPlan
      getter name_context : PhysicalStreamPlanContext
      getter hashed : Bool
      getter schema_snapshot : Hash(String, BinaryDataType)
      getter object_bytes : Bytes
      getter dynamic_bytes : Hash(String, Bytes)
      getter typed_dynamic_bytes : Hash(String, Hash(String, Bytes))
      getter typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan)
      getter typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32))
      getter typed_dynamic_modes : Hash(String, UInt64)
      getter outer_rows : Array(UInt64)
      getter first_mark : Int32
      getter selected_count : Int32
      getter profile : BinaryBulkProfile
      getter shared_profile : BinaryBulkProfile
      getter shared_data_version : UInt64
      getter shared_bucket_count : Int32
      getter object_structure : ObjectStructure
      getter advanced_copy_inputs : Hash(String, ObjectSharedPhysicalLaneInput)
      getter advanced_bucket_inputs : Array(ObjectSharedPhysicalBucketLaneInputs)
      getter bulk_bindings : Array(BulkBinding)
      getter discriminator_bindings : Array(DiscriminatorBinding)
      getter codec_budget : BinaryCodecBudget
      getter transport_budget : CompressedStreamBudget
      getter descriptor : ObjectDocumentFileDescriptor?
      getter replay_complete : Bool
      getter occurrence_grid : StorageOccurrenceGrid?
      getter size_data_name : String?
      getter size_marks_name : String?

      def initialize(
        @source : PartStreamSource,
        @physical_plan : ObjectDocumentPhysicalPlan,
        @document_plan : ObjectDocumentPlan,
        @name_context : PhysicalStreamPlanContext,
        @hashed : Bool,
        @schema_snapshot : Hash(String, BinaryDataType),
        @object_bytes : Bytes,
        @dynamic_bytes : Hash(String, Bytes),
        @typed_dynamic_bytes : Hash(String, Hash(String, Bytes)),
        @typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
        @typed_dynamic_site_statistics_offsets : Hash(String, Hash(String, Int32)),
        @typed_dynamic_modes : Hash(String, UInt64),
        @outer_rows : Array(UInt64),
        @first_mark : Int32,
        @selected_count : Int32,
        @profile : BinaryBulkProfile,
        @shared_profile : BinaryBulkProfile,
        @shared_data_version : UInt64,
        @shared_bucket_count : Int32,
        @object_structure : ObjectStructure,
        @advanced_copy_inputs : Hash(String, ObjectSharedPhysicalLaneInput),
        @advanced_bucket_inputs : Array(ObjectSharedPhysicalBucketLaneInputs),
        @bulk_bindings : Array(BulkBinding),
        @discriminator_bindings : Array(DiscriminatorBinding),
        @codec_budget : BinaryCodecBudget,
        @transport_budget : CompressedStreamBudget,
        @descriptor : ObjectDocumentFileDescriptor?,
        @replay_complete : Bool,
        @occurrence_grid : StorageOccurrenceGrid?,
        @size_data_name : String?,
        @size_marks_name : String?,
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

    # Child-site metadata path used by an Array wrapper. `limits` are already
    # reduced by the wrapper's depth contribution; initial_array_level is a
    # separate physical-name coordinate and does not reduce logical depth.
    def self.inspect_child_site(
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
        part_path, column_name, typed_schema, 0, 0, profile, shared_profile,
        hashed, limits, transport_limits, true, true, 1_u64
      )
      prepared.descriptor.not_nil!
    end

    # Inspect one Object JSON site nested below a caller-owned storage column.
    # Public part metadata is intentionally not reopened here: `source`, the
    # budgets, and the escaped prefix belong to the enclosing operation.
    def self.inspect_at_site(
      source : PartStreamSource,
      escaped_prefix : String,
      typed_schema : Hash(String, BinaryDataType),
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      initial_array_level : UInt64 = 0_u64,
      expected_mark_row_counts : Array(UInt64)? = nil,
      typed_schema_depth : Int32 = 1,
      inferred_actual_root_depth : Int32 = 1,
      typed_dynamic_json_child : Bool = false,
    ) : ObjectDocumentFileDescriptor
      prepared = prepare_site_read(
        source,
        escaped_prefix,
        typed_schema,
        0,
        0,
        profile,
        shared_profile,
        hashed,
        codec_budget,
        name_context,
        transport_budget,
        true,
        initial_array_level,
        expected_mark_row_counts,
        nil,
        nil,
        nil,
        1,
        typed_schema_depth,
        inferred_actual_root_depth,
        typed_dynamic_json_child,
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

    # Reads dense Dynamic rows for one shared Object path. Advanced layouts
    # avoid the root whole-Object Copy lanes and retain selected-path Data;
    # MAP0/MAP1 instead decode their ordinary shared lane(s). Every layout
    # validates complete physical mark grids before projecting the selection.
    def self.read_shared_path_marks(
      part_path : String,
      column_name : String,
      descriptor : ObjectDocumentFileDescriptor,
      path : String,
      first_mark : Int,
      mark_count : Int,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : Array(Array(BinaryValue))
      if first_mark < 0 || mark_count < 0
        raise ArgumentError.new("mark selection must be nonnegative")
      end
      physical_rows = descriptor.mark_row_counts
      if first_mark > physical_rows.size || mark_count > physical_rows.size - first_mark
        raise ArgumentError.new("mark selection is outside the Object grid")
      end
      if path.empty?
        raise ArgumentError.new("selected Object shared path must not be empty")
      end

      version = descriptor.plan.structures.object.shared_data_version
      codec_budget = BinaryCodecBudget.new(limits)
      codec_budget.ensure_wire_bytes(path.bytesize.to_u64)
      codec_budget.charge_wire_bytes(path.bytesize.to_u64)
      codec_budget.charge_elements(path.bytesize.to_u64)
      transport_budget = CompressedStreamBudget.new(transport_limits)
      physical_plan = ObjectDocumentPhysicalPlan.new(
        column_name,
        descriptor.plan,
        profile,
        BinaryBulkProfile.single_stream,
        limits,
      )
      bucket_count = physical_plan.shared_bucket_count
      if bucket_count != ObjectSharedBucketLayout.bucket_count(descriptor.plan.structures.object)
        raise CorruptPartError.new("selected Object shared bucket count disagrees with its descriptor")
      end
      source = PartStreamSource.new(part_path)
      if version < 2_u64
        return read_map_shared_path_marks(
          source,
          physical_plan,
          descriptor,
          path,
          first_mark,
          mark_count,
          hashed,
          codec_budget,
          transport_budget,
        )
      end

      selected_bucket = ObjectSharedBucketLayout.bucket_for(path, bucket_count)

      lane_count = bucket_count.to_u64 * ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.size.to_u64
      lane_owner_count = checked_add_u64(lane_count, bucket_count.to_u64)
      codec_budget.ensure_future_nodes(lane_owner_count)
      codec_budget.preflight_children(lane_owner_count)
      bucket_inputs = Array(ObjectSharedPhysicalBucketLaneInputs).new(bucket_count)
      bucket_count.times do |bucket_index|
        lanes = Hash(String, ObjectSharedPhysicalLaneInput).new(
          initial_capacity: ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.size
        )
        ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
          logical_name = physical_plan.advanced_bucket_stream_name(bucket_index, lane)
          data_name, marks_name = file_pair(logical_name, hashed)
          validate_physical_name!(data_name)
          validate_physical_name!(marks_name)
          lanes[String.new(lane.to_slice)] = source.physical_lane_input(data_name, marks_name)
          codec_budget.charge_node
        end
        bucket_inputs << ObjectSharedPhysicalBucketLaneInputs.new(lanes)
        codec_budget.charge_node
      end
      decoded = ObjectSharedAdvancedDocumentCodec.decode_path_only(
        bucket_inputs,
        physical_rows,
        physical_rows,
        version.to_i,
        bucket_count,
        selected_bucket,
        path,
        first_mark.to_i32,
        mark_count.to_i32,
        codec_budget,
        transport_budget,
        profile: profile,
      )
      unless decoded.size == mark_count
        raise CorruptPartError.new("selected Object shared path returned the wrong number of marks")
      end
      mark_count.times do |index|
        unless decoded[index].size.to_u64 == physical_rows[first_mark + index]
          raise CorruptPartError.new("selected Object shared path rows disagree with the outer grid")
        end
      end
      decoded
    end

    # Child-site value path. Returns one mark of parent rows, each with
    # its own decoded child document list. The complete .size0 schedule is
    # validated during preparation, including for an empty selection.
    def self.read_child_site(
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
    ) : Array(Array(Array(ObjectDocument)))
      prepared = prepare_read(
        part_path, column_name, typed_schema, first_mark, mark_count,
        profile, shared_profile, hashed, limits, transport_limits, false,
        true, 1_u64
      )
      flat = read_prepared(prepared)
      group_child_documents(prepared, flat)
    end

    # Reads selected marks from one Object JSON site using parent physical
    # rows. No child `.size0` schedule is inferred or consumed here.
    def self.read_at_site(
      source : PartStreamSource,
      escaped_prefix : String,
      typed_schema : Hash(String, BinaryDataType),
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      initial_array_level : UInt64 = 0_u64,
      expected_mark_row_counts : Array(UInt64)? = nil,
    ) : Array(Array(ObjectDocument))
      prepared = prepare_site_read(
        source,
        escaped_prefix,
        typed_schema,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        hashed,
        codec_budget,
        name_context,
        transport_budget,
        false,
        initial_array_level,
        expected_mark_row_counts,
      )
      read_prepared(prepared)
    end

    # Inspect an Object leaf beneath caller-owned Array/Tuple wrappers. The
    # enclosing reader owns the array-size schedule and supplies its complete
    # P/C occurrence grid; this method validates Object physical marks against
    # P and never guesses or rereads a `.sizeN` stream.
    def self.inspect_child_at_site(
      source : PartStreamSource,
      escaped_prefix : String,
      typed_schema : Hash(String, BinaryDataType),
      grid : StorageOccurrenceGrid,
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      initial_array_level : UInt64 = 0_u64,
    ) : ObjectDocumentFileDescriptor
      prepared = prepare_site_read(
        source,
        escaped_prefix,
        typed_schema,
        0,
        0,
        profile,
        shared_profile,
        hashed,
        codec_budget,
        name_context,
        transport_budget,
        true,
        initial_array_level,
        nil,
        grid,
      )
      prepared.descriptor.not_nil!
    end

    # Read selected logical Object occurrences from a structural child site.
    # Physical mark records are checked against `grid.physical_rows_at`; the
    # codec receives `grid.logical_occurrences_at`. Array parent regrouping is
    # deliberately left to the enclosing recursive storage reader.
    def self.read_child_at_site(
      source : PartStreamSource,
      escaped_prefix : String,
      typed_schema : Hash(String, BinaryDataType),
      grid : StorageOccurrenceGrid,
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      initial_array_level : UInt64 = 0_u64,
      expected_document_plan : ObjectDocumentPlan? = nil,
      expected_schema : ObjectDocumentSchema? = nil,
      expected_schema_depth : Int32 = 1,
      typed_schema_depth : Int32 = 1,
      inferred_actual_root_depth : Int32 = 1,
    ) : Array(Array(ObjectDocument))
      prepared = prepare_site_read(
        source,
        escaped_prefix,
        typed_schema,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        hashed,
        codec_budget,
        name_context,
        transport_budget,
        false,
        initial_array_level,
        nil,
        grid,
        expected_document_plan,
        expected_schema,
        expected_schema_depth,
        typed_schema_depth,
        inferred_actual_root_depth,
      )
      read_prepared(prepared)
    end

    private def self.prepare_site_read(
      source : PartStreamSource,
      escaped_prefix : String,
      typed_schema : Hash(String, BinaryDataType),
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
      shared_profile : BinaryBulkProfile,
      hashed : Bool,
      codec_budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      transport_budget : CompressedStreamBudget,
      build_descriptor : Bool,
      initial_array_level : UInt64,
      expected_mark_row_counts : Array(UInt64)?,
      occurrence_grid_override : StorageOccurrenceGrid? = nil,
      expected_document_plan : ObjectDocumentPlan? = nil,
      expected_schema : ObjectDocumentSchema? = nil,
      expected_schema_depth : Int32 = 1,
      typed_schema_depth : Int32 = 1,
      inferred_actual_root_depth : Int32 = 1,
      typed_dynamic_json_child : Bool = false,
    ) : PreparedRead
      unless !codec_budget.writing? && !transport_budget.writing?
        raise ArgumentError.new("Object site reader requires read-direction budgets")
      end
      unless same_limits?(codec_budget.limits, name_context.limits)
        raise ArgumentError.new("Object site read and physical-name limits differ")
      end
      transport_budget.ensure_direction(false)
      prepare_read(
        "",
        "",
        typed_schema,
        first_mark,
        mark_count,
        profile,
        shared_profile,
        hashed,
        codec_budget.limits,
        transport_budget.limits,
        build_descriptor,
        false,
        initial_array_level,
        source,
        escaped_prefix,
        expected_mark_row_counts,
        codec_budget,
        transport_budget,
        name_context,
        occurrence_grid_override,
        expected_document_plan,
        expected_schema,
        expected_schema_depth,
        typed_schema_depth,
        inferred_actual_root_depth,
        typed_dynamic_json_child,
      )
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
      child_site : Bool = false,
      initial_array_level : UInt64 = 0_u64,
      source_override : PartStreamSource? = nil,
      escaped_prefix_override : String? = nil,
      expected_outer_rows : Array(UInt64)? = nil,
      codec_budget_override : BinaryCodecBudget? = nil,
      transport_budget_override : CompressedStreamBudget? = nil,
      name_context_override : PhysicalStreamPlanContext? = nil,
      occurrence_grid_override : StorageOccurrenceGrid? = nil,
      expected_document_plan_override : ObjectDocumentPlan? = nil,
      expected_schema_override : ObjectDocumentSchema? = nil,
      expected_schema_depth : Int32 = 1,
      typed_schema_depth : Int32 = 1,
      inferred_actual_root_depth : Int32 = 1,
      typed_dynamic_json_child : Bool = false,
    ) : PreparedRead
      validate_selection_arguments!(first_mark, mark_count)
      reject_json_schema!(typed_schema)
      codec_budget = codec_budget_override || BinaryCodecBudget.new(limits)
      transport_budget = transport_budget_override || CompressedStreamBudget.new(transport_limits)
      column_prefix = if site_prefix = escaped_prefix_override
                        preflight_escaped_prefix!(site_prefix, hashed, limits)
                      else
                        preflight_column_name!(column_name, hashed, limits)
                      end
      schema_snapshot = preflight_and_copy_schema!(
        typed_schema, column_prefix, hashed, limits, codec_budget, typed_schema_depth
      )
      replay_complete = schema_snapshot.each_value.any? do |type|
        BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
      end
      typed_dynamic_metadata_names = if escaped_prefix_override
                                       discover_typed_dynamic_metadata_names_at_site!(
                                         column_prefix,
                                         schema_snapshot,
                                         typed_schema_depth,
                                         limits,
                                         hashed,
                                         codec_budget
                                       )
                                     else
                                       discover_typed_dynamic_metadata_names!(
                                         column_name,
                                         schema_snapshot,
                                         typed_schema_depth,
                                         limits,
                                         hashed,
                                         codec_budget
                                       )
                                     end
      source = source_override || PartStreamSource.new(part_path)
      name_context = name_context_override || PhysicalStreamPlanContext.new(limits)
      unless same_limits?(name_context.limits, limits)
        raise ArgumentError.new("Object read and physical-name context limits differ")
      end

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
      effective_inferred_actual_root_depth = inferred_actual_root_depth
      if typed_dynamic_json_child && object.dynamic_path_count > 0
        effective_depth64 = inferred_actual_root_depth.to_i64 + 1_i64
        if effective_depth64 <= 0_i64 || effective_depth64 > Int32::MAX.to_i64
          raise CorruptPartError.new("typed Dynamic JSON child inferred descriptor depth exceeds Int32")
        end
        effective_inferred_actual_root_depth = effective_depth64.to_i32
        codec_budget.ensure_depth(effective_inferred_actual_root_depth)
      end
      shared_bucket_count = ObjectSharedBucketLayout.bucket_count(object)
      validate_metadata_grid!(object_grid, object_statistics_offset, object_bytes.size)
      charge_source_roster!(object_grid, codec_budget)
      outer_rows = copy_outer_rows(object_grid)
      if expected_rows = expected_outer_rows
        validate_expected_outer_rows!(outer_rows, expected_rows)
      end
      if supplied_grid = occurrence_grid_override
        supplied_grid.validate_for!(outer_rows.size, codec_budget)
        outer_rows.each_with_index do |rows, mark_index|
          unless rows == supplied_grid.physical_rows_at(mark_index)
            raise CorruptPartError.new("Object physical marks disagree with the supplied occurrence grid")
          end
        end
      end
      selected_count = validate_selection!(first_mark, mark_count, outer_rows.size)

      occurrence_grid = occurrence_grid_override
      size_data_name = nil.as(String?)
      size_marks_name = nil.as(String?)
      size_grid = nil.as(CompressedMarkGrid?)
      if child_site
        if occurrence_grid_override
          raise ArgumentError.new("Object reader cannot infer and accept an occurrence grid simultaneously")
        end
        size_data_name, size_marks_name, size_grid, child_rows = inspect_child_schedule!(
          source,
          column_name,
          column_prefix,
          outer_rows,
          hashed,
          limits,
          codec_budget,
          transport_budget,
        )
        occurrence_grid = StorageOccurrenceGrid.new(outer_rows, child_rows, codec_budget)
      end

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
        dynamic, statistics_offset = parse_dynamic_metadata(
          bytes,
          limits,
          codec_budget,
          effective_inferred_actual_root_depth,
        )
        validate_metadata_grid!(grid, statistics_offset, bytes.size)
        dynamic_bytes[String.new(raw_path.to_slice)] = bytes
        dynamic_structures[String.new(raw_path.to_slice)] = dynamic
      end

      typed_dynamic_bytes = Hash(String, Hash(String, Bytes)).new
      typed_dynamic_plans = Hash(String, BinaryDynamicBulkPlan).new
      typed_dynamic_site_statistics_offsets = Hash(String, Hash(String, Int32)).new
      typed_dynamic_structures = Hash(String, Hash(String, DynamicStructure)).new
      typed_dynamic_direct_structures = Hash(String, DynamicStructure).new
      typed_dynamic_json_object_leaf_plans = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new
      typed_dynamic_json_leaf_coordinates = Hash(String, Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectSiteCoordinates)).new
      typed_dynamic_json_logical_read_bytes = 0_u64
      root_dynamic_json_object_leaf_plans = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new
      root_dynamic_json_leaf_coordinates = Hash(String, Hash(BinaryDynamicJsonLeafKey, ObjectRootDynamicJsonCoordinates)).new
      root_dynamic_json_logical_read_bytes = 0_u64
      schema_snapshot.each do |path, type|
        next unless type.contains_dynamic?
        names = typed_dynamic_metadata_names[path]?
        unless names
          raise CorruptPartError.new("typed Dynamic declared site names are missing")
        end
        site_bytes = Hash(String, Bytes).new(initial_capacity: names.size)
        site_grids = Hash(String, CompressedMarkGrid).new(initial_capacity: names.size)
        names.each do |site_path, logical_name|
          data_name, marks_name = file_pair(logical_name, hashed)
          validate_physical_name!(data_name)
          validate_physical_name!(marks_name)
          grid = source.inspect_grid(data_name, marks_name, nil, transport_budget)
          validate_same_rows!(grid, outer_rows)
          charge_metadata_read!(grid, codec_budget)
          bytes = source.read_all(data_name, transport_budget)
          ensure_logical_size!(bytes, grid)
          site_bytes[String.new(site_path.to_slice)] = bytes
          site_grids[String.new(site_path.to_slice)] = grid
        end
        root_depth = object_declared_dynamic_root_depth(typed_schema_depth)
        typed_prefix = PhysicalStreamName.append_escaped_component(column_prefix, path, name_context)
        resolver = BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
          type,
          typed_prefix,
          initial_array_level,
          limits,
          codec_budget,
          name_context,
          root_depth,
        )
        json_coordinates = Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectSiteCoordinates).new
        loader = ->(site_path : String, structures : Hash(String, DynamicStructure), _budget : BinaryCodecBudget) {
          logical_name = resolver.structure_stream_name(site_path, structures)
          unless names[site_path]? == logical_name
            raise CorruptPartError.new("typed Dynamic structure name differs from the schema-derived physical roster")
          end
          site_bytes[site_path]? || raise(CorruptPartError.new("typed Dynamic structure bytes are missing a declared site"))
        }
        json_object_leaf_plan_loader = ->(key : BinaryDynamicJsonLeafKey, json_descriptor_depth : Int32, _structure : DynamicStructure, structures : Hash(String, DynamicStructure), budget : BinaryCodecBudget) {
          coordinates = resolver.json_object_leaf_site(key, structures)
          json_descriptor = coordinates.json_type.json_type ||
                            raise(CorruptPartError.new("typed Dynamic JSON leaf has no persisted descriptor"))
          json_schema = copy_json_typed_schema(json_descriptor, budget)
          child_descriptor = inspect_at_site(
            source,
            coordinates.escaped_prefix,
            json_schema,
            budget,
            name_context,
            transport_budget,
            profile,
            BinaryBulkProfile.single_stream,
            hashed,
            coordinates.array_level,
            outer_rows,
            json_descriptor_depth + 1,
            json_descriptor_depth + 1,
            typed_dynamic_json_child: true,
          )
          typed_dynamic_json_logical_read_bytes = checked_add_u64(
            typed_dynamic_json_logical_read_bytes,
            child_descriptor.logical_read_bytes
          )
          if json_coordinates.has_key?(key)
            raise CorruptPartError.new("typed Dynamic JSON leaf coordinates are duplicated")
          end
          json_coordinates[key] = coordinates
          child_descriptor.plan
        }
        dynamic_plan = ObjectDeclaredDynamicDeclaration.prepare_read_sites_plan_with_loader(
          type,
          codec_budget,
          profile,
          loader,
          root_depth: root_depth,
          descriptor_preflight: resolver.descriptor_preflight,
          json_object_leaf_plan_loader: json_object_leaf_plan_loader,
        )
        typed_dynamic_json_leaf_coordinates[String.new(path.to_slice)] = json_coordinates
        json_keys = dynamic_plan.json_object_leaf_keys(codec_budget)
        unless json_keys.empty?
          records = json_keys.size.to_u64
          codec_budget.preflight_children(records)
          codec_budget.ensure_future_nodes(records)
          records.times { codec_budget.charge_node }
          leaf_plans = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(json_keys.size)
          json_keys.each do |key|
            leaf_plans << {key, dynamic_plan.json_object_binding(key).plan}
          end
          typed_dynamic_json_object_leaf_plans[String.new(path.to_slice)] = leaf_plans
        end
        expected_sites = dynamic_plan.site_paths
        unless expected_sites.size == site_grids.size && expected_sites.size == names.size
          raise CorruptPartError.new("typed Dynamic metadata grids do not match the retained site roster")
        end
        site_offsets = Hash(String, Int32).new(initial_capacity: expected_sites.size)
        structures = Hash(String, DynamicStructure).new(initial_capacity: expected_sites.size)
        expected_sites.each do |site_path|
          grid = site_grids[site_path]? || raise(CorruptPartError.new("typed Dynamic metadata grid is missing a declared site"))
          unless names.has_key?(site_path)
            raise CorruptPartError.new("typed Dynamic metadata name is missing a declared site")
          end
          # The retained parse supplies each site's exact statistics boundary.
          # `prepare_read_sites_plan_with_loader` retained each exact parse.
          statistics_offset = dynamic_plan.statistics_offset_for(site_path)
          bytes = site_bytes[site_path]? || raise(CorruptPartError.new("typed Dynamic metadata bytes are missing a declared site"))
          validate_metadata_grid!(grid, statistics_offset, bytes.size)
          site_offsets[String.new(site_path.to_slice)] = statistics_offset
          structures[String.new(site_path.to_slice)] = dynamic_plan.structure_for(site_path)
        end
        copied_path = String.new(path.to_slice)
        typed_dynamic_bytes[copied_path] = site_bytes
        typed_dynamic_plans[copied_path] = dynamic_plan
        typed_dynamic_site_statistics_offsets[copied_path] = site_offsets
        typed_dynamic_structures[copied_path] = structures
        if type.tag == BinaryDataType::TAG_DYNAMIC
          typed_dynamic_direct_structures[copied_path] = structures["root"]? || raise(CorruptPartError.new("typed Dynamic root structure is missing"))
        end
      end

      # Inferred Object Dynamic paths have no declared descriptor. Discover
      # every JSON actual arm directly from the persisted DynamicStructure,
      # then bind the exact child Object metadata before selected values are
      # exposed. The standalone actual root keeps its own depth origin; a
      # nested child Object passes that origin explicitly through this call.
      object.dynamic_path_count.times do |index|
        raw_path = object.dynamic_path_at(index)
        structure = dynamic_structures[raw_path]? ||
                    raise(CorruptPartError.new("Object Dynamic metadata is missing a discovered path"))
        has_json_actual = false
        structure.type_count.times do |type_index|
          has_json_actual ||= structure.type_at(type_index).contains_json?
        end
        # Keep the pre-W216 route for no-JSON Dynamic domains. Metadata parsing
        # above bounded each descriptor at the inherited origin before
        # DynamicStructure computes its cached summary flags; this census does
        # not require canonical-name materialization.
        next unless has_json_actual

        json_leaf_types = DynamicJsonObjectBindingRoster.json_leaf_types_for_root(
          structure,
          codec_budget,
          effective_inferred_actual_root_depth,
        )
        next if json_leaf_types.empty?

        records = checked_add_u64(checked_multiply_u64(json_leaf_types.size.to_u64, 2_u64), 2_u64)
        codec_budget.preflight_children(records)
        codec_budget.charge_wire_bytes(raw_path.bytesize.to_u64)
        records.times { codec_budget.charge_node }
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path, name_context)
        json_site_resolver = ObjectRootDynamicJsonSiteResolver.new(
          path_prefix,
          structure,
          codec_budget,
          name_context,
          initial_array_level,
          effective_inferred_actual_root_depth,
        )
        leaf_plans = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(json_leaf_types.size)
        coordinates_by_key = Hash(BinaryDynamicJsonLeafKey, ObjectRootDynamicJsonCoordinates).new(
          initial_capacity: json_leaf_types.size
        )
        json_leaf_types.each do |entry|
          key = entry[0]
          json_type = entry[1]
          json_depth = entry[2]
          coordinates = json_site_resolver.resolve_json_leaf(key)
          unless coordinates.json_type == json_type && coordinates.json_depth == json_depth
            raise CorruptPartError.new("inferred Dynamic JSON leaf coordinates differ from the persisted descriptor roster")
          end
          if coordinates_by_key.has_key?(key)
            raise CorruptPartError.new("inferred Dynamic JSON leaf coordinates are duplicated")
          end
          descriptor = json_type.json_type ||
                       raise(CorruptPartError.new("inferred Dynamic JSON actual has no persisted JSON descriptor"))
          json_schema = copy_json_typed_schema(descriptor, codec_budget)
          child_root_depth64 = json_depth.to_i64 + 1_i64
          if child_root_depth64 > Int32::MAX.to_i64
            raise CorruptPartError.new("inferred Dynamic JSON child descriptor depth exceeds Int32")
          end
          child_root_depth = child_root_depth64.to_i32
          child_descriptor = inspect_at_site(
            source,
            coordinates.escaped_prefix,
            json_schema,
            codec_budget,
            name_context,
            transport_budget,
            profile,
            shared_profile,
            hashed,
            coordinates.array_level,
            outer_rows,
            child_root_depth,
            child_root_depth,
          )
          root_dynamic_json_logical_read_bytes = checked_add_u64(
            root_dynamic_json_logical_read_bytes,
            child_descriptor.logical_read_bytes
          )
          coordinates_by_key[key] = coordinates
          leaf_plans << {key, child_descriptor.plan}
        end

        unless leaf_plans.size == json_leaf_types.size
          raise CorruptPartError.new("inferred Dynamic JSON child plan roster changed during discovery")
        end
        copied_path = String.new(raw_path.to_slice)
        root_dynamic_json_object_leaf_plans[copied_path] = leaf_plans
        root_dynamic_json_leaf_coordinates[copied_path] = coordinates_by_key
      end

      # A root Dynamic JSON census consumes absolute parent marks. Keep the
      # Object parent P grid and all Dynamic discriminator marks in that same
      # coordinate system; the original first_mark is applied only when the
      # Object codec returns its selected slice. Reading a rebased discriminator
      # window here would pair full JSON Q schedules with the wrong parent P.
      replay_complete = replay_complete || !root_dynamic_json_leaf_coordinates.empty?

      structure_set = ObjectDynamicStructureSet.new(object, dynamic_structures)
      recursive_typed_dynamic_structures = Hash(String, Hash(String, DynamicStructure)).new
      typed_dynamic_structures.each do |path, sites|
        recursive_typed_dynamic_structures[path] = sites unless typed_dynamic_direct_structures.has_key?(path)
      end
      document_plan = ObjectDocumentPlan.new(
        structure_set,
        schema_snapshot,
        typed_dynamic_direct_structures,
        recursive_typed_dynamic_structures,
        typed_dynamic_json_object_leaf_plans,
        root_dynamic_json_object_leaf_plans: root_dynamic_json_object_leaf_plans,
        root_dynamic_json_budget: codec_budget,
        inferred_actual_root_depth: effective_inferred_actual_root_depth,
      )
      if expected_schema = expected_schema_override
        begin
          expected_schema.validate_plan(document_plan, codec_budget, expected_schema_depth)
        rescue ex : ArgumentError
          raise CorruptPartError.new(ex.message || "Object child metadata differs from its JSON descriptor")
        end
      end
      if expected_plan = expected_document_plan_override
        unless same_document_plan_rosters?(
                 document_plan,
                 expected_plan,
                 codec_budget,
                 expected_schema_depth,
                 effective_inferred_actual_root_depth,
               )
          raise CorruptPartError.new("Object child metadata changed after Dynamic JSON binding")
        end
      end
      physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
        column_prefix,
        document_plan,
        profile,
        shared_profile,
        limits,
        initial_array_level,
        name_context,
        object_declared_dynamic_root_depth(typed_schema_depth),
        effective_inferred_actual_root_depth,
        codec_budget,
      )

      typed_dynamic_metadata_names.each do |path, names|
        physical = physical_plan.typed_dynamic(path)
        dynamic_plan = typed_dynamic_plans[path]? ||
                       raise(CorruptPartError.new("typed Dynamic metadata has no retained read plan"))
        unless names.size == dynamic_plan.site_count && physical.structure_stream_names.size == dynamic_plan.site_count
          raise CorruptPartError.new("typed Dynamic physical structure roster changed after metadata discovery")
        end
        dynamic_plan.site_paths.each do |site_path|
          logical_name = names[site_path]?
          unless logical_name
            raise CorruptPartError.new("typed Dynamic discovered metadata name is missing a retained site")
          end
          unless physical.structure_name_for(site_path) == logical_name
            raise CorruptPartError.new("typed Dynamic discovered metadata name disagrees with the final physical plan")
          end
        end
      end
      typed_dynamic_json_leaf_coordinates.each do |path, coordinates_by_key|
        physical = physical_plan.typed_dynamic(path)
        unless physical.json_object_site_count == coordinates_by_key.size
          raise CorruptPartError.new("typed Dynamic JSON physical sites differ from discovered metadata")
        end
        coordinates_by_key.each do |key, coordinates|
          site = physical.json_object_site(key)
          unless site.escaped_prefix == coordinates.escaped_prefix &&
                 site.array_level == coordinates.array_level &&
                 site.binding.leaf_key == key &&
                 site.binding.json_type == coordinates.json_type
            raise CorruptPartError.new("typed Dynamic JSON physical coordinates changed after metadata discovery")
          end
        end
      end
      root_dynamic_json_leaf_coordinates.each do |path, coordinates_by_key|
        physical = physical_plan.root_dynamic_json(path)
        expected_leaf_plans = root_dynamic_json_object_leaf_plans[path]?
        unless expected_leaf_plans && physical.json_object_site_count == coordinates_by_key.size &&
               expected_leaf_plans.size == coordinates_by_key.size
          raise CorruptPartError.new("inferred Dynamic JSON physical sites differ from discovered metadata")
        end
        expected_leaf_plans.each do |entry|
          key = entry[0]
          expected_plan = entry[1]
          coordinates = coordinates_by_key[key]?
          unless coordinates
            raise CorruptPartError.new("inferred Dynamic JSON discovered coordinate is missing")
          end
          site = physical.json_object_site(key)
          child_root_depth64 = coordinates.json_depth.to_i64 + 1_i64
          if child_root_depth64 <= 0_i64 || child_root_depth64 > Int32::MAX.to_i64
            raise CorruptPartError.new("inferred Dynamic JSON child descriptor depth exceeds Int32")
          end
          child_root_depth = child_root_depth64.to_i32
          unless site.escaped_prefix == coordinates.escaped_prefix &&
                 site.array_level == coordinates.array_level &&
                 site.json_depth == coordinates.json_depth &&
                 site.binding.leaf_key == key &&
                 site.binding.json_type == coordinates.json_type &&
                 site.binding.plan.same?(expected_plan) &&
                 site.physical_plan.typed_descriptor_root_depth == child_root_depth &&
                 site.physical_plan.inferred_actual_root_depth == child_root_depth
            raise CorruptPartError.new("inferred Dynamic JSON physical binding changed after metadata discovery")
          end
        end
      end

      physical_plan.preflight_shared_bucket_bindings!(hashed, codec_budget)
      advanced_copy_inputs, advanced_bucket_inputs = if object.shared_data_version >= 2_u64
                                                       resolve_advanced_shared_inputs!(source, physical_plan, hashed, codec_budget)
                                                     else
                                                       {Hash(String, ObjectSharedPhysicalLaneInput).new,
                                                        [] of ObjectSharedPhysicalBucketLaneInputs}
                                                     end
      bulk_bindings = collect_bulk_bindings(document_plan, physical_plan, hashed)
      discriminator_bindings = collect_discriminator_bindings(object, physical_plan, hashed)
      typed_qbit_roles = Hash(String, ObjectRuntimeQBitOccurrenceSchedule::RoleSet).new
      typed_dynamic_plans.each do |path, plan|
        roles = ObjectRuntimeQBitOccurrenceSchedule.typed_dynamic_roles(plan)
        typed_qbit_roles[path] = roles unless roles.empty?
      end
      inferred_qbit_roles = Hash(String, Hash(String, ObjectRuntimeQBitOccurrenceSchedule::RoleSet)).new
      inferred_qbit_paths = Hash(String, Bool).new
      object.dynamic_path_count.times do |path_index|
        path = object.dynamic_path_at(path_index)
        structure = dynamic_structures[path]? ||
                    raise(CorruptPartError.new("Object Dynamic QBit roster is missing its parsed structure"))
        arm_roles = Hash(String, ObjectRuntimeQBitOccurrenceSchedule::RoleSet).new
        structure.type_count.times do |type_index|
          type = structure.type_at(type_index)
          next unless type.contains_qbit?
          arm_name = structure.canonical_variant_names[structure.canonical_index_for(type)]
          arm_physical = physical_plan.dynamic_arm(path, arm_name)
          roles = ObjectRuntimeQBitOccurrenceSchedule.static_dynamic_roles(type, arm_physical, limits)
          next if roles.empty?
          arm_roles[arm_name] = roles
        end
        unless arm_roles.empty?
          inferred_qbit_roles[path] = arm_roles
          inferred_qbit_paths[path] = true
        end
      end
      typed_qbit_grids = Hash(String, Hash(String, CompressedMarkGrid)).new
      inferred_qbit_grids = Hash(String, Hash(String, Hash(String, CompressedMarkGrid))).new
      inferred_discriminator_grids = Hash(String, CompressedMarkGrid).new
      qbit_shape_grids = Hash(String, CompressedMarkGrid).new
      selected_wire_bytes = 0_u64
      logical_lane_bytes = 0_u64
      validate_all_value_grids!(
        source,
        bulk_bindings,
        discriminator_bindings,
        outer_rows,
        transport_budget
      ) do |grid, prefix, binding_kind, binding_path, binding_arm, binding_role, binding_data_name|
        logical_lane_bytes = checked_add_u64(logical_lane_bytes, grid.logical_size.to_u64)
        if binding_kind == :typed_dynamic
          if roles = typed_qbit_roles[binding_path]?
            if roles.has_key?(binding_role)
              path_grids = typed_qbit_grids[binding_path]? || Hash(String, CompressedMarkGrid).new
              path_grids[binding_role] = grid
              typed_qbit_grids[binding_path] = path_grids
              if ObjectRuntimeQBitOccurrenceSchedule.shape_result_role?(binding_role)
                qbit_shape_grids[String.new(binding_data_name.to_slice)] = grid
              end
            end
          end
        elsif binding_kind == :dynamic && !binding_arm.empty?
          if arm_roles = inferred_qbit_roles[binding_path]?
            if roles = arm_roles[binding_arm]?
              if roles.has_key?(binding_role)
                path_grids = inferred_qbit_grids[binding_path]? || Hash(String, Hash(String, CompressedMarkGrid)).new
                arm_grids = path_grids[binding_arm]? || Hash(String, CompressedMarkGrid).new
                arm_grids[binding_role] = grid
                path_grids[binding_arm] = arm_grids
                inferred_qbit_grids[binding_path] = path_grids
                if ObjectRuntimeQBitOccurrenceSchedule.shape_result_role?(binding_role)
                  qbit_shape_grids[String.new(binding_data_name.to_slice)] = grid
                end
              end
            end
          end
        elsif binding_kind == :dynamic && binding_arm.empty? && binding_role.empty? &&
              inferred_qbit_paths.has_key?(binding_path)
          inferred_discriminator_grids[binding_path] = grid
          qbit_shape_grids[String.new(binding_data_name.to_slice)] = grid
        end
        unless build_descriptor
          full_typed_dynamic_json = binding_kind == :typed_dynamic &&
                                    (typed_dynamic_plans[binding_path]?.try(&.has_json_object_bindings?) || false)
          first = full_typed_dynamic_json || replay_complete ? 0 : first_mark
          count = full_typed_dynamic_json || replay_complete ? outer_rows.size : selected_count
          selected_wire_bytes = checked_add_u64(
            selected_wire_bytes,
            selected_extent(grid, first, count, prefix)
          )
        end
      end

      # The separate typed Dynamic header reads precede the QBit census;
      # full QBit selector windows include those prefixes again. Include all
      # header reads, even for unrelated paths, before either result read starts.
      typed_dynamic_headers = typed_dynamic_header_bindings(bulk_bindings)
      typed_dynamic_header_result_bytes = 0_u64
      typed_dynamic_headers.each do |binding|
        typed_dynamic_header_result_bytes = checked_add_u64(
          typed_dynamic_header_result_bytes,
          binding.prefix_size.to_u64,
        )
      end
      ObjectRuntimeQBitOccurrenceSchedule.preflight_shape_results!(
        qbit_shape_grids,
        transport_budget,
        typed_dynamic_header_result_bytes,
      )

      # All typed and inferred QBit visitors share one per-mark shape-work
      # scope. The retained counters are preflighted once here; visitors add
      # their existing size/selector shape costs to this owner instead of
      # resetting the allowance for each path or arm.
      qbit_occurrence_totals = if typed_qbit_roles.empty? && inferred_qbit_roles.empty?
                                 nil
                               else
                                 BinaryQBitOccurrenceTotals.new(outer_rows.size, limits, codec_budget)
                               end

      if grid = size_grid
        logical_lane_bytes = checked_add_u64(logical_lane_bytes, grid.logical_size.to_u64)
        unless build_descriptor
          first = replay_complete ? 0 : first_mark
          count = replay_complete ? outer_rows.size : selected_count
          selected_wire_bytes = checked_add_u64(selected_wire_bytes, selected_extent(grid, first, count, 0))
        end
      end

      # Validate every declared typed-Dynamic discriminator header after the
      # complete grid is admitted, but before selected value windows are read.
      # Each physical discriminator lane owns its mode independently, even
      # when selection is empty. Retain it by physical filename for the
      # selected-window TOCTOU check below.
      typed_dynamic_modes = Hash(String, UInt64).new
      typed_qbit_modes = Hash(String, Hash(String, UInt64)).new
      typed_dynamic_headers.each do |binding|
        BinaryBulkPhysicalPrefixAdapter.preflight_read([{binding.role, binding.prefix_size, 1}], codec_budget)
        window = source.read_window(binding.data_name, binding.marks_name, 0, 0, binding.prefix_size, transport_budget)
        mode = BinaryBulkDiscriminatorFramingAdapter.validate_header(
          binding.role,
          window.bytes,
          binding.prefix_size
        )
        if typed_dynamic_modes.has_key?(binding.data_name)
          raise CorruptPartError.new("typed Dynamic physical discriminator filename is duplicated")
        end
        typed_dynamic_modes[binding.data_name] = mode
        if roles = typed_qbit_roles[binding.path]?
          if roles.has_key?(binding.role)
            path_modes = typed_qbit_modes[binding.path]? || Hash(String, UInt64).new
            path_modes[binding.role] = mode
            typed_qbit_modes[binding.path] = path_modes
          end
        end
      end

      # Object's typed Dynamic plan already carries the prepared recursive
      # QBit site roster; inferred Dynamic plans instead reuse their complete
      # legacy discriminator schedules to seed each static actual's logical
      # arm-count axis. Both censuses happen during preparation, before any
      # selected or EOF callback can observe the part.
      root_qbit_site_grid = occurrence_grid
      typed_qbit_roles.each_key do |path|
        plan = typed_dynamic_plans[path]? ||
               raise(CorruptPartError.new("typed Dynamic QBit plan is missing from the retained roster"))
        type = schema_snapshot[path]? ||
               raise(CorruptPartError.new("typed Dynamic QBit declaration is missing from the typed schema"))
        physical = physical_plan.typed_dynamic(path)
        grids = typed_qbit_grids[path]? || Hash(String, CompressedMarkGrid).new
        modes = typed_qbit_modes[path]? || Hash(String, UInt64).new
        site_grid = root_qbit_site_grid || StorageOccurrenceGrid.new(outer_rows, outer_rows, codec_budget)
        root_qbit_site_grid = site_grid
        ObjectRuntimeQBitOccurrenceSchedule.validate_typed_dynamic!(
          plan,
          type,
          physical,
          source,
          grids,
          modes,
          outer_rows,
          site_grid,
          codec_budget,
          transport_budget,
          qbit_occurrence_totals,
        )
      end
      inferred_qbit_roles.each do |path, arm_roles|
        structure = dynamic_structures[path]? ||
                    raise(CorruptPartError.new("Object Dynamic QBit roster is missing its parsed structure"))
        binding = discriminator_bindings.find { |candidate| candidate.path == path } ||
                  raise(CorruptPartError.new("Object Dynamic QBit discriminator binding is missing"))
        grid = inferred_discriminator_grids[path]? ||
               raise(CorruptPartError.new("Object Dynamic QBit discriminator grid is missing"))
        ObjectRuntimeQBitOccurrenceSchedule.validate_inferred_dynamic!(
          path,
          structure,
          physical_plan,
          source,
          binding.data_name,
          binding.marks_name,
          grid,
          inferred_qbit_grids[path]? || Hash(String, Hash(String, CompressedMarkGrid)).new,
          outer_rows,
          occurrence_grid,
          limits,
          codec_budget,
          transport_budget,
          qbit_occurrence_totals,
        )
      end

      metadata_size = metadata_total_size(object_bytes, dynamic_bytes, typed_dynamic_bytes)
      codec_budget.ensure_wire_bytes(checked_add_u64(metadata_size, selected_wire_bytes))

      logical_read_bytes = checked_add_u64(metadata_size, logical_lane_bytes)
      logical_read_bytes = checked_add_u64(logical_read_bytes, typed_dynamic_json_logical_read_bytes)
      logical_read_bytes = checked_add_u64(logical_read_bytes, root_dynamic_json_logical_read_bytes)
      descriptor = nil.as(ObjectDocumentFileDescriptor?)
      if build_descriptor
        logical_names, checksum_names = descriptor_stream_names!(
          physical_plan,
          hashed,
          limits,
          codec_budget,
          child_site ? size_stream_name(column_prefix, limits) : nil,
        )
        descriptor = ObjectDocumentFileDescriptor.new(
          document_plan,
          outer_rows,
          logical_names,
          checksum_names,
          logical_read_bytes,
          occurrence_grid,
        )
      end

      # Selection validation bounded both indices to outer_rows.size before narrowing.
      PreparedRead.new(
        source,
        physical_plan,
        document_plan,
        name_context,
        hashed,
        schema_snapshot,
        object_bytes,
        dynamic_bytes,
        typed_dynamic_bytes,
        typed_dynamic_plans,
        typed_dynamic_site_statistics_offsets,
        typed_dynamic_modes,
        outer_rows,
        first_mark.to_i32,
        selected_count.to_i32,
        profile,
        shared_profile,
        object.shared_data_version,
        shared_bucket_count,
        object,
        advanced_copy_inputs,
        advanced_bucket_inputs,
        bulk_bindings,
        discriminator_bindings,
        codec_budget,
        transport_budget,
        descriptor,
        replay_complete,
        occurrence_grid,
        size_data_name,
        size_marks_name,
      )
    end

    private def self.read_prepared(prepared : PreparedRead) : Array(Array(ObjectDocument))
      source = prepared.source
      schema_snapshot = prepared.schema_snapshot
      object_bytes = prepared.object_bytes
      dynamic_bytes = prepared.dynamic_bytes
      typed_dynamic_bytes = prepared.typed_dynamic_bytes
      typed_dynamic_plans = prepared.typed_dynamic_plans
      typed_dynamic_site_statistics_offsets = prepared.typed_dynamic_site_statistics_offsets
      typed_dynamic_modes = prepared.typed_dynamic_modes
      outer_rows = prepared.outer_rows
      first_mark = prepared.first_mark
      selected_count = prepared.selected_count
      occurrence_grid = prepared.occurrence_grid
      object_structure = prepared.object_structure
      profile = prepared.profile
      shared_profile = prepared.shared_profile
      shared_data_version = prepared.shared_data_version
      bulk_bindings = prepared.bulk_bindings
      discriminator_bindings = prepared.discriminator_bindings
      codec_budget = prepared.codec_budget
      transport_budget = prepared.transport_budget
      replay_complete = prepared.replay_complete
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? outer_rows.size : selected_count
      logical_rows = outer_rows
      if grid = occurrence_grid
        count = grid.mark_count.to_u64
        codec_budget.ensure_future_nodes(count)
        codec_budget.ensure_future_elements(count)
        count.times { codec_budget.charge_node }
        codec_budget.charge_elements(count)
        logical_rows = Array(UInt64).new(grid.mark_count) do |index|
          grid.logical_occurrences_at(index)
        end
        codec_budget.ensure_future_nodes(selected_count.to_u64)
        codec_budget.ensure_future_elements(selected_count.to_u64)
        selected_count.times { codec_budget.charge_node }
        codec_budget.charge_elements(selected_count.to_u64)
      end
      selected_rows = Array(UInt64).new(selected_count)
      selected_count.times do |index|
        selected_rows << logical_rows[first_mark + index]
      end

      advanced_shared_rows = [] of Array(ObjectSharedMapRow)
      if shared_data_version >= 2_u64
        full_advanced_rows = ObjectSharedAdvancedDocumentCodec.decode(
          prepared.advanced_copy_inputs,
          prepared.advanced_bucket_inputs,
          outer_rows,
          logical_rows,
          shared_data_version.to_i,
          prepared.shared_bucket_count,
          codec_budget,
          transport_budget,
          profile: profile,
        )
        validate_advanced_shared_rows!(full_advanced_rows, schema_snapshot, object_structure, codec_budget)
        advanced_first = replay_complete ? 0 : read_first
        advanced_count = replay_complete ? full_advanced_rows.size : read_count
        advanced_shared_rows = select_advanced_shared_rows(
          full_advanced_rows,
          advanced_first,
          advanced_count,
          codec_budget,
        )
      end
      prefix_reads = [] of Tuple(String, Int32, Int32)
      bulk_bindings.each do |binding|
        next unless (binding.kind == :typed || binding.kind == :typed_dynamic) &&
                    BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(binding.role, binding.prefix_size)
        binding_read_count = if binding.kind == :typed_dynamic &&
                                typed_dynamic_full_json_grid?(binding.path, typed_dynamic_plans)
                               outer_rows.size
                             else
                               read_count
                             end
        if binding_read_count == Int32::MAX
          raise CorruptPartError.new("Object Variant read coordinate count exceeds the supported domain")
        end
        prefix_reads << {binding.role, binding.prefix_size, binding_read_count + 1}
      end
      BinaryBulkPhysicalPrefixAdapter.preflight_read(prefix_reads, codec_budget) unless prefix_reads.empty?

      typed_roles = Hash(String, Hash(String, BinaryBulkStream)).new
      typed_dynamic_roles = Hash(String, Hash(String, BinaryBulkStream)).new
      dynamic_roles = Hash(String, Hash(String, Hash(String, BinaryBulkStream))).new
      shared_bucket_roles = [] of Hash(String, BinaryBulkStream)
      if shared_data_version == 1_u64
        shared_bindings_count = bulk_bindings.count { |binding| binding.kind == :shared }.to_u64
        shared_owner_count = checked_add_u64(
          checked_multiply_u64(prepared.shared_bucket_count.to_u64, 5_u64),
          shared_bindings_count
        )
        codec_budget.ensure_future_nodes(shared_owner_count)
        codec_budget.preflight_children(shared_owner_count)
        prepared.shared_bucket_count.times do
          codec_budget.charge_node
          shared_bucket_roles << Hash(String, BinaryBulkStream).new
        end
      end
      shared_roles = Hash(String, BinaryBulkStream).new
      bulk_bindings.each do |binding|
        full_typed_dynamic_json = binding.kind == :typed_dynamic &&
                                  typed_dynamic_full_json_grid?(binding.path, typed_dynamic_plans)
        binding_read_first = full_typed_dynamic_json ? 0 : read_first
        binding_read_count = full_typed_dynamic_json ? outer_rows.size : read_count
        window = source.read_window(
          binding.data_name,
          binding.marks_name,
          binding_read_first,
          binding_read_count,
          binding.prefix_size,
          transport_budget
        )
        lane_bytes = window.bytes
        lane_offsets = window.offsets
        if binding.kind == :typed_dynamic &&
           BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(binding.role, binding.prefix_size)
          mode = BinaryBulkDiscriminatorFramingAdapter.validate_header(
            binding.role,
            lane_bytes,
            binding.prefix_size
          )
          expected_mode = typed_dynamic_modes[binding.data_name]?
          unless expected_mode == mode
            raise CorruptPartError.new("typed Dynamic discriminator mode changed after header preflight")
          end
          logical = BinaryBulkDiscriminatorFramingAdapter.read_lane(
            binding.role,
            lane_bytes,
            lane_offsets,
            binding.prefix_size,
            codec_budget
          )
          lane_bytes = logical[0]
          lane_offsets = logical[1]
        elsif binding.kind == :typed &&
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
        if shared_data_version == 1_u64 && binding.kind == :shared
          codec_budget.charge_node
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
        when :typed_dynamic
          if roles = typed_dynamic_roles[binding.path]?
            roles[binding.role] = stream
          else
            roles = Hash(String, BinaryBulkStream).new
            roles[binding.role] = stream
            typed_dynamic_roles[binding.path] = roles
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
          if shared_data_version == 0_u64
            shared_roles[binding.role] = stream
          else
            bucket_index = binding.bucket_index || raise(CorruptPartError.new("shared Object lane has no bucket identity"))
            roles = shared_bucket_roles[bucket_index]? || raise(CorruptPartError.new("shared Object lane bucket is outside its metadata roster"))
            roles[binding.role] = stream
          end
        else
          raise CorruptPartError.new("unknown Object physical lane class")
        end
      end

      typed_streams = Hash(String, BinaryBulkStreams).new
      typed_roles.each { |path, roles| typed_streams[path] = BinaryBulkStreams.new(read_count, roles) }
      typed_dynamic_data = Hash(String, BinaryBulkStreams).new
      typed_dynamic_roles.each do |path, roles|
        marks = typed_dynamic_full_json_grid?(path, typed_dynamic_plans) ? outer_rows.size : read_count
        typed_dynamic_data[path] = BinaryBulkStreams.new(marks, roles)
      end
      typed_dynamic_rosters_match =
        typed_dynamic_data.size == typed_dynamic_plans.size &&
          typed_dynamic_bytes.size == typed_dynamic_plans.size &&
          typed_dynamic_site_statistics_offsets.size == typed_dynamic_plans.size
      typed_dynamic_data.each_key do |path|
        typed_dynamic_rosters_match = false unless typed_dynamic_plans.has_key?(path)
      end
      typed_dynamic_plans.each do |path, dynamic_plan|
        metadata = typed_dynamic_bytes[path]?
        offsets = typed_dynamic_site_statistics_offsets[path]?
        unless metadata && offsets
          typed_dynamic_rosters_match = false
          next
        end
        site_paths = dynamic_plan.site_paths
        unless metadata.size == site_paths.size && offsets.size == site_paths.size
          typed_dynamic_rosters_match = false
          next
        end
        site_paths.each do |site_path|
          unless metadata.has_key?(site_path) && offsets[site_path]? == dynamic_plan.statistics_offset_for(site_path)
            typed_dynamic_rosters_match = false
          end
        end
        metadata.each_key do |site_path|
          typed_dynamic_rosters_match = false unless dynamic_plan.has_site?(site_path)
        end
        offsets.each_key do |site_path|
          typed_dynamic_rosters_match = false unless dynamic_plan.has_site?(site_path)
        end
      end
      unless typed_dynamic_rosters_match
        raise CorruptPartError.new("typed Dynamic prepared metadata and value rosters disagree")
      end

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
        discriminator = discriminator_stream(
          window,
          occurrence_grid ? logical_rows : nil,
          occurrence_grid ? read_first : 0
        )
        arms = Hash(String, BinaryBulkStreams).new
        if prepared.physical_plan.has_root_dynamic_json?(binding.path)
          dynamic_structure = prepared.document_plan.structures.dynamic_for(binding.path)
          canonical_names = dynamic_structure.canonical_variant_names
          existing_arms = dynamic_roles[binding.path]?
          empty_arm_count = 0_u64
          empty_arm_name_bytes = 0_u64
          canonical_names.each do |arm|
            next if existing_arms && existing_arms.has_key?(arm)
            next unless prepared.physical_plan.dynamic_arm(binding.path, arm).stream_count == 0
            empty_arm_count = checked_add_u64(empty_arm_count, 1_u64)
            empty_arm_name_bytes = checked_add_u64(empty_arm_name_bytes, arm.bytesize.to_u64)
          end
          if empty_arm_count > 0_u64
            codec_budget.preflight_children(empty_arm_count)
            codec_budget.ensure_future_nodes(empty_arm_count)
            codec_budget.ensure_future_elements(empty_arm_count)
            codec_budget.charge_wire_bytes(empty_arm_name_bytes)
            empty_arm_count.times { codec_budget.charge_node }
            codec_budget.charge_elements(empty_arm_count)
            canonical_names.each do |arm|
              next if existing_arms && existing_arms.has_key?(arm)
              next unless prepared.physical_plan.dynamic_arm(binding.path, arm).stream_count == 0
              arms[arm] = BinaryBulkStreams.new(read_count, Hash(String, BinaryBulkStream).new)
            end
          end
        end
        if arm_roles = dynamic_roles[binding.path]?
          arm_roles.each do |arm, roles|
            arms[arm] = BinaryBulkStreams.new(read_count, roles)
          end
        end
        dynamic_streams[binding.path] = DynamicValueStreams.new(discriminator, arms)
      end

      shared_streams : BinaryBulkStreams | Array(BinaryBulkStreams) = if shared_data_version == 0_u64
        BinaryBulkStreams.new(read_count, shared_roles)
      elsif shared_data_version == 1_u64
        bucket_streams = Array(BinaryBulkStreams).new(prepared.shared_bucket_count)
        prepared.shared_bucket_count.times do |bucket_index|
          codec_budget.charge_node
          bucket_streams << BinaryBulkStreams.new(read_count, shared_bucket_roles[bucket_index])
        end
        prepared.shared_bucket_count.times { codec_budget.charge_node }
        bucket_streams
      else
        [] of BinaryBulkStreams
      end
      stream_rows = replay_complete ? logical_rows : selected_rows
      ordinary_schema = Hash(String, BinaryDataType).new
      schema_snapshot.each do |path, type|
        ordinary_schema[path] = type unless type.contains_dynamic?
      end
      streams = ObjectDocumentStreams.new(
        ObjectDynamicStructureStreams.new(object_bytes, dynamic_bytes),
        stream_rows,
        typed_streams,
        dynamic_streams,
        shared_streams,
        advanced_shared_rows: advanced_shared_rows,
      )

      physical_root_dynamic_json_object_leaf_loader = ->(path : String, key : BinaryDynamicJsonLeafKey, binding : DynamicJsonObjectBinding, grid : StorageOccurrenceGrid, json_depth : Int32, budget : BinaryCodecBudget) {
        site = prepared.physical_plan.root_dynamic_json(path).json_object_site(key)
        child_physical = site.physical_plan
        child_root_depth64 = json_depth.to_i64 + 1_i64
        if child_root_depth64 <= 0_i64 || child_root_depth64 > Int32::MAX.to_i64
          raise CorruptPartError.new("inferred Dynamic JSON child descriptor depth exceeds Int32")
        end
        child_root_depth = child_root_depth64.to_i32
        unless grid.mark_count == outer_rows.size
          raise CorruptPartError.new("inferred Dynamic JSON child grid differs from the complete Object domain")
        end
        outer_rows.size.times do |mark|
          unless grid.physical_rows_at(mark) == outer_rows[mark]
            raise CorruptPartError.new("inferred Dynamic JSON child physical grid differs from its parent Object")
          end
        end
        unless site.leaf_key == key && site.json_depth == json_depth &&
               site.binding.leaf_key == key && site.binding.json_type == binding.json_type &&
               site.binding.plan.same?(binding.plan) &&
               site.binding.schema.typed_paths == binding.schema.typed_paths &&
               child_physical.typed_descriptor_root_depth == child_root_depth &&
               child_physical.inferred_actual_root_depth == child_root_depth
          raise CorruptPartError.new("inferred Dynamic JSON physical and logical child bindings differ")
        end

        descriptor = binding.json_type.json_type ||
                     raise(CorruptPartError.new("inferred Dynamic JSON child binding lost its descriptor"))
        typed_schema = copy_json_typed_schema(descriptor, budget)
        documents = ObjectDocumentFileReader.read_child_at_site(
          source,
          site.escaped_prefix,
          typed_schema,
          grid,
          budget,
          prepared.name_context,
          transport_budget,
          0,
          outer_rows.size,
          profile,
          shared_profile,
          prepared.hashed,
          site.array_level,
          binding.plan,
          binding.schema,
          json_depth,
          child_root_depth,
          child_root_depth,
        )
        unless documents.size == grid.mark_count
          raise CorruptPartError.new("inferred Dynamic JSON child documents differ from the complete Q grid")
        end
        grid.mark_count.times do |mark|
          unless documents[mark].size.to_u64 == grid.logical_occurrences_at(mark)
            raise CorruptPartError.new("inferred Dynamic JSON child documents differ from their discriminator schedule")
          end
        end
        documents
      }

      result = if full_grid = occurrence_grid
                 decode_grid = if replay_complete
                                 full_grid
                               else
                                 selected_occurrence_grid(full_grid, read_first, read_count, codec_budget)
                               end
                 ObjectDocumentCodec.decode_child_site_with_budget(
                   ordinary_schema,
                   streams,
                   decode_grid,
                   codec_budget,
                   first_mark: replay_complete ? first_mark : 0,
                   mark_count: selected_count,
                   profile: profile,
                   shared_profile: shared_profile,
                   typed_descriptor_root_depth: prepared.physical_plan.typed_descriptor_root_depth,
                   inferred_actual_root_depth: prepared.physical_plan.inferred_actual_root_depth,
                   root_dynamic_json_object_leaf_plans: prepared.document_plan.root_dynamic_json_object_leaf_plans(codec_budget),
                   physical_root_dynamic_json_object_leaf_loader: physical_root_dynamic_json_object_leaf_loader,
                 )
               else
                 ObjectDocumentCodec.decode_with_budget(
                   ordinary_schema,
                   streams,
                   codec_budget,
                   first_mark: replay_complete ? first_mark : 0,
                   mark_count: selected_count,
                   profile: profile,
                   shared_profile: shared_profile,
                   typed_descriptor_root_depth: prepared.physical_plan.typed_descriptor_root_depth,
                   inferred_actual_root_depth: prepared.physical_plan.inferred_actual_root_depth,
                   root_dynamic_json_object_leaf_plans: prepared.document_plan.root_dynamic_json_object_leaf_plans(codec_budget),
                   physical_root_dynamic_json_object_leaf_loader: physical_root_dynamic_json_object_leaf_loader,
                 )
               end
      typed_dynamic_rows = Hash(String, Array(Array(BinaryValue))).new
      typed_dynamic_data.each do |path, data|
        type = schema_snapshot[path]? || raise(CorruptPartError.new("typed Dynamic value stream has no declared schema"))
        dynamic_plan = typed_dynamic_plans[path]? || raise(CorruptPartError.new("typed Dynamic value stream has no retained plan"))
        unless type.contains_dynamic? && dynamic_plan.type == type
          raise CorruptPartError.new("typed Dynamic value stream has no matching declared plan")
        end
        if dynamic_plan.has_json_object_bindings?
          unless data.mark_count == outer_rows.size && logical_rows.size == outer_rows.size
            raise CorruptPartError.new("typed Dynamic JSON value grid differs from its complete Object domain")
          end
          empty_structures = BinaryDynamicStructureStreams.new(Hash(String, Bytes).new)
          dynamic_streams = BinaryDynamicBulkStreams.new(empty_structures, data, budget: codec_budget)
          physical_dynamic = prepared.physical_plan.typed_dynamic(path)
          child_loader = ->(key : BinaryDynamicJsonLeafKey, binding : DynamicJsonObjectBinding, grid : StorageOccurrenceGrid, budget : BinaryCodecBudget) {
            site = physical_dynamic.json_object_site(key)
            structure = dynamic_plan.structure_for(key.dynamic_site)
            json_depth = physical_dynamic.json_object_leaf_depth(key)
            begin
              binding.validate_for!(key, structure, budget, json_depth)
              site.binding.validate_for!(key, structure, budget, json_depth)
            rescue ex : ArgumentError
              raise CorruptPartError.new(ex.message || "typed Dynamic JSON child binding changed before Object read")
            end
            unless site.binding.plan.same?(binding.plan) && site.binding.schema.typed_paths == binding.schema.typed_paths
              raise CorruptPartError.new("typed Dynamic JSON physical and logical child bindings differ")
            end
            descriptor = binding.json_type.json_type ||
                         raise(CorruptPartError.new("typed Dynamic JSON child binding lost its descriptor"))
            typed_schema = copy_json_typed_schema(descriptor, budget)
            typed_child_root_depth64 = json_depth.to_i64 + 1_i64
            if typed_child_root_depth64 <= 0_i64 || typed_child_root_depth64 > Int32::MAX.to_i64
              raise CorruptPartError.new("typed Dynamic JSON child descriptor depth exceeds Int32")
            end
            typed_child_root_depth = typed_child_root_depth64.to_i32
            inferred_child_root_depth64 = typed_child_root_depth64
            if binding.plan.structures.object.dynamic_path_count > 0
              inferred_child_root_depth64 += 1_i64
            end
            if inferred_child_root_depth64 <= 0_i64 || inferred_child_root_depth64 > Int32::MAX.to_i64
              raise CorruptPartError.new("typed Dynamic JSON child inferred descriptor depth exceeds Int32")
            end
            inferred_child_root_depth = inferred_child_root_depth64.to_i32
            if binding.plan.structures.object.dynamic_path_count > 0
              budget.ensure_depth(inferred_child_root_depth)
            end
            unless site.physical_plan.typed_descriptor_root_depth == typed_child_root_depth &&
                   site.physical_plan.inferred_actual_root_depth == inferred_child_root_depth
              raise CorruptPartError.new("typed Dynamic JSON physical child descriptor origins changed")
            end
            ObjectDocumentFileReader.read_child_at_site(
              prepared.source,
              site.escaped_prefix,
              typed_schema,
              grid,
              budget,
              prepared.name_context,
              prepared.transport_budget,
              0,
              outer_rows.size,
              profile,
              BinaryBulkProfile.single_stream,
              prepared.hashed,
              site.array_level,
              binding.plan,
              binding.schema,
              json_depth,
              typed_child_root_depth,
              inferred_child_root_depth,
            )
          }
          json_reader = BinaryDynamicBulkJsonObjectReader.new(
            dynamic_plan,
            dynamic_streams,
            logical_rows,
            codec_budget,
            profile,
            physical_rows_per_mark: outer_rows,
            physical_child_loader: child_loader,
            initial_descriptor_depth: physical_dynamic.initial_descriptor_depth,
          )
          full_rows = BinaryBulkDecoder.decode(
            type,
            data,
            logical_rows,
            codec_budget,
            0,
            outer_rows.size,
            profile,
            dynamic_plan,
            json_reader,
            physical_dynamic.initial_descriptor_depth,
          )
          typed_dynamic_rows[path] = slice_selected_marks(full_rows, first_mark, selected_count, codec_budget)
        else
          typed_dynamic_rows[path] = BinaryBulkDecoder.decode(
            type,
            data,
            stream_rows,
            codec_budget,
            replay_complete ? first_mark : 0,
            selected_count,
            profile,
            dynamic_plan,
            shared_value_depth_origin: prepared.physical_plan.typed_dynamic(path).initial_descriptor_depth,
          )
        end
        typed_dynamic_rows[path].each do |mark_values|
          mark_values.each do |value|
            ObjectDeclaredDynamicDeclaration.validate_selected_values!(
              value,
              type,
              codec_budget,
              false,
              prepared.physical_plan.typed_descriptor_root_depth,
              allow_shared_json: true,
            )
          end
        end
      end
      if typed_dynamic_rows.size != typed_dynamic_plans.size || typed_dynamic_bytes.size != typed_dynamic_plans.size ||
         typed_dynamic_site_statistics_offsets.size != typed_dynamic_plans.size
        raise CorruptPartError.new("typed Dynamic prepared metadata and value rosters disagree")
      end

      merge_typed_dynamic_values!(result, typed_dynamic_rows, typed_dynamic_plans, schema_snapshot, codec_budget)
    end

    private def self.validate_selection_arguments!(first_mark : Int, mark_count : Int?) : Nil
      raise ArgumentError.new("first mark must be nonnegative") if first_mark < 0
      if count = mark_count
        raise ArgumentError.new("mark count must be nonnegative") if count < 0
      end
      nil
    end

    private def self.inspect_child_schedule!(
      source : PartStreamSource,
      column_name : String,
      column_prefix : String,
      outer_rows : Array(UInt64),
      hashed : Bool,
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Tuple(String, String, CompressedMarkGrid, Array(UInt64))
      if outer_rows.empty?
        raise CorruptPartError.new("Array(JSON) part has no real parent marks")
      end

      size_name = size_stream_name(column_prefix, limits)
      data_name, marks_name = file_pair(size_name, hashed)
      validate_physical_name!(data_name)
      validate_physical_name!(marks_name)

      total_parents = 0_u64
      outer_rows.each do |rows|
        total_parents = checked_add_u64(total_parents, rows)
      end
      if total_parents > Int32::MAX.to_u64
        raise CorruptPartError.new("Array(JSON) parent schedule exceeds the supported domain")
      end
      # Reading .size0 scans one UInt64 per parent, even when the requested
      # value window is empty. Charge that complete part-level work before the
      # decoded size buffer or occurrence-count array is allocated.
      codec_budget.ensure_future_nodes(total_parents)
      codec_budget.ensure_future_elements(total_parents)
      total_parents.times { codec_budget.charge_node }
      codec_budget.charge_elements(total_parents)

      grid = source.inspect_grid(data_name, marks_name, 0, transport_budget)
      validate_same_rows!(grid, outer_rows)
      expected_size = checked_multiply_u64(total_parents, 8_u64)
      unless grid.logical_size.to_u64 == expected_size && grid.prefix_size == 0
        raise CorruptPartError.new("Array(JSON) .size0 extent disagrees with its complete parent grid")
      end
      if grid.mark_count.to_u64 > limits.max_nodes.to_u64 || grid.mark_count.to_u64 > limits.max_elements.to_u64
        raise CorruptPartError.new("Array(JSON) child schedule mark count exceeds codec limits")
      end
      codec_budget.ensure_future_nodes(grid.mark_count.to_u64)
      codec_budget.ensure_future_elements(grid.mark_count.to_u64)
      grid.mark_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(grid.mark_count.to_u64)
      codec_budget.charge_wire_bytes(expected_size)
      bytes = source.read_all(data_name, transport_budget)
      ensure_logical_size!(bytes, grid)

      child_rows = Array(UInt64).new(grid.mark_count)
      total_children = 0_u64
      cursor = 0
      grid.mark_count.times do |mark_index|
        children_for_mark = 0_u64
        outer_rows[mark_index].times do
          size = uint64_le_at(bytes, cursor)
          cursor += 8
          if size > Int32::MAX.to_u64
            raise CorruptPartError.new("Array(JSON) child row count exceeds the supported domain")
          end
          children_for_mark = checked_add_u64(children_for_mark, size)
        end
        if children_for_mark > Int32::MAX.to_u64
          raise CorruptPartError.new("Array(JSON) child rows in one mark exceed the supported domain")
        end
        total_children = checked_add_u64(total_children, children_for_mark)
        if total_children > Int32::MAX.to_u64
          raise CorruptPartError.new("Array(JSON) flattened child rows exceed the supported domain")
        end
        child_rows << children_for_mark
      end
      unless cursor == bytes.size
        raise CorruptPartError.new("Array(JSON) .size0 schedule has trailing or missing bytes")
      end
      grid.logical_size == expected_size.to_i64 || raise(CorruptPartError.new("Array(JSON) size schedule changed during inspection"))
      {data_name, marks_name, grid, child_rows}
    end

    private def self.size_stream_name(column_prefix : String, limits : BinaryCodecLimits) : String
      name = PhysicalStreamName.append_literal(column_prefix, ".size0")
      ensure_name_size!(name.bytesize.to_u64, limits)
      name
    end

    private def self.selected_occurrence_grid(
      grid : StorageOccurrenceGrid,
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : StorageOccurrenceGrid
      if first_mark < 0 || mark_count < 0 || first_mark > grid.mark_count || mark_count > grid.mark_count - first_mark
        raise CorruptPartError.new("selected child occurrence window is outside the complete grid")
      end
      records = mark_count.to_u64 * 2_u64
      budget.ensure_future_nodes(records)
      budget.ensure_future_elements(records)
      budget.charge_elements(records)
      mark_count.times { budget.charge_node; budget.charge_node }
      physical_rows = Array(UInt64).new(mark_count)
      child_rows = Array(UInt64).new(mark_count)
      mark_count.times do |index|
        physical_rows << grid.physical_rows_at(first_mark + index)
        child_rows << grid.logical_occurrences_at(first_mark + index)
      end
      StorageOccurrenceGrid.new(physical_rows, child_rows, budget)
    end

    private def self.typed_dynamic_full_json_grid?(
      path : String,
      plans : Hash(String, BinaryDynamicBulkPlan),
    ) : Bool
      if plan = plans[path]?
        plan.has_json_object_bindings?
      else
        false
      end
    end

    private def self.copy_json_typed_schema(
      descriptor : BinaryJsonType,
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryDataType)
      count = descriptor.typed_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      total_path_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        size = descriptor.typed_path_byte_size(index).to_u64
        if total_path_bytes > UInt64::MAX - size
          raise CorruptPartError.new("typed JSON path byte count overflows")
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

    private def self.slice_selected_marks(
      marks : Array(Array(BinaryValue)),
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : Array(Array(BinaryValue))
      if first_mark < 0 || mark_count < 0 || first_mark > marks.size || mark_count > marks.size - first_mark
        raise CorruptPartError.new("selected typed Dynamic mark range is outside the full JSON child domain")
      end
      count = mark_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.charge_node
      count.times { budget.charge_node }
      Array(Array(BinaryValue)).new(mark_count) do |index|
        marks[first_mark + index]
      end
    end

    private def self.group_child_documents(
      prepared : PreparedRead,
      flat_marks : Array(Array(ObjectDocument)),
    ) : Array(Array(Array(ObjectDocument)))
      grid = prepared.occurrence_grid || raise(ArgumentError.new("child grouping requires an occurrence grid"))
      data_name = prepared.size_data_name || raise(CorruptPartError.new("Array(JSON) .size0 data name is missing"))
      marks_name = prepared.size_marks_name || raise(CorruptPartError.new("Array(JSON) .size0 mark name is missing"))
      first_mark = prepared.first_mark
      mark_count = prepared.selected_count
      unless flat_marks.size == mark_count
        raise CorruptPartError.new("Array(JSON) decoded child mark count differs from its selection")
      end

      parent_count = 0_u64
      child_count = 0_u64
      mark_count.times do |index|
        physical = grid.physical_rows_at(first_mark + index)
        logical = grid.logical_occurrences_at(first_mark + index)
        parent_count = checked_add_u64(parent_count, physical)
        child_count = checked_add_u64(child_count, logical)
      end
      retained_nodes = checked_add_u64(mark_count.to_u64, parent_count)
      retained_elements = checked_add_u64(parent_count, child_count)
      prepared.codec_budget.ensure_future_nodes(retained_nodes)
      prepared.codec_budget.ensure_future_elements(retained_elements)

      byte_count = checked_multiply_u64(parent_count, 8_u64)
      prepared.codec_budget.charge_wire_bytes(byte_count)
      window = prepared.source.read_window(
        data_name,
        marks_name,
        first_mark,
        mark_count,
        0,
        prepared.transport_budget
      )
      bytes = window.bytes
      offsets = window.offsets
      window_rows = window.rows_per_mark
      unless window.prefix_size == 0 && window_rows.size == mark_count &&
             offsets.size == mark_count + 1 && offsets.first? == 0_u64 && offsets.last? == bytes.size.to_u64 &&
             bytes.size.to_u64 == byte_count
        raise CorruptPartError.new("selected Array(JSON) .size0 window has inconsistent coordinates")
      end

      # Validate all selected parent sizes and the per-mark occurrence totals
      # before allocating grouped child rows. This detects a redistribution
      # mismatch when the affected payload mark is selected; it is not a
      # whole-part decode of every arbitrary inner payload lane.
      cursor = 0
      mark_count.times do |mark_index|
        global_mark = first_mark + mark_index
        expected_parents = grid.physical_rows_at(global_mark)
        expected_children = grid.logical_occurrences_at(global_mark)
        unless window_rows[mark_index] == expected_parents
          raise CorruptPartError.new("selected Array(JSON) .size0 parent rows differ from the complete grid")
        end
        start = offsets[mark_index]
        finish = offsets[mark_index + 1]
        unless finish >= start && finish - start == expected_parents * 8_u64
          raise CorruptPartError.new("selected Array(JSON) .size0 offsets disagree with parent rows")
        end
        observed_children = 0_u64
        expected_parents.times do
          size = uint64_le_at(bytes, cursor)
          cursor += 8
          if size > Int32::MAX.to_u64
            raise CorruptPartError.new("selected Array(JSON) child row count exceeds the supported domain")
          end
          observed_children = checked_add_u64(observed_children, size)
        end
        unless observed_children == expected_children
          raise CorruptPartError.new("selected Array(JSON) .size0 counts differ from the complete child schedule")
        end
        unless flat_marks[mark_index].size.to_u64 == expected_children
          raise CorruptPartError.new("selected Array(JSON) child payload disagrees with .size0 counts")
        end
      end
      unless cursor == bytes.size
        raise CorruptPartError.new("selected Array(JSON) .size0 window has trailing bytes")
      end

      # Charge retained grouping containers after whole-window checks and
      # before the first proportional Array allocation.
      retained_nodes.times { prepared.codec_budget.charge_node }
      prepared.codec_budget.charge_elements(retained_elements)
      grouped = Array(Array(Array(ObjectDocument))).new(mark_count)
      cursor = 0
      mark_count.times do |mark_index|
        parent_rows = Array(Array(ObjectDocument)).new(grid.physical_rows_at(first_mark + mark_index).to_i)
        flat_index = 0
        grid.physical_rows_at(first_mark + mark_index).times do
          size = uint64_le_at(bytes, cursor).to_i
          cursor += 8
          child_documents = Array(ObjectDocument).new(size)
          size.times do
            child_documents << flat_marks[mark_index][flat_index]
            flat_index += 1
          end
          parent_rows << child_documents
        end
        grouped << parent_rows
      end
      grouped
    end

    private def self.uint64_le_at(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("Array(JSON) .size0 value is truncated")
      end
      value = 0_u64
      8.times do |index|
        value |= bytes[offset + index].to_u64 << (index * 8)
      end
      value
    end

    # The raw schema is a caller-supplied declaration boundary. Reject JSON
    # before column-name rendering, schema snapshotting, or part metadata I/O;
    # inspect and zero-window reads share this preflight through prepare_read.
    private def self.reject_json_schema!(schema : Hash(String, BinaryDataType)) : Nil
      schema.each_value do |type|
        if type.contains_json?
          raise UnsupportedFormatError.new("JSON is outside the admitted persisted Object declaration grammar")
        end
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

    private def self.preflight_escaped_prefix!(prefix : String, hashed : Bool, limits : BinaryCodecLimits) : String
      PhysicalStreamName.validate_canonical_escaped_prefix(prefix)
      object_marks_size = checked_add_u64(prefix.bytesize.to_u64, ".object_structure.mrk2".bytesize.to_u64)
      ensure_name_size!(prefix.bytesize.to_u64, limits)
      ensure_name_size!(object_marks_size, limits)
      ensure_unhashed_name_size!(object_marks_size, hashed)
      String.new(prefix.to_slice)
    end

    private def self.preflight_and_copy_schema!(
      schema : Hash(String, BinaryDataType),
      column_prefix : String,
      hashed : Bool,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      typed_schema_depth : Int32 = 1,
    ) : Hash(String, BinaryDataType)
      count = schema.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      context = BinaryCodecContext.new(limits, nil, false, budget, false, false)
      expanded_total = 0_u64
      schema.each do |path, type|
        if type.tag == BinaryDataType::TAG_DYNAMIC
          unless ObjectDeclaredDynamicDeclaration.max_types_for(type)
            raise UnsupportedFormatError.new("Object typed Dynamic descriptor is not canonical")
          end
        end
        escaped_size = PhysicalStreamName.escaped_size(path)
        logical_size = checked_add_u64(column_prefix.bytesize.to_u64, checked_add_u64(1_u64, escaped_size))
        ensure_name_size!(logical_size, limits)
        marks_size = checked_add_u64(logical_size, ".mrk2".bytesize.to_u64)
        ensure_name_size!(marks_size, limits)
        ensure_unhashed_name_size!(marks_size, hashed)
        expanded_total = checked_add_u64(expanded_total, logical_size)
        ensure_name_size!(expanded_total, limits)
        context.validate_type_tree(type, typed_schema_depth)
        if type.contains_variant? && ObjectRecursiveDeclaration.measure_descriptor(type, limits, typed_schema_depth).nil?
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

    # Discovers only schema-derived names. Structure bytes are not trusted or
    # parsed here; every site's exact first parse is retained later in its
    # BinaryDynamicBulkPlan.
    private def self.discover_typed_dynamic_metadata_names!(
      column_name : String,
      schema : Hash(String, BinaryDataType),
      typed_schema_depth : Int32,
      limits : BinaryCodecLimits,
      hashed : Bool,
      budget : BinaryCodecBudget,
    ) : Hash(String, Hash(String, String))
      shapes = Hash(String, ObjectDeclaredDynamicSites::Shape).new
      total_sites = 0_u64
      total_path_bytes = 0_u64
      schema.each do |path, type|
        next unless type.contains_dynamic?
        shape = ObjectDeclaredDynamicSites.shape_for(
          type, limits, object_declared_dynamic_root_depth(typed_schema_depth)
        )
        if shape.count == 0_u64
          raise UnsupportedFormatError.new("typed Object Dynamic descriptor has no declared Dynamic site")
        end
        total_sites = checked_add_u64(total_sites, shape.count)
        total_path_bytes = checked_add_u64(total_path_bytes, shape.path_bytes)
        shapes[String.new(path.to_slice)] = shape
      end
      return Hash(String, Hash(String, String)).new if total_sites == 0_u64

      if total_sites > limits.max_nodes.to_u64 || total_sites > limits.max_elements.to_u64
        raise CorruptPartError.new("typed Object Dynamic site roster exceeds codec limits")
      end
      # Reserve aggregate site/name work before allocating a per-field map.
      budget.ensure_future_nodes(total_sites)
      budget.ensure_future_elements(total_sites)
      depth_factor = checked_add_u64(limits.max_depth.to_u64, 1_u64)
      path_work_bytes = checked_multiply_u64(total_path_bytes, depth_factor)
      budget.ensure_wire_bytes(path_work_bytes)

      names_by_field = Hash(String, Hash(String, String)).new(initial_capacity: shapes.size)
      total_name_bytes = 0_u64
      shapes.each do |path, shape|
        type = schema[path]? || raise(CorruptPartError.new("typed Object Dynamic schema changed during metadata discovery"))
        names = ObjectDocumentPhysicalPlan.typed_dynamic_structure_names(
          column_name,
          path,
          type,
          budget
        )
        unless names.size.to_u64 == shape.count
          raise CorruptPartError.new("typed Dynamic metadata names do not match the declared site count")
        end
        names.each do |_site_path, logical_name|
          ensure_name_size!(logical_name.bytesize.to_u64, limits)
          data_name_bytes = checked_add_u64(logical_name.bytesize.to_u64, ".bin".bytesize.to_u64)
          marks_name_bytes = checked_add_u64(logical_name.bytesize.to_u64, ".mrk2".bytesize.to_u64)
          ensure_name_size!(data_name_bytes, limits)
          ensure_name_size!(marks_name_bytes, limits)
          ensure_unhashed_name_size!(data_name_bytes, hashed)
          ensure_unhashed_name_size!(marks_name_bytes, hashed)
          total_name_bytes = checked_add_u64(total_name_bytes, logical_name.bytesize.to_u64)
          ensure_name_size!(total_name_bytes, limits)
        end
        names_by_field[String.new(path.to_slice)] = names
      end
      names_by_field
    end

    private def self.discover_typed_dynamic_metadata_names_at_site!(
      escaped_prefix : String,
      schema : Hash(String, BinaryDataType),
      typed_schema_depth : Int32,
      limits : BinaryCodecLimits,
      hashed : Bool,
      budget : BinaryCodecBudget,
    ) : Hash(String, Hash(String, String))
      shapes = Hash(String, ObjectDeclaredDynamicSites::Shape).new
      total_sites = 0_u64
      total_path_bytes = 0_u64
      schema.each do |path, type|
        next unless type.contains_dynamic?
        shape = ObjectDeclaredDynamicSites.shape_for(
          type, limits, object_declared_dynamic_root_depth(typed_schema_depth)
        )
        if shape.count == 0_u64
          raise UnsupportedFormatError.new("typed Object Dynamic descriptor has no declared Dynamic site")
        end
        total_sites = checked_add_u64(total_sites, shape.count)
        total_path_bytes = checked_add_u64(total_path_bytes, shape.path_bytes)
        shapes[String.new(path.to_slice)] = shape
      end
      return Hash(String, Hash(String, String)).new if total_sites == 0_u64

      if total_sites > limits.max_nodes.to_u64 || total_sites > limits.max_elements.to_u64
        raise CorruptPartError.new("typed Object Dynamic site roster exceeds codec limits")
      end
      budget.ensure_future_nodes(total_sites)
      budget.ensure_future_elements(total_sites)
      depth_factor = checked_add_u64(limits.max_depth.to_u64, 1_u64)
      path_work_bytes = checked_multiply_u64(total_path_bytes, depth_factor)
      budget.ensure_wire_bytes(path_work_bytes)

      names_by_field = Hash(String, Hash(String, String)).new(initial_capacity: shapes.size)
      total_name_bytes = 0_u64
      shapes.each do |path, shape|
        type = schema[path]? || raise(CorruptPartError.new("typed Object Dynamic schema changed during metadata discovery"))
        names = ObjectDocumentPhysicalPlan.typed_dynamic_structure_names_at_site(
          escaped_prefix,
          path,
          type,
          budget
        )
        unless names.size.to_u64 == shape.count
          raise CorruptPartError.new("typed Dynamic metadata names do not match the declared site count")
        end
        names.each do |_site_path, logical_name|
          ensure_name_size!(logical_name.bytesize.to_u64, limits)
          data_name_bytes = checked_add_u64(logical_name.bytesize.to_u64, ".bin".bytesize.to_u64)
          marks_name_bytes = checked_add_u64(logical_name.bytesize.to_u64, ".mrk2".bytesize.to_u64)
          ensure_name_size!(data_name_bytes, limits)
          ensure_name_size!(marks_name_bytes, limits)
          ensure_unhashed_name_size!(data_name_bytes, hashed)
          ensure_unhashed_name_size!(marks_name_bytes, hashed)
          total_name_bytes = checked_add_u64(total_name_bytes, logical_name.bytesize.to_u64)
          ensure_name_size!(total_name_bytes, limits)
        end
        names_by_field[String.new(path.to_slice)] = names
      end
      names_by_field
    end

    # Ordinary Object callers historically root typed Dynamic metadata at
    # Object depth 2, even though their standalone typed-schema traversal
    # starts at depth 1. A nested JSON site already supplies the absolute
    # typed-field depth, so retain the legacy floor without adding the JSON
    # wrapper depth a second time.
    private def self.object_declared_dynamic_root_depth(typed_schema_depth : Int32) : Int32
      typed_schema_depth < 2_i32 ? 2_i32 : typed_schema_depth
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
      type_depth : Int32 = 1,
    ) : Tuple(DynamicStructure, Int32)
      context = BinaryCodecContext.new(limits, bytes, false, budget, false, false)
      structure, statistics_offset = DynamicStructureCodec.read_with_statistics_offset(
        context,
        type_depth: type_depth,
      )
      context.ensure_consumed
      {structure, statistics_offset}
    end

    private def self.validate_layout!(object : ObjectStructure) : Nil
      ObjectSharedBucketLayout.validate!(object)
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

    private def self.validate_expected_outer_rows!(actual : Array(UInt64), expected : Array(UInt64)) : Nil
      unless actual.size == expected.size
        raise CorruptPartError.new("Object site mark count differs from its parent physical grid")
      end
      actual.size.times do |index|
        unless actual[index] == expected[index]
          raise CorruptPartError.new("Object site row grid differs from its parent physical grid")
        end
      end
      nil
    end

    # Re-reading an Object child after the Dynamic discriminator census must
    # not silently switch to a different metadata roster between discovery and
    # value decoding. Statistics are hints, so compare Object/Dynamic schemas
    # and typed descendants while deliberately ignoring statistics payloads.
    private def self.same_document_plan_rosters?(
      actual : ObjectDocumentPlan,
      expected : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      json_descriptor_depth : Int32,
      inferred_actual_root_depth : Int32,
    ) : Bool
      actual_object = actual.structures.object
      expected_object = expected.structures.object
      return false unless same_object_roster?(actual_object, expected_object)

      context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      actual_object.dynamic_path_count.times do |index|
        path = actual_object.dynamic_path_at(index)
        actual_dynamic = actual.structures.dynamic_for(path)
        expected_dynamic = expected.structures.dynamic_for(path)
        return false unless same_dynamic_roster?(
                              actual_dynamic, expected_dynamic, context, inferred_actual_root_depth
                            )

        actual_json_bindings = actual.root_dynamic_json_object_leaf_plans_for(path, budget)
        expected_json_bindings = expected.root_dynamic_json_object_leaf_plans_for(path, budget)
        return false unless actual_json_bindings.size == expected_json_bindings.size

        actual_json_bindings.sort! do |left, right|
          compare_dynamic_json_leaf_keys(left[0], right[0])
        end
        expected_json_bindings.sort! do |left, right|
          compare_dynamic_json_leaf_keys(left[0], right[0])
        end

        inferred_actual_depth64 = inferred_actual_root_depth.to_i64
        if inferred_actual_depth64 <= 0_i64 || inferred_actual_depth64 > budget.limits.max_depth.to_i64
          raise CorruptPartError.new("inferred Object Dynamic descriptor depth exceeds the configured limit")
        end
        actual_json_bindings.size.times do |binding_index|
          actual_entry = actual_json_bindings[binding_index]
          expected_entry = expected_json_bindings[binding_index]
          key = actual_entry[0]
          return false unless key == expected_entry[0]

          leaf_depth64 = inferred_actual_depth64 + key.descriptor_path_size.to_i64
          if leaf_depth64 <= 0_i64 || leaf_depth64 > budget.limits.max_depth.to_i64
            raise CorruptPartError.new("inferred Dynamic JSON descriptor depth exceeds the configured limit")
          end
          child_root_depth64 = leaf_depth64 + 1_i64
          if child_root_depth64 > Int32::MAX.to_i64
            raise CorruptPartError.new("inferred Dynamic JSON child descriptor depth exceeds Int32")
          end
          unless same_document_plan_rosters?(
                   actual_entry[1],
                   expected_entry[1],
                   budget,
                   leaf_depth64.to_i32,
                   child_root_depth64.to_i32,
                 )
            return false
          end
        end
      end

      return false unless actual.typed_path_count == expected.typed_path_count
      actual.typed_path_count.times do |index|
        actual_path = actual.typed_path_at(index)
        expected_path = expected.typed_path_at(index)
        return false unless actual_path == expected_path
        actual_type = actual.typed_type_for(actual_path)
        expected_type = expected.typed_type_for(expected_path)
        context.validate_type_tree(actual_type, json_descriptor_depth + 1)
        context.validate_type_tree(expected_type, json_descriptor_depth + 1) unless actual_type.same?(expected_type)
        return false unless actual_type == expected_type
      end

      return false unless actual.typed_dynamic_count == expected.typed_dynamic_count
      actual.typed_dynamic_count.times do |index|
        path = actual.typed_dynamic_path_at(index)
        return false unless expected.has_typed_dynamic?(path)
        actual_site_count = actual.typed_dynamic_site_count_for(path)
        return false unless actual_site_count == expected.typed_dynamic_site_count_for(path)
        actual_site_count.times do |site_index|
          site_path = actual.typed_dynamic_site_path_at(path, site_index)
          return false unless site_path == expected.typed_dynamic_site_path_at(path, site_index)
          actual_type = actual.typed_dynamic_site_type_for(path, site_path)
          expected_type = expected.typed_dynamic_site_type_for(path, site_path)
          actual_object_depth = actual.typed_dynamic_site_object_depth_for(path, site_path)
          expected_object_depth = expected.typed_dynamic_site_object_depth_for(path, site_path)
          return false unless actual_object_depth == expected_object_depth
          if json_descriptor_depth <= 0_i32 || actual_object_depth <= 0_i32
            raise CorruptPartError.new("typed Object Dynamic descriptor depth is invalid")
          end
          # ObjectDocumentPlan stores this coordinate relative to its local
          # Object root (2). Rebase it under the inherited JSON descriptor:
          # Object typed fields start at JSON depth + 1, while `object_depth`
          # starts at local depth 2, hence JSON depth - 1 + object depth.
          absolute_dynamic_depth = json_descriptor_depth.to_i64 - 1_i64 + actual_object_depth.to_i64
          if absolute_dynamic_depth <= 0_i64 || absolute_dynamic_depth >= Int32::MAX.to_i64
            raise CorruptPartError.new("typed Object Dynamic actual type depth exceeds Int32")
          end
          declared_dynamic_depth = absolute_dynamic_depth.to_i32
          actual_arm_depth = (absolute_dynamic_depth + 1_i64).to_i32
          context.validate_type_tree(actual_type, declared_dynamic_depth)
          context.validate_type_tree(expected_type, declared_dynamic_depth) unless actual_type.same?(expected_type)
          return false unless actual_type == expected_type
          unless same_dynamic_roster?(
                   actual.typed_dynamic_site_structure_for(path, site_path),
                   expected.typed_dynamic_site_structure_for(path, site_path),
                   context,
                   actual_arm_depth,
                 )
            return false
          end
        end
      end
      true
    end

    private def self.compare_dynamic_json_leaf_keys(
      left : BinaryDynamicJsonLeafKey,
      right : BinaryDynamicJsonLeafKey,
    ) : Int32
      site_order = left.compare_dynamic_site(right)
      return site_order unless site_order == 0
      arm_order = left.canonical_arm_index <=> right.canonical_arm_index
      return arm_order unless arm_order == 0
      common_path = Math.min(left.descriptor_path_size, right.descriptor_path_size)
      common_path.times do |index|
        order = left.descriptor_child_at(index) <=> right.descriptor_child_at(index)
        return order unless order == 0
      end
      left.descriptor_path_size <=> right.descriptor_path_size
    end

    private def self.same_object_roster?(actual : ObjectStructure, expected : ObjectStructure) : Bool
      return false unless actual.version == expected.version &&
                          actual.shared_data_version == expected.shared_data_version &&
                          actual.bucket_count == expected.bucket_count &&
                          actual.legacy_max_dynamic_paths == expected.legacy_max_dynamic_paths &&
                          actual.dynamic_path_count == expected.dynamic_path_count
      actual.dynamic_path_count.times do |index|
        return false unless expected.has_dynamic_path?(actual.dynamic_path_at(index))
      end
      true
    end

    private def self.same_dynamic_roster?(
      actual : DynamicStructure,
      expected : DynamicStructure,
      context : BinaryCodecContext,
      type_depth : Int32,
    ) : Bool
      return false unless actual.type_count == expected.type_count && actual.shared_index == expected.shared_index
      actual.type_count.times do |actual_index|
        actual_type = actual.type_at(actual_index)
        context.validate_type_tree(actual_type, type_depth)
        found = false
        expected.type_count.times do |expected_index|
          expected_type = expected.type_at(expected_index)
          context.validate_type_tree(expected_type, type_depth) unless actual_type.same?(expected_type)
          if actual_type == expected_type
            found = true
            break
          end
        end
        return false unless found
      end
      true
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
        if plan.has_typed_dynamic?(path)
          append_dynamic_bulk_bindings!(bindings, :typed_dynamic, path, physical.typed_dynamic(path), hashed)
        else
          append_bulk_bindings!(bindings, :typed, path, "", physical.typed(path), hashed)
        end
      end

      object = plan.structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        dynamic = plan.structures.dynamic_for(path)
        dynamic.canonical_variant_names.each do |arm|
          append_bulk_bindings!(bindings, :dynamic, path, arm, physical.dynamic_arm(path, arm), hashed)
        end
      end
      unless physical.shared_bucket_count == ObjectSharedBucketLayout.bucket_count(object)
        raise CorruptPartError.new("shared Object physical buckets disagree with their metadata")
      end
      if object.shared_data_version == 0_u64
        append_bulk_bindings!(bindings, :shared, "", "", physical.shared, hashed)
      elsif object.shared_data_version == 1_u64
        physical.shared_bucket_count.times do |bucket_index|
          append_bulk_bindings!(
            bindings,
            :shared,
            "",
            "",
            physical.shared_bucket(bucket_index),
            hashed,
            bucket_index.to_i32
          )
        end
      end
      bindings
    end

    private def self.resolve_advanced_shared_inputs!(
      source : PartStreamSource,
      physical : ObjectDocumentPhysicalPlan,
      hashed : Bool,
      budget : BinaryCodecBudget,
    ) : Tuple(Hash(String, ObjectSharedPhysicalLaneInput), Array(ObjectSharedPhysicalBucketLaneInputs))
      copy_count = ObjectSharedAdvancedDocumentCodec::COPY_LANES.size.to_u64
      bucket_count = physical.shared_bucket_count.to_u64
      owner_count = checked_add_u64(copy_count, bucket_count)
      budget.ensure_future_nodes(owner_count)
      budget.ensure_future_elements(owner_count)

      copy_inputs = Hash(String, ObjectSharedPhysicalLaneInput).new(initial_capacity: copy_count.to_i)
      ObjectSharedAdvancedDocumentCodec::COPY_LANES.each do |lane|
        logical_name = physical.advanced_copy_stream_name(lane)
        data_name, marks_name = file_pair(logical_name, hashed)
        validate_physical_name!(data_name)
        validate_physical_name!(marks_name)
        copy_inputs[String.new(lane.to_slice)] = source.physical_lane_input(data_name, marks_name)
        budget.charge_node
      end

      bucket_inputs = Array(ObjectSharedPhysicalBucketLaneInputs).new(physical.shared_bucket_count)
      physical.shared_bucket_count.times do |bucket_index|
        lanes = Hash(String, ObjectSharedPhysicalLaneInput).new(
          initial_capacity: ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.size
        )
        ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
          logical_name = physical.advanced_bucket_stream_name(bucket_index, lane)
          data_name, marks_name = file_pair(logical_name, hashed)
          validate_physical_name!(data_name)
          validate_physical_name!(marks_name)
          lanes[String.new(lane.to_slice)] = source.physical_lane_input(data_name, marks_name)
        end
        bucket_inputs << ObjectSharedPhysicalBucketLaneInputs.new(lanes)
        budget.charge_node
      end
      budget.charge_elements(owner_count)
      {copy_inputs, bucket_inputs}
    end

    # MAP0/MAP1 do not have the advanced physical Data lanes. Their public
    # selected-path projection reads the ordinary shared MAP lane(s), validates
    # every complete physical mark grid, and then projects the requested path.
    # This is bounded by the selected mark window but is not the advanced
    # path-only Data reader: MAP1 validates/decodes every shared bucket.
    private def self.read_map_shared_path_marks(
      source : PartStreamSource,
      physical : ObjectDocumentPhysicalPlan,
      descriptor : ObjectDocumentFileDescriptor,
      path : String,
      first_mark : Int,
      mark_count : Int,
      hashed : Bool,
      budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Array(Array(BinaryValue))
      object = descriptor.plan.structures.object
      version = object.shared_data_version
      unless version == 0_u64 || version == 1_u64
        raise UnsupportedFormatError.new("selected Object shared path requires MAP0 or MAP_WITH_BUCKETS metadata")
      end

      bucket_count = ObjectSharedBucketLayout.bucket_count(object)
      unless physical.shared_bucket_count == bucket_count
        raise CorruptPartError.new("selected Object shared bucket count disagrees with its descriptor")
      end
      physical.preflight_shared_bucket_bindings!(hashed, budget)

      physical_rows = descriptor.mark_row_counts
      selected_row_total = 0_u64
      mark_count.times do |offset|
        rows = physical_rows[first_mark + offset]
        if rows > Int32::MAX.to_u64
          raise CorruptPartError.new("selected Object shared rows exceed the supported in-memory domain")
        end
        selected_row_total = checked_add_u64(selected_row_total, rows)
      end

      # Admit the detached lane maps/streams and the selected-row roster before
      # constructing any proportional owner. BinaryBulkCodec accounts the
      # actual selected lane bytes and recursive values on this same budget.
      role_total = 0_u64
      bucket_count.times do |bucket_index|
        lane_plan = version == 0_u64 ? physical.shared : physical.shared_bucket(bucket_index)
        lane_names = lane_plan.stream_names
        role_total = checked_add_u64(role_total, lane_names.size.to_u64)
      end
      lane_owner_count = checked_add_u64(
        checked_add_u64(role_total, role_total),
        checked_add_u64(
          checked_add_u64(bucket_count.to_u64 * 2_u64, mark_count.to_u64 * 2_u64),
          1_u64,
        )
      )
      budget.ensure_future_nodes(lane_owner_count)
      budget.ensure_future_elements(lane_owner_count)
      budget.preflight_children(lane_owner_count)
      lane_owner_count.times { budget.charge_node }

      selected_rows = Array(UInt64).new(mark_count)
      mark_count.times do |offset|
        selected_rows << physical_rows[first_mark + offset]
      end

      bucket_streams = Array(BinaryBulkStreams).new(bucket_count)
      bucket_count.times do |bucket_index|
        lane_plan = version == 0_u64 ? physical.shared : physical.shared_bucket(bucket_index)
        lane_names = lane_plan.stream_names
        lane_roles = Hash(String, BinaryBulkStream).new(initial_capacity: lane_names.size)
        lane_names.each_key do |role|
          prefix_size = lane_plan.prefix_size_for(role)
          data_name = lane_plan.data_file_for(role, hashed)
          marks_name = lane_plan.marks_file_for(role, hashed)
          validate_physical_name!(data_name)
          validate_physical_name!(marks_name)

          grid = source.inspect_grid(data_name, marks_name, prefix_size, transport_budget)
          unless grid.prefix_size == prefix_size
            raise CorruptPartError.new("shared MAP lane prefix disagrees with its physical plan")
          end
          validate_same_rows!(grid, physical_rows)

          window = source.read_window(
            data_name,
            marks_name,
            first_mark,
            mark_count,
            prefix_size,
            transport_budget,
          )
          unless window.first_mark == first_mark && window.prefix_size == prefix_size
            raise CorruptPartError.new("shared MAP lane returned a different selected window")
          end
          rows_in_window = window.rows_per_mark
          offsets = window.offsets
          lane_bytes = window.bytes
          unless rows_in_window.size == mark_count && offsets.size.to_u64 == mark_count.to_u64 + 1_u64 &&
                 offsets.first? == prefix_size.to_u64 && offsets.last? == lane_bytes.size.to_u64
            raise CorruptPartError.new("shared MAP lane selected offsets do not span the returned window")
          end
          mark_count.times do |offset|
            unless rows_in_window[offset] == selected_rows[offset] && offsets[offset] <= offsets[offset + 1]
              raise CorruptPartError.new("shared MAP lane selected rows or offsets disagree with the Object grid")
            end
          end
          lane_roles[String.new(role.to_slice)] = BinaryBulkStream.new(lane_bytes, offsets)
        end
        bucket_streams << BinaryBulkStreams.new(mark_count, lane_roles)
      end

      coordinator_nodes = checked_add_u64(mark_count.to_u64, selected_row_total)
      budget.ensure_future_nodes(coordinator_nodes)
      budget.ensure_future_elements(selected_row_total)

      plan = descriptor.plan
      typed_path_count = plan.typed_path_count.to_u64
      typed_path_bytes = 0_u64
      plan.typed_path_count.times do |index|
        typed_path_bytes = checked_add_u64(typed_path_bytes, plan.typed_path_byte_size_at(index).to_u64)
      end
      budget.ensure_future_nodes(typed_path_count)
      budget.preflight_children(typed_path_count)
      budget.ensure_wire_bytes(typed_path_bytes)
      budget.charge_wire_bytes(typed_path_bytes)
      typed_schema = Hash(String, BinaryDataType).new(initial_capacity: plan.typed_path_count)
      plan.typed_path_count.times do |index|
        typed_path = plan.typed_path_at(index)
        typed_schema[typed_path] = plan.typed_type_for(typed_path)
        budget.charge_node
      end

      decoded = if version == 0_u64
                  ObjectDocumentSharedCodec.decode_with_budget(
                    bucket_streams[0], selected_rows, object, typed_schema, budget,
                    0, mark_count, BinaryBulkProfile.single_stream,
                  )
                else
                  # The bucket codec consumes only shared MAP lanes. The empty
                  # metadata/typed/dynamic owners here are a narrow carrier; no
                  # root Object or Copy lane is reconstructed by this path.
                  carrier = ObjectDocumentStreams.new(
                    ObjectDynamicStructureStreams.new(Bytes.empty, Hash(String, Bytes).new),
                    selected_rows,
                    Hash(String, BinaryBulkStreams).new,
                    Hash(String, DynamicValueStreams).new,
                    bucket_streams,
                  )
                  ObjectDocumentSharedBucketsCodec.decode_with_budget(
                    carrier, selected_rows, object, typed_schema, budget,
                    0, mark_count, BinaryBulkProfile.single_stream,
                  )
                end

      unless decoded.size == mark_count
        raise CorruptPartError.new("selected Object shared MAP returned the wrong number of marks")
      end
      budget.ensure_future_nodes(coordinator_nodes)
      budget.ensure_future_elements(selected_row_total)
      budget.charge_elements(selected_row_total)

      dynamic_type = BinaryDataType.dynamic(max_types: ObjectSharedAdvancedChunkCodec::JSON_DYNAMIC_MAX_TYPES)
      result = Array(Array(BinaryValue)).new(mark_count)
      mark_count.times do |mark_index|
        entries_by_row = decoded[mark_index]
        unless entries_by_row.size.to_u64 == selected_rows[mark_index]
          raise CorruptPartError.new("selected Object shared MAP rows disagree with the outer mark grid")
        end
        mark_result = Array(BinaryValue).new(selected_rows[mark_index].to_i)
        entries_by_row.each do |entries|
          value = nil.as(BinaryValue?)
          entries.each do |entry|
            next unless entry[0] == path
            if value
              raise CorruptPartError.new("selected Object shared MAP path is duplicated within a row")
            end
            value = entry[1]
          end
          mark_result << BinaryValue.dynamic(dynamic_type, value)
          budget.charge_node
        end
        result << mark_result
        budget.charge_node
      end
      result
    end

    private def self.validate_advanced_shared_rows!(
      rows_by_mark : Array(Array(ObjectSharedMapRow)),
      schema : Hash(String, BinaryDataType),
      object : ObjectStructure,
      budget : BinaryCodecBudget,
    ) : Nil
      entry_count = 0_u64
      path_bytes = 0_u64
      rows_by_mark.each do |rows|
        rows.each do |row|
          row.entry_count.times do |entry_index|
            entry = row.entry_at(entry_index)
            entry_count = checked_add_u64(entry_count, 1_u64)
            path_bytes = checked_add_u64(path_bytes, entry.path_byte_size.to_u64)
            value = entry.value
            if value.type.tag == BinaryDataType::TAG_NOTHING || value.is_null? ||
               value.type.tag == BinaryDataType::TAG_NULLABLE
              raise CorruptPartError.new("advanced shared Object rows cannot contain top-level NULL values")
            end
          end
        end
      end

      conflict_roster = checked_add_u64(schema.size.to_u64, object.dynamic_path_count.to_u64)
      comparison_work = checked_add_u64(entry_count, checked_multiply_u64(path_bytes, conflict_roster))
      # Compare raw path bytes against every typed and Dynamic declaration
      # before selection, so an invalid unselected mark cannot hide a conflict.
      # The bounded work is admitted before any data-dependent nested scan.
      # The caller's codec budget has already paid for physical decoding; this
      # additional pass is separately charged as semantic reconciliation.
      budget.ensure_future_elements(comparison_work)
      budget.charge_elements(comparison_work)
      rows_by_mark.each do |rows|
        rows.each do |row|
          row.entry_count.times do |entry_index|
            entry = row.entry_at(entry_index)
            conflict = schema.each_key.any? { |path| raw_path_matches?(entry, path) }
            if !conflict
              object.dynamic_path_count.times do |path_index|
                if raw_path_matches_dynamic?(entry, object, path_index)
                  conflict = true
                  break
                end
              end
            end
            if conflict
              raise CorruptPartError.new("shared Object path overlaps a typed or Dynamic path")
            end
          end
        end
      end
      nil
    end

    private def self.select_advanced_shared_rows(
      source : Array(Array(ObjectSharedMapRow)),
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
    ) : Array(Array(ObjectSharedMapRow))
      if first_mark < 0 || mark_count < 0 || first_mark > source.size || mark_count > source.size - first_mark
        raise CorruptPartError.new("selected advanced shared Object window is outside the complete parent grid")
      end
      retained_rows = 0_u64
      mark_count.times do |offset|
        retained_rows = checked_add_u64(retained_rows, source[first_mark + offset].size.to_u64)
      end
      retained = checked_add_u64(mark_count.to_u64, retained_rows)
      # This helper creates a selected outer/inner matrix and the streams
      # constructor takes one detached snapshot of that matrix as a second
      # owner. Preflight both before the first proportional array is allocated.
      owners = checked_multiply_u64(retained, 2_u64)
      budget.ensure_future_nodes(owners)
      budget.ensure_future_elements(owners)
      owners.times { budget.charge_node }
      budget.charge_elements(owners)

      selected = Array(Array(ObjectSharedMapRow)).new(mark_count)
      mark_count.times do |offset|
        selected << source[first_mark + offset].dup
      end
      selected
    end

    private def self.raw_path_matches?(entry : ObjectSharedMapEntry, path : String) : Bool
      bytes = path.to_slice
      return false unless bytes.size == entry.path_byte_size
      bytes.size.times do |index|
        return false unless bytes[index] == entry.path_byte_at(index)
      end
      true
    end

    private def self.raw_path_matches_dynamic?(
      entry : ObjectSharedMapEntry,
      object : ObjectStructure,
      path_index : Int,
    ) : Bool
      return false unless object.dynamic_path_byte_size(path_index) == entry.path_byte_size
      entry.path_byte_size.times do |index|
        return false unless object.dynamic_path_byte_at(path_index, index) == entry.path_byte_at(index)
      end
      true
    end

    private def self.append_dynamic_bulk_bindings!(
      bindings : Array(BulkBinding),
      kind : Symbol,
      path : String,
      physical : BinaryDynamicBulkPhysicalPlan,
      hashed : Bool,
    ) : Nil
      physical.data_stream_names.each_key do |role|
        prefix_size = physical.prefix_size_for(role)
        data_name = physical.data_file_for(role, hashed)
        marks_name = physical.marks_file_for(role, hashed)
        validate_physical_name!(data_name)
        validate_physical_name!(marks_name)
        bindings << BulkBinding.new(
          kind,
          String.new(path.to_slice),
          "",
          String.new(role.to_slice),
          data_name,
          marks_name,
          prefix_size
        )
      end
      nil
    end

    private def self.typed_dynamic_header_bindings(bindings : Array(BulkBinding)) : Array(BulkBinding)
      bindings.select do |binding|
        binding.kind == :typed_dynamic &&
          BinaryBulkPhysicalPrefixAdapter.variant_discriminator_role?(binding.role, binding.prefix_size)
      end
    end

    private def self.append_bulk_bindings!(
      bindings : Array(BulkBinding),
      kind : Symbol,
      path : String,
      arm : String,
      physical : BinaryBulkPhysicalPlan,
      hashed : Bool,
      bucket_index : Int32? = nil,
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
          prefix_size,
          bucket_index
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
      &block : CompressedMarkGrid, Int32, Symbol, String, String, String, String ->
    ) : Nil
      bulk_bindings.each do |binding|
        grid = source.inspect_grid(binding.data_name, binding.marks_name, binding.prefix_size, budget)
        validate_same_rows!(grid, outer_rows)
        yield grid, binding.prefix_size, binding.kind, binding.path, binding.arm, binding.role, binding.data_name
      end
      discriminator_bindings.each do |binding|
        grid = source.inspect_grid(
          binding.data_name,
          binding.marks_name,
          DynamicDiscriminatorCodec::HEADER_BYTES.to_i,
          budget
        )
        validate_same_rows!(grid, outer_rows)
        yield grid, DynamicDiscriminatorCodec::HEADER_BYTES.to_i, :dynamic, binding.path, "", "", binding.data_name
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

    private def self.discriminator_stream(
      window : CompressedMarkWindow,
      logical_rows : Array(UInt64)? = nil,
      logical_first : Int = 0,
    ) : DynamicDiscriminatorStream
      bytes = window.bytes
      offsets = window.offsets
      physical_rows = window.rows_per_mark
      if rows = logical_rows
        if logical_first < 0 || logical_first > rows.size || physical_rows.size > rows.size - logical_first
          raise CorruptPartError.new("selected discriminator rows are outside the child occurrence grid")
        end
      end
      unless window.prefix_size == DynamicDiscriminatorCodec::HEADER_BYTES &&
             offsets.size == physical_rows.size + 1 &&
             offsets.first? == DynamicDiscriminatorCodec::HEADER_BYTES &&
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
      marks = Array(DynamicDiscriminatorMark).new(physical_rows.size + 1)
      physical_rows.size.times do |index|
        row_count = logical_rows ? logical_rows[logical_first + index] : physical_rows[index]
        marks << DynamicDiscriminatorMark.new(offsets[index], row_count)
      end
      marks << DynamicDiscriminatorMark.new(offsets.last, 0_u64)
      DynamicDiscriminatorStream.new(bytes, marks)
    end

    private def self.metadata_total_size(
      object_bytes : Bytes,
      dynamics : Hash(String, Bytes),
      typed_dynamics : Hash(String, Hash(String, Bytes)),
    ) : UInt64
      total = object_bytes.size.to_u64
      dynamics.each_value { |bytes| total = checked_add_u64(total, bytes.size.to_u64) }
      typed_dynamics.each_value do |sites|
        sites.each_value { |bytes| total = checked_add_u64(total, bytes.size.to_u64) }
      end
      total
    end

    private def self.merge_typed_dynamic_values!(
      result : Array(Array(ObjectDocument)),
      dynamic_rows : Hash(String, Array(Array(BinaryValue))),
      dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
    ) : Array(Array(ObjectDocument))
      return result if dynamic_plans.empty?
      unless dynamic_rows.size == dynamic_plans.size
        raise CorruptPartError.new("typed Dynamic values do not match the retained metadata plans")
      end

      row_count = 0_u64
      path_copy_bytes = 0_u64
      result.each_with_index do |marks, mark_index|
        dynamic_rows.each_value do |marks_values|
          unless marks_values.size == result.size && marks_values[mark_index].size == marks.size
            raise CorruptPartError.new("typed Dynamic selected rows disagree with the Object result grid")
          end
        end
        marks.each do |document|
          row_count = checked_add_u64(row_count, 1_u64)
          document.path_count.times do |path_index|
            path_copy_bytes = checked_add_u64(path_copy_bytes, checked_multiply_u64(document.path_byte_size_at(path_index).to_u64, 2_u64))
          end
          dynamic_plans.each_key do |path|
            path_copy_bytes = checked_add_u64(path_copy_bytes, checked_multiply_u64(path.bytesize.to_u64, 2_u64))
          end
        end
      end
      copied_fields = 0_u64
      row_count.times do
        copied_fields = checked_add_u64(copied_fields, dynamic_plans.size.to_u64)
      end
      result.each do |marks|
        marks.each do |document|
          copied_fields = checked_add_u64(copied_fields, document.path_count.to_u64)
        end
      end
      budget.ensure_future_nodes(row_count)
      budget.ensure_future_elements(copied_fields)
      budget.ensure_wire_bytes(path_copy_bytes)

      dynamic_plans.each_key do |path|
        unless schema.has_key?(path)
          raise CorruptPartError.new("typed Dynamic retained plan has no declared schema path")
        end
      end
      result.each_with_index do |marks, mark_index|
        marks.each_with_index do |document, row_index|
          fields = Hash(String, BinaryValue).new(initial_capacity: document.path_count + dynamic_plans.size)
          document.path_count.times do |path_index|
            path = document.path_at(path_index)
            fields[path] = document.value_for(path)
          end
          dynamic_plans.each_key do |path|
            if document.has_path?(path)
              raise CorruptPartError.new("typed Dynamic Object path collides with decoded Object fields")
            end
            fields[path] = dynamic_rows[path][mark_index][row_index]
          end
          budget.charge_node
          budget.charge_elements(fields.size.to_u64) if fields.size > 0
          result[mark_index][row_index] = begin
            ObjectDocument.new(fields)
          rescue ex : ArgumentError
            raise CorruptPartError.new("invalid assembled Object document: #{ex.message}")
          end
        end
      end
      budget.charge_wire_bytes(path_copy_bytes)
      result
    end

    private def self.checked_multiply_u64(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Object file reader size accounting overflows UInt64")
      end
      left * right
    end

    private def self.descriptor_stream_names!(
      physical : ObjectDocumentPhysicalPlan,
      hashed : Bool,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      additional_name : String? = nil,
    ) : Tuple(Array(String), Array(String))
      count = physical.stream_count.to_u64 + (additional_name ? 1_u64 : 0_u64)
      budget.preflight_children(count) if count > 0_u64
      logical_names = physical.stream_names
      if name = additional_name
        if logical_names.includes?(name)
          raise CorruptPartError.new("Array(JSON) wrapper stream collides with an inner Object lane")
        end
        logical_names << String.new(name.to_slice)
        logical_names.sort!
      end
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

    private def self.same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end
  end
end
