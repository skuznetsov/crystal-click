module CrystalClick
  # Paired actual-roster Dynamic codec. Physical binding is a separate frontier.
  module BinaryDynamicBulkCodec
    def self.encode(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(
        type, structures, granules, budget, profile: profile,
        json_object_plans: json_object_plans, json_object_leaf_plans: json_object_leaf_plans,
      )
    end

    def self.encode_with_budget(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkStreams
      unless budget.writing?
        raise ArgumentError.new("Dynamic bulk encoder requires a write-direction budget")
      end
      plan = BinaryDynamicBulkPlan.new_with_budget(
        type, structures, budget, profile, json_object_plans, json_object_leaf_plans,
      )
      json_object_writer = if plan.has_json_object_bindings?
                             BinaryDynamicBulkJsonObjectWriter.new(plan, budget, granules)
                           end
      structure_streams = plan.encode_structure_streams(budget)
      data_streams = BinaryBulkEncoder.encode(
        type,
        granules,
        budget,
        profile,
        plan,
        json_object_writer: json_object_writer,
      )
      json_objects = json_object_writer.try(&.finish_leaf_streams(profile)) ||
                     Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new
      BinaryDynamicBulkStreams.new(
        structure_streams, data_streams, budget: budget, json_object_leaf_streams: json_objects)
    end

    def self.decode(
      type : BinaryDataType,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(type, streams, rows_per_mark, budget,
        first_mark: first_mark, mark_count: mark_count, profile: profile,
        json_object_plans: json_object_plans, json_object_leaf_plans: json_object_leaf_plans)
    end

    def self.decode_with_budget(
      type : BinaryDataType,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : Array(Array(BinaryValue))
      if budget.writing?
        raise ArgumentError.new("Dynamic bulk decoder requires a read-direction budget")
      end
      plan = BinaryDynamicBulkPlan.decode_structure_streams(
        type, streams.structures, budget, profile, json_object_plans, json_object_leaf_plans,
      )
      selected_first, selected_count = validate_selection(first_mark, mark_count, streams.data.mark_count)
      json_object_reader = if plan.has_json_object_bindings? || streams.json_object_count > 0
                             BinaryDynamicBulkJsonObjectReader.new(plan, streams, rows_per_mark, budget, profile)
                           end

      if reader = json_object_reader
        all_marks = BinaryBulkDecoder.decode(type, streams.data, rows_per_mark, budget, 0, nil, profile, plan, reader)
        if selected_first == 0 && selected_count == all_marks.size
          return all_marks
        end
        return [] of Array(BinaryValue) if selected_count == 0

        # The eager paired path must decode every mark before returning a
        # selected window. Account the retained outer slice records under the
        # same operation budget before copying those mark references.
        budget.preflight_children(selected_count.to_u64)
        selected_count.times { budget.charge_node }
        Array(Array(BinaryValue)).new(selected_count) do |offset|
          all_marks[selected_first + offset]
        end
      else
        BinaryBulkDecoder.decode(type, streams.data, rows_per_mark, budget, first_mark, mark_count, profile, plan)
      end
    end

    private def self.validate_selection(first_mark : Int, mark_count : Int?, real_marks : Int32) : {Int32, Int32}
      first = first_mark.to_i128
      marks = real_marks.to_i128
      if first < 0_i128 || first > marks
        raise CorruptPartError.new("binary bulk selected mark range is outside the real mark domain")
      end
      count = mark_count.try(&.to_i128) || (marks - first)
      if count < 0_i128 || count > (marks - first)
        raise CorruptPartError.new("binary bulk selected mark range is outside the real mark domain")
      end
      {first.to_i32, count.to_i32}
    end
  end
end
