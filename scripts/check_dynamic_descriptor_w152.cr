require "../src/crystal_click"

module W152DescriptorEmitter
  def self.emit(label : String, type : CrystalClick::BinaryDataType) : Nil
    descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
    decoded = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    unless decoded == type && decoded.name == type.name &&
           CrystalClick::BinaryDataTypeCodec.encode(decoded) == descriptor
      raise "W152 library descriptor round trip failed for #{label}"
    end
    puts "#{label}\t#{type.name}\t#{descriptor.hexstring.upcase}"
  end

  def self.run : Nil
    (0..254).each do |max_types|
      type = CrystalClick::BinaryDataType.dynamic(max_types)
      expected_name = max_types == 32 ? "Dynamic" : "Dynamic(max_types=#{max_types})"
      unless type.dynamic_max_types.not_nil! == max_types.to_u8 && type.name == expected_name
        raise "W152 Dynamic factory metadata differs at cap #{max_types}"
      end
      emit("cap:#{max_types}", type)
    end

    default_type = CrystalClick::BinaryDataType.dynamic
    explicit_default = CrystalClick::BinaryDataType.dynamic(32)
    other_cap = CrystalClick::BinaryDataType.dynamic(33)
    unless default_type == explicit_default && default_type.hash == explicit_default.hash &&
           default_type.hash != other_cap.hash &&
           default_type != other_cap && Set{default_type, explicit_default, other_cap}.size == 2
      raise "W152 local nominal equality/hash does not retain the Dynamic cap"
    end

    string = CrystalClick::BinaryDataType.primitive("String")
    emit("wrapper:array0", CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(0)))
    emit("wrapper:tuple1", CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.dynamic(1)] of CrystalClick::BinaryDataType,
      ["x"] of String
    ))
    emit("wrapper:map32", CrystalClick::BinaryDataType.map(string, CrystalClick::BinaryDataType.dynamic(32)))
    emit("wrapper:nullable_tuple254", CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple(
        [CrystalClick::BinaryDataType.dynamic(254)] of CrystalClick::BinaryDataType,
        ["x"] of String
      )
    ))
  end
end

W152DescriptorEmitter.run
