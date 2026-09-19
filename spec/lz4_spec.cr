require "./spec_helper"

describe CrystalClick::LZ4 do
  it "decodes literals and overlapping matches" do
    # Token: one literal ('a'), one match of length 6 at distance 1.
    input = Bytes[0x12, 0x61, 0x01, 0x00]
    CrystalClick::LZ4.decode(input, 7).should eq(Bytes[0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61])
  end

  it "rejects an output-size mismatch" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode(Bytes[0x10, 0x61], 2)
    end
  end

  it "rejects a match that runs past the input" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode(Bytes[0x10, 0x61, 0x00, 0x00], 2)
    end
  end
end
