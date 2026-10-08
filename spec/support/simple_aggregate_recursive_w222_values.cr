module CrystalClick::SimpleAggregateRecursiveW222Values
  extend self

  SOURCES = [
    "SimpleAggregateFunction(groupArrayArray, Array(Int32))",
    "SimpleAggregateFunction(sumMap, Tuple(Array(Int32), Array(Int64)))",
    "SimpleAggregateFunction(minMap, Tuple(Array(Int32), Array(Int64)))",
    "SimpleAggregateFunction(maxMap, Tuple(Array(Int32), Array(Int64)))",
    "SimpleAggregateFunction(groupUniqArrayArrayMap, Map(Int32, Array(Int64)))",
    "SimpleAggregateFunction(groupArrayLastArray(5), Array(UInt64))",
    "SimpleAggregateFunction(anyLast, Array(Int16))",
  ] of String

  def type(source : String) : BinaryDataType
    SimpleAggregateBulkColumnDeclaration.parse(source) ||
      raise "W222 static recursive declaration was not admitted: #{source}"
  end

  # Build values only from the exact child descriptors owned by the parsed
  # declaration. The row patterns include empty and non-empty child lanes.
  def value(type : BinaryDataType, row_index : Int32) : BinaryValue
    aggregate_type = if type.tag == BinaryDataType::TAG_NULLABLE
                       type.child_at(0)
                     else
                       type
                     end
    unless aggregate_type.tag == BinaryDataType::TAG_SIMPLE_AGGREGATE
      raise ArgumentError.new("W222 value requires a root SAF or outer Nullable(SAF)")
    end

    storage_type = aggregate_type.child_at(0)
    storage_value = case storage_type.tag
                    when BinaryDataType::TAG_ARRAY
                      array(storage_type, row_index, 0)
                    when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
                      tuple(storage_type, row_index)
                    when BinaryDataType::TAG_MAP
                      map(storage_type, row_index)
                    else
                      raise ArgumentError.new("W222 source roster has an unexpected storage child")
                    end
    wrapped = BinaryValue.simple_aggregate(aggregate_type, storage_value)
    type.tag == BinaryDataType::TAG_NULLABLE ? BinaryValue.nullable(type, wrapped) : wrapped
  end

  def granules(type : BinaryDataType) : Array(Array(BinaryValue))
    # Five rows at a 2,2,1 mark grid exercise a final short mark.
    Array(Array(BinaryValue)).new(3) do |mark_index|
      row_count = mark_index == 2 ? 1 : 2
      Array(BinaryValue).new(row_count) do |row_offset|
        value(type, mark_index * 2 + row_offset)
      end
    end
  end

  def signature(value : BinaryValue) : String
    if value.is_null?
      return "#{value.type.name}=NULL"
    end

    recursive = case value.type.tag
                when BinaryDataType::TAG_SIMPLE_AGGREGATE, BinaryDataType::TAG_NULLABLE,
                     BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_UNNAMED_TUPLE,
                     BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
                  true
                else
                  false
                end
    if recursive
      "#{value.type.name}[#{value.elements.map { |child| signature(child) }.join(";")}]"
    else
      "#{value.type.name}:#{value.bytes.to_a.join(",")}"
    end
  end

  def signature_grid(granules : Array(Array(BinaryValue))) : Array(Array(String))
    granules.map do |mark|
      mark.map { |row| signature(row) }
    end
  end

  private def array(type : BinaryDataType, row_index : Int32, lane : Int32) : BinaryValue
    count = row_index % 3
    element_type = type.child_at(0)
    elements = Array(BinaryValue).new(count) do |element_index|
      fixed(element_type, (row_index * 100 + lane * 10 + element_index + 1).to_u64)
    end
    BinaryValue.array(type, elements)
  end

  private def tuple(type : BinaryDataType, row_index : Int32) : BinaryValue
    unless type.child_count == 2 && type.child_at(0).tag == BinaryDataType::TAG_ARRAY &&
           type.child_at(1).tag == BinaryDataType::TAG_ARRAY
      raise ArgumentError.new("W222 tuple source roster must contain two Array fields")
    end
    fields = [array(type.child_at(0), row_index, 1), array(type.child_at(1), row_index, 2)] of BinaryValue
    BinaryValue.tuple(type, fields)
  end

  private def map(type : BinaryDataType, row_index : Int32) : BinaryValue
    unless type.child_at(1).tag == BinaryDataType::TAG_ARRAY
      raise ArgumentError.new("W222 map source roster must have Array values")
    end
    entries = [] of BinaryValue
    # Include an empty Map row and rows with two key/value pairs. Array values
    # vary independently, including empty value arrays.
    if row_index > 0
      2.times do |entry_index|
        key = (row_index * 10 + entry_index + 1).to_u64
        entries << fixed(type.child_at(0), key)
        entries << array(type.child_at(1), row_index + entry_index, 3)
      end
    end
    BinaryValue.map(type, entries)
  end

  private def fixed(type : BinaryDataType, value : UInt64) : BinaryValue
    width = type.fixed_width || raise ArgumentError.new("W222 scalar child is not fixed width")
    bytes = Bytes.new(width) do |index|
      ((value >> (8 * index)) & 0xff_u64).to_u8
    end
    BinaryValue.fixed(type, bytes)
  end
end
