module AggregateBitwiseW255Values
  FUNCTIONS     = ["groupBitAnd", "groupBitOr", "groupBitXor"] of String
  INTEGER_TYPES = [
    {"UInt8", 1}, {"UInt16", 2}, {"UInt32", 4}, {"UInt64", 8},
    {"UInt128", 16}, {"UInt256", 32},
    {"Int8", 1}, {"Int16", 2}, {"Int32", 4}, {"Int64", 8},
    {"Int128", 16}, {"Int256", 32},
  ] of Tuple(String, Int32)

  def self.pattern(width : Int32, seed : UInt8) : Bytes
    Bytes.new(width) do |index|
      ((seed.to_i32 + index * 37) & 0xff).to_u8
    end
  end

  def self.join(parts : Array(Bytes)) : Bytes
    size = parts.sum(&.size)
    result = Bytes.new(size)
    offset = 0
    parts.each do |part|
      part.size.times { |index| result[offset + index] = part[index] }
      offset += part.size
    end
    result
  end

  def self.var_uint(value : UInt64) : Bytes
    bytes = Bytes.new(10, 0_u8)
    remaining = value
    count = 0
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      byte |= 0x80_u8 unless remaining == 0_u64
      bytes[count] = byte
      count += 1
      break if remaining == 0_u64
    end
    Bytes.new(count) { |index| bytes[index] }
  end

  def self.function_wire(
    function_name : String,
    argument_wire : Bytes,
    version : UInt64 = 0_u64,
    parameter_count : UInt64 = 0_u64,
    argument_count : UInt64 = 1_u64,
  ) : Bytes
    name = Bytes.new(function_name.bytesize) { |index| function_name.to_slice[index] }
    join([
      Bytes[CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION],
      var_uint(version),
      var_uint(name.size.to_u64),
      name,
      var_uint(parameter_count),
      var_uint(argument_count),
      argument_wire,
    ] of Bytes)
  end

  def self.state(type : CrystalClick::BinaryDataType, seed : UInt8) : CrystalClick::BinaryValue
    width = CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type).state_width
    CrystalClick::BinaryValue.aggregate_function_state(type, pattern(width, seed))
  end
end
