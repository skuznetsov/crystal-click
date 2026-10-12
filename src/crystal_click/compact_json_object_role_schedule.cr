module CrystalClick
  # Frozen root Object schedule for the bounded Compact MAP, MAP_WITH_BUCKETS,
  # ADVANCED and ADVANCED_CHUNKED checkpoints. It owns the source-order prefix roster and
  # the existing callback-order owner's body-role projection; it does not
  # invent a Wide event registry.
  class CompactJsonObjectRoleSchedule
    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding

    getter prefix_pairs : Array(CallbackPair)
    getter body_pairs : Array(CallbackPair)
    getter body_bindings : Array(BodyBinding)
    getter event_names : Array(String)
    getter advanced : Bool

    private def initialize(
      @prefix_pairs : Array(CallbackPair),
      @body_pairs : Array(CallbackPair),
      @body_bindings : Array(BodyBinding),
      @event_names : Array(String),
      @advanced : Bool,
    )
    end

    def self.build(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : CompactJsonObjectRoleSchedule
      object = prefix.plan.structures.object
      shared_version = object.shared_data_version
      bucket_count = physical_plan.shared_bucket_count
      advanced = (shared_version == 2_u64 || shared_version == 3_u64) && bucket_count == 2
      map = (shared_version == 0_u64 && bucket_count == 1) || (shared_version == 1_u64 && bucket_count == 2)
      unless advanced || map
        raise UnsupportedFormatError.new("Compact static JSON role schedule admits only root MAP/MAP_WITH_BUCKETS or ADVANCED/CHUNKED shared data with their sealed bucket counts")
      end
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("Compact static JSON role schedule requires the source single-stream profile")
      end

      prefix_pairs = ObjectDocumentInlineCallbackOrder.prefix_callback_pairs(
        physical_plan,
        prefix.plan,
        prefix.callback_prefix,
        budget,
        advanced,
        nil,
        false,
      )
      unless prefix_pairs.size == prefix.prefix_callback_count
        raise CorruptPartError.new("Compact static JSON prefix roster differs from the parsed Object plan")
      end
      prefix_pairs.each_with_index do |pair, index|
        observed, _bytes = prefix.prefix_callback_at(index, budget)
        unless pair[0] == observed
          raise CorruptPartError.new("Compact static JSON prefix callback order differs from the parsed Object plan")
        end
      end

      body_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
        physical_plan,
        prefix.plan,
        profile,
        prefix.callback_prefix,
        budget,
        advanced,
        true,
      )
      bindings = if advanced
                   ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
                     physical_plan,
                     prefix.plan,
                     profile,
                     budget,
                     nil,
                     false,
                   )
                 else
                   ObjectDocumentInlineCallbackOrder.body_lane_bindings(
                     physical_plan,
                     prefix.plan,
                     profile,
                     budget,
                   )
                 end
      unless body_pairs.size == bindings.size
        raise CorruptPartError.new("Compact static JSON body roles differ from their callback identities")
      end

      names = [] of String
      seen = Set(String).new
      prefix_pairs.each do |canonical, callback|
        unless seen.add?(callback)
          raise CorruptPartError.new("Compact static JSON prefix callback name is duplicated")
        end
        names << callback
      end
      body_pairs.each_with_index do |pair, index|
        unless pair[0] == bindings[index][0]
          raise CorruptPartError.new("Compact static JSON body callback is not bound to its parsed role")
        end
        unless seen.add?(pair[1])
          raise CorruptPartError.new("Compact static JSON callback schedule duplicates a physical name")
        end
        names << pair[1]
      end

      new(prefix_pairs, body_pairs, bindings, names, advanced)
    end
  end
end
