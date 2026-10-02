require "./spec_helper"

W114_VARIANT_COMPACT_PART = File.expand_path("../test/fixtures/public/wide_variant_w56/compact/part", __DIR__)

class CrystalClick::WidePart
  # Test-only bridge for characterizing the currently private decoder before
  # its production extraction.
  def w114_test_variant_read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
    variant_read_var_uint(bytes, offset)
  end
end

private def w114_variant_reader : CrystalClick::WidePart
  CrystalClick::WidePart.open_typed(W114_VARIANT_COMPACT_PART, "payload")
end

describe "W114 Variant discriminator varuint characterization" do
  it "decodes canonical boundaries with the cursor after the encoding" do
    reader = w114_variant_reader
    cases = [
      {Bytes[0x00_u8], 0_u64},
      {Bytes[0x7f_u8], 127_u64},
      {Bytes[0x80_u8, 0x01_u8], 128_u64},
      {Bytes[0x80_u8, 0x80_u8, 0x01_u8], 16_384_u64},
    ]

    cases.each do |bytes, expected|
      reader.w114_test_variant_read_var_uint(bytes, 0).should eq({expected, bytes.size.to_i32})
    end
  end

  it "decodes UInt64::MAX and preserves a nonzero starting offset" do
    reader = w114_variant_reader
    maximum = Bytes[
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x01_u8,
    ]
    reader.w114_test_variant_read_var_uint(maximum, 0).should eq({UInt64::MAX, 10_i32})

    prefixed = Bytes[0xee_u8, 0x80_u8, 0x01_u8, 0xaa_u8]
    reader.w114_test_variant_read_var_uint(prefixed, 1).should eq({128_u64, 3_i32})
  end

  it "rejects negative offsets and truncated encodings with the current labels" do
    reader = w114_variant_reader

    negative = expect_raises(CrystalClick::CorruptPartError) do
      reader.w114_test_variant_read_var_uint(Bytes[0x00_u8], -1)
    end
    negative.message.to_s.should eq("Variant COMPACT mark row count is truncated")

    truncated = expect_raises(CrystalClick::CorruptPartError) do
      reader.w114_test_variant_read_var_uint(Bytes[0x80_u8], 0)
    end
    truncated.message.to_s.should eq("Variant COMPACT mark row count is truncated")
  end

  it "rejects tenth-byte overflow and encodings longer than ten bytes" do
    reader = w114_variant_reader
    overflow = Bytes.new(10, 0x80_u8)
    overflow[9] = 0x02_u8
    overflow_error = expect_raises(CrystalClick::CorruptPartError) do
      reader.w114_test_variant_read_var_uint(overflow, 0)
    end
    overflow_error.message.to_s.should eq("Variant COMPACT mark row count overflows")

    too_long = Bytes.new(11, 0x80_u8)
    length_error = expect_raises(CrystalClick::CorruptPartError) do
      reader.w114_test_variant_read_var_uint(too_long, 0)
    end
    length_error.message.to_s.should eq("Variant COMPACT mark row count is too long")
  end

  it "rejects noncanonical encodings with a zero terminal payload" do
    reader = w114_variant_reader
    error = expect_raises(CrystalClick::CorruptPartError) do
      reader.w114_test_variant_read_var_uint(Bytes[0x80_u8, 0x00_u8], 0)
    end
    error.message.to_s.should eq("Variant COMPACT mark row count is noncanonical")
  end
end
