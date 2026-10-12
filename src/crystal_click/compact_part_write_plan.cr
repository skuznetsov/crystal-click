module CrystalClick
  alias CompactPartWriteInput = CompactStaticColumnInput | CompactDynamicColumnInput
  alias CompactPartCallbackPlan = CompactStaticCallbackPlan | CompactDynamicCallbackPlan
  alias CompactPartEncodedColumn = CompactEncodedColumn | CompactDynamicEncodedColumn

  # Ordered mixed Compact physical plan. It composes the existing strict
  # static callback plan with explicit Dynamic plans while retaining one
  # schema-order substream roster and mark-slot grid.
  class CompactPartWritePlan
    getter mark_format : CompactMarkFormat
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode
    getter column_count : Int32
    getter slot_count : Int32

    @limits : BinaryCodecLimits
    @column_plans : Array(CompactPartCallbackPlan)
    @substreams : Array({String, Array(String)})

    def initialize(
      columns : Array(CompactPartWriteInput),
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      @mark_format : CompactMarkFormat = CompactMarkFormat::Mrk3,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      unless budget.writing? && same_limits?(limits, budget.limits)
        raise ArgumentError.new("Compact mixed write plan requires a compatible write codec budget")
      end
      @limits = limits
      @variant_discriminator_mode.wire_value
      if columns.empty? || columns.size > WidePart::MAX_METADATA_COLUMNS || columns.size > Int32::MAX
        raise UnsupportedFormatError.new("Compact mixed column roster is empty or exceeds its limit")
      end
      unless @mark_format == CompactMarkFormat::Mrk3 || @mark_format == CompactMarkFormat::Mrk4
        raise UnsupportedFormatError.new("Compact writer does not admit this mark format")
      end

      @column_count = columns.size.to_i32
      @column_plans = Array(CompactPartCallbackPlan).new(@column_count)
      @substreams = Array({String, Array(String)}).new(@column_count)
      seen_columns = Set(String).new
      total_substreams = 0_i64

      columns.each do |column|
        name = String.new(column.name.to_slice)
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES || !seen_columns.add?(name)
          raise UnsupportedFormatError.new("Compact column names are invalid or duplicated")
        end

        callback_plan = case column
                        when CompactStaticColumnInput
                          CompactStaticCallbackPlan.new(column, limits, @variant_discriminator_mode)
                        when CompactDynamicColumnInput
                          CompactDynamicCallbackPlan.new(column, limits, budget, @variant_discriminator_mode)
                        else
                          raise UnsupportedFormatError.new("unsupported Compact callback input")
                        end
        names = callback_plan.callback_names
        if names.empty?
          raise UnsupportedFormatError.new("Compact column has no physical callbacks")
        end
        if @mark_format.mrk4? &&
           names.size.to_i64 > WidePart::MAX_METADATA_SUBSTREAMS.to_i64 - total_substreams
          raise UnsupportedFormatError.new("Compact callback roster exceeds the reader limit")
        end
        if @mark_format.mrk4?
          names.each do |stream_name|
            if stream_name.empty? || stream_name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
              raise UnsupportedFormatError.new("Compact physical stream name exceeds its metadata limit")
            end
          end
        end

        total_substreams += names.size
        @column_plans << callback_plan
        @substreams << {name, names}
      end

      selected_slots = case @mark_format
                       when CompactMarkFormat::Mrk3
                         @column_count.to_i64
                       when CompactMarkFormat::Mrk4
                         total_substreams
                       else
                         raise UnsupportedFormatError.new("Compact writer does not admit this mark format")
                       end
      if selected_slots <= 0 || selected_slots > Int32::MAX
        raise UnsupportedFormatError.new("Compact mark-slot count exceeds its in-memory domain")
      end
      if @mark_format.mrk4? && selected_slots > WidePart::MAX_METADATA_SUBSTREAMS.to_i64
        raise UnsupportedFormatError.new("Compact MRK4 roster exceeds the reader substream limit")
      end
      @slot_count = selected_slots.to_i32
    end

    def column_plans : Array(CompactPartCallbackPlan)
      @column_plans.dup
    end

    def same_limits?(limits : BinaryCodecLimits) : Bool
      same_limits?(@limits, limits)
    end

    def substreams : Array({String, Array(String)})
      @substreams.map do |name, streams|
        {String.new(name.to_slice), streams.map { |stream| String.new(stream.to_slice) }}
      end
    end

    def substreams_workspace_bytes : UInt64
      bytes = instance_sizeof(Array({String, Array(String)})).to_u64
      bytes = checked_add(
        bytes,
        checked_multiply(@substreams.size.to_u64, sizeof({String, Array(String)}).to_u64),
      )
      @substreams.each do |name, streams|
        bytes = checked_add(bytes, string_owner_workspace_bytes(name))
        bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
        bytes = checked_add(bytes, checked_multiply(streams.size.to_u64, sizeof(Pointer(String)).to_u64))
        streams.each { |stream| bytes = checked_add(bytes, string_owner_workspace_bytes(stream)) }
      end
      bytes
    end

    def same_input?(input : CompactPartWriteInput, index : Int) : Bool
      callback_plan = @column_plans[index]?
      return false unless callback_plan
      return false unless callback_plan.column_name == input.name && callback_plan.type == input.type

      if static_input = input.as?(CompactStaticColumnInput)
        static_plan = callback_plan.as?(CompactStaticCallbackPlan) || return false
        static_input.profile == static_plan.profile && static_input.map_basic?
      elsif dynamic_input = input.as?(CompactDynamicColumnInput)
        dynamic_plan = callback_plan.as?(CompactDynamicCallbackPlan) || return false
        dynamic_input.profile == dynamic_plan.profile && dynamic_input.map_basic? &&
          dynamic_plan.same_context?(dynamic_input.dynamic_context)
      else
        false
      end
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def string_owner_workspace_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact mixed substream snapshot workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact mixed substream snapshot workspace overflows UInt64")
      end
      left * right
    end
  end
end
