require "./spec_helper"

module LZ4SpecFixture
  def self.match_block(literals : Bytes, distance : Int, match_length : Int, tail = Bytes.empty) : Bytes
    raise "fixture distance must fit the literal seed" unless distance > 0 && distance <= literals.size
    raise "fixture match must contain at least four bytes" unless match_length >= 4

    literal_nibble = literals.size < 15 ? literals.size : 15
    match_nibble = match_length < 19 ? match_length - 4 : 15
    encoded = [] of UInt8
    encoded << ((literal_nibble << 4) | match_nibble).to_u8
    append_extension(encoded, literals.size - 15) if literal_nibble == 15
    literals.each { |byte| encoded << byte }
    encoded << (distance & 0xff).to_u8
    encoded << ((distance >> 8) & 0xff).to_u8
    append_extension(encoded, match_length - 19) if match_nibble == 15

    unless tail.empty?
      tail_nibble = tail.size < 15 ? tail.size : 15
      encoded << (tail_nibble << 4).to_u8
      append_extension(encoded, tail.size - 15) if tail_nibble == 15
      tail.each { |byte| encoded << byte }
    end

    Bytes.new(encoded.size) { |index| encoded[index] }
  end

  def self.expected_periodic(seed : Bytes, match_length : Int, tail = Bytes.empty) : Bytes
    raise "fixture seed must not be empty" if seed.empty?

    expected = Bytes.new(seed.size + match_length + tail.size)
    expected[0, seed.size].copy_from(seed)
    match_length.times do |index|
      expected[seed.size + index] = seed[index % seed.size]
    end
    expected[seed.size + match_length, tail.size].copy_from(tail) unless tail.empty?
    expected
  end

  private def self.append_extension(encoded : Array(UInt8), length : Int)
    remaining = length
    while remaining >= 255
      encoded << 255_u8
      remaining -= 255
    end
    encoded << remaining.to_u8
  end
end

describe CrystalClick::LZ4 do
  it "decodes literals and overlapping matches" do
    # Token: one literal ('a'), one match of length 6 at distance 1.
    input = Bytes[0x12, 0x61, 0x01, 0x00]
    CrystalClick::LZ4.decode(input, 7).should eq(Bytes[0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61])
  end

  it "copies non-overlapping matches and forward matches at distances one through three" do
    prefix = Bytes[0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48]
    input = LZ4SpecFixture.match_block(prefix, prefix.size, 5)
    CrystalClick::LZ4.decode(input, 13).should eq(Bytes[0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x41, 0x42, 0x43, 0x44, 0x45])

    {Bytes[0x41], Bytes[0x42, 0x43], Bytes[0x58, 0x59, 0x5a]}.each do |seed|
      match_length = 73
      expected = LZ4SpecFixture.expected_periodic(seed, match_length)
      input = LZ4SpecFixture.match_block(seed, seed.size, match_length)
      CrystalClick::LZ4.decode(input, expected.size).should eq(expected)
    end
  end

  it "preserves periodic matches below, at, and above word and block width boundaries" do
    {7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129}.each do |distance|
      seed = Bytes.new(distance) { |index| (33 + index).to_u8 }
      {distance - 1, distance, distance + 5}.each do |match_length|
        expected = LZ4SpecFixture.expected_periodic(seed, match_length)
        input = LZ4SpecFixture.match_block(seed, distance, match_length)
        CrystalClick::LZ4.decode(input, expected.size).should eq(expected)
      end
    end
  end

  it "decodes extended lengths across multiple copy blocks and a trailing literal sequence" do
    seed = Bytes[0x61, 0x62, 0x63]
    tail = Bytes[0x58, 0x59, 0x5a]
    match_length = 521
    expected = LZ4SpecFixture.expected_periodic(seed, match_length, tail)
    input = LZ4SpecFixture.match_block(seed, 3, match_length, tail)

    CrystalClick::LZ4.decode(input, expected.size).should eq(expected)
  end

  it "writes only the exact destination sub-slice" do
    seed = Bytes[0x61, 0x62, 0x63]
    match_length = 79
    expected = LZ4SpecFixture.expected_periodic(seed, match_length)
    input = LZ4SpecFixture.match_block(seed, 3, match_length)
    storage = Bytes.new(expected.size + 2, 0xee_u8)
    destination = storage[1, expected.size]

    result = CrystalClick::LZ4.decode_into(input, destination, expected.size)

    result.size.should eq(expected.size)
    result.should eq(expected)
    storage[0].should eq(0xee_u8)
    storage[-1].should eq(0xee_u8)
  end

  it "rejects literal and match output overruns before copying the overrun" do
    storage = Bytes.new(3, 0xa5_u8)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode_into(Bytes[0x20, 0x41, 0x42], storage[1, 1], 1)
    end
    storage.should eq(Bytes[0xa5, 0xa5, 0xa5])

    match_storage = Bytes.new(7, 0xa5_u8)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode_into(Bytes[0x10, 0x41, 0x01, 0x00], match_storage[2, 4], 4)
    end
    match_storage.should eq(Bytes[0xa5, 0xa5, 0x41, 0xa5, 0xa5, 0xa5, 0xa5])
  end

  it "rejects zero and out-of-range match distances" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode(Bytes[0x10, 0x41, 0x00, 0x00], 5)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode(Bytes[0x10, 0x41, 0x02, 0x00], 5)
    end
  end

  it "rejects truncated literals, offsets, and extended lengths" do
    {Bytes[0x20], Bytes[0x10, 0x41, 0x01], Bytes[0xf0], Bytes[0x1f, 0x41, 0x01, 0x00]}.each do |input|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::LZ4.decode(input, 32)
      end
    end
  end

  it "rejects an output-size mismatch" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode(Bytes[0x10, 0x61], 2)
    end
  end
end
