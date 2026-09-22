require "./spec_helper"

private def delta_neon_write_u64(bytes : Bytes, offset : Int, value : UInt64)
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def delta_neon_words(values : Array(UInt64), offset : Int = 0) : Bytes
  bytes = Bytes.new(offset + values.size * 8 + 3, 0_u8)
  values.each_with_index do |value, index|
    delta_neon_write_u64(bytes, offset + index * 8, value)
  end
  bytes[offset, values.size * 8]
end

private def delta_neon_expected(deltas : Array(UInt64), initial : UInt64 = 0_u64) : Array(UInt64)
  accumulator = initial
  deltas.map do |delta|
    accumulator = accumulator &+ delta
  end
end

private def delta_neon_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

describe "UInt64 Delta decode backend" do
  it "matches wrapping prefix sums for block and tail lengths" do
    [1, 2, 3, 7, 8, 15, 16, 17, 31, 32, 33].each do |count|
      deltas = Array(UInt64).new(count) do |index|
        case index % 5
        when 0
          UInt64::MAX
        when 1
          1_u64
        when 2
          0x0102_0304_0506_0708_u64
        when 3
          17_u64
        else
          UInt64::MAX - 3_u64
        end
      end
      initial = 0xfeed_face_cafe_beef_u64
      input = delta_neon_words(deltas, 1)
      output_storage = Bytes.new(3 + count * 8 + 2, 0_u8)
      output = output_storage[3, count * 8]

      last = CrystalClick::CompressedBlock.decode_delta_words(input, output, count, initial)

      output_values = Array(UInt64).new(count) do |index|
        delta_neon_read_u64(output, index * 8)
      end
      output_values.should eq(delta_neon_expected(deltas, initial))
      last.should eq(output_values.last)
    end
  end

  it "preserves UInt64 wraparound from a nonzero accumulator" do
    deltas = [UInt64::MAX, 1_u64, UInt64::MAX, 2_u64]
    input = delta_neon_words(deltas)
    output = Bytes.new(deltas.size * 8)

    last = CrystalClick::CompressedBlock.decode_delta_words(input, output, deltas.size, 7_u64)

    expected = [6_u64, 7_u64, 6_u64, 8_u64]
    deltas.size.times do |index|
      delta_neon_read_u64(output, index * 8).should eq(expected[index])
    end
    last.should eq(expected.last)
  end

  it "supports unaligned input and output byte slices" do
    deltas = [1_u64, 2_u64, 3_u64, 5_u64, 8_u64, 13_u64, 21_u64]
    input = delta_neon_words(deltas, 1)
    output_storage = Bytes.new(deltas.size * 8 + 5, 0_u8)
    output = output_storage[3, deltas.size * 8]

    CrystalClick::CompressedBlock.decode_delta_words(input, output, deltas.size)

    deltas.size.times do |index|
      delta_neon_read_u64(output, index * 8).should eq(delta_neon_expected(deltas)[index])
    end
  end

  it "keeps the existing forward-overlap in-place path safe" do
    deltas = [3_u64, 5_u64, UInt64::MAX, 9_u64, 11_u64, 13_u64, 17_u64]
    storage = Bytes.new(11 + deltas.size * 8 + 4, 0_u8)
    input = delta_neon_words(deltas, 11)
    input.copy_to(storage[11, deltas.size * 8])
    words = storage[11, deltas.size * 8]
    output = storage[0, deltas.size * 8]

    last = CrystalClick::CompressedBlock.decode_delta_words(words, output, deltas.size)

    expected = delta_neon_expected(deltas)
    deltas.size.times do |index|
      delta_neon_read_u64(output, index * 8).should eq(expected[index])
    end
    last.should eq(expected.last)
  end

  it "keeps destination-after-source overlap safe with a backward fallback" do
    deltas = [0x0102_0304_0506_0708_u64, 2_u64, UInt64::MAX, 4_u64, 8_u64]
    storage = Bytes.new(3 + deltas.size * 8, 0_u8)
    input = delta_neon_words(deltas)
    input.copy_to(storage[0, deltas.size * 8])
    words = storage[0, deltas.size * 8]
    output = storage[3, deltas.size * 8]

    last = CrystalClick::CompressedBlock.decode_delta_words(words, output, deltas.size)

    expected = delta_neon_expected(deltas)
    deltas.size.times do |index|
      delta_neon_read_u64(output, index * 8).should eq(expected[index])
    end
    last.should eq(expected.last)
  end

  it "returns the initial accumulator for an empty word range" do
    initial = 0xfeed_face_cafe_beef_u64
    CrystalClick::CompressedBlock.decode_delta_words(Bytes.new(0), Bytes.new(0), 0, initial).should eq(initial)
  end

  it "rejects a negative count and prevalidated-size violations" do
    input = Bytes.new(8)
    output = Bytes.new(8)

    expect_raises(ArgumentError) do
      CrystalClick::CompressedBlock.decode_delta_words(input, output, -1)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedBlock.decode_delta_words(input[0, 7], output, 1)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedBlock.decode_delta_words(input, output[0, 7], 1)
    end
  end
end
