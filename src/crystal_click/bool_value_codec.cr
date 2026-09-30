module CrystalClick
  # Shared semantic codec for Bool payload values. Structural Bool-like bytes
  # such as null maps and Variant tags are validated by their own owners.
  module BoolValueCodec
    def self.decode(byte : UInt8) : Bool
      byte != 0_u8
    end

    def self.encode(value : Bool) : UInt8
      value ? 1_u8 : 0_u8
    end

    def self.decode_values(bytes : Bytes) : Array(Bool)
      Array(Bool).new(bytes.size) { |index| decode(bytes[index]) }
    end
  end
end
