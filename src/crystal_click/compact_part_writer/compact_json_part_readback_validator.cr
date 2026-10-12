module CrystalClick
  # Owns JSON's storage carrier and semantic validation at the staged-part
  # boundary; the physical writer and public reader remain independent.
  class CompactJsonPartReadbackValidator
    def self.validate!(
      stage : String,
      input : CompactJsonColumnInput,
      expected_rows : UInt64,
      mark_rows : Array(UInt64),
      planned_data_size : UInt64,
      slot_count : Int,
      limits : BinaryCodecLimits,
      reader_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Nil
      CompactReadbackGrid.preflight!(transport_budget, mark_rows.size, slot_count, planned_data_size)
      reader = CompactRecursiveJsonColumnReader.open(
        stage, input.name, input.schema, limits, reader_limits, codec_budget, transport_budget,
      )
      unless reader.row_count == expected_rows && reader.mark_row_counts == mark_rows
        raise CorruptPartError.new("staged Compact JSON reader differs from the parent grid")
      end
      transport_budget.reserve_result_bytes(to_i64(reader.retained_workspace_bytes))
      consumed = 0_u64
      mark_rows.each_with_index do |rows, mark_index|
        expected = input.granules[mark_index]
        unless expected.size.to_u64 == rows
          raise CorruptPartError.new("staged Compact JSON input differs from its mark grid")
        end
        transport_budget.reserve_result_bytes(to_i64(result_workspace(expected, limits, reader_limits)))
        peak_workspace = 0_u64
        observer = ->(workspace : UInt64) do
          transport_budget.preflight_result_bytes(to_i64(workspace))
          peak_workspace = workspace if workspace > peak_workspace
          nil
        end
        marks = reader.read_marks(mark_index, 1, observer)
        unless marks.size == 1 && marks[0].size.to_u64 == rows
          raise CorruptPartError.new("staged Compact JSON readback differs from its selected parent grid")
        end
        expected.each_with_index do |value, row_index|
          CompactPartValueComparison.storage!(marks[0][row_index], value, codec_budget)
        end
        transport_budget.reserve_result_bytes(to_i64(peak_workspace))
        consumed += rows
      end
      unless consumed == expected_rows
        raise CorruptPartError.new("staged Compact JSON readback did not consume all input rows")
      end
      nil
    end

    private def self.result_workspace(
      values : Array(StorageColumnValue),
      limits : BinaryCodecLimits,
      reader_limits : CompressedStreamLimits,
    ) : UInt64
      # Both row arrays retain reference slots. The established materialization
      # visitor measures the complete storage/Object/JSON tree, not just scalar
      # bytes or a minimum wrapper shape.
      census = ObjectValuesMaterializationBudget.new(
        logical_limit: reader_limits.max_result_bytes.to_u64,
        max_string_bytes: limits.max_bytes.to_u64,
        max_tuple_cells: limits.max_elements.to_u64,
        max_nodes: limits.max_nodes.to_u64,
        max_elements: limits.max_elements.to_u64,
        max_depth: limits.max_depth,
      )
      census.reserve_binary_values_base(values.size.to_u64)
      census.charge_storage_values(values)
      outer = instance_sizeof(Array(Array(StorageColumnValue))).to_u64 + sizeof(Pointer(Array(StorageColumnValue))).to_u64
      if census.retained_logical_bytes > UInt64::MAX - outer
        raise UnsupportedFormatError.new("Compact JSON readback workspace overflows UInt64")
      end
      census.retained_logical_bytes + outer
    rescue ex : BoundsError
      raise UnsupportedFormatError.new("Compact JSON readback result exceeds its materialization limit")
    end

    private def self.to_i64(value : UInt64) : Int64
      if value > Int64::MAX.to_u64
        raise UnsupportedFormatError.new("Compact JSON readback workspace exceeds Int64")
      end
      value.to_i64
    end
  end
end
