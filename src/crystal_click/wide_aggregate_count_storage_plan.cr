module CrystalClick
  # Exact one-lane physical plan for ordinary top-level AggregateFunction(count)
  # descriptors. The argument is nominal descriptor metadata; it does not add a
  # physical stream, and Count's variable-width state never uses UInt64 storage.
  class WideAggregateCountStoragePlan
    MAX_MARK_RANGE_ROWS     = 65_536_u64
    MAX_STATE_BYTES_PER_ROW =     10_u64

    NO_ARGUMENT_TYPE_NAME = "AggregateFunction(count)"
    ARGUMENT_TYPE_PREFIX  = "AggregateFunction(count, "
    TYPE_NAME_SUFFIX      = ")"

    getter data_type : BinaryDataType

    def self.for_type_name(type_name : String) : WideAggregateCountStoragePlan?
      limits = BinaryCodecLimits.default
      # Check the complete external spelling before taking a substring or
      # invoking the recursive argument-name parser.
      return nil if type_name.bytesize.to_i64 > limits.max_bytes

      return new(BinaryDataType.aggregate_count) if type_name == NO_ARGUMENT_TYPE_NAME
      return nil unless type_name.starts_with?(ARGUMENT_TYPE_PREFIX) && type_name.ends_with?(TYPE_NAME_SUFFIX)
      return nil if type_name.bytesize <= ARGUMENT_TYPE_PREFIX.bytesize + TYPE_NAME_SUFFIX.bytesize

      argument_bytes = type_name.bytesize - ARGUMENT_TYPE_PREFIX.bytesize - TYPE_NAME_SUFFIX.bytesize
      argument_name = type_name.byte_slice(ARGUMENT_TYPE_PREFIX.bytesize, argument_bytes)
      argument = BinaryAggregateCountArgumentNameParser.parse_canonical(argument_name) || return nil

      # The general Count factory owns the recursive nominal policy (including
      # transformed Nullable(Nothing) identity and noncanonical Decimal width).
      # Re-rendering under the Count name budget also checks the full shell and
      # requires an exact canonical spelling after factory validation.
      type = BinaryDataType.aggregate_count(argument)
      canonical_name = bounded_type_name(type) || return nil
      return nil unless canonical_name == type_name

      new(type)
    rescue ex : ArgumentError | UnsupportedFormatError
      nil
    end

    def self.for_type(type : BinaryDataType) : WideAggregateCountStoragePlan?
      return nil unless type.tag == BinaryDataType::TAG_AGGREGATE_COUNT
      return nil unless type.aggregate_count_type

      # Structural equality after the canonical parse-render round trip is
      # essential: some descriptor spellings (notably Decimal) do not encode
      # every nominal field in their SQL display name.
      canonical_name = bounded_type_name(type) || return nil
      plan = for_type_name(canonical_name) || return nil
      plan.data_type == type ? plan : nil
    rescue ex : ArgumentError | UnsupportedFormatError
      nil
    end

    def self.require(type : BinaryDataType) : WideAggregateCountStoragePlan
      for_type(type) || raise(UnsupportedFormatError.new("AggregateFunction(count) requires one exact admitted descriptor"))
    end

    private def self.bounded_type_name(type : BinaryDataType) : String?
      budget = BinaryCodecBudget.new(BinaryCodecLimits.default, true)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      BinaryTypeNameBudget.materialize(type, budget, bounds)
    rescue ex : ArgumentError | UnsupportedFormatError
      nil
    end

    private def initialize(@data_type : BinaryDataType)
      unless @data_type.tag == BinaryDataType::TAG_AGGREGATE_COUNT && @data_type.aggregate_count_type
        raise ArgumentError.new("AggregateFunction(count) storage plan requires its nominal descriptor")
      end
    end

    def type_name : String
      @data_type.name
    end

    def physical_streams(column : String) : Array(String)
      [PhysicalStreamName.escape(column)]
    end

    def stream_width(column : String, stream_name : String) : Int32
      expected_stream = PhysicalStreamName.escape(column)
      raise UnsupportedFormatError.new("AggregateFunction(count) has one exact value stream") unless stream_name == expected_stream
      1
    end

    def maximum_state_bytes(row_count : UInt64) : Int32
      if row_count > MAX_MARK_RANGE_ROWS
        raise CorruptPartError.new("AggregateFunction(count) mark range exceeds row limit")
      end
      (row_count * MAX_STATE_BYTES_PER_ROW).to_i32
    end
  end
end
