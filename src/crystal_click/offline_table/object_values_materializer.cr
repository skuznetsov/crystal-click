module CrystalClick
  class OfflineTable
    # Existing .values Object path. It retains only output documents across
    # parts; each ObjectColumnReader is fully inspected before result allocation
    # and then reopened one candidate at a time, keeping active part ownership
    # bounded without claiming an RSS ceiling.
    private class ObjectValuesMaterializer
      private struct CandidateReadPlan
        getter workspace_bytes : UInt64

        def initialize(@workspace_bytes : UInt64)
        end
      end

      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        type_name : String,
        expected_rows : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
      ) : Array(OfflineColumnValue)
        schema = ObjectDocumentSchema.parse_declaration(type_name)
        raise BoundsError.new("Object catalog exceeds part limit") if candidates.size > WidePartTable::MAX_PARTS
        raise BoundsError.new("Object catalog exceeds row limit") if expected_rows > OfflineTable::MAX_MATERIALIZED_VALUES_ROWS

        candidate_rows = sum_candidate_rows(candidates)
        raise CorruptPartError.new("Object catalog candidate count differs from preflight row count") unless candidate_rows == expected_rows

        schema_fields = schema.typed_paths
        schema_bytes = schema_logical_charge(schema, schema_fields)
        max_workspace = 0_u64

        # First pass opens and validates every part, including zero-row cases,
        # without retaining its descriptor owner into the next iteration.
        candidates.each do |candidate|
          plan = inspect_candidate(candidate, column, schema, expected_rows)
          max_workspace = plan.workspace_bytes if plan.workspace_bytes > max_workspace
        end

        budget = ObjectValuesMaterializationBudget.new(
          max_string_bytes: max_string_bytes,
          max_tuple_cells: max_tuple_cells,
        )
        schema_field_count = schema_fields.size.to_u64
        descriptor_nodes = checked_add(1_u64, checked_multiply(schema_field_count, 2_u64))
        descriptor_elements = checked_multiply(schema_field_count, 2_u64)
        budget.reserve_base(
          expected_rows,
          schema_bytes,
          max_workspace,
          descriptor_nodes: descriptor_nodes,
          descriptor_elements: descriptor_elements,
        )
        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        observed_rows = 0_u64

        # Reopen and consume one candidate at a time. The second open repeats
        # all identity/count checks to fail closed if a part changed in between.
        candidates.each do |candidate|
          reader = ObjectColumnReader.open(candidate.path, column, schema)
          mark_rows = reader.mark_row_counts
          validate_reader!(reader, candidate, mark_rows, schema, expected_rows)
          base_reader_workspace = reader_workspace_bytes(reader, mark_rows)
          mark_rows.each_with_index do |expected_mark_rows, mark_index|
            batch_workspace = mark_workspace_bytes(base_reader_workspace, expected_mark_rows)
            budget.ensure_workspace(batch_workspace)
            marks = reader.read_marks(mark_index, 1)
            unless marks.size == 1 && marks[0].size.to_u64 == expected_mark_rows
              raise CorruptPartError.new("Object catalog mark row count changed during materialization")
            end
            documents = marks[0]
            remaining_rows = expected_rows - observed_rows
            if documents.size.to_u64 > remaining_rows
              raise CorruptPartError.new("Object catalog observed more rows than preflight")
            end
            budget.charge_documents(documents, batch_workspace)
            documents.each do |document|
              values << document
              observed_rows += 1_u64
            end
          end
        end

        raise CorruptPartError.new("Object catalog row count differs from preflight") unless observed_rows == expected_rows
        raise CorruptPartError.new("Object catalog retained row count differs from result allocation") unless values.size.to_u64 == expected_rows
        values
      end

      private def self.inspect_candidate(
        candidate : OfflinePartCandidate,
        column : String,
        schema : ObjectDocumentSchema,
        expected_rows : UInt64,
      ) : CandidateReadPlan
        reader = ObjectColumnReader.open(candidate.path, column, schema)
        mark_rows = reader.mark_row_counts
        validate_reader!(reader, candidate, mark_rows, schema, expected_rows)
        CandidateReadPlan.new(mark_workspace_bytes(reader_workspace_bytes(reader, mark_rows), maximum_mark_rows(mark_rows)))
      end

      private def self.validate_reader!(
        reader : ObjectColumnReader,
        candidate : OfflinePartCandidate,
        mark_rows : Array(UInt64),
        schema : ObjectDocumentSchema,
        expected_rows : UInt64,
      ) : Nil
        unless reader.row_count == candidate.row_count
          raise CorruptPartError.new("Object catalog part row count differs from candidate metadata")
        end
        rows_from_marks = 0_u64
        mark_rows.each do |rows|
          if rows > UInt64::MAX - rows_from_marks
            raise CorruptPartError.new("Object catalog mark row count overflows UInt64")
          end
          rows_from_marks += rows
        end
        unless rows_from_marks == reader.row_count
          raise CorruptPartError.new("Object catalog mark grid differs from part row count")
        end

        # ObjectColumnReader.open parsed the physical declaration with the same
        # bounded parser and compared its canonical semantics to this schema.
        # Compare canonical text here; source_declaration intentionally keeps
        # the detached literal for diagnostics and can use another option order.
        unless reader.schema_declaration == schema.declaration
          raise CorruptPartError.new("Object catalog and part JSON declarations differ")
        end
        unless reader.row_count <= expected_rows
          raise CorruptPartError.new("Object catalog part count exceeds table preflight")
        end
        nil
      end

      private def self.schema_logical_charge(schema : ObjectDocumentSchema, fields : Hash(String, BinaryDataType)) : UInt64
        bytes = instance_sizeof(ObjectDocumentSchema).to_u64
        bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryDataType)).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
        bytes = checked_add(bytes, instance_sizeof(String).to_u64 + schema.declaration_byte_size.to_u64 + 1_u64)
        bytes = checked_add(bytes, checked_multiply(fields.size.to_u64, sizeof(Pointer(String)).to_u64))
        bytes = checked_add(bytes, checked_multiply(fields.size.to_u64, sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryDataType)).to_u64 + 8_u64))
        fields.each do |path, type|
          bytes = checked_add(bytes, instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64)
          bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
          bytes = checked_add(bytes, instance_sizeof(Array(BinaryDataType)).to_u64)
          bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
          name = type.name
          bytes = checked_add(bytes, instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64)
          if temporal = type.temporal_type
            bytes = checked_add(bytes, instance_sizeof(BinaryTemporalType).to_u64)
            if zone = temporal.time_zone?
              bytes = checked_add(bytes, zone.logical_charge)
            end
          end
        end
        # Include the detached typed-path snapshot used above while estimating;
        # the schema itself remains the single retained descriptor owner.
        checked_multiply(bytes, 2_u64)
      end

      private def self.reader_workspace_bytes(reader : ObjectColumnReader, mark_rows : Array(UInt64)) : UInt64
        bytes = reader.logical_read_bytes
        bytes = checked_add(bytes, instance_sizeof(ObjectColumnReader).to_u64)
        bytes = checked_add(bytes, instance_sizeof(ObjectDocumentFileDescriptor).to_u64)
        mark_slots = checked_multiply(mark_rows.size.to_u64, sizeof(UInt64).to_u64)
        bytes = checked_add(bytes, checked_multiply(mark_slots, 2_u64))
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64 * 2_u64)

        # Include both reader-owned names/declarations and detached accessor
        # copies used for semantic comparison and roster accounting.
        names = reader.physical_stream_names
        name_bytes = instance_sizeof(Array(String)).to_u64
        name_bytes = checked_add(name_bytes, checked_multiply(names.size.to_u64, sizeof(Pointer(String)).to_u64))
        names.each do |name|
          name_bytes = checked_add(name_bytes, instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64)
        end
        bytes = checked_add(bytes, checked_multiply(name_bytes, 2_u64))

        checksum_names = reader.selected_checksum_names
        checksum_bytes = instance_sizeof(Array(String)).to_u64
        checksum_bytes = checked_add(checksum_bytes, checked_multiply(checksum_names.size.to_u64, sizeof(Pointer(String)).to_u64))
        checksum_names.each do |name|
          checksum_bytes = checked_add(checksum_bytes, instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64)
        end
        bytes = checked_add(bytes, checked_multiply(checksum_bytes, 2_u64))

        source = reader.source_declaration
        canonical = reader.schema_declaration
        declaration_bytes = instance_sizeof(String).to_u64 + source.bytesize.to_u64 + 1_u64
        declaration_bytes = checked_add(declaration_bytes, instance_sizeof(String).to_u64 + canonical.bytesize.to_u64 + 1_u64)
        checked_add(bytes, checked_multiply(declaration_bytes, 2_u64))
      end

      private def self.mark_workspace_bytes(reader_bytes : UInt64, rows : UInt64) : UInt64
        outer = instance_sizeof(Array(Array(ObjectDocument))).to_u64 + sizeof(Pointer(Array(ObjectDocument))).to_u64
        inner = instance_sizeof(Array(ObjectDocument)).to_u64 + checked_multiply(rows, sizeof(Pointer(ObjectDocument)).to_u64)
        checked_add(reader_bytes, checked_add(outer, inner))
      end

      private def self.maximum_mark_rows(mark_rows : Array(UInt64)) : UInt64
        maximum = 0_u64
        mark_rows.each { |rows| maximum = rows if rows > maximum }
        maximum
      end

      private def self.sum_candidate_rows(candidates : Array(OfflinePartCandidate)) : UInt64
        total = 0_u64
        candidates.each do |candidate|
          if candidate.row_count > UInt64::MAX - total
            raise CorruptPartError.new("Object catalog candidate row count overflows UInt64")
          end
          total += candidate.row_count
        end
        total
      end

      private def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Object catalog logical charge overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
        raise BoundsError.new("Object catalog logical charge overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
        left * right
      end
    end
  end
end
