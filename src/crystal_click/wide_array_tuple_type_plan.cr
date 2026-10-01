module CrystalClick
  # Physical/type authority for one outer Array over a compositional named
  # Tuple. Inner scalar admission, paths, null maps and value widths remain
  # owned by WideTupleTypePlan; this layer adds only the outer size stream.
  class WideArrayTupleTypePlan
    @tuple_plan : WideTupleTypePlan
    @column_type : String

    private def initialize(@tuple_plan : WideTupleTypePlan)
      @column_type = "Array(#{@tuple_plan.type_name})"
    end

    def self.for_type(type : String) : WideArrayTupleTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      tuple_plan = WideTupleTypePlan.for_array_type(type) || return nil
      new(tuple_plan)
    end

    # Canonical full outer declaration. Return an owned String snapshot so a
    # caller cannot mutate the plan's retained schema authority.
    def column_type : String
      String.new(@column_type.to_slice)
    end

    def type_name : String
      column_type
    end

    def tuple_plan : WideTupleTypePlan
      @tuple_plan
    end

    def outer_size_stream(column : String) : String
      "#{column}.size0"
    end

    # The .size0 stream precedes the Tuple leaf streams. Each stream's row
    # marks still count outer rows; its values may span flattened elements.
    def physical_streams(column : String) : Array(String)
      streams = [outer_size_stream(column)]
      streams.concat(@tuple_plan.physical_streams(column))
      streams
    end

    def leaf_stream_name(column : String, field : WideTupleField) : String
      @tuple_plan.leaf_stream_name(column, field)
    end

    def raw_string_stream?(column : String, stream_name : String) : Bool
      @tuple_plan.raw_string_stream?(column, stream_name)
    end

    def stream_width(column : String, stream_name : String) : Int32?
      return 8 if stream_name == outer_size_stream(column)
      @tuple_plan.stream_width(column, stream_name)
    end

    # One combined logical bound for the retained outer schedule/handles and
    # the flattened Tuple result. `schedule_charge` is the checked temporary
    # per-mark schedule retained while materialization runs. This is a logical
    # budget, not a peak-RSS estimate.
    def materialization_charge(
      outer_rows : UInt64,
      elements : UInt64,
      string_payload_bytes : UInt64,
      schedule_charge : UInt64 = 0_u64,
    ) : UInt64?
      tuple_charge = @tuple_plan.materialization_charge(elements, string_payload_bytes) || return nil
      total = tuple_charge

      outer_fixed = instance_sizeof(WideArrayTupleColumnData).to_u64
      array_header = instance_sizeof(Array(UInt64)).to_u64
      return nil if array_header > (UInt64::MAX - outer_fixed) // 2_u64
      outer_fixed += array_header * 2_u64
      return nil if outer_fixed > UInt64::MAX - total
      total += outer_fixed

      size_slots = outer_rows
      return nil if size_slots > UInt64::MAX - 1_u64
      offset_slots = size_slots + 1_u64
      per_row = 8_u64 + sizeof(WideArrayTupleRow).to_u64
      return nil if size_slots > UInt64::MAX // per_row
      outer_slots = size_slots * per_row
      return nil if offset_slots > UInt64::MAX // 8_u64
      offsets = offset_slots * 8_u64
      return nil if offsets > UInt64::MAX - outer_slots
      outer_slots += offsets
      return nil if outer_slots > UInt64::MAX - total
      total += outer_slots

      return nil if schedule_charge > UInt64::MAX - total
      total + schedule_charge
    end
  end
end
