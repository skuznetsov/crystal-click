module CrystalClick
  # Exact physical/schema authority for one BASIC Map(K, named Tuple(...))
  # composition. Admission comes from one complete-source parser invocation;
  # key and value children are never reparsed under reset budgets.
  class WideMapTupleTypePlan
    @column_type : String
    @key_type : WideTupleLeafType
    @tuple_plan : WideTupleTypePlan

    private def initialize(@key_type : WideTupleLeafType, @tuple_plan : WideTupleTypePlan)
      @column_type = String.build do |io|
        io << "Map("
        io << @key_type.type_name
        io << ", "
        io << @tuple_plan.type_name
        io << ')'
      end
    end

    def self.for_type(type : String) : WideMapTupleTypePlan?
      return nil if type.bytesize > WideTupleSchemaParser::MAX_SOURCE_BYTES
      key_type, tuple_plan = WideTupleTypePlan.for_map_type(type) || return nil
      new(key_type, tuple_plan)
    end

    def column_type : String
      String.new(@column_type.to_slice)
    end

    def type_name : String
      column_type
    end

    def key_type : WideTupleLeafType
      @key_type
    end

    def tuple_plan : WideTupleTypePlan
      @tuple_plan
    end

    def outer_size_stream(column : String) : String
      "#{column}.size0"
    end

    def key_stream_name(column : String) : String
      "#{column}%2Ekeys"
    end

    def key_size_stream_name(column : String) : String
      "#{key_stream_name(column)}.size"
    end

    def value_column_prefix(column : String) : String
      "#{column}%2Evalues"
    end

    # Every value leaf's physical marks count outer rows, even though its
    # payload cardinality is the flattened Map-entry axis.
    def physical_streams(column : String) : Array(String)
      streams = [outer_size_stream(column)]
      streams << key_size_stream_name(column) if @key_type.base_type_name == "String"
      streams << key_stream_name(column)
      streams.concat(@tuple_plan.physical_streams(value_column_prefix(column)))
      streams
    end

    def raw_string_stream?(column : String, stream_name : String) : Bool
      return true if @key_type.base_type_name == "String" && stream_name == key_stream_name(column)
      @tuple_plan.raw_string_stream?(value_column_prefix(column), stream_name)
    end

    def stream_width(column : String, stream_name : String) : Int32?
      return 8 if stream_name == outer_size_stream(column)
      if @key_type.base_type_name == "String"
        return 8 if stream_name == key_size_stream_name(column)
        return 1 if stream_name == key_stream_name(column)
      elsif stream_name == key_stream_name(column)
        return @key_type.raw_width
      end
      @tuple_plan.stream_width(value_column_prefix(column), stream_name)
    end

    # One checked logical bound for the retained Map row schedule, physical key
    # leaf, and recursively planned Tuple values. String payload bytes include
    # keys and every value String, including bytes hidden beneath Nullable NULL.
    # This is a declared logical budget, not an RSS/peak-allocation estimate.
    def materialization_charge(
      outer_rows : UInt64,
      entries : UInt64,
      key_string_bytes : UInt64,
      value_string_bytes : UInt64,
      schedule_charge : UInt64 = 0_u64,
    ) : UInt64?
      tuple_charge = @tuple_plan.materialization_charge(entries, value_string_bytes) || return nil

      total = tuple_charge
      fixed = instance_sizeof(WideMapTupleColumnData).to_u64
      array_headers = instance_sizeof(Array(UInt64)).to_u64
      return nil if array_headers > (UInt64::MAX - fixed) // 2_u64
      fixed += array_headers * 2_u64
      fixed += instance_sizeof(WideTupleLeafColumn).to_u64
      fixed += instance_sizeof(Array(UInt8)).to_u64
      key_descriptor_charge = @key_type.logical_charge
      return nil if key_descriptor_charge > UInt64::MAX - fixed
      fixed += key_descriptor_charge
      if parameterized_type = @key_type.parameterized_type
        descriptor_charge = parameterized_type.logical_charge
        return nil if descriptor_charge > UInt64::MAX - fixed
        fixed += descriptor_charge
      end
      if datetime_type = @key_type.datetime_type
        descriptor_charge = datetime_type.logical_charge
        return nil if descriptor_charge > UInt64::MAX - fixed
        fixed += descriptor_charge
      end
      return nil if fixed > UInt64::MAX - total
      total += fixed

      # One size slot and one row-offset slot per outer row, plus the terminal
      # offset. Key storage is one exact non-Nullable scalar slot per entry.
      return nil if outer_rows > UInt64::MAX - 1_u64
      offset_slots = outer_rows + 1_u64
      return nil if outer_rows > UInt64::MAX // sizeof(UInt64).to_u64
      size_bytes = outer_rows * sizeof(UInt64).to_u64
      return nil if offset_slots > UInt64::MAX // sizeof(UInt64).to_u64
      offset_bytes = offset_slots * sizeof(UInt64).to_u64
      key_slot_width = @key_type.owned_slot_bytes
      return nil if entries > UInt64::MAX // key_slot_width
      key_bytes = entries * key_slot_width
      return nil if size_bytes > UInt64::MAX - offset_bytes
      variable_slots = size_bytes + offset_bytes
      return nil if key_bytes > UInt64::MAX - variable_slots
      variable_slots += key_bytes
      return nil if variable_slots > UInt64::MAX - total
      total += variable_slots

      return nil if key_string_bytes > UInt64::MAX - total
      total += key_string_bytes
      return nil if schedule_charge > UInt64::MAX - total
      total + schedule_charge
    end
  end
end
