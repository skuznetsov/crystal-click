require "spec"
require "../src/crystal_click/wide_part/variant_discriminator_decoder"

class CrystalClick::WidePart
  def self.w115_test_decode_variant_discriminator(
    bytes : Bytes,
    rows : UInt64,
    mode : UInt64,
    plan : WideVariantTypePlanDescriptor,
  ) : Array(UInt8)
    VariantDiscriminatorDecoder.decode(bytes, rows, mode, plan)
  end

  def self.w115_test_variant_read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
    VariantDiscriminatorDecoder.read_var_uint(bytes, offset)
  end
end

private def w115_variant_discriminator_plan : CrystalClick::WideVariantTypePlanDescriptor
  CrystalClick::WideVariantBoolStringUInt64TypePlan::DESCRIPTOR
end

private def w115_decode_variant_discriminator(
  bytes : Bytes,
  rows : UInt64,
  mode : UInt64,
) : Array(UInt8)
  CrystalClick::WidePart.w115_test_decode_variant_discriminator(
    bytes,
    rows,
    mode,
    w115_variant_discriminator_plan
  )
end

describe "WidePart standalone Variant discriminator decoder entry point" do
  it "decodes BASIC tags including NULL" do
    w115_decode_variant_discriminator(
      Bytes[0_u8, 255_u8, 1_u8],
      3_u64,
      CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
    ).should eq([0_u8, 255_u8, 1_u8])
  end

  it "decodes COMPACT mixed row tags including NULL" do
    w115_decode_variant_discriminator(
      Bytes[3_u8, 0_u8, 0_u8, 255_u8, 1_u8],
      3_u64,
      CrystalClick::WideVariantTypePlanDescriptor::MODE_COMPACT
    ).should eq([0_u8, 255_u8, 1_u8])
  end

  it "decodes COMPACT uniform tags including uniform NULL" do
    w115_decode_variant_discriminator(
      Bytes[3_u8, 1_u8, 255_u8],
      3_u64,
      CrystalClick::WideVariantTypePlanDescriptor::MODE_COMPACT
    ).should eq([255_u8, 255_u8, 255_u8])
  end

  it "rejects truncated and extra BASIC payload bytes" do
    truncated = expect_raises(CrystalClick::CorruptPartError) do
      w115_decode_variant_discriminator(
        Bytes[0_u8],
        2_u64,
        CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
      )
    end
    truncated.message.to_s.should eq("Variant BASIC discriminator is truncated")

    extra = expect_raises(CrystalClick::CorruptPartError) do
      w115_decode_variant_discriminator(
        Bytes[0_u8, 1_u8, 2_u8],
        2_u64,
        CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
      )
    end
    extra.message.to_s.should eq("Variant BASIC discriminator has extra bytes")
  end

  it "rejects mismatched and truncated COMPACT row counts" do
    mismatch = expect_raises(CrystalClick::CorruptPartError) do
      w115_decode_variant_discriminator(
        Bytes[1_u8, 0_u8, 0_u8],
        2_u64,
        CrystalClick::WideVariantTypePlanDescriptor::MODE_COMPACT
      )
    end
    mismatch.message.to_s.should eq("Variant COMPACT mark row count does not match marks")

    truncated = expect_raises(CrystalClick::CorruptPartError) do
      w115_decode_variant_discriminator(
        Bytes[128_u8],
        1_u64,
        CrystalClick::WideVariantTypePlanDescriptor::MODE_COMPACT
      )
    end
    truncated.message.to_s.should eq("Variant COMPACT mark row count is truncated")
  end

  it "rejects missing, malformed, truncated, or trailing COMPACT tag framing" do
    cases = [
      {Bytes[1_u8], 1_u64, "Variant COMPACT discriminator format is truncated"},
      {Bytes[1_u8, 0_u8], 1_u64, "Variant COMPACT discriminator tags are truncated"},
      {Bytes[1_u8, 1_u8], 1_u64, "Variant COMPACT uniform discriminator is truncated"},
      {Bytes[1_u8, 2_u8], 1_u64, "Variant COMPACT discriminator format is unsupported"},
      {Bytes[1_u8, 0_u8, 0_u8, 9_u8], 1_u64, "Variant COMPACT discriminator has extra bytes"},
    ]

    cases.each do |bytes, rows, message|
      error = expect_raises(CrystalClick::CorruptPartError) do
        w115_decode_variant_discriminator(
          bytes,
          rows,
          CrystalClick::WideVariantTypePlanDescriptor::MODE_COMPACT
        )
      end
      error.message.to_s.should eq(message)
    end
  end

  it "rejects tags outside the exact plan while allowing NULL" do
    error = expect_raises(CrystalClick::CorruptPartError) do
      w115_decode_variant_discriminator(
        Bytes[3_u8],
        1_u64,
        CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
      )
    end
    error.message.to_s.should eq("Variant discriminator tag is unsupported")

    w115_decode_variant_discriminator(
      Bytes[2_u8],
      1_u64,
      CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
    ).should eq([2_u8])

    w115_decode_variant_discriminator(
      Bytes[255_u8],
      1_u64,
      CrystalClick::WideVariantTypePlanDescriptor::MODE_BASIC
    ).should eq([255_u8])
  end

  it "preserves canonical VarUInt values and cursor positions" do
    cases = [
      {Bytes[0_u8], 0_u64},
      {Bytes[127_u8], 127_u64},
      {Bytes[128_u8, 1_u8], 128_u64},
      {Bytes[128_u8, 128_u8, 1_u8], 16_384_u64},
    ]

    cases.each do |bytes, expected|
      CrystalClick::WidePart.w115_test_variant_read_var_uint(bytes, 0).should eq({expected, bytes.size.to_i32})
    end

    maximum = Bytes[
      255_u8, 255_u8, 255_u8, 255_u8, 255_u8,
      255_u8, 255_u8, 255_u8, 255_u8, 1_u8,
    ]
    CrystalClick::WidePart.w115_test_variant_read_var_uint(maximum, 0).should eq({UInt64::MAX, 10_i32})

    prefixed = Bytes[238_u8, 128_u8, 1_u8, 170_u8]
    CrystalClick::WidePart.w115_test_variant_read_var_uint(prefixed, 1).should eq({128_u64, 3_i32})
  end

  it "preserves canonical VarUInt rejection cases and labels" do
    cases = [
      {Bytes[0_u8], -1, "Variant COMPACT mark row count is truncated"},
      {Bytes[128_u8], 0, "Variant COMPACT mark row count is truncated"},
      {Bytes[128_u8, 0_u8], 0, "Variant COMPACT mark row count is noncanonical"},
    ]

    cases.each do |bytes, offset, message|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.w115_test_variant_read_var_uint(bytes, offset)
      end
      error.message.to_s.should eq(message)
    end

    overflow = Bytes.new(10, 128_u8)
    overflow[9] = 2_u8
    overflow_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePart.w115_test_variant_read_var_uint(overflow, 0)
    end
    overflow_error.message.to_s.should eq("Variant COMPACT mark row count overflows")

    too_long = Bytes.new(11, 128_u8)
    length_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WidePart.w115_test_variant_read_var_uint(too_long, 0)
    end
    length_error.message.to_s.should eq("Variant COMPACT mark row count is too long")
  end
end
