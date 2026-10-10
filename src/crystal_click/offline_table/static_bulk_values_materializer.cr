module CrystalClick
  class OfflineTable
    # Owns the public .values result for admitted static BinaryBulk families
    # using the generic reader while preserving their nominal declaration
    # owners. The shared budget accounts retained BinaryValue trees plus known
    # reader/grid workspace; it is logical ownership accounting, not an RSS bound.
    private class StaticBulkValuesMaterializer
      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        type : BinaryDataType,
        expected_rows : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
      ) : Array(OfflineColumnValue)
        raise BoundsError.new("static BinaryBulk catalog exceeds part limit") if candidates.size > WidePartTable::MAX_PARTS
        raise BoundsError.new("static BinaryBulk catalog exceeds row limit") if expected_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS

        declaration = if type.contains_qbit?
                        BinaryQBitBulkColumnDeclaration.new(type).declaration
                      elsif type.contains_aggregate_function?
                        BinaryAggregateFunctionBulkColumnDeclaration.new(type).declaration
                      elsif type.contains_custom_geo?
                        BinaryCustomGeoBulkColumnDeclaration.new(type).declaration
                      elsif type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE ||
                            (type.tag == BinaryDataType::TAG_NULLABLE && type.child_at(0).tag == BinaryDataType::TAG_SIMPLE_AGGREGATE)
                        simple_aggregate_declaration = SimpleAggregateBulkColumnDeclaration.new(type).declaration
                        unless SimpleAggregateBulkColumnDeclaration.parse(simple_aggregate_declaration) &&
                               WidePart.supports_simple_aggregate_bulk_type?(simple_aggregate_declaration)
                          raise UnsupportedFormatError.new("static bulk materializer requires an admitted recursive SimpleAggregate declaration")
                        end
                        simple_aggregate_declaration
                      else
                        StaticBinaryBulkColumnDeclaration.new(type).declaration
                      end
        unless WidePart.supports_static_binary_bulk_type?(declaration)
          raise UnsupportedFormatError.new("static bulk materializer requires an admitted nominal BinaryBulk profile")
        end

        candidate_rows = sum_candidate_rows(candidates)
        unless candidate_rows == expected_rows
          raise CorruptPartError.new("static BinaryBulk catalog candidate count differs from preflight row count")
        end

        budget = ObjectValuesMaterializationBudget.new(
          max_string_bytes: max_string_bytes,
          max_tuple_cells: max_tuple_cells,
        )
        budget.reserve_base(expected_rows, 0_u64, descriptor_nodes: 0_u64, descriptor_elements: 0_u64)
        budget.charge_binary_type(type)

        # Open and validate every part before allocating the retained result.
        # Each reader owns only one part's selected physical grid.
        candidates.each do |candidate|
          reader = BinaryBulkColumnReader.open(candidate.path, column, type)
          mark_rows = reader.mark_row_counts
          validate_reader!(reader, candidate, mark_rows, type, expected_rows)
          workspace = full_part_workspace_bytes(reader, mark_rows, candidate, column)
          budget.ensure_workspace(workspace)
        end

        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        observed_rows = 0_u64

        # Reopen one candidate at a time and commit each complete parent mark
        # under the shared descendant and active-workspace budget.
        candidates.each do |candidate|
          reader = BinaryBulkColumnReader.open(candidate.path, column, type)
          mark_rows = reader.mark_row_counts
          validate_reader!(reader, candidate, mark_rows, type, expected_rows)
          workspace = full_part_workspace_bytes(reader, mark_rows, candidate, column)

          mark_rows.each_with_index do |expected_mark_rows, mark_index|
            budget.ensure_workspace(workspace)
            selected = reader.read_marks(mark_index, 1)
            unless selected.size == 1 && selected[0].size.to_u64 == expected_mark_rows
              raise CorruptPartError.new("static BinaryBulk catalog mark row count changed during materialization")
            end

            mark_values = selected[0]
            if observed_rows > expected_rows || mark_values.size.to_u64 > expected_rows - observed_rows
              raise CorruptPartError.new("static BinaryBulk catalog observed more rows than preflight")
            end
            mark_values.each do |value|
              unless value.type == type
                raise CorruptPartError.new("static BinaryBulk value type differs from its declaration")
              end
            end

            budget.charge_binary_values(mark_values, workspace)
            mark_values.each do |value|
              values << value
              observed_rows += 1_u64
            end
          end
        end

        unless observed_rows == expected_rows && values.size.to_u64 == expected_rows
          raise CorruptPartError.new("static BinaryBulk catalog row count differs from its preflight result")
        end
        values
      end

      private def self.validate_reader!(
        reader : BinaryBulkColumnReader,
        candidate : OfflinePartCandidate,
        mark_rows : Array(UInt64),
        type : BinaryDataType,
        expected_rows : UInt64,
      ) : Nil
        unless reader.row_count == candidate.row_count
          raise CorruptPartError.new("static BinaryBulk catalog part row count differs from candidate metadata")
        end
        unless reader.mark_count == mark_rows.size && !mark_rows.empty?
          raise CorruptPartError.new("static BinaryBulk catalog mark grid differs from its part")
        end

        rows_from_marks = 0_u64
        mark_rows.each do |rows|
          if rows > UInt64::MAX - rows_from_marks
            raise CorruptPartError.new("static BinaryBulk catalog mark row count overflows UInt64")
          end
          rows_from_marks += rows
        end
        unless rows_from_marks == reader.row_count
          raise CorruptPartError.new("static BinaryBulk catalog mark grid differs from part row count")
        end
        unless reader.schema_declaration == type.name && reader.source_declaration == reader.schema_declaration
          raise CorruptPartError.new("static BinaryBulk catalog source declaration is not canonical")
        end
        unless reader.row_count <= expected_rows
          raise CorruptPartError.new("static BinaryBulk catalog part count exceeds table preflight")
        end
        nil
      end

      private def self.full_part_workspace_bytes(
        reader : BinaryBulkColumnReader,
        mark_rows : Array(UInt64),
        candidate : OfflinePartCandidate,
        column : String,
      ) : UInt64
        bytes = reader.logical_read_bytes
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkColumnReader).to_u64)
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkPhysicalPlan).to_u64)
        bytes = checked_add(bytes, instance_sizeof(PartStreamSource).to_u64)
        bytes = checked_add(bytes, reader.retained_grid_workspace_bytes)

        mark_count = mark_rows.size.to_u64
        mark_slots = checked_multiply(mark_count, sizeof(UInt64).to_u64)
        bytes = checked_add(bytes, checked_multiply(instance_sizeof(Array(UInt64)).to_u64, 3_u64))
        bytes = checked_add(bytes, checked_multiply(mark_slots, 3_u64))

        physical_names = reader.physical_stream_names
        checksum_names = reader.selected_checksum_names
        bytes = checked_add(bytes, checked_multiply(string_array_bytes(physical_names), 2_u64))
        bytes = checked_add(bytes, checked_multiply(string_array_bytes(checksum_names), 2_u64))

        # Account conservative mark result containers and one active lane
        # window. The full logical payload bound intentionally overestimates
        # a selected window and excludes transient allocator/RSS effects.
        mark_result = instance_sizeof(Array(Array(BinaryValue))).to_u64
        mark_result = checked_add(mark_result, sizeof(Pointer(Array(BinaryValue))).to_u64)
        mark_result = checked_add(mark_result, instance_sizeof(Array(BinaryValue)).to_u64)
        mark_result = checked_add(mark_result, checked_multiply(reader.row_count, sizeof(Pointer(BinaryValue)).to_u64))
        bytes = checked_add(bytes, mark_result)

        bytes = checked_add(bytes, string_owner_bytes(reader.schema_declaration))
        bytes = checked_add(bytes, string_owner_bytes(reader.source_declaration))
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
            raise CorruptPartError.new("static BinaryBulk catalog candidate row count overflows UInt64")
          end
          total += candidate.row_count
        end
        total
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("static BinaryBulk logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("static BinaryBulk logical charge overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
