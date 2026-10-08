require "./binary_recursive_data_type_name_reader"

module CrystalClick
  # Parses the canonical SQL name of one AggregateFunction(count) argument.
  # This is deliberately separate from WideTypePlan's physical-part grammar:
  # accepting a logical argument name does not admit that type as a stored
  # column, a value lane, or a wrapper around AggregateFunction(count).
  # It also does not assert ClickHouse's normalized aggregate identity:
  # Nullable(Nothing), for example, can be reported under a distinct function
  # name and is rejected by BinaryAggregateCountArgumentPolicy, not this
  # standalone argument grammar.
  class BinaryAggregateCountArgumentNameParser
    def self.parse_canonical(
      source : String,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : BinaryDataType?
      type = BinaryRecursiveDataTypeNameReader.parse_canonical(source, limits) || return nil
      return nil if type.contains_aggregate_function?
      legacy_simple_aggregate_tree?(type) ? type : nil
    end

    # Count's syntax parser shares the neutral recursive grammar, but its
    # existing semantic profile stays closed to the new recursive and
    # parameterized SAF families.
    private def self.legacy_simple_aggregate_tree?(root : BinaryDataType) : Bool
      pending = [root] of BinaryDataType
      until pending.empty?
        type = pending.pop
        if type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE
          descriptor = type.simple_aggregate_type.not_nil!
          return false unless descriptor.parameters.empty? &&
                              BinarySimpleAggregateType.legacy_storage_type?(descriptor.function, descriptor.storage_type)
        end
        type.child_count.times do |index|
          pending << type.child_at(index)
        end
      end
      true
    end
  end
end
