require "./compact_shared_plan_workspace_error"

module CrystalClick
  # Single-part typed table backend for Compact physical storage. It preserves
  # WidePartTableBatch carriers while delegating static and Dynamic lifecycle
  # decoding to Compact readers and conversion to established batch adapters.
  class CompactPartTable
    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private alias CompactColumnReader = CompactBinaryBulkColumnReader | CompactDynamicBulkColumnReader
    private alias SelectedReader = {String, String, BinaryDataType, CompactColumnReader}
    private alias SelectedCarrier = CompactJsonColumnMark
    private alias CompactBinaryMarkCarrier = Array(BinaryValue) | Slice(UInt64)
    private alias MaterializedMark = {Array(CompactBinaryMarkCarrier), Array(SelectedCarrier), Array(Slice(UInt32)), UInt64}
    private EMPTY_JSON_UINT32_PATH_VALUES = [] of Slice(UInt32)

    @columns : Array(String)
    @column_types : Array({String, String})
    @column_sources : Array({String, String, String})
    @readers : Array(SelectedReader)
    @direct_uint64_readers : Array(Bool)
    @json_readers : Array(CompactJsonColumnAdapter)
    @json_uint32_path_readers : Array(CompactJsonUInt32PathReader)
    @column_reader_slots : Array(Tuple(Symbol, Int32))
    @part_path : String
    @emit_part_name : String
    @emit_part_path : String
    @mark_row_counts : Array(UInt64)
    @transport_budget : CompressedStreamBudget
    @direct_uint64_scan_context : CompactPartPhysicalContext?

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : CompactPartTable
      new(parts, columns)
    end

    # :nodoc:
    # Reopen this physical part on a worker while preserving the owning table's
    # cumulative transport budget across worker admission and selected marks.
    def self.open_selected_typed_with_transport_budget(
      parts : Array(String),
      columns : Array(String),
      budget : CompressedStreamBudget,
      scan_context : CompactPartPhysicalContext? = nil,
    ) : CompactPartTable
      new(parts, columns, nil, budget, scan_context)
    end

    # :nodoc:
    # Projection children are physically stored below their parent part, but
    # callback identity belongs to the parent. The constructor validates and
    # binds the selected child beneath that parent before opening its columns.
    def self.open_selected_projection_child_typed(
      parent_path : String,
      projection_name : String,
      columns : Array(String),
    ) : CompactPartTable
      new([parent_path], columns, projection_name)
    end

    private def initialize(
      parts : Array(String),
      columns : Array(String),
      projection_name : String? = nil,
      shared_transport_budget : CompressedStreamBudget? = nil,
      shared_scan_context : CompactPartPhysicalContext? = nil,
    )
      unless parts.size == 1
        raise BoundsError.new("Compact table backend requires exactly one physical part")
      end
      if columns.empty?
        raise BoundsError.new("no columns selected")
      end
      if columns.size > WidePartTable::MAX_COLUMNS
        raise BoundsError.new("column count exceeds limit")
      end

      @columns = Array(String).new(columns.size)
      seen = Set(String).new
      columns.each do |column|
        if column.empty? || column.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
          raise BoundsError.new("column name is empty or exceeds limit")
        end
        raise BoundsError.new("duplicate selected column") unless seen.add?(column)
        @columns << String.new(column.to_slice)
      end

      if selected_projection_name = projection_name
        parent_path, parent_name = validate_selected_part(parts[0])
        @emit_part_name = String.new(parent_name.to_slice)
        @emit_part_path = String.new(parent_path.to_slice)
        @part_path = ProjectionChildSelection.projection_child_path!(parent_path, selected_projection_name)
        child_checksums = PartChecksums.open(@part_path)
        ProjectionChildSelection.validate_binding!(parent_path, selected_projection_name, child_checksums)
      else
        @part_path, @emit_part_name = validate_selected_part(parts[0])
        @emit_part_path = @part_path
      end
      budget = shared_transport_budget || CompressedStreamBudget.read_default
      @transport_budget = budget
      @direct_uint64_scan_context = nil
      projection_admission_session = if projection_name
                                       CompactProjectionAggregateReaderAdmissionSession.new(@part_path, budget)
                                     end
      metadata = PartMetadataFileReader.new(@part_path, budget)
      physical_columns = WidePart.parse_columns_metadata(metadata.read("columns.txt"))
      physical_types = Hash(String, String).new(initial_capacity: physical_columns.size)
      physical_columns.each do |name, type|
        raise CorruptPartError.new("duplicate Compact physical column") if physical_types.has_key?(name)
        physical_types[name] = type
      end

      direct_plain_uint64_selection = {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
                                        projection_name.nil? &&
                                          @columns.all? { |column| physical_types[column]? == "UInt64" }
                                      {% else %}
                                        false
                                      {% end %}
      if shared_scan_context
        unless direct_plain_uint64_selection &&
               shared_scan_context.data_path == File.join(@part_path, "data.bin") &&
               shared_scan_context.transport_budget.same?(budget)
          raise CorruptPartError.new("shared Compact UInt64 scan context does not match its selected part")
        end
        @direct_uint64_scan_context = shared_scan_context
      elsif direct_plain_uint64_selection
        @direct_uint64_scan_context = CompactPartPhysicalContext.open(@part_path, budget)
      end

      @readers = Array(SelectedReader).new(@columns.size)
      @direct_uint64_readers = Array(Bool).new(@columns.size)
      @json_readers = Array(CompactJsonColumnAdapter).new(@columns.size)
      @json_uint32_path_readers = Array(CompactJsonUInt32PathReader).new(@columns.size)
      @column_reader_slots = Array(Tuple(Symbol, Int32)).new(@columns.size)
      @column_types = Array({String, String}).new(@columns.size)
      @column_sources = Array({String, String, String}).new(@columns.size)
      @mark_row_counts = [] of UInt64
      row_count = nil.as(UInt64?)

      @columns.each do |column|
        source_type = physical_types[column]?
        unless source_type
          path = compact_json_uint32_path_parts(column)
          unless path
            raise CorruptPartError.new("selected column is absent from Compact columns.txt")
          end
          if projection_name
            raise UnsupportedFormatError.new("Compact JSON typed paths are not admitted for projection children")
          end
          parent_column, field_name = path
          parent_type = physical_types[parent_column]? ||
                        raise(CorruptPartError.new("selected column is absent from Compact columns.txt"))
          path_reader = CompactJsonUInt32PathReader.open(
            @part_path,
            physical_columns,
            column,
            parent_column,
            parent_type,
            field_name,
            budget,
          )
          if existing_rows = row_count
            unless path_reader.row_count == existing_rows
              raise CorruptPartError.new("selected Compact columns have different parent row counts")
            end
            unless path_reader.mark_row_counts == @mark_row_counts
              raise CorruptPartError.new("selected Compact columns have different parent mark grids")
            end
          else
            row_count = path_reader.row_count
            @mark_row_counts = path_reader.mark_row_counts
          end

          @column_reader_slots << {:json_uint32, @json_uint32_path_readers.size}
          @json_uint32_path_readers << path_reader
          @column_types << {String.new(column.to_slice), String.new(path_reader.schema_declaration.to_slice)}
          @column_sources << {
            String.new(column.to_slice),
            String.new(parent_column.to_slice),
            String.new(parent_type.to_slice),
          }
          next
        end
        dynamic_type = compact_dynamic_type(source_type)
        json_schema = dynamic_type ? nil : CompactJsonColumnAdapter.schema_for_json_declaration(source_type)
        if schema = json_schema
          json_reader = CompactJsonColumnAdapter.open(
            @part_path,
            column,
            source_type,
            schema,
            transport_budget: budget,
          )
          unless json_reader.schema_declaration == schema.declaration &&
                 json_reader.source_declaration == source_type
            raise CorruptPartError.new("selected Compact JSON declaration differs from its physical schema")
          end
          if existing_rows = row_count
            unless json_reader.row_count == existing_rows
              raise CorruptPartError.new("selected Compact columns have different parent row counts")
            end
            unless json_reader.mark_row_counts == @mark_row_counts
              raise CorruptPartError.new("selected Compact columns have different parent mark grids")
            end
          else
            row_count = json_reader.row_count
            @mark_row_counts = json_reader.mark_row_counts
          end

          @column_reader_slots << {:json, @json_readers.size}
          @json_readers << json_reader
          @column_types << {String.new(column.to_slice), String.new(json_reader.schema_declaration.to_slice)}
          @column_sources << {
            String.new(column.to_slice),
            String.new(column.to_slice),
            String.new(source_type.to_slice),
          }
          next
        end

        projection_aggregate_descriptor = WidePartProjectionAggregateDescriptor.for_column(column, source_type)
        projection_count_plan = WideAggregateCountStoragePlan.for_type_name(source_type)
        if count_plan = projection_count_plan
          unless projection_name && column == "count()" &&
                 count_plan.type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME
            raise UnsupportedFormatError.new("Compact AggregateFunction(count) is admitted only for the literal projection count() child")
          end
        elsif projection_aggregate_descriptor
          unless projection_name && (projection_aggregate_descriptor.sum? || projection_aggregate_descriptor.minmax?)
            raise UnsupportedFormatError.new("Compact UInt64 sum/min/max states are admitted only for projection children")
          end
        end

        type = if count_plan = projection_count_plan
                 count_plan.data_type
               elsif descriptor = projection_aggregate_descriptor
                 descriptor.type
               else
                 dynamic_type || StaticBinaryBulkColumnDeclaration.parse(source_type) ||
                   raise(UnsupportedFormatError.new("selected Compact declaration is outside static or Dynamic BinaryBulk admission"))
               end
        if dynamic_type.nil? && projection_aggregate_descriptor.nil? && !BinaryValueTypedBatchAdapter.admitted?(type)
          raise UnsupportedFormatError.new("selected Compact declaration has no established typed batch carrier")
        end

        reader : CompactColumnReader = if count_plan = projection_count_plan
          count_reader = CompactBinaryBulkColumnReader.open_projection_count(
            @part_path,
            transport_budget: budget,
            admission_session: projection_admission_session,
          )
          count_reader.aggregate_count_key_names ||
            raise(CorruptPartError.new("Compact projection Count reader omitted its hidden key roster"))
          count_reader
        elsif projection_aggregate_descriptor && projection_name
          CompactBinaryBulkColumnReader.open_projection_aggregate_with_descriptor(
            @part_path,
            projection_aggregate_descriptor,
            transport_budget: budget,
            admission_session: projection_admission_session,
          )
        elsif dynamic_type
          CompactDynamicBulkColumnReader.open(
            @part_path,
            column,
            type,
            transport_budget: budget,
          )
        else
          CompactBinaryBulkColumnReader.open(
            @part_path,
            column,
            type,
            transport_budget: budget,
            context: @direct_uint64_scan_context,
          )
        end
        if projection_name && projection_aggregate_descriptor.nil? && type.name == "UInt64"
          if session = projection_admission_session
            if compact_reader = reader.as?(CompactBinaryBulkColumnReader)
              compact_reader.validate_projection_aggregate_candidate!(session)
            end
          end
        end
        unless reader.schema_declaration == source_type && reader.source_declaration == source_type
          raise CorruptPartError.new("selected Compact declaration differs from its physical schema")
        end
        if existing_rows = row_count
          unless reader.row_count == existing_rows
            raise CorruptPartError.new("selected Compact columns have different parent row counts")
          end
          unless reader.mark_row_counts == @mark_row_counts
            raise CorruptPartError.new("selected Compact columns have different parent mark grids")
          end
        else
          row_count = reader.row_count
          @mark_row_counts = reader.mark_row_counts
        end

        @column_reader_slots << {:binary, @readers.size}
        @readers << {String.new(column.to_slice), String.new(source_type.to_slice), type, reader}
        @direct_uint64_readers << (
          projection_name.nil? && dynamic_type.nil? && projection_aggregate_descriptor.nil? &&
          source_type == "UInt64" && type.name == "UInt64"
        )
        @column_types << {String.new(column.to_slice), String.new(source_type.to_slice)}
        @column_sources << {
          String.new(column.to_slice),
          String.new(column.to_slice),
          String.new(source_type.to_slice),
        }
      end

      @total_row_count = row_count || raise(CorruptPartError.new("Compact table has no selected readers"))
      if @total_row_count == 0_u64 || @total_row_count > WidePartTable::MAX_TOTAL_ROWS
        raise BoundsError.new("Compact part row count is outside the typed table limit")
      end
      if @mark_row_counts.empty? || @mark_row_counts.size > WidePartTable::MAX_MARKS_PER_READER
        raise BoundsError.new("Compact part mark count is outside the typed table limit")
      end
      if @mark_row_counts.size.to_u64 > WidePartTable::MAX_TOTAL_MARKS
        raise BoundsError.new("Compact part mark count exceeds total mark limit")
      end
      @mark_row_counts.each do |rows|
        if rows == 0_u64 || rows > WidePartTable::MAX_MARK_ROWS
          raise BoundsError.new("Compact mark row count is outside the typed table limit")
        end
      end

      @part_count = 1_i32
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    # :nodoc:
    # The caller enables synchronization before any worker shares this budget.
    def parallel_scan_transport_budget! : CompressedStreamBudget
      @transport_budget.enable_synchronization!
      @transport_budget
    end

    def columns : Array(String)
      @columns.map { |column| String.new(column.to_slice) }
    end

    def column_types : Array({String, String})
      @column_types.map { |name, type| {String.new(name.to_slice), String.new(type.to_slice)} }
    end

    def column_sources : Array({String, String, String})
      @column_sources.map do |name, source_name, source_type|
        {String.new(name.to_slice), String.new(source_name.to_slice), String.new(source_type.to_slice)}
      end
    end

    # Detached UInt64 sibling roster for projection-only Count selections.
    # Ordinary Compact selections expose no hidden Count key.
    def aggregate_count_key_names : Array(String)?
      @readers.each do |entry|
        if reader = entry[3].as?(CompactBinaryBulkColumnReader)
          names = reader.aggregate_count_key_names
          return names if names
        end
      end
      nil
    end

    # Detached hidden UInt64 key roster for any admitted aggregate projection.
    # Count keeps its historical accessor above for W295 callers.
    def projection_aggregate_key_names : Array(String)?
      @readers.each do |entry|
        if reader = entry[3].as?(CompactBinaryBulkColumnReader)
          names = reader.projection_aggregate_key_names
          return names if names
        end
      end
      nil
    end

    def part_mark_row_counts : Array(Array(UInt64))
      [@mark_row_counts.dup]
    end

    # :nodoc:
    # True only where every selected binary reader is an admitted ordinary
    # UInt64 lane, so the worker can share one typed slab across Compact parts.
    def reusable_uint64_scan? : Bool
      reusable_direct_uint64_column_count > 0
    end

    # :nodoc:
    # Root JSON Object rows can reuse one scan-owned assembly hash after the
    # reader has authenticated its prepared layout.
    def reusable_object_document_scan? : Bool
      @json_readers.any?(&.reusable_object_document_scan?)
    end

    # :nodoc:
    # Candidate admission is metadata-only. The root reader must still prove
    # the complete Advanced schedule before a plan can reach workers.
    def shared_advanced_json_scan_candidate? : Bool
      @emit_part_path == @part_path && @json_readers.size == 1 &&
        @json_readers[0].carrier_kind == :object &&
        @json_uint32_path_readers.empty? && @direct_uint64_readers.all?
    end

    # :nodoc:
    def prepare_shared_advanced_json_scan : CompactStaticJsonAdvancedPartPlan?
      return nil unless shared_advanced_json_scan_candidate?

      workspace_limit = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      @readers.each do |entry|
        bytes = entry[3].retained_workspace_bytes
        if bytes > workspace_limit
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        workspace_limit -= bytes
      end
      observer = ->(bytes : UInt64) do
        if bytes > workspace_limit
          raise CompactSharedPlanWorkspaceError.new
        end
        nil
      end
      @json_readers[0].prepare_advanced_part_plan(observer, @readers.map(&.[0]))
    rescue CompactSharedPlanWorkspaceError
      # Whole-part companions need more retained space than the ordinary
      # per-mark reader. Keep the serial path when a shared plan will not fit.
      validate_dynamic_schedules!
      nil
    end

    # :nodoc:
    # Caller-owned retained one-mark output seam for the Compact Advanced
    # columnar lane. `source_row_offset` is the selected-part's base in the
    # parent table. With `matching_rows`, output row i maps to the supplied
    # physical offset at i. The output remains borrowed until the next reset.
    def scan_compact_json_columnar_mark_into(
      mark_index : Int,
      plan : CompactStaticJsonAdvancedPartPlan,
      budget : BinaryCodecBudget,
      output : CompactJsonColumnarBatch,
      part_index : Int = 0,
      source_row_offset : UInt64 = 0_u64,
      part_row_offset : UInt64? = nil,
      matching_rows : Slice(Int32)? = nil,
    ) : Nil
      validate_shared_advanced_json_scan_plan!(plan)
      unless mark_index >= 0 && mark_index < @mark_row_counts.size &&
             plan.mark_count == @mark_row_counts.size &&
             plan.mark_row_count_at(mark_index) == @mark_row_counts[mark_index]
        raise CorruptPartError.new("Compact Advanced columnar plan differs from its physical mark grid")
      end
      plan.decode_mark_into(mark_index, budget, output, matching_rows: matching_rows)

      mark_start = part_row_offset || begin
        offset = 0_u64
        mark_index.times do |prior|
          rows = @mark_row_counts[prior]
          if rows > UInt64::MAX - offset
            raise CorruptPartError.new("Compact Advanced columnar part row offset overflows")
          end
          offset += rows
        end
        offset
      end
      if mark_start > UInt64::MAX - source_row_offset
        raise CorruptPartError.new("Compact Advanced columnar source row offset overflows")
      end
      output.set_location!(
        part_index,
        @emit_part_name,
        @emit_part_path,
        mark_index,
        0_u64,
        mark_start,
        source_row_offset + mark_start,
      )
      nil
    end

    # :nodoc:
    # Shared only with worker readers of this exact all-UInt64 physical part.
    def parallel_uint64_scan_context : CompactPartPhysicalContext?
      reusable_uint64_scan? ? @direct_uint64_scan_context : nil
    end

    def scan_typed(
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      scan_typed_with_workspace(batch_rows, nil) { |batch| yield batch }
      nil
    end

    # :nodoc:
    # Internal workspace injection lets one scan operation reuse one slab
    # across Compact parts without retaining it on a reader instance.
    def scan_typed_with_workspace(
      batch_rows : Int,
      workspace : CompactUInt64ScanWorkspace?,
      object_document_workspace : ObjectDocumentDecodeWorkspace? = nil,
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(batch_rows)
      scan_workspace = scan_workspace_for_scan(workspace)
      scan_selected_marks(nil, batch_rows, nil, scan_workspace, nil, object_document_workspace, advanced_json_plan) { |batch| yield batch }
      nil
    end

    # :nodoc:
    # Materialize an ordered mark list through the established Compact typed
    # path, retaining its normal frame checksum verification policy.
    def scan_typed_mark_indices(
      mark_indices : Array(Int32),
      batch_rows : Int,
      & : WidePartTableBatch -> Nil
    ) : Nil
      scan_typed_mark_indices_with_workspace(mark_indices, batch_rows, nil) { |batch| yield batch }
      nil
    end

    # :nodoc:
    # Parallel workers pass a stable per-worker workspace through this
    # internal entrypoint and wait for each callback acknowledgement before
    # the next mark can reuse its storage.
    def scan_typed_mark_indices_with_workspace(
      mark_indices : Array(Int32),
      batch_rows : Int,
      workspace : CompactUInt64ScanWorkspace?,
      scan_image : CompactUInt64ScanImage? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(batch_rows)
      selected_marks = mark_indices.dup
      previous = -1
      selected_marks.each do |mark_index|
        unless mark_index >= 0 && mark_index < @mark_row_counts.size && mark_index > previous
          raise BoundsError.new("parallel Compact mark indices are outside the physical grid or unordered")
        end
        previous = mark_index
      end
      raise BoundsError.new("parallel Compact mark list is empty") if selected_marks.empty?
      scan_workspace = scan_workspace_for_scan(workspace)
      scan_selected_marks(selected_marks, batch_rows, nil, scan_workspace, scan_image) { |batch| yield batch }
      nil
    end

    # :nodoc:
    # Ordered delivery may be owned by a coordinator after worker prefetch.
    # The coordinator must check this plan again immediately before yielding.
    def scan_shared_advanced_json_mark_indices(
      mark_indices : Array(Int32),
      batch_rows : Int,
      plan : CompactStaticJsonAdvancedPartPlan,
      guard_delivery : Bool = true,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(batch_rows)
      validate_shared_advanced_json_scan_plan!(plan)
      plan.validate_source! if guard_delivery && mark_indices.empty?
      previous = -1_i32
      mark_indices.each do |mark|
        unless mark > previous && mark < @mark_row_counts.size
          raise BoundsError.new("parallel Compact mark indices are outside the physical grid or unordered")
        end
        previous = mark
      end
      scan_selected_marks_loop(mark_indices, batch_rows, nil, nil, nil,
        ObjectDocumentDecodeWorkspace.new, plan, guard_delivery) { |batch| yield batch }
      nil
    end

    def scan_typed_window(
      start_row : UInt64,
      max_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(max_rows, "window row count")
      if start_row > @total_row_count
        raise BoundsError.new("window start is beyond the source row count")
      end
      if start_row == @total_row_count
        if plan = advanced_json_plan
          validate_shared_advanced_json_scan_plan!(plan)
          plan.validate_source!
        else
          validate_dynamic_schedules!
        end
        return nil
      end

      available = @total_row_count - start_row
      rows = max_rows.to_u64 < available ? max_rows.to_u64 : available
      scan_workspace = scan_workspace_for_scan(nil)
      scan_selected_marks(nil, max_rows, {start_row, start_row + rows}, scan_workspace, nil,
        advanced_json_plan: advanced_json_plan) { |batch| yield batch }
      nil
    end

    def scan_typed_candidate_marks(
      mark_indices : Array(Array(Int32)),
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      unless mark_indices.size == 1
        raise BoundsError.new("candidate mark list does not match the Compact part")
      end
      selected = mark_indices[0].dup
      previous = -1
      selected.each do |mark|
        if mark < 0 || mark >= @mark_row_counts.size
          raise BoundsError.new("candidate mark index is out of range")
        end
        if mark <= previous
          raise BoundsError.new("candidate mark indices must be strictly increasing")
        end
        previous = mark
      end
      # A candidate callback is one complete physical granule, matching the
      # existing typed Wide candidate-mark contract.
      scan_workspace = scan_workspace_for_scan(nil)
      scan_selected_marks(selected, WidePartTable::MAX_MARK_ROWS.to_i, nil, scan_workspace, nil,
        advanced_json_plan: advanced_json_plan) { |batch| yield batch }
      nil
    end

    private def scan_selected_marks(
      candidate_marks : Array(Int32)?,
      batch_rows : Int,
      window_rows : {UInt64, UInt64}?,
      scan_workspace : CompactUInt64ScanWorkspace?,
      scan_image : CompactUInt64ScanImage?,
      object_document_workspace : ObjectDocumentDecodeWorkspace? = nil,
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      if plan = advanced_json_plan
        validate_shared_advanced_json_scan_plan!(plan)
        plan.validate_source! if candidate_marks.try(&.empty?)
      elsif shared_advanced_json_scan_candidate?
        advanced_json_plan = prepare_shared_advanced_json_scan
      else
        validate_dynamic_schedules!
      end
      object_document_workspace ||= if advanced_json_plan || @json_readers.any?(&.advanced_object_document_decode?)
                                      ObjectDocumentDecodeWorkspace.new
                                    end

      if image = scan_image
        if reusable_uint64_scan?
          context = @direct_uint64_scan_context || raise(CorruptPartError.new("Compact direct UInt64 scan lost its admitted context"))
          image.validate_context!(context)
        end
        scan_selected_marks_loop(candidate_marks, batch_rows, window_rows, scan_workspace, image, object_document_workspace) { |batch| yield batch }
      elsif reusable_uint64_scan? && candidate_marks.try(&.empty?) != true
        context = @direct_uint64_scan_context || raise(CorruptPartError.new("Compact direct UInt64 scan lost its admitted context"))
        CompactUInt64ScanImage.with_context(context, @transport_budget) do |opened_image|
          scan_selected_marks_loop(candidate_marks, batch_rows, window_rows, scan_workspace, opened_image, object_document_workspace) { |batch| yield batch }
        end
      else
        scan_selected_marks_loop(candidate_marks, batch_rows, window_rows, scan_workspace, nil, object_document_workspace,
          advanced_json_plan) { |batch| yield batch }
      end
      nil
    end

    private def validate_shared_advanced_json_scan_plan!(plan : CompactStaticJsonAdvancedPartPlan) : Nil
      unless shared_advanced_json_scan_candidate?
        raise CorruptPartError.new("Compact Advanced plan differs from the table selection")
      end
      @json_readers[0].validate_advanced_part_plan!(plan, @readers.map(&.[0]))
    end

    private def scan_selected_marks_loop(
      candidate_marks : Array(Int32)?,
      batch_rows : Int,
      window_rows : {UInt64, UInt64}?,
      scan_workspace : CompactUInt64ScanWorkspace?,
      scan_image : CompactUInt64ScanImage?,
      object_document_workspace : ObjectDocumentDecodeWorkspace? = nil,
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
      guard_delivery : Bool = true,
      & : WidePartTableBatch -> Nil
    ) : Nil
      selected_cursor = 0
      part_row_offset = 0_u64
      @mark_row_counts.each_with_index do |mark_rows, mark_index|
        if mark_rows > UInt64::MAX - part_row_offset
          raise CorruptPartError.new("Compact part row offset overflows")
        end
        mark_start = part_row_offset
        mark_end = mark_start + mark_rows
        selected = true
        if marks = candidate_marks
          selected = selected_cursor < marks.size && marks[selected_cursor] == mark_index
          selected_cursor += 1 if selected
        end
        part_row_offset = mark_end
        next unless selected

        row_start = 0_u64
        row_end = mark_rows
        if window = window_rows
          window_start, window_end = window
          mark_end = part_row_offset
          next if window_start >= mark_end || window_end <= mark_start
          row_start = window_start > mark_start ? window_start - mark_start : 0_u64
          row_end = window_end < mark_end ? window_end - mark_start : mark_rows
        end
        next unless row_start < row_end

        values_by_column, json_carriers, path_values, retained_charge = materialize_mark(
          mark_index,
          mark_rows,
          scan_workspace,
          scan_image,
          object_document_workspace,
          advanced_json_plan,
        )
        cursor = row_start
        while cursor < row_end
          remaining = row_end - cursor
          slice_rows = remaining < batch_rows.to_u64 ? remaining : batch_rows.to_u64
          emit_batch(
            mark_index,
            mark_start,
            cursor,
            slice_rows,
            values_by_column,
            json_carriers,
            path_values,
          ) do |batch|
            advanced_json_plan.try(&.validate_source!) if guard_delivery
            yield batch
          end
          cursor += slice_rows
        end
        # The logical charge bounds one selected mark at a time. Values and
        # adapter owners become callback-scoped and are not retained here.
        retained_charge
      end
      unless part_row_offset == @total_row_count
        raise CorruptPartError.new("Compact part row grid differs from its total row count")
      end
      nil
    end

    private def scan_workspace_for_scan(
      provided : CompactUInt64ScanWorkspace?,
    ) : CompactUInt64ScanWorkspace?
      return provided if provided
      return nil unless reusable_uint64_scan?
      CompactUInt64ScanWorkspace.new
    end

    private def reusable_direct_uint64_column_count : Int32
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
        return 0_i32 if @readers.empty? || !@json_readers.empty? || !@json_uint32_path_readers.empty? ||
                        @direct_uint64_readers.size != @readers.size ||
                        !@direct_uint64_readers.all? { |direct| direct }
        @readers.size.to_i32
      {% else %}
        0_i32
      {% end %}
    end

    # A learned Dynamic plan is part-wide state. Validate every granule
    # before mark/window selection can publish rows, including an empty
    # candidate set or an EOF-first window. Previously normalized Dynamic
    # owners remain live while later readers prepare, so their retained
    # workspace is included in each subsequent reader's preflight.
    private def validate_dynamic_schedules! : Nil
      limit = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      @readers.each_with_index do |entry, reader_index|
        reader = entry[3].as?(CompactDynamicBulkColumnReader)
        next unless reader

        other_retained_workspace = 0_u64
        @readers.each_with_index do |other_entry, other_index|
          next if other_index == reader_index
          other_retained_workspace = checked_add(other_retained_workspace, other_entry[3].retained_workspace_bytes)
        end
        @json_readers.each do |other_reader|
          other_retained_workspace = checked_add(other_retained_workspace, other_reader.retained_workspace_bytes)
        end
        @json_uint32_path_readers.each do |other_reader|
          other_retained_workspace = checked_add(other_retained_workspace, other_reader.retained_workspace_bytes)
        end
        if other_retained_workspace > limit
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        reader_workspace_limit = limit - other_retained_workspace
        workspace_observer = ->(workspace_bytes : UInt64) do
          begin
            if workspace_bytes > reader_workspace_limit
              raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
            end
          rescue ex : BoundsError
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          nil
        end
        reader.validate_complete_schedule(workspace_observer)
      end

      @json_readers.each_with_index do |reader, reader_index|
        other_retained_workspace = 0_u64
        @readers.each do |entry|
          other_retained_workspace = checked_add(other_retained_workspace, entry[3].retained_workspace_bytes)
        end
        @json_readers.each_with_index do |other_reader, other_index|
          next if other_index == reader_index
          other_retained_workspace = checked_add(other_retained_workspace, other_reader.retained_workspace_bytes)
        end
        @json_uint32_path_readers.each do |other_reader|
          other_retained_workspace = checked_add(other_retained_workspace, other_reader.retained_workspace_bytes)
        end
        if other_retained_workspace > limit
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        reader_workspace_limit = limit - other_retained_workspace
        workspace_observer = ->(workspace_bytes : UInt64) do
          begin
            if workspace_bytes > reader_workspace_limit
              raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
            end
          rescue ex : BoundsError
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          nil
        end
        reader.validate_complete_schedule(workspace_observer)
      end
      nil
    end

    private def materialize_mark(
      mark_index : Int32,
      rows : UInt64,
      scan_workspace : CompactUInt64ScanWorkspace?,
      scan_image : CompactUInt64ScanImage?,
      object_document_workspace : ObjectDocumentDecodeWorkspace? = nil,
      advanced_json_plan : CompactStaticJsonAdvancedPartPlan? = nil,
    ) : MaterializedMark
      remaining_bytes = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      retained_workspace = 0_u64
      @readers.each do |entry|
        retained_workspace = checked_add(retained_workspace, entry[3].retained_workspace_bytes)
      end
      @json_readers.each do |reader|
        retained_workspace = checked_add(retained_workspace, reader.retained_workspace_bytes)
      end
      if plan = advanced_json_plan
        retained_workspace = checked_add(retained_workspace, plan.retained_workspace_bytes)
      end
      @json_uint32_path_readers.each do |reader|
        retained_workspace = checked_add(retained_workspace, reader.retained_workspace_bytes)
      end
      retained_workspace = checked_add(retained_workspace, compact_json_uint32_path_mark_workspace_bytes(mark_index))
      retained_workspace = checked_add(retained_workspace, direct_mark_workspace_bytes)

      reusable_direct_count = reusable_direct_uint64_column_count
      reusable_direct_workspace = false
      if reusable_direct_count > 0 && scan_workspace && retained_workspace <= remaining_bytes
        if rows > UInt64::MAX // reusable_direct_count.to_u64
          raise CorruptPartError.new("Compact UInt64 scan slab size overflows")
        end
        required_values = rows * reusable_direct_count.to_u64
        available = remaining_bytes - retained_workspace
        header_bytes = scan_workspace.retained_header_bytes
        planned_slab_values = if header_bytes <= available
                                scan_workspace.planned_capacity_values(
                                  required_values,
                                  available - header_bytes,
                                )
                              else
                                nil
                              end
        if capacity_values = planned_slab_values
          scan_workspace.prepare_capacity!(capacity_values)
          slab_bytes = capacity_values * sizeof(UInt64).to_u64
          retained_workspace = checked_add(retained_workspace, header_bytes)
          retained_workspace = checked_add(retained_workspace, slab_bytes)
          reusable_direct_workspace = true
        else
          # A retained high-water slab must not make a mark fail when the
          # former detached result still fits the existing materialization
          # budget. Drop it before falling back to the established route.
          scan_workspace.release_slab!
        end
      end
      if retained_workspace > remaining_bytes
        raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
      end
      remaining_bytes -= retained_workspace

      # The scan-wide schedule gate above authenticates every selected JSON
      # grid before mark callbacks. Root Object wrappers reserve from that
      # published grid metadata; other recursive shapes keep their occurrence
      # preflight before any JSON payload is materialized.
      json_preflights = Array(CompactJsonMarkPreflight).new(@json_readers.size)
      json_carrier_bytes = 0_u64
      json_carrier_nodes = 0_u64
      json_carrier_elements = 0_u64
      json_shape_nodes = 0_u64
      json_shape_tuple_cells = 0_u64
      json_shape_elements = 0_u64
      json_recursive_shape_bytes = 0_u64
      json_peak_transient_bytes = 0_u64
      @json_readers.each do |reader|
        preflight = reader.mark_preflight_after_scan_schedule_validation(mark_index, rows, advanced_json_plan)
        json_preflights << preflight
        json_carrier_bytes = checked_add(json_carrier_bytes, preflight.carrier_bytes)
        json_carrier_nodes = checked_add(json_carrier_nodes, preflight.carrier_nodes)
        json_carrier_elements = checked_add(json_carrier_elements, preflight.carrier_elements)
        json_shape_nodes = checked_add(json_shape_nodes, preflight.shape.nodes)
        json_shape_tuple_cells = checked_add(json_shape_tuple_cells, preflight.shape.tuple_cells)
        json_shape_elements = checked_add(json_shape_elements, preflight.shape.elements)

        if reader.carrier_kind == :recursive
          json_recursive_shape_bytes = checked_add(json_recursive_shape_bytes, preflight.shape.bytes)
          if preflight.temporary_bytes > json_peak_transient_bytes
            json_peak_transient_bytes = preflight.temporary_bytes
          end
        else
          transient = checked_add(preflight.temporary_bytes, preflight.shape.bytes)
          if transient > json_peak_transient_bytes
            json_peak_transient_bytes = transient
          end
        end
      end

      # All selected reader contexts stay live for this mark. Charge their
      # aggregate retained owner before allocating results or decoding values.
      values_by_column = Array(CompactBinaryMarkCarrier).new(@readers.size)
      retained_total = retained_workspace
      path_values = if @json_uint32_path_readers.empty?
                      EMPTY_JSON_UINT32_PATH_VALUES
                    else
                      Array(Slice(UInt32)).new(@json_uint32_path_readers.size)
                    end
      if @json_uint32_path_readers.any?
        path_workspace = CompressedBlock::DecodeWorkspace.new
        @json_uint32_path_readers.each do |reader|
          if rows > UInt64::MAX // sizeof(UInt32).to_u64
            raise CorruptPartError.new("Compact JSON UInt32 path mark materialization charge overflows")
          end
          result_bytes = rows * sizeof(UInt32).to_u64
          if result_bytes > remaining_bytes
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          remaining_bytes -= result_bytes
          retained_total = checked_add(retained_total, result_bytes)

          values = Slice(UInt32).new(rows.to_i)
          destination = Bytes.new(values.to_unsafe.as(UInt8*), values.size * sizeof(UInt32))
          reader.read_mark_into(mark_index, destination, path_workspace)
          path_values << values
        end
      end
      reusable_slot = 0

      @readers.each_with_index do |entry, reader_index|
        if @direct_uint64_readers[reader_index]
          if rows > UInt64::MAX // sizeof(UInt64).to_u64
            raise CorruptPartError.new("Compact UInt64 mark materialization charge overflows")
          end
          direct_bytes = rows * sizeof(UInt64).to_u64
          reader = entry[3].as?(CompactBinaryBulkColumnReader) ||
                   raise(CorruptPartError.new("Compact direct UInt64 selection has a non-BinaryBulk reader"))

          if reusable_direct_workspace
            workspace = scan_workspace || raise(CorruptPartError.new("Compact UInt64 scan lost its local workspace"))
            lane = workspace.values_for(rows, reusable_slot, reusable_direct_count)
            reader.read_ordinary_uint64_mark_into(mark_index, lane.to_unsafe_bytes, workspace.transport_workspace, scan_image)
            values_by_column << lane
            reusable_slot += 1
            next
          end

          if direct_bytes > remaining_bytes
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          remaining_bytes -= direct_bytes
          retained_total = checked_add(retained_total, direct_bytes)

          bytes = if plan = advanced_json_plan
                    plan.uint64_mark_bytes(entry[0], mark_index)
                  else
                    reader.read_ordinary_uint64_mark(mark_index, scan_image)
                  end
          unless bytes.size.to_u64 == direct_bytes
            raise CorruptPartError.new("Compact direct UInt64 reader returned an invalid mark width")
          end

          if borrowable_uint64_bytes?(bytes)
            values_by_column << borrowed_uint64_slice(bytes, rows)
          else
            # The raw authenticated mark and its portable typed copy coexist
            # during conversion, so charge that transient copy before growing
            # the fallback array.
            if direct_bytes > remaining_bytes
              raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
            end
            remaining_bytes -= direct_bytes
            retained_total = checked_add(retained_total, direct_bytes)
            values_by_column << decode_uint64_bytes(bytes, rows)
          end
          next
        end

        reader = entry[3]
        charge = ObjectValuesMaterializationBudget.new(logical_limit: remaining_bytes)
        begin
          charge.reserve_binary_values_base(rows, 0_u64)
        rescue ex : BoundsError
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end

        peak_extra_workspace = 0_u64
        workspace_observer = ->(current_extra_workspace : UInt64) do
          begin
            charge.ensure_workspace(current_extra_workspace)
          rescue ex : BoundsError
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          if current_extra_workspace > peak_extra_workspace
            peak_extra_workspace = current_extra_workspace
          end
          nil
        end

        decoded_marks = reader.read_marks(mark_index, 1, workspace_observer)
        unless decoded_marks.size == 1 && decoded_marks[0].size.to_u64 == rows
          raise CorruptPartError.new("Compact selected mark returned an invalid BinaryValue grid")
        end
        values = decoded_marks[0]
        begin
          charge.charge_binary_values(values, peak_extra_workspace)
        rescue ex : BoundsError
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        owner_bytes = checked_add(charge.retained_logical_bytes, peak_extra_workspace)
        if owner_bytes > remaining_bytes
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        remaining_bytes -= owner_bytes
        retained_total = checked_add(retained_total, owner_bytes)
        values_by_column << values
      end

      # Convert-estimates are preflighted for every callback slice and selected
      # column before any legacy carrier array or callback is exposed.
      cursor = 0_u64
      carrier_bytes = 0_u64
      while cursor < rows
        slice_rows = (rows - cursor) < WidePartTable::MAX_BATCH_ROWS.to_u64 ? (rows - cursor) : WidePartTable::MAX_BATCH_ROWS.to_u64
        @readers.each_with_index do |entry, column_index|
          next if values_by_column[column_index].is_a?(Slice(UInt64))
          # Dynamic already has its exact BinaryValue carrier; installing the
          # borrowed slice does not allocate a second typed owner.
          next if entry[2].contains_dynamic?
          values = values_by_column[column_index].as(Array(BinaryValue))
          slice = Slice.new(values.to_unsafe + cursor.to_i, slice_rows.to_i)
          estimated = if WideAggregateCountStoragePlan.for_type(entry[2])
                        WideAggregateCountTableMaterializer.preflight(
                          slice_rows,
                          remaining_bytes - carrier_bytes,
                        )
                      elsif projection_aggregate_state?(entry[0], entry[1])
                        0_u64
                      else
                        BinaryValueTypedBatchAdapter.estimated_materialization_bytes(entry[2], slice) ||
                          raise(UnsupportedFormatError.new("Compact selected mark has no bounded typed carrier estimate"))
                      end
          if estimated > remaining_bytes - carrier_bytes
            raise CorruptPartError.new("Compact typed carriers exceed aggregate materialization limit")
          end
          carrier_bytes += estimated
        end
        cursor += slice_rows
      end

      # Binary owners have already been decoded and bounded above. Subtract
      # their logical result charge, but keep every reader base in the JSON
      # budget's workspace so mixed selections share one aggregate ceiling.
      binary_owner_bytes = checked_add(retained_total - retained_workspace, carrier_bytes)
      if binary_owner_bytes > WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
      end
      # Preserve the established BinaryValue/Dynamic-only accounting exactly:
      # the OfflineColumnValue reservation below exists solely to own the new
      # JSON carrier sidecar and must not add an empty owner to old selections.
      if @json_readers.empty?
        return {values_by_column, [] of SelectedCarrier, path_values, checked_add(retained_total, carrier_bytes)}
      end
      json_limit = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64 - binary_owner_bytes
      json_budget = ObjectValuesMaterializationBudget.new(logical_limit: json_limit)
      json_preflight_workspace = checked_add(
        retained_workspace,
        checked_add(json_recursive_shape_bytes, json_peak_transient_bytes),
      )
      begin
        json_budget.reserve_base(
          0_u64,
          json_carrier_bytes,
          json_preflight_workspace,
          descriptor_nodes: json_carrier_nodes,
          descriptor_elements: json_carrier_elements,
        )
        ensure_json_shape_limits!(
          json_budget,
          json_shape_nodes,
          json_shape_tuple_cells,
          json_shape_elements,
        )
      rescue ex : BoundsError
        raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
      end

      json_carriers = Array(SelectedCarrier).new(@json_readers.size)
      @json_readers.each_with_index do |reader, reader_index|
        preflight = json_preflights[reader_index]
        plan_workspace = advanced_json_plan.try(&.retained_workspace_bytes) || 0_u64
        other_retained_workspace = retained_workspace - reader.retained_workspace_bytes - plan_workspace
        peak_workspace = 0_u64
        workspace_observer = ->(current_workspace_bytes : UInt64) do
          begin
            active_workspace = checked_add(other_retained_workspace, current_workspace_bytes)
            expected_peak = checked_add(preflight.temporary_bytes, preflight.shape.bytes)
            json_budget.ensure_workspace(checked_add(active_workspace, expected_peak))
            if active_workspace > peak_workspace
              peak_workspace = active_workspace
            end
          rescue ex : BoundsError
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          nil
        end

        values = reader.storage_values_for_mark(mark_index, rows, workspace_observer, object_document_workspace, advanced_json_plan)
        carrier = reader.carrier_for(values)
        reader.charge_carrier!(json_budget, values, carrier, preflight, peak_workspace)
        json_carriers << carrier
      end

      {
        values_by_column,
        json_carriers,
        path_values,
        checked_add(checked_add(retained_total, carrier_bytes), json_budget.retained_logical_bytes),
      }
    end

    private def emit_batch(
      mark_index : Int32,
      mark_start : UInt64,
      row_offset : UInt64,
      rows : UInt64,
      values_by_column : Array(CompactBinaryMarkCarrier),
      json_carriers : Array(SelectedCarrier),
      path_values : Array(Slice(UInt32)),
      & : WidePartTableBatch -> Nil
    ) : Nil
      row_end = row_offset + rows
      type_names = @column_types.map(&.[1])
      batch = WidePartTableBatch.new(
        0_i32,
        @emit_part_name,
        @emit_part_path,
        mark_index,
        row_offset,
        mark_start + row_offset,
        mark_start + row_offset,
        @columns,
        type_names,
        [] of WidePartNumericSlice,
        row_count: rows,
      )
      @column_reader_slots.each do |kind, reader_index|
        if kind == :binary
          entry = @readers[reader_index]
          carrier = values_by_column[reader_index]
          if values = carrier.as?(Slice(UInt64))
            slice = Slice.new(values.to_unsafe + row_offset.to_i, rows.to_i)
            batch.install_compact_uint64_values(entry[0], slice, rows.to_i32)
          else
            values = carrier.as(Array(BinaryValue))
            slice = Slice.new(values.to_unsafe + row_offset.to_i, rows.to_i)
            if WideAggregateCountStoragePlan.for_type(entry[2])
              batch.install_aggregate_count_states(entry[0], slice, rows.to_i32)
            elsif entry[2].contains_dynamic?
              batch.install_dynamic_bulk_values(entry[0], slice, rows.to_i32)
            elsif projection_aggregate_state?(entry[0], entry[1])
              batch.install_binary_bulk_values(entry[0], slice, rows.to_i32)
            else
              BinaryValueTypedBatchAdapter.install(
                batch,
                entry[0],
                entry[2],
                slice,
                rows.to_i32,
              )
            end
          end
        elsif kind == :json_uint32
          reader = @json_uint32_path_readers[reader_index]
          values = path_values[reader_index]
          batch.install_compact_uint32_values(reader.column_name, values[row_offset.to_i, rows.to_i], rows.to_i32)
        else
          reader = @json_readers[reader_index]
          carrier = json_carriers[reader_index]
          case carrier
          when Array(ObjectDocument)
            slice = Slice.new(carrier.to_unsafe + row_offset.to_i, rows.to_i)
            batch.install_object_documents(reader.column_name, slice, rows.to_i)
          when Array(Array(ObjectDocument))
            slice = Slice.new(carrier.to_unsafe + row_offset.to_i, rows.to_i)
            batch.install_array_object_documents(reader.column_name, slice, rows.to_i)
          when Array(StorageColumnValue)
            slice = Slice.new(carrier.to_unsafe + row_offset.to_i, rows.to_i)
            batch.install_recursive_values(reader.column_name, slice, rows.to_i)
          else
            raise CorruptPartError.new("selected Compact JSON carrier kind is unknown")
          end
        end
      end
      yield batch
      nil
    end

    private def compact_json_uint32_path_mark_workspace_bytes(mark_index : Int32) : UInt64
      return 0_u64 if @json_uint32_path_readers.empty?

      bytes = checked_add(
        instance_sizeof(Array(Slice(UInt32))).to_u64,
        @json_uint32_path_readers.size.to_u64 * sizeof(Slice(UInt32)).to_u64,
      )
      bytes = checked_add(bytes, instance_sizeof(CompressedBlock::DecodeWorkspace).to_u64)
      max_decode_workspace = 0_u64
      @json_uint32_path_readers.each do |reader|
        path_workspace = reader.workspace_bytes_for_mark(mark_index)
        max_decode_workspace = path_workspace if path_workspace > max_decode_workspace
      end
      checked_add(bytes, max_decode_workspace)
    end

    private def compact_json_uint32_path_parts(column : String) : {String, String}?
      separator = column.byte_index('.') || return nil
      return nil if separator == 0 || separator == column.bytesize - 1
      return nil if column.byte_slice(separator + 1).includes?('.')

      parent = column.byte_slice(0, separator)
      field = column.byte_slice(separator + 1)
      return nil if parent.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES || field.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
      {String.new(parent.to_slice), String.new(field.to_slice)}
    end

    private def projection_aggregate_state?(column_name : String, type_name : String) : Bool
      descriptor = WidePartProjectionAggregateDescriptor.for_column(column_name, type_name)
      descriptor ? !descriptor.count? : false
    end

    private def direct_mark_workspace_bytes : UInt64
      return 0_u64 unless @direct_uint64_readers.any? { |direct| direct }
      bytes = checked_add(
        instance_sizeof(Array(Bool)).to_u64,
        @direct_uint64_readers.size.to_u64 * sizeof(Bool).to_u64,
      )
      bytes = checked_add(bytes, instance_sizeof(Array(CompactBinaryMarkCarrier)).to_u64)
      checked_add(
        bytes,
        @readers.size.to_u64 * sizeof(CompactBinaryMarkCarrier).to_u64,
      )
    end

    private def borrowable_uint64_bytes?(bytes : Bytes) : Bool
      return false if bytes.empty?
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
        (bytes.to_unsafe.address & 7_u64) == 0_u64
      {% else %}
        false
      {% end %}
    end

    private def borrowed_uint64_slice(bytes : Bytes, rows : UInt64) : Slice(UInt64)
      expected_bytes = rows * sizeof(UInt64).to_u64
      unless bytes.size.to_u64 == expected_bytes
        raise CorruptPartError.new("Compact direct UInt64 byte width differs from its row count")
      end
      Slice.new(bytes.to_unsafe.unsafe_as(Pointer(UInt64)), rows.to_i)
    end

    private def decode_uint64_bytes(bytes : Bytes, rows : UInt64) : Slice(UInt64)
      expected_bytes = rows * sizeof(UInt64).to_u64
      unless bytes.size.to_u64 == expected_bytes
        raise CorruptPartError.new("Compact direct UInt64 byte width differs from its row count")
      end
      Slice(UInt64).new(rows.to_i) do |index|
        IO::ByteFormat::LittleEndian.decode(UInt64, bytes[index * sizeof(UInt64), sizeof(UInt64)])
      end
    end

    private def ensure_json_shape_limits!(
      budget : ObjectValuesMaterializationBudget,
      nodes : UInt64,
      tuple_cells : UInt64,
      elements : UInt64,
    ) : Nil
      unless nodes <= budget.max_nodes - budget.node_count
        raise BoundsError.new("Object recursive node limit exceeded")
      end
      unless tuple_cells <= budget.max_tuple_cells - budget.tuple_cells
        raise BoundsError.new("Object Tuple cell limit exceeded")
      end
      unless elements <= budget.max_elements - budget.element_count
        raise BoundsError.new("Object recursive element limit exceeded")
      end
      nil
    end

    private def validate_batch_rows(rows : Int, label : String = "batch row count") : Nil
      if rows <= 0 || rows > WidePartTable::MAX_BATCH_ROWS
        raise BoundsError.new("#{label} is out of range")
      end
      nil
    end

    private def compact_dynamic_type(source_type : String) : BinaryDataType?
      if source_type == "Dynamic"
        bytes = source_type.to_slice
        return ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, 0, bytes.size).try(&.materialize)
      end
      DynamicBulkColumnDeclaration.parse(source_type)
    end

    private def validate_selected_part(requested_path : String) : {String, String}
      if requested_path.empty? || requested_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("part path is empty or exceeds limit")
      end
      path = File.expand_path(requested_path)
      name = File.basename(path)
      if name.bytesize > WidePartTable::MAX_PART_NAME_BYTES
        raise BoundsError.new("part name exceeds limit")
      end
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, String.new(name.to_slice)}
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact table materialization charge overflows")
      end
      left + right
    end
  end
end
