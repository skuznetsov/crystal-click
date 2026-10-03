module CrystalClick
  # Public paired facade for the bounded shared LowCardinality physical
  # dictionary/index profile. This does not widen BinaryBulkCodec admission.
  module BinaryLowCardinalityStorageCodec
    def self.encode(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : BinaryBulkStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(type, granules, budget)
    end

    def self.encode_with_budget(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : BinaryBulkStreams
      BinaryLowCardinalityStorageEncoder.encode(type, granules, budget)
    end

    def self.decode(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      occurrences_per_mark : Array(UInt64),
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(type, streams, occurrences_per_mark, budget, first_mark, mark_count)
    end

    def self.decode_with_budget(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      occurrences_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
    ) : Array(Array(BinaryValue))
      BinaryLowCardinalityStorageDecoder.decode(
        type,
        streams,
        occurrences_per_mark,
        budget,
        first_mark,
        mark_count
      )
    end
  end
end
