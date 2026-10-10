module CrystalClick
  module WidePartWriter
    # Exact typed staged-readback comparison shared by the owner adapters.
    private class WidePartValueComparison
      def self.binary!(actual : BinaryValue, expected : BinaryValue) : Nil
        unless actual.type == expected.type && actual.is_null? == expected.is_null? &&
               (actual.type.tag != BinaryDataType::TAG_VARIANT || actual.variant_index? == expected.variant_index?) &&
               actual.byte_size == expected.byte_size && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged BinaryValue differs from input descriptor")
        end
        actual.byte_size.times do |index|
          unless actual.byte_at(index) == expected.byte_at(index)
            raise CorruptPartError.new("staged BinaryValue scalar bytes differ from input")
          end
        end
        if actual.type.tag == BinaryDataType::TAG_JSON
          json!(actual.json_row, expected.json_row)
          return nil
        end
        actual.child_count.times { |index| binary!(actual.child_at(index), expected.child_at(index)) }
        nil
      end

      def self.document!(actual : ObjectDocument, expected : ObjectDocument) : Nil
        actual_index = 0
        expected.path_count.times do |expected_index|
          path = expected.path_at(expected_index)
          expected_value = expected.value_for(path)
          next if expected_value.type.tag == BinaryDataType::TAG_NOTHING && expected_value.is_null?
          unless actual_index < actual.path_count && actual.path_at(actual_index) == path
            raise CorruptPartError.new("staged Object document path roster differs from input")
          end
          binary!(actual.value_for(path), expected_value)
          actual_index += 1
        end
        unless actual_index == actual.path_count
          raise CorruptPartError.new("staged Object document has an unexpected path")
        end
        nil
      end

      def self.storage!(actual : StorageColumnValue, expected : StorageColumnValue) : Nil
        unless actual.kind == expected.kind && actual.child_count == expected.child_count
          raise CorruptPartError.new("staged recursive value shape differs from input")
        end
        if actual.tuple? || actual.array?
          actual.child_count.times { |index| storage!(actual.child_at(index), expected.child_at(index)) }
        elsif actual.object?
          document!(actual.object_document, expected.object_document)
        else
          binary!(actual.bulk_value, expected.bulk_value)
        end
        nil
      end

      private def self.json!(actual : BinaryJsonRow, expected : BinaryJsonRow) : Nil
        unless actual.path_count == expected.path_count
          raise CorruptPartError.new("staged JSON path count differs from input")
        end
        expected.path_count.times do |index|
          unless actual.path_at(index) == expected.path_at(index)
            raise CorruptPartError.new("staged JSON path roster differs from input")
          end
          binary!(actual.value_at(index), expected.value_at(index))
        end
        nil
      end
    end
  end
end
