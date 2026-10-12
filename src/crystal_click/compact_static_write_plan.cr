module CrystalClick
  # Shared immutable binding between the caller's columns, ordered physical
  # callback identities, and the selected Compact mark-slot grid.
  class CompactStaticWritePlan
    getter mark_format : CompactMarkFormat
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode
    getter column_count : Int32
    getter slot_count : Int32

    @limits : BinaryCodecLimits
    @column_plans : Array(CompactStaticCallbackPlan)
    @substreams : Array({String, Array(String)})

    def initialize(
      columns : Array(CompactStaticColumnInput),
      limits : BinaryCodecLimits,
      @mark_format : CompactMarkFormat = CompactMarkFormat::Mrk3,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      @limits = limits
      @variant_discriminator_mode.wire_value
      if columns.empty? || columns.size > WidePart::MAX_METADATA_COLUMNS || columns.size > Int32::MAX
        raise UnsupportedFormatError.new("Compact static column roster is empty or exceeds its limit")
      end
      unless @mark_format == CompactMarkFormat::Mrk3 || @mark_format == CompactMarkFormat::Mrk4
        raise UnsupportedFormatError.new("Compact static writer does not admit this mark format")
      end

      @column_count = columns.size.to_i32
      @column_plans = Array(CompactStaticCallbackPlan).new(@column_count)
      @substreams = Array({String, Array(String)}).new(@column_count)
      seen_columns = Set(String).new
      total_substreams = 0_i64

      columns.each do |column|
        name = String.new(column.name.to_slice)
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES || !seen_columns.add?(name)
          raise UnsupportedFormatError.new("Compact static column names are invalid or duplicated")
        end

        plan = CompactStaticCallbackPlan.new(column, limits, @variant_discriminator_mode)
        names = plan.callback_names
        if names.empty?
          raise UnsupportedFormatError.new("Compact static column has no physical callbacks")
        end
        if @mark_format.mrk4? &&
           names.size.to_i64 > WidePart::MAX_METADATA_SUBSTREAMS.to_i64 - total_substreams
          raise UnsupportedFormatError.new("Compact static callback roster exceeds the reader limit")
        end
        if @mark_format.mrk4?
          names.each do |stream_name|
            if stream_name.empty? || stream_name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise UnsupportedFormatError.new("Compact static physical stream name exceeds its metadata limit")
            end
          end
        end

        total_substreams += names.size
        @column_plans << plan
        @substreams << {name, names}
      end

      selected_slots = case @mark_format
                       when CompactMarkFormat::Mrk3
                         @column_count.to_i64
                       when CompactMarkFormat::Mrk4
                         total_substreams
                       else
                         raise UnsupportedFormatError.new("Compact static writer does not admit this mark format")
                       end
      if selected_slots <= 0 || selected_slots > Int32::MAX
        raise UnsupportedFormatError.new("Compact static mark-slot count exceeds its in-memory domain")
      end
      if @mark_format.mrk4? && selected_slots > WidePart::MAX_METADATA_SUBSTREAMS.to_i64
        raise UnsupportedFormatError.new("Compact static MRK4 roster exceeds the reader substream limit")
      end
      @slot_count = selected_slots.to_i32
    end

    def column_plans : Array(CompactStaticCallbackPlan)
      @column_plans.dup
    end

    def same_limits?(limits : BinaryCodecLimits) : Bool
      @limits.max_depth == limits.max_depth && @limits.max_nodes == limits.max_nodes &&
        @limits.max_elements == limits.max_elements && @limits.max_bytes == limits.max_bytes
    end

    # Schema-order blocks with each column's exact serializer callback order.
    # These names are already detached from the callback-plan owners.
    def substreams : Array({String, Array(String)})
      @substreams.map do |name, names|
        {String.new(name.to_slice), names.map { |stream| String.new(stream.to_slice) }}
      end
    end

    # Logical bytes allocated by one detached #substreams snapshot: its outer
    # array and tuple slots, each copied inner array and pointer slots, and all
    # copied String owners. This is allocation-free so callers can reserve the
    # shared result budget before obtaining the snapshot.
    def substreams_workspace_bytes : UInt64
      bytes = instance_sizeof(Array({String, Array(String)})).to_u64
      bytes = checked_workspace_add(
        bytes,
        checked_workspace_multiply(@substreams.size.to_u64, sizeof({String, Array(String)}).to_u64),
      )

      @substreams.each do |name, streams|
        bytes = checked_workspace_add(bytes, string_owner_workspace_bytes(name))
        bytes = checked_workspace_add(bytes, instance_sizeof(Array(String)).to_u64)
        bytes = checked_workspace_add(
          bytes,
          checked_workspace_multiply(streams.size.to_u64, sizeof(Pointer(String)).to_u64),
        )
        streams.each do |stream|
          bytes = checked_workspace_add(bytes, string_owner_workspace_bytes(stream))
        end
      end
      bytes
    end

    private def string_owner_workspace_bytes(value : String) : UInt64
      checked_workspace_add(instance_sizeof(String).to_u64, checked_workspace_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_workspace_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact substream snapshot workspace overflows UInt64")
      end
      left + right
    end

    private def checked_workspace_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact substream snapshot workspace overflows UInt64")
      end
      left * right
    end
  end
end
