module CrystalClick
  # Paired actual-roster Dynamic codec. Physical binding is a separate frontier.
  module BinaryDynamicBulkCodec
    def self.encode(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(type, structures, granules, budget, profile: profile)
    end

    def self.encode_with_budget(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkStreams
      unless budget.writing?
        raise ArgumentError.new("Dynamic bulk encoder requires a write-direction budget")
      end
      plan = BinaryDynamicBulkPlan.new_with_budget(type, structures, budget, profile)
      structure_streams = plan.encode_structure_streams(budget)
      data_streams = BinaryBulkEncoder.encode(type, granules, budget, profile, plan)
      BinaryDynamicBulkStreams.new(structure_streams, data_streams)
    end

    def self.decode(
      type : BinaryDataType,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(type, streams, rows_per_mark, budget,
        first_mark: first_mark, mark_count: mark_count, profile: profile)
    end

    def self.decode_with_budget(
      type : BinaryDataType,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(BinaryValue))
      if budget.writing?
        raise ArgumentError.new("Dynamic bulk decoder requires a read-direction budget")
      end
      plan = BinaryDynamicBulkPlan.decode_structure_streams(type, streams.structures, budget, profile)
      BinaryBulkDecoder.decode(type, streams.data, rows_per_mark, budget, first_mark, mark_count, profile, plan)
    end
  end
end
