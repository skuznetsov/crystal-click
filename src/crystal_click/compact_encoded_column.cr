module CrystalClick
  # One compact-writer input column encoded in either the ordinary whole-grid
  # layout or a reset LC layout with one BinaryBulk state sequence per mark.
  class CompactEncodedColumn
    getter plan : CompactStaticCallbackPlan

    @whole_grid_streams : BinaryBulkStreams?
    @per_mark_streams : Array(BinaryBulkStreams)
    @mark_count : Int32

    def self.encode(
      plan : CompactStaticCallbackPlan,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : CompactEncodedColumn
      mark_count = granules.size.to_i32
      if plan.type.contains_low_cardinality?
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
        new(plan, nil, per_mark_streams, mark_count)
      else
        streams = BinaryBulkCodec.encode_with_budget(
          plan.type,
          granules,
          budget,
          profile: plan.profile,
        )
        validate_stream_roster!(plan, streams, mark_count)
        new(plan, streams, [] of BinaryBulkStreams, mark_count)
      end
    end

    private def initialize(
      @plan : CompactStaticCallbackPlan,
      @whole_grid_streams : BinaryBulkStreams?,
      @per_mark_streams : Array(BinaryBulkStreams),
      @mark_count : Int32,
    )
      if @mark_count <= 0
        raise ArgumentError.new("Compact encoded column requires a nonempty mark grid")
      end
      if @plan.type.contains_low_cardinality?
        unless @whole_grid_streams.nil? && @per_mark_streams.size == @mark_count
          raise ArgumentError.new("Compact LowCardinality column requires one independent stream grid per mark")
        end
      else
        unless @whole_grid_streams && @per_mark_streams.empty?
          raise ArgumentError.new("stateless Compact column requires exactly one whole-grid stream set")
        end
      end
    end

    # Returns the body extent or generated prefix bytes for one ordered physical
    # callback. The returned slice borrows the immutable BinaryBulk stream.
    def callback_bytes(callback : CompactBinaryBulkCallback, mark_index : Int32) : Bytes
      unless mark_index >= 0 && mark_index < @mark_count
        raise UnsupportedFormatError.new("Compact callback mark is outside the encoded column grid")
      end
      stream = stream_for(callback.role, mark_index)
      if callback.prefix?
        prefix_size = callback.prefix_size.to_u64
        unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES.to_u64 &&
               stream.byte_size.to_u64 >= prefix_size
          raise UnsupportedFormatError.new("Compact callback prefix is outside its source BinaryBulk lane")
        end
        return stream.borrowed_slice(0_u64, prefix_size)
      end

      source_mark = @per_mark_streams.empty? ? mark_index : 0
      start = stream.offset_at(source_mark)
      finish = stream.offset_at(source_mark + 1)
      if finish < start || finish > stream.byte_size.to_u64
        raise UnsupportedFormatError.new("Compact callback extent is outside its BinaryBulk lane")
      end
      stream.borrowed_slice(start, finish - start)
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

      if plan.type.contains_low_cardinality?
        prefix_roles = Set(String).new
        plan.each_callback_event do |callback|
          next unless callback.prefix?
          unless callback.prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES &&
                 callback.role.ends_with?(".dictionary") && prefix_roles.add?(callback.role)
            raise UnsupportedFormatError.new("Compact LowCardinality prefix event is not a unique dictionary prefix")
          end
          validate_additional_keys_only_dictionary!(streams.stream(callback.role))
        end
        unless prefix_roles.size > 0
          raise UnsupportedFormatError.new("Compact LowCardinality plan has no dictionary prefix events")
        end
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
