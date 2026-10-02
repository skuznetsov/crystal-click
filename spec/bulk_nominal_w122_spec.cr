require "./spec_helper"

describe "W122 independent nominal bulk repertoire" do
  it "preserves every admitted fixed nominal leaf without host numeric conversion" do
    # Widths are authored from the physical type repertoire, not the codec.
    cases = [
      {"UInt8", 1}, {"UInt16", 2}, {"UInt32", 4}, {"UInt64", 8},
      {"UInt128", 16}, {"UInt256", 32},
      {"Int8", 1}, {"Int16", 2}, {"Int32", 4}, {"Int64", 8},
      {"Int128", 16}, {"Int256", 32}, {"Float32", 4}, {"Float64", 8},
      {"Date", 2}, {"Date32", 4}, {"Time", 4}, {"UUID", 16},
      {"IPv4", 4}, {"IPv6", 16}, {"BFloat16", 2},
    ]
    types = cases.map { |name, width| {CrystalClick::BinaryDataType.primitive(name), width} }
    types << {CrystalClick::BinaryDataType.fixed_string(3), 3}
    types << {CrystalClick::BinaryDataType.datetime, 4}
    types << {CrystalClick::BinaryDataType.datetime("UTC"), 4}
    types << {CrystalClick::BinaryDataType.datetime64(9), 8}
    types << {CrystalClick::BinaryDataType.datetime64(3, "UTC"), 8}
    types << {CrystalClick::BinaryDataType.time64(9), 8}
    types << {CrystalClick::BinaryDataType.enum8([{"low", -1_i16}, {"high", 1_i16}]), 1}
    types << {CrystalClick::BinaryDataType.enum16([{"low", -300_i16}, {"high", 300_i16}]), 2}
    [{32, 9, 4}, {64, 18, 8}, {128, 38, 16}, {256, 76, 32}].each do |bits, precision, width|
      types << {CrystalClick::BinaryDataType.decimal(bits, precision, precision), width}
    end

    types.each do |type, width|
      payload = Bytes.new(width * 2) { |index| ((index * 37 + 129) & 255).to_u8 }
      literal = CrystalClick::BinaryBulkStreams.new(3, {
        "root.data" => CrystalClick::BinaryBulkStream.new(payload, [0_u64, width.to_u64, width.to_u64, (width * 2).to_u64]),
      })
      decoded = CrystalClick::BinaryBulkCodec.decode(type, literal, [1_u64, 0_u64, 1_u64])
      decoded[1].should be_empty
      decoded[0][0].type.should eq(type)
      decoded[2][0].type.should eq(type)
      decoded[0][0].bytes.should eq(payload[0, width])
      decoded[2][0].bytes.should eq(payload[width, width])
      encoded = CrystalClick::BinaryBulkCodec.encode(type, decoded)
      encoded.stream("root.data").bytes.should eq(payload)
      encoded.stream("root.data").offsets.should eq(literal.stream("root.data").offsets)

      truncated = CrystalClick::BinaryBulkStreams.new(1, {
        "root.data" => CrystalClick::BinaryBulkStream.new(payload[0, width - 1], [0_u64, (width - 1).to_u64]),
      })
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, truncated, [1_u64])
      end
    end
  end

  it "does not alias identical-width nominal values" do
    date = CrystalClick::BinaryDataType.primitive("Date")
    value = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt16"), Bytes[1, 2])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(date, [[value]])
    end
  end

  it "keeps named Tuple fields columnar and nested Array counts independent" do
    byte = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(byte)
    type = CrystalClick::BinaryDataType.tuple([byte, array], ["escaped.name", "items"])
    literal = CrystalClick::BinaryBulkStreams.new(1, {
      "root.field.0.data"          => CrystalClick::BinaryBulkStream.new(Bytes[7, 8], [0_u64, 2_u64]),
      "root.field.1.sizes"         => CrystalClick::BinaryBulkStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0], [0_u64, 16_u64]),
      "root.field.1.elements.data" => CrystalClick::BinaryBulkStream.new(Bytes[9, 10], [0_u64, 2_u64]),
    })
    decoded = CrystalClick::BinaryBulkCodec.decode(type, literal, [2_u64]).first
    decoded[0].element_at(0).bytes.should eq(Bytes[7])
    decoded[0].element_at(1).element_count.should eq(0)
    decoded[1].element_at(0).bytes.should eq(Bytes[8])
    decoded[1].element_at(1).elements.map(&.bytes).should eq([Bytes[9], Bytes[10]])
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [decoded])
    literal.roles.each do |role|
      encoded.stream(role).bytes.should eq(literal.stream(role).bytes)
    end
  end

  it "normalizes logical Bool but preserves opaque String bytes" do
    bool = CrystalClick::BinaryDataType.primitive("Bool")
    literal = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[0, 255], [0_u64, 2_u64]),
    })
    values = CrystalClick::BinaryBulkCodec.decode(bool, literal, [2_u64])
    values.first.map(&.as_bool).should eq([false, true])
    CrystalClick::BinaryBulkCodec.encode(bool, values).stream("root.data").bytes.should eq(Bytes[0, 1])

    string = CrystalClick::BinaryDataType.primitive("String")
    raw = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[3, 255, 0, 254], [0_u64, 4_u64]),
    })
    decoded = CrystalClick::BinaryBulkCodec.decode(string, raw, [1_u64])
    decoded.first.first.as_string.to_slice.should eq(Bytes[255, 0, 254])
    CrystalClick::BinaryBulkCodec.encode(string, decoded).stream("root.data").bytes.should eq(Bytes[3, 255, 0, 254])
  end
end
