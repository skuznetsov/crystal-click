module CrystalClick
  # Staged semantic comparison is deliberately separate from public value
  # identity equality. JSON owns paths/values outside byte and child lanes.
  class CompactPartValueComparison
    def self.binary!(actual : BinaryValue, expected : BinaryValue, budget : BinaryCodecBudget, depth : Int32 = 1) : Nil
      require_read_budget!(budget)
      budget.visit_node(depth)
      unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
             (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
             actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
        raise CorruptPartError.new("staged Compact BinaryValue differs from input descriptor")
      end
      budget.charge_wire_bytes(actual.byte_size.to_u64)
      actual.byte_size.times do |index|
        unless actual.byte_at(index) == expected.byte_at(index)
          raise CorruptPartError.new("staged Compact scalar bytes differ from input")
        end
      end
      if actual.type.tag == BinaryDataType::TAG_JSON
        json!(actual.json_row, expected.json_row, budget, depth)
      else
        budget.preflight_children(actual.child_count.to_u64)
        actual.child_count.times { |index| binary!(actual.child_at(index), expected.child_at(index), budget, depth + 1) }
      end
      nil
    end

    def self.document!(actual : ObjectDocument, expected : ObjectDocument, budget : BinaryCodecBudget, depth : Int32 = 1) : Nil
      require_read_budget!(budget)
      budget.visit_node(depth)
      budget.preflight_children(expected.path_count.to_u64)
      actual_index = 0
      expected.path_count.times do |expected_index|
        path_bytes = expected.path_byte_size_at(expected_index).to_u64
        budget.charge_wire_bytes(path_bytes)
        path = expected.path_at(expected_index)
        expected_value = expected.value_for(path)
        # Nothing is the existing Object codec's absent-path representation.
        next if expected_value.type.tag == BinaryDataType::TAG_NOTHING && expected_value.is_null?
        unless actual_index < actual.path_count && actual.path_byte_size_at(actual_index) == path_bytes
          raise CorruptPartError.new("staged Compact Object path roster differs from input")
        end
        path_bytes.to_i.times do |byte_index|
          unless actual.path_byte_at(actual_index, byte_index) == expected.path_byte_at(expected_index, byte_index)
            raise CorruptPartError.new("staged Compact Object path differs from input")
          end
        end
        binary!(actual.value_for(path), expected_value, budget, depth + 1)
        actual_index += 1
      end
      unless actual_index == actual.path_count
        raise CorruptPartError.new("staged Compact Object document has an unexpected path")
      end
      nil
    end

    def self.storage!(actual : StorageColumnValue, expected : StorageColumnValue, budget : BinaryCodecBudget, depth : Int32 = 1) : Nil
      require_read_budget!(budget)
      budget.visit_node(depth)
      unless actual.kind == expected.kind && actual.child_count == expected.child_count
        raise CorruptPartError.new("staged Compact recursive value shape differs from input")
      end
      if actual.tuple? || actual.array?
        budget.preflight_children(actual.child_count.to_u64)
        actual.child_count.times { |index| storage!(actual.child_at(index), expected.child_at(index), budget, depth + 1) }
      elsif actual.object?
        document!(actual.object_document, expected.object_document, budget, depth)
      else
        binary!(actual.bulk_value, expected.bulk_value, budget, depth)
      end
      nil
    end

    private def self.json!(actual : BinaryJsonRow, expected : BinaryJsonRow, budget : BinaryCodecBudget, depth : Int32) : Nil
      unless actual.path_count == expected.path_count
        raise CorruptPartError.new("staged Compact JSON path count differs from input")
      end
      budget.preflight_children(expected.path_count.to_u64)
      expected.path_count.times do |index|
        path_bytes = expected.path_byte_size(index)
        budget.charge_wire_bytes(path_bytes.to_u64)
        unless actual.path_byte_size(index) == path_bytes
          raise CorruptPartError.new("staged Compact JSON path roster differs from input")
        end
        path_bytes.times do |byte_index|
          unless actual.path_byte_at(index, byte_index) == expected.path_byte_at(index, byte_index)
            raise CorruptPartError.new("staged Compact JSON path differs from input")
          end
        end
        binary!(actual.value_at(index), expected.value_at(index), budget, depth + 1)
      end
      nil
    end

    private def self.require_read_budget!(budget : BinaryCodecBudget) : Nil
      raise ArgumentError.new("Compact staged value comparison requires a read-direction budget") if budget.writing?
      nil
    end
  end
end
