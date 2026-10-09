require "./spec_helper"

private def w240ea_runtime_json(kind : Symbol) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  child = case kind
          when :variant
            type = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
            arm = (0...type.child_count).find { |index| type.child_at(index) == uint8 }.not_nil!
            CrystalClick::BinaryValue.variant(type, arm, CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]))
          when :dynamic
            type = CrystalClick::BinaryDataType.dynamic(1)
            CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]))
          when :low_cardinality
            type = CrystalClick::BinaryDataType.low_cardinality(string)
            CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string("seven"))
          else
            raise "unrostered W240 admission adversary"
          end
  array_type = CrystalClick::BinaryDataType.array(child.type)
  array = CrystalClick::BinaryValue.array(array_type, [child] of CrystalClick::BinaryValue)
  json_type = CrystalClick::BinaryDataType.json
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [{"x", array}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

describe "W240 root-authored shared JSON admission adversaries" do
  {:variant, :dynamic, :low_cardinality}.each do |kind|
    it "does not admit #{kind} hidden inside a JSON runtime container on write" do
      value = w240ea_runtime_json(kind)
      # These are legal existing scalar JSON values. Their admission here
      # must not widen the narrower shared MAP envelope policy by accident.
      wire = CrystalClick::BinaryValueCodec.encode(value)
      decoded = CrystalClick::BinaryValueCodec.decode(wire)
      CrystalClick::BinaryValueCodec.encode(decoded).should eq(wire)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
          value,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        )
      end
    end

    it "does not admit #{kind} hidden inside independently framed JSON on read" do
      value = w240ea_runtime_json(kind)
      envelope = CrystalClick::BinaryValueCodec.encode(value)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
          envelope,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end
    end
  end
end
