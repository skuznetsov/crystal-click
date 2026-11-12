module CrystalClick
  class OfflineTable
    # Owns the Compact-only .values route for admitted JSON schemas.
    # Every candidate completes its physical schedule census before
    # the result is allocated; the second pass reopens one part at a time and
    # repeats the declaration, grid, profile and roster checks before decoding.
    private class CompactJsonValuesMaterializer
      LOGICAL_LIMIT = ObjectValuesMaterializationBudget::DEFAULT_LOGICAL_LIMIT

      private struct DescriptorUsage
        getter bytes : UInt64
        getter nodes : UInt64
        getter elements : UInt64

        def initialize(@bytes : UInt64, @nodes : UInt64, @elements : UInt64)
        end

        def +(other : DescriptorUsage) : DescriptorUsage
          DescriptorUsage.new(
            checked_add(@bytes, other.bytes),
            checked_add(@nodes, other.nodes),
            checked_add(@elements, other.elements),
          )
        end

        private def checked_add(left : UInt64, right : UInt64) : UInt64
          raise BoundsError.new("Compact JSON descriptor accounting overflows UInt64") if right > UInt64::MAX - left
          left + right
        end
      end

      private class CandidatePlan
        getter candidate_name : String
        getter candidate_path : String
        getter candidate_rows : UInt64
        getter schema_declaration : String
        getter source_declaration : String
        getter ordinary_profile : BinaryBulkProfile
        getter physical_stream_names : Array(String)
        getter selected_checksum_names : Array(String)
        getter mark_rows : Array(UInt64)
        getter mark_preflights : Array(CompactJsonMarkPreflight)
        getter active_workspace_bytes : UInt64

        def initialize(
          @candidate_name : String,
          @candidate_path : String,
          @candidate_rows : UInt64,
          @schema_declaration : String,
          @source_declaration : String,
          @ordinary_profile : BinaryBulkProfile,
          @physical_stream_names : Array(String),
          @selected_checksum_names : Array(String),
          @mark_rows : Array(UInt64),
          @mark_preflights : Array(CompactJsonMarkPreflight),
          @active_workspace_bytes : UInt64,
        )
        end
      end

      def self.materialize(
        _table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        _type_name : String,
        schema : StorageColumnSchema,
        expected_rows : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
      ) : Array(OfflineColumnValue)?
        return nil unless CompactRecursiveJsonColumnReader.admitted_schema?(schema)

        raise BoundsError.new("Compact JSON catalog exceeds part limit") if candidates.size > WidePartTable::MAX_PARTS
        raise BoundsError.new("Compact JSON catalog exceeds row limit") if expected_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS
        unless sum_candidate_rows(candidates) == expected_rows
          raise CorruptPartError.new("Compact JSON candidate count differs from preflight row count")
        end

        # Dispatch all candidates before output reservation/allocation. The
        # checksums file selects a backend exactly as TypedPartTable does; each
        # selected Compact reader verifies checksums, metadata and schedule.
        compact_count = 0
        wide_count = 0
        candidates.each do |candidate|
          compact = compact_backend?(candidate.path)
          if compact
            compact_count += 1
          else
            wide_count += 1
          end
        end
        if compact_count > 0 && wide_count > 0
          raise UnsupportedFormatError.new("mixed Wide/Compact JSON .values materialization is outside admission")
        end
        return nil if compact_count == 0 && !candidates.empty?

        descriptor_usage = schema_descriptor_usage(schema)
        result_header_bytes = instance_sizeof(Array(OfflineColumnValue)).to_u64
        result_slot_bytes = checked_multiply(expected_rows, sizeof(OfflineColumnValue).to_u64)
        base_bytes = checked_add(result_header_bytes, checked_add(result_slot_bytes, descriptor_usage.bytes))
        if candidates.empty?
          budget = ObjectValuesMaterializationBudget.new(
            logical_limit: LOGICAL_LIMIT,
            max_string_bytes: max_string_bytes,
            max_tuple_cells: max_tuple_cells,
          )
          budget.reserve_base(
            expected_rows,
            descriptor_usage.bytes,
            descriptor_nodes: descriptor_usage.nodes,
            descriptor_elements: descriptor_usage.elements,
          )
          return Array(OfflineColumnValue).new(expected_rows.to_i)
        end

        plans = Array(CandidatePlan).new(candidates.size)
        retained_plan_bytes = checked_add(
          instance_sizeof(Array(CandidatePlan)).to_u64,
          checked_multiply(candidates.size.to_u64, sizeof(Pointer(CandidatePlan)).to_u64),
        )
        candidate_workspace_peak = 0_u64
        recursive_shape_bytes = 0_u64
        recursive_shape_nodes = 0_u64
        recursive_shape_tuple_cells = 0_u64
        recursive_shape_elements = 0_u64
        array_object_rows = 0_u64
        array_object_children = 0_u64
        total_marks = 0_u64

        # First pass: fully prepare every Compact candidate and retain only a
        # bounded exact census. No JSON document is decoded in this pass.
        candidates.each do |candidate|
          adapter = open_adapter(candidate, column, schema)
          validate_adapter!(adapter, candidate, schema, expected_rows)
          if adapter.mark_count <= 0 || adapter.mark_count > WidePartTable::MAX_MARKS_PER_READER
            raise CorruptPartError.new("Compact JSON mark count is outside the reader bound")
          end
          if adapter.mark_count.to_u64 > WidePartTable::MAX_TOTAL_MARKS - total_marks
            raise BoundsError.new("Compact JSON catalog mark count exceeds limit")
          end
          total_marks += adapter.mark_count.to_u64

          static_plan_bytes = candidate_plan_static_bytes(adapter, candidate, adapter.mark_count)
          ensure_preflight_limit!(base_bytes, retained_plan_bytes, static_plan_bytes)

          reader_base_bytes = reader_base_workspace_bytes(adapter)
          peak_observed_workspace = reader_base_bytes
          workspace_observer = ->(current_workspace : UInt64) do
            active = active_reader_workspace_bytes(adapter, current_workspace)
            peak_observed_workspace = active if active > peak_observed_workspace
            ensure_preflight_limit!(
              base_bytes,
              checked_add(retained_plan_bytes, static_plan_bytes),
              checked_add(peak_observed_workspace, recursive_shape_bytes),
            )
            nil
          end
          adapter.validate_complete_schedule(workspace_observer)
          reader_base_bytes = reader_base_workspace_bytes(adapter)

          mark_rows = adapter.mark_row_counts
          unless mark_rows.size == adapter.mark_count
            raise CorruptPartError.new("Compact JSON mark row inventory changed during preparation")
          end
          mark_total = sum_mark_rows(mark_rows)
          unless mark_total == adapter.row_count && adapter.row_count == candidate.row_count
            raise CorruptPartError.new("Compact JSON parent mark grid differs from candidate row count")
          end
          unless adapter.schema_declaration == schema.declaration &&
                 adapter.source_declaration == schema.source_declaration
            raise CorruptPartError.new("Compact JSON declaration differs from selected schema")
          end

          preflights = Array(CompactJsonMarkPreflight).new(adapter.mark_count)
          candidate_recursive_shape_bytes = 0_u64
          candidate_shape_nodes = 0_u64
          candidate_shape_tuple_cells = 0_u64
          candidate_shape_elements = 0_u64
          candidate_array_children = 0_u64
          candidate_max_transient = 0_u64
          mark_rows.each_with_index do |rows, mark_index|
            preflight = adapter.mark_preflight(mark_index, rows)
            preflights << preflight
            if adapter.carrier_kind == :recursive
              candidate_recursive_shape_bytes = checked_add(candidate_recursive_shape_bytes, preflight.shape.bytes)
              candidate_shape_nodes = checked_add(candidate_shape_nodes, preflight.shape.nodes)
              candidate_shape_tuple_cells = checked_add(candidate_shape_tuple_cells, preflight.shape.tuple_cells)
              candidate_shape_elements = checked_add(candidate_shape_elements, preflight.shape.elements)
            end
            if adapter.carrier_kind == :array_object
              candidate_array_children = checked_add(candidate_array_children, preflight.shape.elements)
            end
            transient = mark_transient_bytes(adapter.carrier_kind, preflight, rows)
            candidate_max_transient = transient if transient > candidate_max_transient
          end

          plan_workspace = checked_add(retained_plan_bytes, static_plan_bytes)
          candidate_read_workspace = checked_add(reader_base_bytes, candidate_max_transient)
          candidate_phase_workspace = if candidate_read_workspace > peak_observed_workspace
                                        candidate_read_workspace
                                      else
                                        peak_observed_workspace
                                      end
          ensure_preflight_limit!(
            base_bytes,
            plan_workspace,
            checked_add(candidate_phase_workspace, checked_add(recursive_shape_bytes, candidate_recursive_shape_bytes)),
          )

          plan = CandidatePlan.new(
            String.new(candidate.name.to_slice),
            String.new(File.expand_path(candidate.path).to_slice),
            candidate.row_count,
            adapter.schema_declaration,
            adapter.source_declaration,
            adapter.ordinary_profile,
            adapter.physical_stream_names,
            adapter.selected_checksum_names,
            mark_rows,
            preflights,
            peak_observed_workspace,
          )
          plans << plan
          retained_plan_bytes = plan_workspace
          candidate_workspace_peak = candidate_phase_workspace if candidate_phase_workspace > candidate_workspace_peak
          recursive_shape_bytes = checked_add(recursive_shape_bytes, candidate_recursive_shape_bytes)
          recursive_shape_nodes = checked_add(recursive_shape_nodes, candidate_shape_nodes)
          recursive_shape_tuple_cells = checked_add(recursive_shape_tuple_cells, candidate_shape_tuple_cells)
          recursive_shape_elements = checked_add(recursive_shape_elements, candidate_shape_elements)
          array_object_rows = checked_add(array_object_rows, candidate.row_count) if adapter.carrier_kind == :array_object
          array_object_children = checked_add(array_object_children, candidate_array_children)
        end

        unless plans.size == candidates.size
          raise CorruptPartError.new("Compact JSON candidate plan inventory is incomplete")
        end

        ensure_shape_limits!(
          descriptor_usage,
          expected_rows,
          recursive_shape_nodes,
          recursive_shape_tuple_cells,
          recursive_shape_elements,
          array_object_rows,
          array_object_children,
          max_string_bytes,
          max_tuple_cells,
        )

        array_carrier_bytes = checked_add(
          checked_multiply(array_object_rows, instance_sizeof(Array(ObjectDocument)).to_u64),
          checked_multiply(array_object_children, sizeof(Pointer(ObjectDocument)).to_u64),
        )
        array_carrier_nodes = array_object_rows
        array_carrier_elements = array_object_children
        retained_descriptor_bytes = checked_add(descriptor_usage.bytes, array_carrier_bytes)
        retained_descriptor_nodes = checked_add(descriptor_usage.nodes, array_carrier_nodes)
        retained_descriptor_elements = checked_add(descriptor_usage.elements, array_carrier_elements)

        # Every candidate grid is already authenticated. Reserve the complete
        # retained shape plus all candidate census descriptors and one active
        # reader before allocating the public result array.
        maximum_workspace = checked_add(retained_plan_bytes, candidate_workspace_peak)
        maximum_workspace = checked_add(maximum_workspace, recursive_shape_bytes)
        budget = ObjectValuesMaterializationBudget.new(
          logical_limit: LOGICAL_LIMIT,
          max_string_bytes: max_string_bytes,
          max_tuple_cells: max_tuple_cells,
        )
        budget.reserve_base(
          expected_rows,
          retained_descriptor_bytes,
          maximum_workspace,
          descriptor_nodes: retained_descriptor_nodes,
          descriptor_elements: retained_descriptor_elements,
        )
        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        remaining_recursive_shape_bytes = recursive_shape_bytes
        observed_rows = 0_u64

        # Second pass: reopen one part at a time, authenticate its entire grid
        # again, compare the exact first-pass census, then decode one mark.
        candidates.each_with_index do |candidate, candidate_index|
          plan = plans[candidate_index]
          validate_candidate_identity!(candidate, plan)
          unless compact_backend?(candidate.path)
            raise CorruptPartError.new("Compact JSON candidate format changed between passes")
          end
          adapter = open_adapter(candidate, column, schema)
          validate_adapter!(adapter, candidate, schema, expected_rows)
          validate_plan_metadata!(adapter, candidate, plan)

          peak_schedule_workspace = 0_u64
          schedule_observer = ->(current_workspace : UInt64) do
            active = active_reader_workspace_bytes(adapter, current_workspace)
            peak_schedule_workspace = active if active > peak_schedule_workspace
            ensure_runtime_workspace!(
              budget,
              retained_plan_bytes,
              peak_schedule_workspace,
              remaining_recursive_shape_bytes,
            )
            nil
          end
          adapter.validate_complete_schedule(schedule_observer)
          validate_plan_grid!(adapter, plan)
          reader_active_workspace = peak_schedule_workspace
          reader_base_workspace = reader_base_workspace_bytes(adapter)
          reader_active_workspace = reader_base_workspace if reader_base_workspace > reader_active_workspace
          reader_active_workspace = plan.active_workspace_bytes if plan.active_workspace_bytes > reader_active_workspace

          plan.mark_rows.each_with_index do |expected_mark_rows, mark_index|
            preflight = plan.mark_preflights[mark_index]
            current_preflight = adapter.mark_preflight(mark_index, expected_mark_rows)
            unless same_preflight?(current_preflight, preflight)
              raise CorruptPartError.new("Compact JSON mark shape changed between passes")
            end
            future_shape_bytes = if adapter.carrier_kind == :recursive
                                   remaining_recursive_shape_bytes - preflight.shape.bytes
                                 else
                                   remaining_recursive_shape_bytes
                                 end
            predicted_read_workspace = checked_add(
              reader_base_workspace_bytes(adapter),
              mark_transient_bytes(adapter.carrier_kind, preflight, expected_mark_rows),
            )
            active_workspace = if predicted_read_workspace > reader_active_workspace
                                 predicted_read_workspace
                               else
                                 reader_active_workspace
                               end
            preflight_workspace = checked_add(retained_plan_bytes, active_workspace)
            preflight_workspace = checked_add(preflight_workspace, future_shape_bytes)
            budget.ensure_workspace(preflight_workspace)

            peak_read_workspace = reader_active_workspace
            read_observer = ->(current_workspace : UInt64) do
              active = active_reader_workspace_bytes(adapter, current_workspace)
              peak_read_workspace = active if active > peak_read_workspace
              ensure_runtime_workspace!(
                budget,
                retained_plan_bytes,
                peak_read_workspace,
                future_shape_bytes,
              )
              nil
            end
            storage_values = adapter.storage_values_for_mark(mark_index, expected_mark_rows, read_observer)
            unless storage_values.size.to_u64 == expected_mark_rows
              raise CorruptPartError.new("Compact JSON mark row count changed during materialization")
            end
            carrier = adapter.carrier_for(storage_values)

            carrier_workspace = checked_add(retained_plan_bytes, peak_read_workspace)
            carrier_workspace = checked_add(carrier_workspace, future_shape_bytes)
            case carrier
            when Array(ObjectDocument)
              carrier_workspace = checked_add(carrier_workspace, preflight.carrier_bytes)
              budget.charge_documents(carrier, carrier_workspace)
              carrier.each do |document|
                values << document
                observed_rows += 1_u64
              end
            when Array(Array(ObjectDocument))
              outer_shell = array_object_outer_shell_bytes(expected_mark_rows)
              carrier_workspace = checked_add(carrier_workspace, outer_shell)
              carrier.each do |documents|
                budget.charge_documents(documents, carrier_workspace)
              end
              carrier.each do |documents|
                values << documents
                observed_rows += 1_u64
              end
            when Array(StorageColumnValue)
              budget.charge_storage_values(carrier, carrier_workspace)
              carrier.each do |value|
                values << value
                observed_rows += 1_u64
              end
              remaining_recursive_shape_bytes -= preflight.shape.bytes
            else
              raise CorruptPartError.new("Compact JSON carrier kind changed during materialization")
            end
            unless observed_rows <= expected_rows && values.size.to_u64 == observed_rows
              raise CorruptPartError.new("Compact JSON materializer observed more rows than preflight")
            end
          end
        end

        unless observed_rows == expected_rows && values.size.to_u64 == expected_rows
          raise CorruptPartError.new("Compact JSON result row count differs from its preflight")
        end
        values
      end

      private def self.compact_backend?(part_path : String) : Bool
        path = File.expand_path(part_path)
        metadata = PartMetadataFileReader.new(path, CompressedStreamBudget.read_default)
        checksums = PartChecksums.parse(
          metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice
        )
        CompactMarkFileAdapter.routing_candidate?(path, checksums)
      rescue ex : IO::Error
        raise CorruptPartError.new(ex.message || "cannot inspect JSON part mark family")
      end

      private def self.open_adapter(
        candidate : OfflinePartCandidate,
        column : String,
        schema : StorageColumnSchema,
      ) : CompactJsonColumnAdapter
        limits = ObjectDocumentSchema::DEFAULT_LIMITS
        transport_limits = CompressedStreamLimits.new
        CompactJsonColumnAdapter.open(
          File.expand_path(candidate.path),
          column,
          schema.source_declaration,
          schema,
          limits: limits,
          transport_limits: transport_limits,
          codec_budget: BinaryCodecBudget.new(limits),
          transport_budget: CompressedStreamBudget.new(transport_limits),
        )
      end

      private def self.validate_adapter!(
        adapter : CompactJsonColumnAdapter,
        candidate : OfflinePartCandidate,
        schema : StorageColumnSchema,
        expected_rows : UInt64,
      ) : Nil
        unless adapter.row_count == candidate.row_count && adapter.row_count <= expected_rows
          raise CorruptPartError.new("Compact JSON part row count differs from candidate metadata")
        end
        unless adapter.mark_count > 0
          raise CorruptPartError.new("Compact JSON part mark grid is empty or inconsistent")
        end
        unless adapter.schema_declaration == schema.declaration &&
               adapter.source_declaration == schema.source_declaration
          raise CorruptPartError.new("Compact JSON part declaration differs from selected schema")
        end
        nil
      end

      private def self.validate_candidate_identity!(candidate : OfflinePartCandidate, plan : CandidatePlan) : Nil
        unless candidate.name == plan.candidate_name &&
               File.expand_path(candidate.path) == plan.candidate_path &&
               candidate.row_count == plan.candidate_rows
          raise CorruptPartError.new("Compact JSON candidate identity changed between passes")
        end
        nil
      end

      private def self.validate_plan_metadata!(
        adapter : CompactJsonColumnAdapter,
        candidate : OfflinePartCandidate,
        plan : CandidatePlan,
      ) : Nil
        unless adapter.row_count == plan.candidate_rows &&
               adapter.mark_count == plan.mark_rows.size &&
               adapter.schema_declaration == plan.schema_declaration &&
               adapter.source_declaration == plan.source_declaration &&
               adapter.ordinary_profile == plan.ordinary_profile &&
               adapter.physical_stream_names == plan.physical_stream_names &&
               adapter.selected_checksum_names == plan.selected_checksum_names
          raise CorruptPartError.new("Compact JSON reader identity changed between passes")
        end
        nil
      end

      private def self.validate_plan_grid!(adapter : CompactJsonColumnAdapter, plan : CandidatePlan) : Nil
        plan.mark_rows.each_with_index do |rows, mark_index|
          current = adapter.mark_preflight(mark_index, rows)
          unless same_preflight?(current, plan.mark_preflights[mark_index])
            raise CorruptPartError.new("Compact JSON occurrence grid changed between passes")
          end
        end
        nil
      end

      private def self.same_preflight?(left : CompactJsonMarkPreflight, right : CompactJsonMarkPreflight) : Bool
        left.shape.nodes == right.shape.nodes &&
          left.shape.tuple_cells == right.shape.tuple_cells &&
          left.shape.elements == right.shape.elements &&
          left.shape.bytes == right.shape.bytes &&
          left.temporary_bytes == right.temporary_bytes &&
          left.carrier_bytes == right.carrier_bytes &&
          left.carrier_nodes == right.carrier_nodes &&
          left.carrier_elements == right.carrier_elements
      end

      private def self.reader_base_workspace_bytes(adapter : CompactJsonColumnAdapter) : UInt64
        adapter.retained_workspace_bytes
      end

      private def self.active_reader_workspace_bytes(adapter : CompactJsonColumnAdapter, observed : UInt64) : UInt64
        reader_base = adapter.retained_workspace_bytes - adapter.adapter_owner_workspace_bytes
        active = observed > reader_base ? observed : reader_base
        checked_add(active, adapter.adapter_owner_workspace_bytes)
      end

      private def self.ensure_runtime_workspace!(
        budget : ObjectValuesMaterializationBudget,
        plan_bytes : UInt64,
        active_reader_workspace : UInt64,
        future_shape_bytes : UInt64,
      ) : Nil
        workspace = checked_add(plan_bytes, active_reader_workspace)
        workspace = checked_add(workspace, future_shape_bytes)
        budget.ensure_workspace(workspace)
        nil
      end

      private def self.mark_transient_bytes(
        carrier_kind : Symbol,
        preflight : CompactJsonMarkPreflight,
        rows : UInt64,
      ) : UInt64
        bytes = preflight.temporary_bytes
        case carrier_kind
        when :object
          bytes = checked_add(bytes, preflight.shape.bytes)
          checked_add(bytes, preflight.carrier_bytes)
        when :array_object
          bytes = checked_add(bytes, preflight.shape.bytes)
          checked_add(bytes, array_object_outer_shell_bytes(rows))
        when :recursive
          checked_add(bytes, preflight.carrier_bytes)
        else
          raise CorruptPartError.new("Compact JSON carrier kind is unknown")
        end
      end

      private def self.array_object_outer_shell_bytes(rows : UInt64) : UInt64
        bytes = instance_sizeof(Array(Array(ObjectDocument))).to_u64
        checked_add(bytes, checked_multiply(rows, sizeof(Pointer(Array(ObjectDocument))).to_u64))
      end

      private def self.candidate_plan_static_bytes(
        adapter : CompactJsonColumnAdapter,
        candidate : OfflinePartCandidate,
        mark_count : Int32,
      ) : UInt64
        bytes = instance_sizeof(CandidatePlan).to_u64
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
        bytes = checked_add(bytes, checked_multiply(mark_count.to_u64, sizeof(UInt64).to_u64))
        bytes = checked_add(bytes, instance_sizeof(Array(CompactJsonMarkPreflight)).to_u64)
        bytes = checked_add(bytes, checked_multiply(mark_count.to_u64, sizeof(CompactJsonMarkPreflight).to_u64))
        bytes = checked_add(bytes, string_owner_bytes(candidate.name))
        bytes = checked_add(bytes, string_owner_bytes(File.expand_path(candidate.path)))
        bytes = checked_add(bytes, string_owner_bytes(adapter.schema_declaration))
        bytes = checked_add(bytes, string_owner_bytes(adapter.source_declaration))
        bytes = checked_add(bytes, string_array_bytes(adapter.physical_stream_names))
        bytes = checked_add(bytes, string_array_bytes(adapter.selected_checksum_names))
        checked_add(bytes, instance_sizeof(BinaryBulkProfile).to_u64)
      end

      private def self.schema_descriptor_usage(schema : StorageColumnSchema) : DescriptorUsage
        usage = DescriptorUsage.new(
          instance_sizeof(StorageColumnSchema).to_u64 +
          instance_sizeof(Array(StorageColumnSchema)).to_u64 +
          instance_sizeof(Array(String)).to_u64 * 2_u64 +
          checked_multiply(schema.child_count.to_u64, sizeof(Pointer(StorageColumnSchema)).to_u64),
          1_u64,
          schema.child_count.to_u64,
        )
        usage = DescriptorUsage.new(
          checked_add(usage.bytes, checked_add(string_owner_bytes(schema.declaration), string_owner_bytes(schema.source_declaration))),
          usage.nodes,
          usage.elements,
        )
        if schema.named_tuple?
          usage = DescriptorUsage.new(
            checked_add(usage.bytes, checked_multiply(schema.child_count.to_u64, sizeof(Pointer(String)).to_u64 * 2_u64)),
            usage.nodes,
            checked_add(usage.elements, schema.child_count.to_u64),
          )
          schema.child_count.times do |index|
            usage = DescriptorUsage.new(
              checked_add(
                usage.bytes,
                checked_add(string_owner_bytes(schema.field_name_at(index)), string_owner_bytes(schema.field_display_at(index))),
              ),
              checked_add(usage.nodes, 2_u64),
              usage.elements,
            )
          end
        end
        if object_schema = schema.object_schema_or_nil
          fields = object_schema.typed_paths
          estimate = ObjectSchemaLogicalUsage.measure(object_schema, fields)
          usage = usage + DescriptorUsage.new(estimate.bytes, estimate.nodes, estimate.elements)
        elsif bulk_type = schema.bulk_type_or_nil
          usage = usage + DescriptorUsage.new(
            instance_sizeof(BinaryDataType).to_u64 + string_owner_bytes(bulk_type.name),
            1_u64,
            bulk_type.child_count.to_u64,
          )
        end
        schema.child_count.times do |index|
          usage = usage + schema_descriptor_usage(schema.child_at(index))
        end
        usage
      end

      private def self.ensure_shape_limits!(
        descriptor_usage : DescriptorUsage,
        expected_rows : UInt64,
        shape_nodes : UInt64,
        shape_tuple_cells : UInt64,
        shape_elements : UInt64,
        array_rows : UInt64,
        array_children : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
      ) : Nil
        budget = ObjectValuesMaterializationBudget.new(
          logical_limit: LOGICAL_LIMIT,
          max_string_bytes: max_string_bytes,
          max_tuple_cells: max_tuple_cells,
        )
        # Mirror reserve_base's node/element counters without allocating the output array.
        base_elements = checked_add(expected_rows, descriptor_usage.elements)
        base_nodes = checked_add(1_u64, descriptor_usage.nodes)
        base_nodes = checked_add(base_nodes, array_rows)
        base_elements = checked_add(base_elements, array_children)
        unless base_nodes <= budget.max_nodes
          raise BoundsError.new("Compact JSON base node limit exceeded")
        end
        unless base_elements <= budget.max_elements
          raise BoundsError.new("Compact JSON base element limit exceeded")
        end
        unless shape_nodes <= budget.max_nodes - base_nodes
          raise BoundsError.new("Compact JSON recursive node limit exceeded")
        end
        unless shape_tuple_cells <= max_tuple_cells
          raise BoundsError.new("Compact JSON Tuple cell limit exceeded")
        end
        unless shape_elements <= budget.max_elements - base_elements
          raise BoundsError.new("Compact JSON recursive element limit exceeded")
        end
        nil
      end

      private def self.ensure_preflight_limit!(
        base_bytes : UInt64,
        plan_bytes : UInt64,
        workspace_bytes : UInt64,
      ) : Nil
        total = checked_add(base_bytes, checked_add(plan_bytes, workspace_bytes))
        if total > LOGICAL_LIMIT
          raise BoundsError.new("Compact JSON aggregate materialization limit exceeded")
        end
        nil
      end

      private def self.sum_candidate_rows(candidates : Array(OfflinePartCandidate)) : UInt64
        total = 0_u64
        candidates.each do |candidate|
          total = checked_add(total, candidate.row_count)
        end
        total
      end

      private def self.sum_mark_rows(mark_rows : Array(UInt64)) : UInt64
        total = 0_u64
        mark_rows.each { |rows| total = checked_add(total, rows) }
        total
      end

      private def self.string_array_bytes(values : Array(String)) : UInt64
        bytes = instance_sizeof(Array(String)).to_u64
        bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(String)).to_u64))
        values.each { |value| bytes = checked_add(bytes, string_owner_bytes(value)) }
        bytes
      end

      private def self.string_owner_bytes(value : String) : UInt64
        checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Compact JSON logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Compact JSON logical charge overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
