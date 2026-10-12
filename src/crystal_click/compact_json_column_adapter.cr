module CrystalClick
  # The three established public carriers used by Compact JSON columns.
  # Root JSON and direct Array(JSON) retain their batch-native ObjectDocument
  # views; other admitted recursive shapes stay in the typed storage tree.
  alias CompactJsonColumnMark = Array(ObjectDocument) | Array(Array(ObjectDocument)) | Array(StorageColumnValue)

  class CompactJsonColumnAdapter
    getter column_name : String
    getter schema : StorageColumnSchema
    getter carrier_kind : Symbol

    @reader : CompactRecursiveJsonColumnReader
    @mark_rows : Array(UInt64)

    def self.schema_for_json_declaration(
      source_declaration : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : StorageColumnSchema?
      if WidePart.json_type?(source_declaration)
        object_schema = ObjectDocumentSchema.parse_declaration(source_declaration, limits)
        return StorageColumnSchema.object(object_schema, source_declaration)
      end

      type = BinaryRecursiveDataTypeNameReader.parse_canonical(source_declaration, limits) || return nil
      return nil unless type.contains_json? && !type.contains_dynamic?

      schema = StorageColumnSchema.parse(source_declaration, limits)
      return nil unless schema.has_json? && schema.declaration == source_declaration
      schema
    end

    def self.open(
      part_path : String,
      column_name : String,
      source_declaration : String,
      schema : StorageColumnSchema,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : CompactJsonColumnAdapter
      unless CompactRecursiveJsonColumnReader.admitted_schema?(schema)
        raise UnsupportedFormatError.new("selected Compact JSON declaration is outside recursive JSON admission")
      end
      unless schema.source_declaration == source_declaration || schema.declaration == source_declaration
        # Root JSON descriptors retain the exact physical declaration as their
        # source; recursive descriptors keep the root source and canonicalize
        # nested nodes. The reader repeats the complete tree comparison.
        raise CorruptPartError.new("selected Compact JSON schema differs from its physical declaration")
      end

      reader = CompactRecursiveJsonColumnReader.open(
        part_path,
        column_name,
        schema,
        limits: limits,
        transport_limits: transport_limits,
        codec_budget: codec_budget,
        transport_budget: transport_budget,
      )
      unless reader.schema_declaration == schema.declaration &&
             reader.source_declaration == source_declaration
        raise CorruptPartError.new("selected Compact JSON declaration changed while opening the reader")
      end
      new(column_name, schema, reader)
    end

    private def initialize(
      column_name : String,
      @schema : StorageColumnSchema,
      @reader : CompactRecursiveJsonColumnReader,
    )
      @column_name = String.new(column_name.to_slice)
      @mark_rows = @reader.mark_row_counts
      @carrier_kind = if @schema.object?
                        :object
                      elsif @schema.array? && @schema.child_at(0).object?
                        :array_object
                      else
                        :recursive
                      end
    end

    def row_count : UInt64
      @reader.row_count
    end

    def mark_count : Int32
      @reader.mark_count
    end

    def mark_row_counts : Array(UInt64)
      @mark_rows.dup
    end

    def schema_declaration : String
      @reader.schema_declaration
    end

    def source_declaration : String
      @reader.source_declaration
    end

    def ordinary_profile : BinaryBulkProfile
      @reader.ordinary_profile
    end

    def physical_stream_names : Array(String)
      @reader.physical_stream_names
    end

    def selected_checksum_names : Array(String)
      @reader.selected_checksum_names
    end

    def logical_read_bytes : UInt64
      @reader.logical_read_bytes
    end

    def retained_workspace_bytes : UInt64
      checked_add(@reader.retained_workspace_bytes, adapter_owner_workspace_bytes)
    end

    # The reader's workspace observer already includes its own retained base.
    # Expose only the sidecar-owned descriptors so aggregate callers can add
    # them without charging the recursive reader base twice.
    def adapter_owner_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonColumnAdapter).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, checked_multiply(@mark_rows.size.to_u64, sizeof(UInt64).to_u64))
    end

    def retained_grid_workspace_bytes : UInt64
      @reader.retained_grid_workspace_bytes
    end

    def validate_complete_schedule(observer : Proc(UInt64, Nil)? = nil) : Nil
      @reader.validate_complete_schedule(observer)
    end

    def storage_value_shape_for_mark(mark_index : Int) : StorageValueShape
      @reader.storage_value_shape_for_mark(mark_index)
    end

    # Metadata-only output-owner estimate. It includes carrier arrays, the
    # recursive mark grid shells, and wrappers derived from the authenticated
    # occurrence shape before any selected values are decoded.
    def mark_preflight(mark_index : Int, expected_rows : UInt64) : CompactJsonMarkPreflight
      validate_mark_rows!(mark_index, expected_rows)
      shape = storage_value_shape_for_mark(mark_index)
      carrier_bytes, carrier_nodes, carrier_elements = carrier_descriptor(shape, expected_rows)
      CompactJsonMarkPreflight.new(
        shape,
        mark_grid_shell_bytes(expected_rows),
        carrier_bytes,
        carrier_nodes,
        carrier_elements,
      )
    rescue ex : BoundsError
      raise CorruptPartError.new("selected Compact JSON mark exceeds aggregate materialization limit")
    end

    def preflight_mark_bytes(mark_index : Int, expected_rows : UInt64, logical_limit : UInt64) : UInt64
      preflight = mark_preflight(mark_index, expected_rows)
      budget = ObjectValuesMaterializationBudget.new(logical_limit: logical_limit)
      reserve_preflight!(budget, preflight)
      ensure_shape_limits!(budget, preflight.shape)
      budget.retained_logical_bytes
    rescue ex : BoundsError
      raise CorruptPartError.new("selected Compact JSON mark exceeds aggregate materialization limit")
    end

    # Reserve the exact public carrier arrays and their row slots. `rows: 0`
    # avoids using ObjectValuesMaterializationBudget's OfflineColumnValue slots
    # as a proxy for these differently typed owners; its mandatory empty
    # OfflineColumnValue header/node is a small conservative fixed allowance.
    def reserve_preflight!(budget : ObjectValuesMaterializationBudget, preflight : CompactJsonMarkPreflight) : Nil
      budget.reserve_base(
        0_u64,
        preflight.carrier_bytes,
        checked_add(preflight.temporary_bytes, preflight.shape.bytes),
        descriptor_nodes: preflight.carrier_nodes,
        descriptor_elements: preflight.carrier_elements,
      )
      ensure_shape_limits!(budget, preflight.shape)
      nil
    end

    # Reads one fully-preflighted parent mark and verifies that the recursive
    # value tree still matches its authenticated declaration and row grid.
    def storage_values_for_mark(
      mark_index : Int,
      expected_rows : UInt64,
      observer : Proc(UInt64, Nil)? = nil,
    ) : Array(StorageColumnValue)
      validate_mark_rows!(mark_index, expected_rows)
      selected = @reader.read_marks(mark_index, 1, observer)
      unless selected.size == 1 && selected[0].size.to_u64 == expected_rows
        raise CorruptPartError.new("selected Compact JSON mark row count changed")
      end
      rows = selected[0]
      rows.each { |value| validate_value!(@schema, value) }
      rows
    end

    def carrier_for(values : Array(StorageColumnValue)) : CompactJsonColumnMark
      case @carrier_kind
      when :object
        documents = Array(ObjectDocument).new(values.size)
        values.each do |value|
          documents << value.object_document
        end
        documents
      when :array_object
        rows = Array(Array(ObjectDocument)).new(values.size)
        values.each do |value|
          unless value.array?
            raise CorruptPartError.new("selected Compact Array(JSON) row is not an Array")
          end
          children = Array(ObjectDocument).new(value.child_count)
          value.child_count.times do |index|
            children << value.child_at(index).object_document
          end
          rows << children
        end
        rows
      when :recursive
        values
      else
        raise CorruptPartError.new("selected Compact JSON carrier kind is unknown")
      end
    end

    # Charge the materialized carrier after the recursive tree is available.
    # Root and direct Array(JSON) carriers charge each retained document;
    # recursive carriers charge the complete StorageColumnValue tree. For the
    # former, temporary recursive wrappers stay accounted as workspace while
    # the document owners are committed.
    def charge_carrier!(
      budget : ObjectValuesMaterializationBudget,
      values : Array(StorageColumnValue),
      carrier : CompactJsonColumnMark,
      preflight : CompactJsonMarkPreflight,
      peak_extra_workspace : UInt64,
    ) : Nil
      workspace = checked_add(preflight.temporary_bytes, peak_extra_workspace)
      case carrier
      when Array(ObjectDocument)
        budget.charge_documents(carrier, checked_add(workspace, preflight.shape.bytes))
      when Array(Array(ObjectDocument))
        workspace = checked_add(workspace, preflight.shape.bytes)
        carrier.each do |documents|
          documents.each do |document|
            budget.charge_document(document, workspace)
          end
        end
      when Array(StorageColumnValue)
        grid_workspace = checked_add(
          instance_sizeof(Array(Array(StorageColumnValue))).to_u64 + sizeof(Pointer(Array(StorageColumnValue))).to_u64,
          peak_extra_workspace,
        )
        budget.charge_storage_values(values, grid_workspace)
      else
        raise CorruptPartError.new("selected Compact JSON carrier kind is unknown")
      end
      nil
    rescue ex : BoundsError
      raise CorruptPartError.new("selected Compact JSON mark exceeds aggregate materialization limit")
    end

    # Schema-directed structure checks use indexed child access so recursive
    # compatibility conversion never obtains an uncharged child-array copy.
    private def validate_value!(schema : StorageColumnSchema, value : StorageColumnValue) : Nil
      unless schema.kind == value.kind
        raise CorruptPartError.new("selected Compact recursive value shape differs from its declaration")
      end

      if schema.tuple?
        unless value.child_count == schema.child_count
          raise CorruptPartError.new("selected Compact Tuple arity differs from its declaration")
        end
        schema.child_count.times do |index|
          validate_value!(schema.child_at(index), value.child_at(index))
        end
      elsif schema.array?
        value.child_count.times do |index|
          validate_value!(schema.child_at(0), value.child_at(index))
        end
      elsif schema.bulk?
        unless value.bulk_value.type == schema.bulk_type
          raise CorruptPartError.new("selected Compact BinaryBulk leaf differs from its declaration")
        end
      end
      nil
    end

    private def carrier_descriptor(
      shape : StorageValueShape,
      rows : UInt64,
    ) : {UInt64, UInt64, UInt64}
      bytes = 0_u64
      nodes = 0_u64
      elements = 0_u64
      case @carrier_kind
      when :object
        bytes = checked_add(
          instance_sizeof(Array(ObjectDocument)).to_u64,
          checked_multiply(rows, sizeof(Pointer(ObjectDocument)).to_u64),
        )
        nodes = 1_u64
        elements = rows
      when :array_object
        bytes = checked_add(
          instance_sizeof(Array(Array(ObjectDocument))).to_u64,
          checked_multiply(rows, sizeof(Pointer(Array(ObjectDocument))).to_u64),
        )
        bytes = checked_add(bytes, checked_multiply(rows, instance_sizeof(Array(ObjectDocument)).to_u64))
        bytes = checked_add(bytes, checked_multiply(shape.elements, sizeof(Pointer(ObjectDocument)).to_u64))
        nodes = checked_add(rows, 1_u64)
        elements = checked_add(rows, shape.elements)
      when :recursive
        bytes = checked_add(
          instance_sizeof(Array(StorageColumnValue)).to_u64,
          checked_multiply(rows, sizeof(Pointer(StorageColumnValue)).to_u64),
        )
        nodes = 1_u64
        elements = rows
      end
      {bytes, nodes, elements}
    end

    private def ensure_shape_limits!(budget : ObjectValuesMaterializationBudget, shape : StorageValueShape) : Nil
      unless shape.nodes <= budget.max_nodes - budget.node_count
        raise BoundsError.new("Object recursive node limit exceeded")
      end
      unless shape.tuple_cells <= budget.max_tuple_cells - budget.tuple_cells
        raise BoundsError.new("Object Tuple cell limit exceeded")
      end
      unless shape.elements <= budget.max_elements - budget.element_count
        raise BoundsError.new("Object recursive element limit exceeded")
      end
      nil
    end

    private def mark_grid_shell_bytes(rows : UInt64) : UInt64
      outer = instance_sizeof(Array(Array(StorageColumnValue))).to_u64
      outer = checked_add(outer, sizeof(Pointer(Array(StorageColumnValue))).to_u64)
      if @carrier_kind == :recursive
        return outer
      end
      row = instance_sizeof(Array(StorageColumnValue)).to_u64
      row = checked_add(row, checked_multiply(rows, sizeof(Pointer(StorageColumnValue)).to_u64))
      checked_add(outer, row)
    end

    private def validate_mark_rows!(mark_index : Int, expected_rows : UInt64) : Nil
      rows = @mark_rows[mark_index]?
      unless rows && rows == expected_rows
        raise CorruptPartError.new("selected Compact JSON mark row count differs from its part grid")
      end
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Compact JSON owner accounting overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("Compact JSON owner accounting overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end
  end
end
