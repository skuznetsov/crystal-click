module CrystalClick
  # One compact-writer input column encoded in either the ordinary whole-grid
  # layout or a reset stateful layout with one BinaryBulk stream set per mark.
  class CompactEncodedColumn
    getter plan : CompactStaticCallbackPlan

    private alias AdaptedLane = Tuple(Bytes, Array(UInt64), Int32)
    private alias AdaptedLaneGrid = Array(Hash(String, AdaptedLane))

    @whole_grid_streams : BinaryBulkStreams?
    @per_mark_streams : Array(BinaryBulkStreams)
    @adapted_variant_lanes : AdaptedLaneGrid
    @mark_count : Int32

    def self.encode(
      plan : CompactStaticCallbackPlan,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : CompactEncodedColumn
      mark_count = granules.size.to_i32
      requires_per_mark_layout = plan.type.contains_low_cardinality? || plan.type.contains_variant?
      if requires_per_mark_layout
        per_mark_streams = [] of BinaryBulkStreams
        granules.each do |rows|
          streams = BinaryBulkEncoder.encode(
            plan.type,
            [rows],
            budget,
            plan.profile,
            low_cardinality_policy: BinaryLowCardinalityStoragePolicy::AdditionalKeysOnly,
          )
          validate_stream_roster!(plan, streams, 1)
          per_mark_streams << streams
        end

        variant_roles = plan.variant_discriminator_roles
        adapted_variant_lanes = adapt_variant_lanes!(plan, per_mark_streams, variant_roles, budget)
        new(plan, nil, per_mark_streams, adapted_variant_lanes, mark_count)
      else
        streams = BinaryBulkCodec.encode_with_budget(
          plan.type,
          granules,
          budget,
          profile: plan.profile,
        )
        validate_stream_roster!(plan, streams, mark_count)
        new(plan, streams, [] of BinaryBulkStreams, [] of Hash(String, AdaptedLane), mark_count)
      end
    end

    private def self.adapt_variant_lanes!(
      plan : CompactStaticCallbackPlan,
      per_mark_streams : Array(BinaryBulkStreams),
      variant_roles : Array(String),
      budget : BinaryCodecBudget,
    ) : AdaptedLaneGrid
      unless plan.type.contains_variant? == !variant_roles.empty?
        raise UnsupportedFormatError.new("Compact Variant type and discriminator lanes differ")
      end
      return [] of Hash(String, AdaptedLane) if variant_roles.empty?
      unless per_mark_streams.size > 0
        raise UnsupportedFormatError.new("Compact Variant layout has no per-mark BinaryBulk streams")
      end

      mode = plan.variant_discriminator_mode.wire_value
      lanes = [] of Tuple(String, BinaryBulkStream, UInt64)
      per_mark_streams.each do |streams|
        variant_roles.each do |role|
          unless streams.roles.includes?(role)
            raise UnsupportedFormatError.new("Compact Variant discriminator role is missing from a mark")
          end
          lanes << {String.new(role.to_slice), streams.stream(role), mode}
        end
      end

      # Preflight the complete recursive-role x mark batch before the adapter
      # allocates any physical lane or detached offset grid.
      BinaryBulkDiscriminatorFramingAdapter.preflight_write(lanes, budget)

      adapted = AdaptedLaneGrid.new(per_mark_streams.size)
      lane_index = 0
      per_mark_streams.size.times do
        by_role = Hash(String, AdaptedLane).new
        variant_roles.each do |role|
          lane_role, source, lane_mode = lanes[lane_index]
          unless lane_role == role && lane_mode == mode
            raise UnsupportedFormatError.new("Compact Variant discriminator preflight order changed")
          end
          lane = BinaryBulkDiscriminatorFramingAdapter.write_lane(lane_role, source, lane_mode)
          validate_adapted_variant_lane!(lane_role, lane, mode)
          by_role[String.new(role.to_slice)] = lane
          lane_index += 1
        end
        adapted << by_role
      end
      unless lane_index == lanes.size
        raise UnsupportedFormatError.new("Compact Variant discriminator batch was not fully adapted")
      end
      adapted
    end

    private def self.validate_adapted_variant_lane!(
      role : String,
      lane : AdaptedLane,
      expected_mode : UInt64,
    ) : Nil
      bytes, offsets, prefix_size = lane
      unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
             offsets.size == 2 && offsets[0] == prefix_size.to_u64 &&
             offsets[1] == bytes.size.to_u64 &&
             BinaryBulkDiscriminatorFramingAdapter.validate_header(role, bytes, prefix_size) == expected_mode
        raise UnsupportedFormatError.new("Compact Variant discriminator framing differs from its selected mode")
      end
      nil
    end

    private def initialize(
      @plan : CompactStaticCallbackPlan,
      @whole_grid_streams : BinaryBulkStreams?,
      @per_mark_streams : Array(BinaryBulkStreams),
      @adapted_variant_lanes : AdaptedLaneGrid,
      @mark_count : Int32,
    )
      if @mark_count <= 0
        raise ArgumentError.new("Compact encoded column requires a nonempty mark grid")
      end
      requires_per_mark_layout = @plan.type.contains_low_cardinality? || @plan.type.contains_variant?
      if requires_per_mark_layout
        expected_variant_roles = @plan.variant_discriminator_roles.sort!
        expected_adapter_mark_count = expected_variant_roles.empty? ? 0 : @mark_count
        unless @whole_grid_streams.nil? && @per_mark_streams.size == @mark_count &&
               @adapted_variant_lanes.size == expected_adapter_mark_count
          raise ArgumentError.new("stateful Compact column requires one independent stream set per mark")
        end
        @adapted_variant_lanes.each do |lanes|
          unless lanes.keys.sort! == expected_variant_roles
            raise ArgumentError.new("Compact Variant adapter roster differs from its callback plan")
          end
        end
      else
        unless @whole_grid_streams && @per_mark_streams.empty? && @adapted_variant_lanes.empty?
          raise ArgumentError.new("stateless Compact column requires exactly one whole-grid stream set")
        end
      end
    end

    # Returns the body extent or generated prefix bytes for one ordered
    # physical callback. The returned slice borrows an immutable source or
    # adapted lane; it does not copy callback bytes.
    def callback_bytes(callback : CompactBinaryBulkCallback, mark_index : Int32) : Bytes
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact callback mark is outside the encoded column grid")
      end
      unless @plan.includes_callback_event?(callback)
        raise UnsupportedFormatError.new("Compact callback is outside its immutable callback plan")
      end

      role = callback.role
      if @plan.variant_discriminator_role?(role)
        return variant_callback_bytes(callback, role, mark_index)
      end

      stream = stream_for(role, mark_index)
      if callback.prefix?
        unless @plan.dictionary_prefix_role?(role) &&
               callback.prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
               stream.byte_size.to_u64 >= callback.prefix_size.to_u64
          raise UnsupportedFormatError.new("Compact callback prefix is outside an admitted dictionary lane")
        end
        return stream.borrowed_slice(0_u64, callback.prefix_size.to_u64)
      end

      source_mark = @per_mark_streams.empty? ? mark_index : 0
      start = stream.offset_at(source_mark)
      finish = stream.offset_at(source_mark + 1)
      if finish < start || finish > stream.byte_size.to_u64
        raise UnsupportedFormatError.new("Compact callback extent is outside its BinaryBulk lane")
      end
      stream.borrowed_slice(start, finish - start)
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @plan.each_callback_event { |callback| yield callback }
      nil
    end

    private def variant_callback_bytes(
      callback : CompactBinaryBulkCallback,
      role : String,
      mark_index : Int32,
    ) : Bytes
      bytes, offsets, prefix_size = adapted_variant_lane(role, mark_index)
      if callback.prefix?
        unless callback.prefix_size == prefix_size &&
               callback.prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
          raise UnsupportedFormatError.new("Compact Variant callback prefix differs from its framed lane")
        end
        return bytes[0, prefix_size]
      end

      unless callback.prefix_size == 0 && offsets.size == 2 &&
             offsets[0] == prefix_size.to_u64 && offsets[1] == bytes.size.to_u64
        raise UnsupportedFormatError.new("Compact Variant body extent differs from its framed lane")
      end
      bytes[offsets[0].to_i32, (offsets[1] - offsets[0]).to_i32]
    end

    private def adapted_variant_lane(role : String, mark_index : Int32) : AdaptedLane
      @adapted_variant_lanes[mark_index][role]? || raise(UnsupportedFormatError.new("Compact Variant callback has no adapted discriminator lane"))
    end

    private def stream_for(role : String, mark_index : Int32) : BinaryBulkStream
      if @per_mark_streams.empty?
        streams = @whole_grid_streams ||
                  raise(UnsupportedFormatError.new("Compact whole-grid stream set is unavailable"))
        streams.stream(role)
      else
        @per_mark_streams[mark_index].stream(role)
      end
    end

    private def self.validate_stream_roster!(
      plan : CompactStaticCallbackPlan,
      streams : BinaryBulkStreams,
      mark_count : Int32,
    ) : Nil
      unless streams.mark_count == mark_count
        raise UnsupportedFormatError.new("Compact BinaryBulk streams differ from the selected mark grid")
      end
      expected_roles = plan.callback_roles.sort!
      unless streams.roles == expected_roles
        raise UnsupportedFormatError.new("Compact BinaryBulk body-role roster differs from its callback plan")
      end
      expected_roles.each do |role|
        stream = streams.stream(role)
        unless stream.mark_count == mark_count && stream.offset_count == mark_count + 1
          raise UnsupportedFormatError.new("Compact BinaryBulk lane has an incomplete offset grid")
        end
        previous = 0_u64
        (mark_count + 1).times do |offset_index|
          offset = stream.offset_at(offset_index)
          if offset < previous || offset > stream.byte_size.to_u64
            raise UnsupportedFormatError.new("Compact BinaryBulk lane offsets are not monotone")
          end
          previous = offset
        end
        unless previous == stream.byte_size.to_u64
          raise UnsupportedFormatError.new("Compact BinaryBulk lane terminal offset differs from its bytes")
        end
      end

      dictionary_roles = plan.dictionary_prefix_roles
      if plan.type.contains_low_cardinality?
        unless dictionary_roles.size > 0
          raise UnsupportedFormatError.new("Compact LowCardinality plan has no dictionary prefix events")
        end
        dictionary_roles.each do |role|
          validate_additional_keys_only_dictionary!(streams.stream(role))
        end
      elsif !dictionary_roles.empty?
        raise UnsupportedFormatError.new("stateless Compact plan has unexpected dictionary prefix roles")
      end

      variant_roles = plan.variant_discriminator_roles
      if plan.type.contains_variant?
        unless variant_roles.size > 0
          raise UnsupportedFormatError.new("Compact Variant plan has no discriminator prefix events")
        end
        variant_roles.each do |role|
          unless role.ends_with?(".discriminators") && streams.roles.includes?(role)
            raise UnsupportedFormatError.new("Compact Variant prefix role is not a discriminator body lane")
          end
        end
      elsif !variant_roles.empty?
        raise UnsupportedFormatError.new("stateless Compact plan has unexpected Variant prefix roles")
      end
      nil
    end

    private def self.validate_additional_keys_only_dictionary!(stream : BinaryBulkStream) : Nil
      prefix_size = BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
      unless stream.mark_count == 1 && stream.offset_count == 2 &&
             stream.offset_at(0) == prefix_size.to_u64 &&
             stream.offset_at(1) == prefix_size.to_u64 &&
             stream.byte_size == prefix_size &&
             stream.byte_at(0) == (BinaryLowCardinalityStorageStreams::VERSION & 0xff_u64).to_u8
        raise UnsupportedFormatError.new("Compact LowCardinality dictionary body must be empty after its version prefix")
      end
      1.upto(prefix_size - 1) do |index|
        unless stream.byte_at(index) ==
                 ((BinaryLowCardinalityStorageStreams::VERSION >> (index * 8)) & 0xff_u64).to_u8
          raise UnsupportedFormatError.new("Compact LowCardinality dictionary prefix has an invalid serialization version")
        end
      end
      nil
    end
  end
end
