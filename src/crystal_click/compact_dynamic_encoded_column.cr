module CrystalClick
  # One Dynamic-bearing Compact column encoded against a frozen part-wide
  # roster. Logical BinaryBulk lanes remain shared-codec output; only callback
  # framing and repeated structure prefixes are owned here.
  class CompactDynamicEncodedColumn
    private alias AdaptedLane = Tuple(Bytes, Array(UInt64), Int32)
    private alias AdaptedLaneGrid = Array(Hash(String, AdaptedLane))

    getter plan : CompactDynamicCallbackPlan

    @per_mark_streams : Array(BinaryBulkStreams)
    @adapted_discriminator_lanes : AdaptedLaneGrid
    @structure_prefixes : Hash(String, Tuple(Bytes, Bytes))
    @mark_count : Int32

    def self.encode(
      plan : CompactDynamicCallbackPlan,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : CompactDynamicEncodedColumn
      unless budget.writing?
        raise ArgumentError.new("Compact Dynamic encoding requires a write-direction budget")
      end
      mark_count = granules.size.to_i32
      if mark_count <= 0
        raise ArgumentError.new("Compact Dynamic encoded column requires a nonempty mark grid")
      end

      structure_prefixes = encode_structure_prefixes(plan, mark_count, budget)
      per_mark_streams = Array(BinaryBulkStreams).new(mark_count)
      granules.each do |rows|
        streams = BinaryBulkEncoder.encode(
          plan.type,
          [rows],
          budget,
          plan.profile,
          dynamic_plan: plan.dynamic_plan,
          low_cardinality_policy: BinaryLowCardinalityStoragePolicy::AdditionalKeysOnly,
        )
        validate_stream_roster!(plan, streams)
        per_mark_streams << streams
      end

      adapted = adapt_discriminator_lanes!(plan, per_mark_streams, budget)
      new(plan, per_mark_streams, adapted, structure_prefixes, mark_count)
    end

    private def self.encode_structure_prefixes(
      plan : CompactDynamicCallbackPlan,
      mark_count : Int32,
      budget : BinaryCodecBudget,
    ) : Hash(String, Tuple(Bytes, Bytes))
      first_streams = plan.dynamic_plan.encode_structure_streams(budget)
      prefixes = Hash(String, Tuple(Bytes, Bytes)).new(initial_capacity: plan.dynamic_plan.site_count)
      plan.dynamic_plan.each_site_path do |path|
        first = first_streams.structure_bytes_for(path)
        structure = plan.dynamic_plan.structure_for(path)
        later = encode_later_structure_prefix(structure, plan.dynamic_plan.depth_for_site(path), budget)
        prefixes[String.new(path.to_slice)] = {first, later}
      end
      unless prefixes.size == plan.dynamic_plan.site_count && mark_count > 0
        raise UnsupportedFormatError.new("Compact Dynamic structure prefix roster differs from its prepared plan")
      end
      prefixes
    end

    private def self.encode_later_structure_prefix(
      first : DynamicStructure,
      depth : Int32,
      budget : BinaryCodecBudget,
    ) : Bytes
      later = if first.version == DynamicStructure::VERSION_V3
                DynamicStructure.new(first.types, nil, first.version)
              else
                zero_statistics = StructureStatistics.new(
                  Array(UInt64).new(first.canonical_variant_count, 0_u64),
                  [] of StructureStatistic,
                )
                DynamicStructure.new(
                  first.types,
                  zero_statistics,
                  first.version,
                  first.legacy_max_dynamic_types,
                )
              end
      context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      DynamicStructureCodec.write_to(later, context, depth, depth + 1)
      context.finish_bytes
    end

    private def self.adapt_discriminator_lanes!(
      plan : CompactDynamicCallbackPlan,
      per_mark_streams : Array(BinaryBulkStreams),
      budget : BinaryCodecBudget,
    ) : AdaptedLaneGrid
      roles = plan.discriminator_roles
      unless plan.type.contains_dynamic? && !roles.empty?
        raise UnsupportedFormatError.new("Compact Dynamic plan has no discriminator state lanes")
      end

      mode = plan.variant_discriminator_mode.wire_value
      lanes = Array(Tuple(String, BinaryBulkStream, UInt64)).new(per_mark_streams.size * roles.size)
      per_mark_streams.each do |streams|
        roles.each do |role|
          unless streams.roles.includes?(role)
            raise UnsupportedFormatError.new("Compact Dynamic discriminator role is missing from a mark")
          end
          lanes << {String.new(role.to_slice), streams.stream(role), mode}
        end
      end
      BinaryBulkDiscriminatorFramingAdapter.preflight_write(lanes, budget)

      adapted = AdaptedLaneGrid.new(per_mark_streams.size)
      lane_index = 0
      per_mark_streams.size.times do
        by_role = Hash(String, AdaptedLane).new(initial_capacity: roles.size)
        roles.each do |role|
          lane_role, source, lane_mode = lanes[lane_index]
          unless lane_role == role && lane_mode == mode
            raise UnsupportedFormatError.new("Compact Dynamic discriminator preflight order changed")
          end
          lane = BinaryBulkDiscriminatorFramingAdapter.write_lane(lane_role, source, lane_mode)
          validate_adapted_lane!(lane_role, lane, mode)
          by_role[String.new(role.to_slice)] = lane
          lane_index += 1
        end
        adapted << by_role
      end
      unless lane_index == lanes.size
        raise UnsupportedFormatError.new("Compact Dynamic discriminator batch was not fully adapted")
      end
      adapted
    end

    private def self.validate_adapted_lane!(role : String, lane : AdaptedLane, expected_mode : UInt64) : Nil
      bytes, offsets, prefix_size = lane
      unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
             offsets.size == 2 && offsets[0] == prefix_size.to_u64 &&
             offsets[1] == bytes.size.to_u64 &&
             BinaryBulkDiscriminatorFramingAdapter.validate_header(role, bytes, prefix_size) == expected_mode
        raise UnsupportedFormatError.new("Compact Dynamic discriminator framing differs from its selected mode")
      end
      nil
    end

    private def self.validate_stream_roster!(plan : CompactDynamicCallbackPlan, streams : BinaryBulkStreams) : Nil
      unless streams.mark_count == 1
        raise UnsupportedFormatError.new("Compact Dynamic BinaryBulk streams differ from the one-mark encoding grid")
      end
      expected_roles = plan.data_roles.sort!
      unless streams.roles == expected_roles
        raise UnsupportedFormatError.new("Compact Dynamic BinaryBulk role roster differs from its callback plan")
      end
      expected_roles.each do |role|
        stream = streams.stream(role)
        unless stream.mark_count == 1 && stream.offset_count == 2
          raise UnsupportedFormatError.new("Compact Dynamic BinaryBulk lane has an incomplete mark grid")
        end
        previous = 0_u64
        2.times do |index|
          offset = stream.offset_at(index)
          if offset < previous || offset > stream.byte_size.to_u64
            raise UnsupportedFormatError.new("Compact Dynamic BinaryBulk lane offsets are not monotone")
          end
          previous = offset
        end
        unless previous == stream.byte_size.to_u64
          raise UnsupportedFormatError.new("Compact Dynamic BinaryBulk lane terminal differs from its bytes")
        end
      end

      plan.dictionary_prefix_roles.each do |role|
        stream = streams.stream(role)
        prefix_size = BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        unless stream.offset_at(0) == prefix_size.to_u64 &&
               stream.offset_at(1) == prefix_size.to_u64 && stream.byte_size == prefix_size &&
               stream.byte_at(0) == (BinaryLowCardinalityStorageStreams::VERSION & 0xff_u64).to_u8
          raise UnsupportedFormatError.new("Compact Dynamic LowCardinality body must be empty after its version prefix")
        end
        1.upto(prefix_size - 1) do |index|
          unless stream.byte_at(index) ==
                   ((BinaryLowCardinalityStorageStreams::VERSION >> (index * 8)) & 0xff_u64).to_u8
            raise UnsupportedFormatError.new("Compact Dynamic LowCardinality prefix has an invalid version")
          end
        end
      end
      nil
    end

    private def initialize(
      @plan : CompactDynamicCallbackPlan,
      @per_mark_streams : Array(BinaryBulkStreams),
      @adapted_discriminator_lanes : AdaptedLaneGrid,
      @structure_prefixes : Hash(String, Tuple(Bytes, Bytes)),
      @mark_count : Int32,
    )
      unless @mark_count > 0 && @per_mark_streams.size == @mark_count &&
             @adapted_discriminator_lanes.size == @mark_count &&
             @structure_prefixes.size == @plan.dynamic_plan.site_count
        raise ArgumentError.new("Compact Dynamic encoded column differs from its prepared mark and site grid")
      end
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @plan.each_callback_event { |event| yield event }
      nil
    end

    # Returns either one structure prefix, a generated eight-byte state prefix,
    # or the selected mark's logical lane body without copying source bytes.
    def callback_bytes(callback : CompactBinaryBulkCallback, mark_index : Int32) : Bytes
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact Dynamic callback mark is outside the encoded column grid")
      end
      unless @plan.includes_callback_event?(callback)
        raise UnsupportedFormatError.new("Compact Dynamic callback is outside its immutable callback plan")
      end

      if site_path = @plan.structure_site_for_callback(callback.name)
        first, later = @structure_prefixes[site_path]? ||
                       raise(UnsupportedFormatError.new("Compact Dynamic structure callback has no encoded prefix"))
        return mark_index == 0 ? first : later
      end

      if role = @plan.prefix_role_for_callback(callback.name)
        if @plan.discriminator_role?(role)
          bytes, _offsets, prefix_size = adapted_discriminator_lane(role, mark_index)
          unless callback.prefix_size == prefix_size
            raise UnsupportedFormatError.new("Compact Dynamic discriminator prefix differs from its callback plan")
          end
          return bytes[0, prefix_size]
        end
        stream = stream_for(role, mark_index)
        unless role.ends_with?(".dictionary") &&
               callback.prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
               stream.byte_size.to_u64 >= callback.prefix_size.to_u64
          raise UnsupportedFormatError.new("Compact Dynamic prefix is outside an admitted dictionary lane")
        end
        return stream.borrowed_slice(0_u64, callback.prefix_size.to_u64)
      end

      role = @plan.body_role_for_callback(callback.name) ||
             raise(UnsupportedFormatError.new("Compact Dynamic body callback has no logical role"))
      if @plan.discriminator_role?(role)
        bytes, offsets, prefix_size = adapted_discriminator_lane(role, mark_index)
        unless callback.prefix_size == 0 && offsets.size == 2 &&
               offsets[0] == prefix_size.to_u64 && offsets[1] == bytes.size.to_u64
          raise UnsupportedFormatError.new("Compact Dynamic discriminator body differs from its framed lane")
        end
        return bytes[offsets[0].to_i32, (offsets[1] - offsets[0]).to_i32]
      end

      stream = stream_for(role, mark_index)
      start = stream.offset_at(0)
      finish = stream.offset_at(1)
      if finish < start || finish > stream.byte_size.to_u64
        raise UnsupportedFormatError.new("Compact Dynamic callback extent is outside its BinaryBulk lane")
      end
      stream.borrowed_slice(start, finish - start)
    end

    private def adapted_discriminator_lane(role : String, mark_index : Int32) : AdaptedLane
      @adapted_discriminator_lanes[mark_index][role]? ||
        raise(UnsupportedFormatError.new("Compact Dynamic callback has no adapted discriminator lane"))
    end

    private def stream_for(role : String, mark_index : Int32) : BinaryBulkStream
      @per_mark_streams[mark_index].stream(role)
    end
  end
end
