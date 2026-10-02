require "./spec_helper"

describe "W122 independent explicit String size-stream profile" do
  it "stores raw byte lengths including zero and embedded NUL without terminators" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    type = CrystalClick::BinaryDataType.primitive("String")
    strings = [CrystalClick::BinaryValue.string(""), CrystalClick::BinaryValue.string("a\0b")]
    granules = [strings, [] of CrystalClick::BinaryValue]
    encoded = CrystalClick::BinaryBulkCodec.encode(type, granules, profile: profile)
    encoded.roles.sort.should eq(["root.data", "root.string_sizes"])
    encoded.stream("root.string_sizes").bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.string_sizes").offsets.should eq([0_u64, 16_u64, 16_u64])
    encoded.stream("root.data").bytes.should eq(Bytes[97, 0, 98])
    encoded.stream("root.data").offsets.should eq([0_u64, 3_u64, 3_u64])
    literal = CrystalClick::BinaryBulkStreams.new(2, {
      "root.string_sizes" => CrystalClick::BinaryBulkStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0], [0_u64, 16_u64, 16_u64]),
      "root.data"         => CrystalClick::BinaryBulkStream.new(Bytes[97, 0, 98], [0_u64, 3_u64, 3_u64]),
    })
    decoded = CrystalClick::BinaryBulkCodec.decode(type, literal, [2_u64, 0_u64], profile: profile)
    decoded[0].map(&.as_string).should eq(["", "a\0b"])
    decoded[1].should be_empty
    bad = CrystalClick::BinaryBulkStreams.new(1, {
      "root.string_sizes" => CrystalClick::BinaryBulkStream.new(Bytes[4, 0, 0, 0, 0, 0, 0, 0], [0_u64, 8_u64]),
      "root.data"         => CrystalClick::BinaryBulkStream.new(Bytes[97, 0, 98], [0_u64, 3_u64]),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, bad, [1_u64], profile: profile)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, literal, [2_u64, 0_u64])
    end
  end

  it "threads the explicit profile through nested Nullable and Array children" do
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    type = CrystalClick::BinaryDataType.array(nullable)
    # Two arrays: [], [NULL, 'a\0b']; the hidden NULL String consumes one
    # zero size but no data. These sizes are neither outer rows nor lengths
    # including a terminator.
    literal = CrystalClick::BinaryBulkStreams.new(1, {
      "root.sizes"                        => CrystalClick::BinaryBulkStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0], [0_u64, 16_u64]),
      "root.elements.nulls"               => CrystalClick::BinaryBulkStream.new(Bytes[1, 0], [0_u64, 2_u64]),
      "root.elements.nested.string_sizes" => CrystalClick::BinaryBulkStream.new(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0], [0_u64, 16_u64]),
      "root.elements.nested.data"         => CrystalClick::BinaryBulkStream.new(Bytes[97, 0, 98], [0_u64, 3_u64]),
    })
    decoded = CrystalClick::BinaryBulkCodec.decode(type, literal, [2_u64], profile: profile)
    decoded.first.first.element_count.should eq(0)
    decoded.first.last.element_at(0).is_null?.should be_true
    decoded.first.last.element_at(1).child_at(0).as_string.should eq("a\0b")
    encoded = CrystalClick::BinaryBulkCodec.encode(type, decoded, profile: profile)
    literal.roles.each do |role|
      encoded.stream(role).bytes.should eq(literal.stream(role).bytes)
      encoded.stream(role).offsets.should eq(literal.stream(role).offsets)
    end
  end
end
