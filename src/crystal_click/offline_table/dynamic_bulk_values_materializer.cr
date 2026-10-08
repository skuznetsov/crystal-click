module CrystalClick
  class OfflineTable
    # Owns the generic Dynamic-bearing .values result. The budget combines the
    # retained result/type/value owners with wire bytes and known reader,
    # roster, mark-grid, and replay-container workspace. The Dynamic reader
    # does not expose the full transient descendant graph decoded by JSON or
    # LowCardinality replay, so this is not a 64 MiB peak-allocation or RSS cap.
    private class DynamicBulkValuesMaterializer
      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        type : BinaryDataType,
        expected_rows : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
      ) : Array(OfflineColumnValue)
        raise BoundsError.new("Dynamic catalog exceeds part limit") if candidates.size > WidePartTable::MAX_PARTS
        raise BoundsError.new("Dynamic catalog exceeds row limit") if expected_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS

        candidate_rows = sum_candidate_rows(candidates)
        unless candidate_rows == expected_rows
          raise CorruptPartError.new("Dynamic catalog candidate count differs from preflight row count")
        end

        budget = ObjectValuesMaterializationBudget.new(
          max_string_bytes: max_string_bytes,
          max_tuple_cells: max_tuple_cells,
        )
        # Reserve the actual public result union slots before allocating them;
        # the nominal descriptor is then charged through the shared visitor.
        budget.reserve_base(expected_rows, 0_u64, descriptor_nodes: 0_u64, descriptor_elements: 0_u64)
        budget.charge_binary_type(type)

        # Preflight every candidate, including complete schedules and any
        # required full-part replay, before allocating the retained result.
        candidates.each do |candidate|
          reader = DynamicBulkColumnReader.open(candidate.path, column, type)
          mark_rows = reader.mark_row_counts
          validate_reader!(reader, candidate, mark_rows, expected_rows)
          workspace = full_part_workspace_bytes(reader, mark_rows, candidate, column)
          budget.ensure_workspace(workspace)
          reader.validate_complete_schedule
        end

        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        observed_rows = 0_u64

        # Reopen one candidate at a time. Actual rosters and profiles may vary
        # by immutable part; each reopen is checked against that part's own
        # declaration and grid rather than another part's runtime roster.
        candidates.each do |candidate|
          reader = DynamicBulkColumnReader.open(candidate.path, column, type)
          mark_rows = reader.mark_row_counts
          validate_reader!(reader, candidate, mark_rows, expected_rows)
          workspace = full_part_workspace_bytes(reader, mark_rows, candidate, column)

          mark_rows.each_with_index do |expected_mark_rows, mark_index|
            # One-mark reads can replay the full LC/JSON domain internally.
            # Reserve the conservative full-part workspace before entering
            # that path, including when the selected mark itself is empty.
            budget.ensure_workspace(workspace)
            selected = reader.read_marks(mark_index, 1)
            unless selected.size == 1 && selected[0].size.to_u64 == expected_mark_rows
              raise CorruptPartError.new("Dynamic catalog mark row count changed during materialization")
            end

            mark_values = selected[0]
            if observed_rows > expected_rows || mark_values.size.to_u64 > expected_rows - observed_rows
              raise CorruptPartError.new("Dynamic catalog observed more rows than preflight")
            end
            mark_values.each do |value|
              unless value.type == type
                raise CorruptPartError.new("Dynamic value type differs from its declaration")
              end
            end

            # Descendant/String/Tuple counters commit atomically for a whole
            # mark before any value from that mark is retained in `values`.
            budget.charge_binary_values(mark_values, workspace)
            mark_values.each do |value|
              values << value
              observed_rows += 1_u64
            end
          end
        end

        unless observed_rows == expected_rows
          raise CorruptPartError.new("Dynamic catalog row count differs from preflight")
        end
        unless values.size.to_u64 == expected_rows
          raise CorruptPartError.new("Dynamic catalog retained row count differs from result allocation")
        end
        values
      end

      private def self.validate_reader!(
        reader : DynamicBulkColumnReader,
        candidate : OfflinePartCandidate,
        mark_rows : Array(UInt64),
        expected_rows : UInt64,
      ) : Nil
        unless reader.row_count == candidate.row_count
          raise CorruptPartError.new("Dynamic catalog part row count differs from candidate metadata")
        end
        unless reader.mark_count == mark_rows.size && !mark_rows.empty?
          raise CorruptPartError.new("Dynamic catalog mark grid differs from its part")
        end

        rows_from_marks = 0_u64
        mark_rows.each do |rows|
          if rows == 0_u64 || rows > UInt64::MAX - rows_from_marks
            raise CorruptPartError.new("Dynamic catalog mark row count is invalid or overflows UInt64")
          end
          rows_from_marks += rows
        end
        unless rows_from_marks == reader.row_count
          raise CorruptPartError.new("Dynamic catalog mark grid differs from part row count")
        end

        # open compares the source literal to the expected type's canonical
        # declaration. Keep this explicit source/canonical check for the
        # second-pass reopen and its part-local diagnostics.
        unless reader.source_declaration == reader.schema_declaration
          raise CorruptPartError.new("Dynamic catalog source declaration is not canonical")
        end
        unless reader.row_count <= expected_rows
          raise CorruptPartError.new("Dynamic catalog part count exceeds table preflight")
        end
        nil
      end

      private def self.full_part_workspace_bytes(
        reader : DynamicBulkColumnReader,
        mark_rows : Array(UInt64),
        candidate : OfflinePartCandidate,
        column : String,
      ) : UInt64
        bytes = reader.logical_read_bytes
        bytes = checked_add(bytes, instance_sizeof(DynamicBulkColumnReader).to_u64)
        bytes = checked_add(bytes, instance_sizeof(DynamicBulkSiteReader).to_u64)
        bytes = checked_add(bytes, instance_sizeof(BinaryDynamicBulkPlan).to_u64)
        bytes = checked_add(bytes, instance_sizeof(BinaryDynamicBulkPhysicalPlan).to_u64)
        bytes = checked_add(bytes, instance_sizeof(PartStreamSource).to_u64)
        # Count the actual retained @grids and @structure_grids census,
        # including each grid's mark-specific positions and row arrays.
        bytes = checked_add(bytes, reader.retained_grid_workspace_bytes)

        # The reader owns one P-grid; mark_row_counts returns a detached copy.
        # Count both owners plus the copies used by full-domain schedule and
        # decode operations.
        mark_count = mark_rows.size.to_u64
        mark_slots = checked_multiply(mark_count, sizeof(UInt64).to_u64)
        bytes = checked_add(bytes, checked_multiply(instance_sizeof(Array(UInt64)).to_u64, 6_u64))
        bytes = checked_add(bytes, checked_multiply(mark_slots, 6_u64))

        # A full replay retains one BinaryValue pointer array per P mark while
        # constructing the decoded result, then may coexist with the selected
        # one-mark return. Descendant owners inside those values are deliberately
        # outside this known-container estimate (see class-level limitation).
        full_result = instance_sizeof(Array(Array(BinaryValue))).to_u64
        full_result = checked_add(full_result, checked_multiply(mark_count, sizeof(Pointer(Array(BinaryValue))).to_u64))
        full_result = checked_add(full_result, checked_multiply(mark_count, instance_sizeof(Array(BinaryValue)).to_u64))
        full_result = checked_add(full_result, checked_multiply(reader.row_count, sizeof(Pointer(BinaryValue)).to_u64))
        largest_mark = 0_u64
        mark_rows.each { |rows| largest_mark = rows if rows > largest_mark }
        selected_result = instance_sizeof(Array(Array(BinaryValue))).to_u64
        selected_result = checked_add(selected_result, sizeof(Pointer(Array(BinaryValue))).to_u64)
        selected_result = checked_add(selected_result, instance_sizeof(Array(BinaryValue)).to_u64)
        selected_result = checked_add(selected_result, checked_multiply(largest_mark, sizeof(Pointer(BinaryValue)).to_u64))
        bytes = checked_add(bytes, checked_add(full_result, selected_result))

        physical_names = reader.physical_stream_names
        checksum_names = reader.selected_checksum_names
        bytes = checked_add(bytes, checked_multiply(string_array_bytes(physical_names), 2_u64))
        bytes = checked_add(bytes, checked_multiply(string_array_bytes(checksum_names), 2_u64))
        # Include bounded role-map/read-window containers and one possible
        # discriminator prefix-read tuple per physical role.
        role_count = physical_names.size.to_u64
        role_workspace = instance_sizeof(Hash(String, BinaryBulkStream)).to_u64
        role_workspace = checked_add(role_workspace, checked_multiply(role_count, sizeof(Pointer(String)).to_u64 * 2_u64))
        role_workspace = checked_add(role_workspace, checked_multiply(role_count, instance_sizeof(BinaryBulkStream).to_u64))
        role_workspace = checked_add(role_workspace, checked_multiply(role_count, sizeof(Tuple(String, Int32, Int32)).to_u64))
        bytes = checked_add(bytes, role_workspace)

        source = reader.source_declaration
        canonical = reader.schema_declaration
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(source), 2_u64))
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(canonical), 2_u64))
        bytes = checked_add(bytes, string_owner_bytes(candidate.name))
        bytes = checked_add(bytes, string_owner_bytes(candidate.path))
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(column), 2_u64))
        checked_add(bytes, string_owner_bytes(File.expand_path(candidate.path)))
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

      private def self.sum_candidate_rows(candidates : Array(OfflinePartCandidate)) : UInt64
        total = 0_u64
        candidates.each do |candidate|
          if candidate.row_count > UInt64::MAX - total
            raise CorruptPartError.new("Dynamic catalog candidate row count overflows UInt64")
          end
          total += candidate.row_count
        end
        total
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Dynamic catalog logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Dynamic catalog logical charge overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
