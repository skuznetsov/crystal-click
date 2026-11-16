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

  def self.expected_match(literals : Bytes, distance : Int, match_length : Int) : Bytes
    raise "fixture distance must fit the literal seed" unless distance > 0 && distance <= literals.size
    raise "fixture match must contain at least four bytes" unless match_length >= 4

    expected = Bytes.new(literals.size + match_length)
    expected[0, literals.size].copy_from(literals)
    match_length.times do |index|
      expected[literals.size + index] = expected[literals.size + index - distance]
    end
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

  it "decodes into padded capacity without changing short-literal or sequential-token semantics" do
    # The first three literals have at least eight bytes remaining in the exact
    # compressed range. The following match must replace any speculative tail
    # bytes before the second token appends its final literals.
    encoded = Bytes[0x32, 0x61, 0x62, 0x63, 0x03, 0x00, 0x30, 0x78, 0x79, 0x7a]
    input_storage = Bytes.new(encoded.size + 2, 0xee_u8)
    input_storage[1, encoded.size].copy_from(encoded)
    input = Bytes.new(input_storage[1, encoded.size].to_unsafe, encoded.size, read_only: true)
    expected = Bytes[0x61, 0x62, 0x63, 0x61, 0x62, 0x63, 0x61, 0x62, 0x63, 0x78, 0x79, 0x7a]
    output_storage = Bytes.new(expected.size + CrystalClick::LZ4::PADDING_SIZE + 33, 0xee_u8)
    output = output_storage[17, expected.size + CrystalClick::LZ4::PADDING_SIZE]

    result = CrystalClick::LZ4.decode_into_padded(input, output, expected.size)

    CrystalClick::LZ4::PADDING_SIZE.should eq(7)
    result.size.should eq(expected.size)
    result.to_unsafe.should eq(output.to_unsafe)
    result.should eq(expected)
    input_storage[0].should eq(0xee_u8)
    input_storage[-1].should eq(0xee_u8)
    output_storage[0, 17].should eq(Bytes.new(17, 0xee_u8))
    output_storage[17 + output.size, output_storage.size - 17 - output.size].should eq(Bytes.new(16, 0xee_u8))
  end

  it "keeps padded match copies correct below, at, and above the eight-byte distance boundary" do
    {7, 8, 9}.each do |distance|
      seed = Bytes.new(distance) { |index| (0x31 + index).to_u8 }
      {4, 8, 17}.each do |match_length|
        expected = LZ4SpecFixture.expected_periodic(seed, match_length)
        encoded = LZ4SpecFixture.match_block(seed, distance, match_length)
        guard_size = 16
        output_storage = Bytes.new(guard_size + expected.size + CrystalClick::LZ4::PADDING_SIZE + guard_size, 0xee_u8)
        output = output_storage[guard_size, expected.size + CrystalClick::LZ4::PADDING_SIZE]

        result = CrystalClick::LZ4.decode_into_padded(encoded, output, expected.size)

        result.size.should eq(expected.size)
        result.should eq(expected)
        output_storage[0, guard_size].should eq(Bytes.new(guard_size, 0xee_u8))
        output_storage[guard_size + output.size, guard_size].should eq(Bytes.new(guard_size, 0xee_u8))
      end
    end
  end

  it "requires writable output with seven padding bytes and preserves corruption checks" do
    input = Bytes[0x10, 0x61]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::LZ4.decode_into_padded(input, Bytes.new(1 + CrystalClick::LZ4::PADDING_SIZE), 2)
    end

    read_only_storage = Bytes.new(2 + CrystalClick::LZ4::PADDING_SIZE)
    read_only_output = Bytes.new(read_only_storage.to_unsafe, read_only_storage.size, read_only: true)
    expect_raises(CrystalClick::BoundsError) do
      CrystalClick::LZ4.decode_into_padded(input, read_only_output, 2)
    end

    {Bytes[0x20, 0x41], Bytes[0x10, 0x41, 0x01], Bytes[0xf0], Bytes[0x10, 0x41, 0x00, 0x00], Bytes[0x10, 0x41]}.each do |malformed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::LZ4.decode_into_padded(malformed, Bytes.new(40 + CrystalClick::LZ4::PADDING_SIZE), 40)
      end
    end
  end

  it "copies zero through five literal bytes exactly at unaligned slice edges" do
    {0, 1, 2, 3, 4, 5}.each do |length|
      literals = Bytes.new(length) { |index| (0x31 + index).to_u8 }
      encoded = Bytes.new(length + 1)
      encoded[0] = (length << 4).to_u8
      encoded[1, length].copy_from(literals) unless literals.empty?

      input_storage = Bytes.new(encoded.size + 2, 0xee_u8)
      input_storage[1, encoded.size].copy_from(encoded)
      input = input_storage[1, encoded.size]
      output_storage = Bytes.new(length + 2, 0xee_u8)
      output = output_storage[1, length]

      CrystalClick::LZ4.decode_into(input, output, length).should eq(literals)
      output_storage[0].should eq(0xee_u8)
      output_storage[-1].should eq(0xee_u8)
      input_storage[0].should eq(0xee_u8)
      input_storage[-1].should eq(0xee_u8)
    end
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

  it "copies each short disjoint match width at unaligned offsets without touching sink guards" do
    literals = Bytes[0x13, 0x2b, 0x47, 0x5d, 0x62, 0x7e, 0x8b, 0x91, 0xa7, 0xb3, 0xc5, 0xd9, 0xe1]
    guard_size = 16
    guard = Bytes.new(guard_size, 0xee_u8)

    {4, 5, 6, 7}.each do |match_length|
      {match_length, match_length + 3}.each do |distance|
        expected = LZ4SpecFixture.expected_match(literals, distance, match_length)
        input = LZ4SpecFixture.match_block(literals, distance, match_length)
        storage = Bytes.new(expected.size + (guard_size * 2), 0xee_u8)
        destination = storage[guard_size, expected.size]

        result = CrystalClick::LZ4.decode_into(input, destination, expected.size)

        result.size.should eq(expected.size)
        result.should eq(expected)
        storage[0, guard_size].should eq(guard)
        storage[guard_size + expected.size, guard_size].should eq(guard)
      end
    end
  end

  it "keeps one-byte-overlapping short matches on the overlap-safe path" do
    literals = Bytes[0x13, 0x2b, 0x47, 0x5d, 0x62, 0x7e, 0x8b, 0x91, 0xa7, 0xb3, 0xc5, 0xd9, 0xe1]

    {4, 5, 6, 7}.each do |match_length|
      distance = match_length - 1
      expected = LZ4SpecFixture.expected_match(literals, distance, match_length)
      input = LZ4SpecFixture.match_block(literals, distance, match_length)

      CrystalClick::LZ4.decode(input, expected.size).should eq(expected)
    end
  end

  it "keeps an unaligned eight-byte disjoint match on the general copy path" do
    literals = Bytes[0x13, 0x2b, 0x47, 0x5d, 0x62, 0x7e, 0x8b, 0x91, 0xa7, 0xb3, 0xc5, 0xd9, 0xe1]
    match_length = 8
    distance = 8
    expected = LZ4SpecFixture.expected_match(literals, distance, match_length)
    input = LZ4SpecFixture.match_block(literals, distance, match_length)
    guard_size = 16
    guard = Bytes.new(guard_size, 0xee_u8)
    storage = Bytes.new(expected.size + (guard_size * 2), 0xee_u8)
    destination = storage[guard_size, expected.size]

    result = CrystalClick::LZ4.decode_into(input, destination, expected.size)

    result.should eq(expected)
    storage[0, guard_size].should eq(guard)
    storage[guard_size + expected.size, guard_size].should eq(guard)
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
