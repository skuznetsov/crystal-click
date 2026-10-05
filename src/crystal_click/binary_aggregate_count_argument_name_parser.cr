require "./binary_aggregate_count_argument_name_reader"

module CrystalClick
  # Parses the canonical SQL name of one AggregateFunction(count) argument.
  # This is deliberately separate from WideTypePlan's physical-part grammar:
  # accepting a logical argument name does not admit that type as a stored
  # column, a value lane, or a wrapper around AggregateFunction(count).
  # It also does not assert ClickHouse's normalized aggregate identity:
  # Nullable(Nothing), for example, can be reported under a distinct function
  # name and must be checked by a later storage-plan admission owner.
  class BinaryAggregateCountArgumentNameParser
    def self.parse_canonical(
      source : String,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : BinaryDataType?
      return nil if source.bytesize.to_i64 > limits.max_bytes

      type = BinaryAggregateCountArgumentNameReader.new(source, limits).parse || return nil
      budget = BinaryCodecBudget.new(limits, true)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      rendered = BinaryTypeNameBudget.materialize(type, budget, bounds)
      rendered == source ? type : nil
    rescue ex : ArgumentError | CorruptPartError | UnsupportedFormatError
      nil
    end
  end
end
