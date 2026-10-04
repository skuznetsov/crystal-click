module CrystalClick
  # Canonical recursive logical defaults used under bulk Nullable NULL rows.
  # The encoder measures every default occurrence before constructing any of
  # these values, then materializes them one at a time while writing lanes.
  class BinaryBulkDefaultValue
    struct Cost
      getter nodes : UInt64
      getter edges : UInt64
      getter wire_bytes : UInt64

      def initialize(@nodes : UInt64, @edges : UInt64, @wire_bytes : UInt64)
      end
    end

    def self.measure(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      cache : Hash(UInt64, Cost)? = nil,
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
    ) : Cost
      reject_dynamic_type!(type, dynamic_plan)
      costs = cache || Hash(UInt64, Cost).new
      key = type.object_id
      if existing = costs[key]?
        return existing
      end

      cost = case type.tag
             when BinaryDataType::TAG_STRING
               Cost.new(1_u64, 0_u64, profile.with_size_stream? ? 8_u64 : 1_u64)
             when BinaryDataType::TAG_VARIANT
               # The sparse-bulk default is Variant NULL: one discriminator,
               # with no selected arm value or arm edge.
               Cost.new(1_u64, 0_u64, 1_u64)
             when BinaryDataType::TAG_DYNAMIC
               # A hidden Dynamic default is NULL: discriminator only.
               Cost.new(1_u64, 0_u64, 1_u64)
             when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_MAP
               Cost.new(1_u64, 0_u64, 8_u64)
             when BinaryDataType::TAG_NULLABLE
               child = measure(type.child_at(0), profile, costs, dynamic_plan)
               Cost.new(add(1_u64, child.nodes), add(1_u64, child.edges), add(1_u64, child.wire_bytes))
             when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
               if type.child_count == 0
                 Cost.new(1_u64, 0_u64, 1_u64)
               else
                 nodes = 1_u64
                 edges = type.child_count.to_u64
                 wire_bytes = 0_u64
                 type.child_count.times do |index|
                   child = measure(type.child_at(index), profile, costs, dynamic_plan)
                   nodes = add(nodes, child.nodes)
                   edges = add(edges, child.edges)
                   wire_bytes = add(wire_bytes, child.wire_bytes)
                 end
                 Cost.new(nodes, edges, wire_bytes)
               end
             when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
               Cost.new(1_u64, 0_u64, 1_u64)
             else
               if width = type.fixed_width
                 Cost.new(1_u64, 0_u64, width.to_u64)
               else
                 raise UnsupportedFormatError.new("unsupported binary bulk default DataType")
               end
             end
      costs[key] = cost
      cost
    end

    # Cost borne by the ordinary bulk visitor after LowCardinality subtrees
    # have been delegated to BinaryLowCardinalityStorageCodec. The external
    # parent edge is still charged by its container; this zero-cost leaf means
    # the wrapper and every descendant are prepaid by the LC owner.
    def self.measure_excluding_low_cardinality(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      cache : Hash(Tuple(UInt64, Bool), Cost)? = nil,
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
    ) : Cost
      reject_dynamic_type!(type, dynamic_plan)
      costs = cache || Hash(Tuple(UInt64, Bool), Cost).new
      key = {type.object_id, true}
      if existing = costs[key]?
        return existing
      end

      cost = case type.tag
             when BinaryDataType::TAG_LOW_CARDINALITY
               Cost.new(0_u64, 0_u64, 0_u64)
             when BinaryDataType::TAG_STRING
               Cost.new(1_u64, 0_u64, profile.with_size_stream? ? 8_u64 : 1_u64)
             when BinaryDataType::TAG_VARIANT
               # Variant NULL has no ordinary child subtree to exclude.
               Cost.new(1_u64, 0_u64, 1_u64)
             when BinaryDataType::TAG_DYNAMIC
               Cost.new(1_u64, 0_u64, 1_u64)
             when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_MAP
               Cost.new(1_u64, 0_u64, 8_u64)
             when BinaryDataType::TAG_NULLABLE
               child = measure_excluding_low_cardinality(type.child_at(0), profile, costs, dynamic_plan)
               Cost.new(add(1_u64, child.nodes), add(1_u64, child.edges), add(1_u64, child.wire_bytes))
             when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
               if type.child_count == 0
                 Cost.new(1_u64, 0_u64, 1_u64)
               else
                 nodes = 1_u64
                 edges = type.child_count.to_u64
                 wire_bytes = 0_u64
                 type.child_count.times do |index|
                   child = measure_excluding_low_cardinality(type.child_at(index), profile, costs, dynamic_plan)
                   nodes = add(nodes, child.nodes)
                   edges = add(edges, child.edges)
                   wire_bytes = add(wire_bytes, child.wire_bytes)
                 end
                 Cost.new(nodes, edges, wire_bytes)
               end
             when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
               Cost.new(1_u64, 0_u64, 1_u64)
             else
               if width = type.fixed_width
                 Cost.new(1_u64, 0_u64, width.to_u64)
               else
                 raise UnsupportedFormatError.new("unsupported binary bulk default DataType")
               end
             end
      costs[key] = cost
      cost
    end

    def self.build(type : BinaryDataType, dynamic_plan : BinaryDynamicBulkPlan? = nil) : BinaryValue
      reject_dynamic_type!(type, dynamic_plan)
      case type.tag
      when BinaryDataType::TAG_STRING
        BinaryValue.string("")
      when BinaryDataType::TAG_BOOL
        BinaryValue.bool(false)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_NULLABLE
        BinaryValue.null(type)
      when BinaryDataType::TAG_ARRAY
        BinaryValue.array(type, [] of BinaryValue)
      when BinaryDataType::TAG_MAP
        BinaryValue.map(type, [] of BinaryValue)
      when BinaryDataType::TAG_LOW_CARDINALITY
        BinaryValue.low_cardinality(type, build(type.child_at(0), dynamic_plan))
      when BinaryDataType::TAG_VARIANT
        BinaryValue.variant_null(type)
      when BinaryDataType::TAG_DYNAMIC
        BinaryValue.dynamic(type)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        fields = Array(BinaryValue).new(type.child_count) do |index|
          build(type.child_at(index), dynamic_plan)
        end
        BinaryValue.tuple(type, fields)
      else
        if width = type.fixed_width
          BinaryValue.fixed(type, Bytes.new(width) { 0_u8 })
        else
          raise UnsupportedFormatError.new("unsupported binary bulk default DataType")
        end
      end
    end

    private def self.reject_dynamic_type!(type : BinaryDataType, dynamic_plan : BinaryDynamicBulkPlan?) : Nil
      if type.contains_dynamic? && dynamic_plan.nil?
        raise UnsupportedFormatError.new("Dynamic is outside the admitted bulk default-value profile")
      end
    end

    private def self.add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary bulk default cost overflows UInt64")
      end
      left + right
    end
  end
end
